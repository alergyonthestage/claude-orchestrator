// Package proxy implements the HTTP reverse proxy for Docker socket filtering.
package proxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/claude-orchestrator/proxy/internal/cache"
	"github.com/claude-orchestrator/proxy/internal/config"
	"github.com/claude-orchestrator/proxy/internal/filter"
)

// Proxy is the Docker socket filtering proxy.
type Proxy struct {
	policy          *config.Policy
	cache           *cache.Cache
	containerFilter *filter.ContainerFilter
	mountFilter     *filter.MountFilter
	securityFilter  *filter.SecurityFilter
	reverseProxy    *httputil.ReverseProxy
	logDenied       bool
	containerCount  atomic.Int32
	trackedIDs      sync.Map // tracks container IDs created/counted by this proxy
}

// New creates a new proxy with the given policy and upstream socket.
func New(policy *config.Policy, upstreamSocket string, logDenied bool) *Proxy {
	p := &Proxy{
		policy:          policy,
		cache:           cache.New(upstreamSocket),
		containerFilter: filter.NewContainerFilter(policy),
		mountFilter:     filter.NewMountFilter(policy),
		securityFilter:  filter.NewSecurityFilter(policy),
		logDenied:       logDenied,
	}

	// Configure reverse proxy to upstream Docker socket
	director := func(req *http.Request) {
		req.URL.Scheme = "http"
		req.URL.Host = "localhost"
	}

	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return net.DialTimeout("unix", upstreamSocket, 5*time.Second)
		},
	}

	p.reverseProxy = &httputil.ReverseProxy{
		Director:  director,
		Transport: transport,
	}

	return p
}

// Init populates the container cache on startup.
func (p *Proxy) Init(ctx context.Context) error {
	if err := p.cache.Refresh(); err != nil {
		log.Printf("warning: initial cache refresh failed: %v", err)
	}

	// Reconcile container count with cache state
	p.reconcileCount()

	// Periodic refresh with count reconciliation
	p.cache.StartPeriodicRefresh(ctx, 30*time.Second)
	go p.periodicReconcile(ctx, 30*time.Second)

	return nil
}

// reconcileCount synchronizes containerCount and trackedIDs with the actual
// cache state. This handles containers removed outside the proxy (host cleanup,
// Docker pruning, crashes) that would otherwise cause count drift.
func (p *Proxy) reconcileCount() {
	allContainers := p.cache.All()

	// Build set of live container IDs that are allowed by policy
	liveIDs := make(map[string]bool)
	for _, info := range allContainers {
		if p.containerFilter.IsAllowed(info) {
			liveIDs[info.ID] = true
		}
	}

	// Remove tracked IDs that no longer exist in the cache
	p.trackedIDs.Range(func(key, _ interface{}) bool {
		id, ok := key.(string)
		if !ok {
			return true
		}
		// trackedIDs stores both IDs and names; only check IDs (64-char hex)
		if len(id) == 64 && !liveIDs[id] {
			p.trackedIDs.Delete(id)
		}
		return true
	})

	// Recount: number of live containers that are tracked by us
	var count int32
	for id := range liveIDs {
		if _, tracked := p.trackedIDs.Load(id); tracked {
			count++
		}
	}

	// Also count containers that match policy but weren't tracked yet (pre-existing)
	for id := range liveIDs {
		if _, tracked := p.trackedIDs.Load(id); !tracked {
			p.trackedIDs.Store(id, true)
			count++
		}
	}

	p.containerCount.Store(count)
}

func (p *Proxy) periodicReconcile(ctx context.Context, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			p.reconcileCount()
		}
	}
}

