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
	p.cache.StartPeriodicRefresh(ctx, 30*time.Second)

	// Count existing project containers and track their IDs
	for _, info := range p.cache.All() {
		if p.containerFilter.IsAllowed(info) {
			p.containerCount.Add(1)
			p.trackedIDs.Store(info.ID, true)
			// Also track by name for lookup flexibility
			if info.Name != "" {
				p.trackedIDs.Store(info.Name, true)
			}
		}
	}

	return nil
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
	case isNetworkCreate(r.Method, path):
		p.handleNetworkCreate(w, r)
	case isNetworkConnect(r.Method, path):
		p.handleNetworkConnect(w, r, path)
	case isNetworkList(r.Method, path):
		p.handleNetworkList(w, r)
	case isImageOp(path):
		// Allow image operations (pull, build, list)
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

	// Parse create request
	var createReq createContainerRequest
	if err := json.Unmarshal(body, &createReq); err != nil {
		p.denyErr(w, r, "parse container create body", err)
		return
	}

	// Extract container name from query param
	containerName := r.URL.Query().Get("name")

	// Validate container name
	if _, err := p.containerFilter.ValidateCreateName(containerName); err != nil {
		p.deny(w, r, err.Error())
		return
	}

	// Inject required labels
	if createReq.Labels == nil {
		createReq.Labels = make(map[string]string)
	}
	for k, v := range p.containerFilter.RequiredLabels() {
		createReq.Labels[k] = v
	}

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

	// Validate capabilities
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

	// Validate bind mounts
	for _, bind := range createReq.HostConfig.Binds {
		if err := p.mountFilter.ValidateBind(bind); err != nil {
			p.deny(w, r, err.Error())
			return
		}
	}

	// Validate Mounts array
	for _, mount := range createReq.HostConfig.Mounts {
		if err := p.mountFilter.ValidateMount(mount.Source, mount.Type); err != nil {
			p.deny(w, r, err.Error())
			return
		}
	}

	// Force readonly if policy requires
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

	// Re-serialize the modified body
	modifiedBody, err := json.Marshal(createReq)
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
	// Always allow default Docker networks
	if name == "bridge" || name == "host" || name == "none" {
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
			Type   string `json:"Type,omitempty"`
			Source string `json:"Source,omitempty"`
			Target string `json:"Target,omitempty"`
		} `json:"Mounts,omitempty"`
	} `json:"HostConfig,omitempty"`

	NetworkingConfig struct {
		EndpointsConfig map[string]interface{} `json:"EndpointsConfig,omitempty"`
	} `json:"NetworkingConfig,omitempty"`
}