// ServeHTTP implements the http.Handler interface.
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	path := cleanPath(r.URL.Path)

	// Always allow: ping, version, system info
	if isAlwaysAllowed(path) {
		p.forward(w, r)
		return
	}

	// Route-based filtering
	switch {
	case isContainerCreate(r.Method, path):
		p.handleContainerCreate(w, r)
	case isContainerList(r.Method, path):
		p.handleContainerList(w, r)
	case isContainerOp(r.Method, path):
		p.handleContainerOp(w, r, path)
	case isContainerDelete(r.Method, path):
		p.handleContainerDelete(w, r, path)
	case isExecOp(r.Method, path):
		// Exec endpoints (/exec/{id}/start, /exec/{id}/resize, /exec/{id}/json).
		// The exec instance was created via POST /containers/{id}/exec which is
		// already validated by handleContainerOp.  Allow the follow-up exec ops.
		p.forward(w, r)
	case isNetworkCreate(r.Method, path):
		p.handleNetworkCreate(w, r)
	case isNetworkConnect(r.Method, path):
		p.handleNetworkConnect(w, r, path)
	case isNetworkList(r.Method, path):
		p.handleNetworkList(w, r)
	case isImageOp(path):
		// Allow image operations (pull, build, list)
		p.forward(w, r)
	case isBuildKitOp(path):
		// Allow BuildKit session/gRPC endpoints for docker build
		p.forward(w, r)
	case isVolumeOp(path):
		// Allow volume operations
		p.forward(w, r)
	default:
		if r.Method == "GET" || r.Method == "HEAD" {
			p.forward(w, r)
		} else {
			p.deny(w, r, "unknown write operation on path: "+path)
		}
	}
}

// handleContainerCreate intercepts POST /containers/create.
func (p *Proxy) handleContainerCreate(w http.ResponseWriter, r *http.Request) {
	// Check container count limit
	maxC := p.securityFilter.MaxContainers()
	if maxC > 0 && int(p.containerCount.Load()) >= maxC {
		p.deny(w, r, fmt.Sprintf("max container limit reached (%d)", maxC))
		return
	}

	// Read body
	body, err := io.ReadAll(r.Body)
	r.Body.Close()
	if err != nil {
		p.denyErr(w, r, "read request body", err)
		return
	}

	// Parse into typed struct for validation and into raw map for round-trip.
	// The typed struct only declares fields the proxy inspects; marshaling it
	// back would drop everything else (Image, Cmd, Env, ...).  The raw map
	// preserves the full request so we only patch what we need.
	var createReq createContainerRequest
	if err := json.Unmarshal(body, &createReq); err != nil {
		p.denyErr(w, r, "parse container create body", err)
		return
	}
	var rawReq map[string]interface{}
	if err := json.Unmarshal(body, &rawReq); err != nil {
		p.denyErr(w, r, "parse container create body (raw)", err)
		return
	}

	// Extract container name from query param
	containerName := r.URL.Query().Get("name")

	// Validate container name
	if _, err := p.containerFilter.ValidateCreateName(containerName); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Inject required labels into the raw map (preserves all other fields)
	rawLabels, _ := rawReq["Labels"].(map[string]interface{})
	if rawLabels == nil {
		rawLabels = make(map[string]interface{})
	}
	for k, v := range p.containerFilter.RequiredLabels() {
		rawLabels[k] = v
	}
	rawReq["Labels"] = rawLabels

	// Validate privileged
	if err := p.securityFilter.ValidatePrivileged(createReq.HostConfig.Privileged); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Validate user
	if err := p.securityFilter.ValidateUser(createReq.User); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Validate capabilities.
	// Docker CLI v29+ sends capabilities with CAP_ prefix (e.g. CAP_SYS_ADMIN);
	// normalizeCap() in the security filter strips it for policy comparison.
	if len(createReq.HostConfig.CapAdd) > 0 {
		if _, err := p.securityFilter.ValidateCapabilities(createReq.HostConfig.CapAdd); err != nil {
			p.deny(w, r, err.Error())
			return
		}
	}

	// Validate memory
	if err := p.securityFilter.ValidateMemory(createReq.HostConfig.Memory); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Validate CPU
	if err := p.securityFilter.ValidateCPU(createReq.HostConfig.NanoCPUs); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Validate sensitive mounts
	if err := p.securityFilter.ValidateSensitiveMounts(createReq.HostConfig.Binds); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Validate bind mounts (path_map translation happens inside ValidateBind)
	for _, bind := range createReq.HostConfig.Binds {
		if err := p.mountFilter.ValidateBind(bind); err != nil {
			p.deny(w, r, err.Error())
			return
		}
	}

	// Validate Mounts array (path_map translation happens inside ValidateMount)
	for _, mount := range createReq.HostConfig.Mounts {
		if err := p.mountFilter.ValidateMount(mount.Source, mount.Type); err != nil {
			p.deny(w, r, err.Error())
			return
		}
	}

	// Rewrite mount paths: translate container-local paths to host paths so
	// the Docker daemon (running on the host) receives valid host paths.
	// This must happen AFTER validation and BEFORE forwarding.
	bindRewritten := false
	for i, bind := range createReq.HostConfig.Binds {
		translated := p.mountFilter.TranslateBind(bind)
		if translated != bind {
			createReq.HostConfig.Binds[i] = translated
			bindRewritten = true
		}
	}
	mountRewritten := false
	for i, mount := range createReq.HostConfig.Mounts {
		if mount.Type == "bind" || mount.Type == "" {
			translated := p.mountFilter.TranslatePath(mount.Source)
			if translated != mount.Source {
				createReq.HostConfig.Mounts[i].Source = translated
				mountRewritten = true
			}
		}
	}

	// Force readonly if policy requires — patch both typed struct and raw map
	if p.mountFilter.ShouldForceReadonly() {
		for i, bind := range createReq.HostConfig.Binds {
			if !strings.HasSuffix(bind, ":ro") {
				parts := strings.SplitN(bind, ":", 3)
				if len(parts) == 2 {
					createReq.HostConfig.Binds[i] = bind + ":ro"
				} else if len(parts) == 3 && parts[2] != "ro" {
					createReq.HostConfig.Binds[i] = parts[0] + ":" + parts[1] + ":ro"
				}
			}
		}
		bindRewritten = true

		// Force readonly on Mounts array too (Docker CLI v29+ sends -v as Mounts)
		for i := range createReq.HostConfig.Mounts {
			if createReq.HostConfig.Mounts[i].Type == "bind" || createReq.HostConfig.Mounts[i].Type == "" {
				createReq.HostConfig.Mounts[i].ReadOnly = true
			}
		}
		mountRewritten = true
	}

	// Sync rewritten Binds back to raw map
	if bindRewritten {
		if hc, ok := rawReq["HostConfig"].(map[string]interface{}); ok {
			rawBinds := make([]interface{}, len(createReq.HostConfig.Binds))
			for i, b := range createReq.HostConfig.Binds {
				rawBinds[i] = b
			}
			hc["Binds"] = rawBinds
		}
	}

	// Sync rewritten Mounts back to raw map (Source and ReadOnly)
	if mountRewritten {
		if hc, ok := rawReq["HostConfig"].(map[string]interface{}); ok {
			if rawMounts, ok := hc["Mounts"].([]interface{}); ok {
				for i, mount := range createReq.HostConfig.Mounts {
					if i < len(rawMounts) {
						if rm, ok := rawMounts[i].(map[string]interface{}); ok {
							rm["Source"] = mount.Source
							rm["ReadOnly"] = mount.ReadOnly
						}
					}
				}
			}
		}
	}

	// Validate network config
	if createReq.NetworkingConfig.EndpointsConfig != nil {
		for netName := range createReq.NetworkingConfig.EndpointsConfig {
			if !p.isNetworkAllowed(netName) {
				p.deny(w, r, fmt.Sprintf("network %q is not allowed by policy", netName))
				return
			}
		}
	}

	// Re-serialize from the raw map (preserves Image, Cmd, Env, and all other fields)
	modifiedBody, err := json.Marshal(rawReq)
	if err != nil {
		p.denyErr(w, r, "serialize modified request", err)
		return
	}

	// Replace the request body and content-length
	r.Body = io.NopCloser(bytes.NewReader(modifiedBody))
	r.ContentLength = int64(len(modifiedBody))

	// Use a response recorder to capture the response
	rec := &responseRecorder{ResponseWriter: w, statusCode: 200}
	p.reverseProxy.ServeHTTP(rec, r)

	// If creation succeeded, add to cache, track ID, and increment count
	if rec.statusCode == 201 {
		var createResp struct {
			ID string `json:"Id"`
		}
		if err := json.Unmarshal(rec.body.Bytes(), &createResp); err == nil {
			p.cache.Add(createResp.ID, containerName, createReq.Labels)
			p.containerCount.Add(1)
			p.trackedIDs.Store(createResp.ID, true)
			if containerName != "" {
				p.trackedIDs.Store(containerName, true)
			}
		}
	}
}

// handleContainerList intercepts GET /containers/json and filters the response.
func (p *Proxy) handleContainerList(w http.ResponseWriter, r *http.Request) {
	if p.policy.Containers.Policy == "unrestricted" {
		p.forward(w, r)
		return
	}

	// Forward to Docker and capture response
	rec := &responseRecorder{ResponseWriter: nil, statusCode: 200, captureOnly: true}
	p.reverseProxy.ServeHTTP(rec, r)

	if rec.statusCode != 200 {
		w.WriteHeader(rec.statusCode)
		w.Write(rec.body.Bytes())
		return
	}

	// Parse container list
	var containers []json.RawMessage
	if err := json.Unmarshal(rec.body.Bytes(), &containers); err != nil {
		w.WriteHeader(rec.statusCode)
		w.Write(rec.body.Bytes())
		return
	}

	// Filter to allowed containers only
	var filtered []json.RawMessage
	for _, raw := range containers {
		var ct struct {
			ID     string            `json:"Id"`
			Names  []string          `json:"Names"`
			Labels map[string]string `json:"Labels"`
		}
		if err := json.Unmarshal(raw, &ct); err != nil {
			continue
		}

		name := ""
		if len(ct.Names) > 0 {
			name = strings.TrimPrefix(ct.Names[0], "/")
		}

		info := &cache.ContainerInfo{ID: ct.ID, Name: name, Labels: ct.Labels}
		if p.containerFilter.IsAllowed(info) {
			filtered = append(filtered, raw)
		}
	}

	// Serialize filtered list
	result, err := json.Marshal(filtered)
	if err != nil {
		w.WriteHeader(500)
		return
	}

	for k, v := range rec.header {
		for _, val := range v {
			w.Header().Set(k, val)
		}
	}
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(result)))
	w.WriteHeader(200)
	w.Write(result)
}

// handleContainerOp handles operations on a specific container (start, stop, exec, logs, inspect).
func (p *Proxy) handleContainerOp(w http.ResponseWriter, r *http.Request, path string) {
	if p.policy.Containers.Policy == "unrestricted" {
		p.forward(w, r)
		return
	}

	idOrName := extractContainerID(path)
	if idOrName == "" {
		p.deny(w, r, "could not extract container ID from path")
		return
	}

	// Allow BuildKit builder containers — these are managed by Docker/buildx
	// for `docker build` and are not created through the proxy.
	// Only bypass if the container is NOT in our tracked set (i.e., it was
	// created by buildx, not by the user naming a container buildx_buildkit_*).
	if isBuildKitContainer(idOrName) {
		if _, tracked := p.trackedIDs.Load(idOrName); !tracked {
			p.forward(w, r)
			return
		}
	}

	info, found := p.cache.Resolve(idOrName)
	if !found {
		// Try refreshing cache for newly created containers
		_ = p.cache.Refresh()
		info, found = p.cache.Resolve(idOrName)
	}

	if !found {
		p.deny(w, r, fmt.Sprintf("container %q not found in cache", idOrName))
		return
	}

	if !p.containerFilter.IsAllowed(info) {
		p.deny(w, r, fmt.Sprintf("access to container %q (%s) denied by policy", info.Name, p.policy.Containers.Policy))
		return
	}

	p.forward(w, r)
}

// isBuildKitContainer returns true if the ID/name matches a BuildKit builder
// container pattern.  These containers are created by Docker/buildx for
// `docker build` and must be accessible for builds to work.
func isBuildKitContainer(idOrName string) bool {
	return strings.HasPrefix(idOrName, "buildx_buildkit_")
}

// handleContainerDelete handles DELETE /containers/{id}.
func (p *Proxy) handleContainerDelete(w http.ResponseWriter, r *http.Request, path string) {
	if p.policy.Containers.Policy == "unrestricted" {
		p.forwardAndTrack(w, r, path, true)
		return
	}

	idOrName := extractContainerID(path)
	info, found := p.cache.Resolve(idOrName)
	if !found {
		_ = p.cache.Refresh()
		info, found = p.cache.Resolve(idOrName)
	}

	if !found {
		p.deny(w, r, fmt.Sprintf("container %q not found in cache", idOrName))
		return
	}

	if !p.containerFilter.IsAllowed(info) {
		p.deny(w, r, fmt.Sprintf("access to container %q denied by policy", info.Name))
		return
	}

	p.forwardAndTrack(w, r, path, true)
}

// handleNetworkCreate intercepts POST /networks/create.
func (p *Proxy) handleNetworkCreate(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	r.Body.Close()
	if err != nil {
		p.denyErr(w, r, "read network create body", err)
		return
	}

	var netReq struct {
		Name string `json:"Name"`
	}
	if err := json.Unmarshal(body, &netReq); err != nil {
		p.denyErr(w, r, "parse network create body", err)
		return
	}

	if !p.isNetworkAllowed(netReq.Name) {
		p.deny(w, r, fmt.Sprintf("network name %q not allowed — must match prefix: %v", netReq.Name, p.policy.Networks.AllowedPrefixes))
		return
	}

	r.Body = io.NopCloser(bytes.NewReader(body))
	r.ContentLength = int64(len(body))
	p.forward(w, r)
}

// handleNetworkConnect intercepts POST /networks/{id}/connect.
// Docker accepts network name or ID in the URL path; we validate against allowed prefixes.
func (p *Proxy) handleNetworkConnect(w http.ResponseWriter, r *http.Request, path string) {
	netIDOrName := extractNetworkID(path)
	if netIDOrName != "" && !p.isNetworkAllowed(netIDOrName) {
		p.deny(w, r, fmt.Sprintf("network %q not allowed for connect — must match prefix: %v", netIDOrName, p.policy.Networks.AllowedPrefixes))
		return
	}
	p.forward(w, r)
}

// handleNetworkList intercepts GET /networks and filters the response.
func (p *Proxy) handleNetworkList(w http.ResponseWriter, r *http.Request) {
	if len(p.policy.Networks.AllowedPrefixes) == 0 {
		p.forward(w, r)
		return
	}

	rec := &responseRecorder{ResponseWriter: nil, statusCode: 200, captureOnly: true}
	p.reverseProxy.ServeHTTP(rec, r)

	if rec.statusCode != 200 {
		w.WriteHeader(rec.statusCode)
		w.Write(rec.body.Bytes())
		return
	}

	var networks []json.RawMessage
	if err := json.Unmarshal(rec.body.Bytes(), &networks); err != nil {
		w.WriteHeader(rec.statusCode)
		w.Write(rec.body.Bytes())
		return
	}

	var filtered []json.RawMessage
	for _, raw := range networks {
		var net struct {
			Name string `json:"Name"`
		}
		if err := json.Unmarshal(raw, &net); err != nil {
			continue
		}
		if p.isNetworkAllowed(net.Name) {
			filtered = append(filtered, raw)
		}
	}

	result, _ := json.Marshal(filtered)
	for k, v := range rec.header {
		for _, val := range v {
			w.Header().Set(k, val)
		}
	}
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(result)))
	w.WriteHeader(200)
	w.Write(result)
}

// isNetworkAllowed checks if a network name matches allowed prefixes.
func (p *Proxy) isNetworkAllowed(name string) bool {
	if len(p.policy.Networks.AllowedPrefixes) == 0 {
		return true
	}
	// Allow safe default Docker networks.
	// "host" is NOT allowed by default — it gives full access to the host
	// network namespace in Docker-from-Docker, bypassing network isolation.
	// "default" is used by Docker API when no --network is specified.
	if name == "bridge" || name == "none" || name == "default" {
		return true
	}
	for _, prefix := range p.policy.Networks.AllowedPrefixes {
		if strings.HasPrefix(name, prefix) {
			return true
		}
	}
	return false
}

// forward passes the request through to upstream Docker.
func (p *Proxy) forward(w http.ResponseWriter, r *http.Request) {
	p.reverseProxy.ServeHTTP(w, r)
}

// forwardAndTrack forwards the request and updates the cache after.
func (p *Proxy) forwardAndTrack(w http.ResponseWriter, r *http.Request, path string, isDelete bool) {
	rec := &responseRecorder{ResponseWriter: w, statusCode: 200}
	p.reverseProxy.ServeHTTP(rec, r)

	if isDelete && (rec.statusCode == 200 || rec.statusCode == 204) {
		idOrName := extractContainerID(path)
		p.cache.Remove(idOrName)
		// Only decrement if this container was tracked (created or counted by us)
		if _, tracked := p.trackedIDs.LoadAndDelete(idOrName); tracked {
			p.containerCount.Add(-1)
		}
	}
}

// deny sends a 403 Forbidden response with a Docker-compatible error message.
func (p *Proxy) deny(w http.ResponseWriter, r *http.Request, reason string) {
	if p.logDenied {
		log.Printf("DENIED %s %s: %s", r.Method, r.URL.Path, reason)
	}

	msg := fmt.Sprintf("cco-docker-proxy: operation denied — %s", reason)
	body, _ := json.Marshal(map[string]string{"message": msg})

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusForbidden)
	w.Write(body)
}

func (p *Proxy) denyErr(w http.ResponseWriter, r *http.Request, action string, err error) {
	p.deny(w, r, fmt.Sprintf("%s: %v", action, err))
}

// responseRecorder captures the response from the upstream for post-processing.
type responseRecorder struct {
	http.ResponseWriter
	statusCode  int
	body        bytes.Buffer
	header      http.Header
	captureOnly bool // if true, don't write to the underlying ResponseWriter
	wroteHeader bool
}

func (r *responseRecorder) Header() http.Header {
	if r.captureOnly {
		if r.header == nil {
			r.header = make(http.Header)
		}
		return r.header
	}
	return r.ResponseWriter.Header()
}

func (r *responseRecorder) WriteHeader(code int) {
	r.statusCode = code
	r.wroteHeader = true
	if !r.captureOnly {
		r.ResponseWriter.WriteHeader(code)
	}
}

func (r *responseRecorder) Write(b []byte) (int, error) {
	r.body.Write(b)
	if !r.captureOnly {
		return r.ResponseWriter.Write(b)
	}
	return len(b), nil
}

// createContainerRequest models the relevant fields of a Docker container create request.
type createContainerRequest struct {
	User   string            `json:"User,omitempty"`
	Labels map[string]string `json:"Labels,omitempty"`

	HostConfig struct {
		Binds      []string `json:"Binds,omitempty"`
		Privileged bool     `json:"Privileged,omitempty"`
		CapAdd     []string `json:"CapAdd,omitempty"`
		Memory     int64    `json:"Memory,omitempty"`
		NanoCPUs   int64    `json:"NanoCpus,omitempty"`
		Mounts     []struct {
			Type     string `json:"Type,omitempty"`
			Source   string `json:"Source,omitempty"`
			Target   string `json:"Target,omitempty"`
			ReadOnly bool   `json:"ReadOnly,omitempty"`
		} `json:"Mounts,omitempty"`
	} `json:"HostConfig,omitempty"`

	NetworkingConfig struct {
		EndpointsConfig map[string]interface{} `json:"EndpointsConfig,omitempty"`
	} `json:"NetworkingConfig,omitempty"`
}

