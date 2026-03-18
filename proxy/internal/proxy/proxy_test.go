package proxy

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/claude-orchestrator/proxy/internal/config"
)

// testPolicy returns a policy suitable for testing with project_only container
// policy and allowlist mount policy.
func testPolicy() *config.Policy {
	return &config.Policy{
		ProjectName: "testproj",
		Containers: config.ContainerPolicy{
			Policy:        "project_only",
			CreateAllowed: true,
			NamePrefix:    "cc-testproj-",
			RequiredLabels: map[string]string{
				"cco.project": "testproj",
			},
		},
		Mounts: config.MountPolicy{
			Policy:        "allowlist",
			AllowedPaths:  []string{"/workspace/testproj"},
			DeniedPaths:   []string{"/etc/shadow"},
			ImplicitDeny:  []string{"/var/run/docker.sock"},
			ForceReadonly: false,
		},
		Security: config.SecurityPolicy{
			NoPrivileged:      true,
			NoSensitiveMounts: true,
			ForceNonRoot:      false,
			MaxContainers:     10,
		},
		Networks: config.NetworkPolicy{
			AllowedPrefixes: []string{"cc-testproj"},
		},
	}
}

// newTestProxyReal creates a real Proxy instance via New() and replaces the
// reverse proxy transport to point to the given test server.
func newTestProxyReal(t *testing.T, policy *config.Policy, upstream *httptest.Server) *Proxy {
	t.Helper()
	p := New(policy, "/tmp/nonexistent-test.sock", true)

	// Override the reverse proxy to point to our test server over TCP.
	p.reverseProxy.Director = func(req *http.Request) {
		req.URL.Scheme = "http"
		req.URL.Host = upstream.Listener.Addr().String()
	}
	p.reverseProxy.Transport = http.DefaultTransport

	return p
}

// mockDockerUpstream creates a mock Docker daemon that handles:
// - POST /containers/create -> 201 with {"Id": "..."}
// - GET /containers/json -> 200 with container list
// - GET /_ping, /version, /info -> 200
// - Everything else -> 200
func mockDockerUpstream(containers []map[string]interface{}) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// Container create
		if isContainerCreate(r.Method, path) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			json.NewEncoder(w).Encode(map[string]string{
				"Id": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
			})
			return
		}

		// Container list
		if isContainerList(r.Method, path) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(200)
			json.NewEncoder(w).Encode(containers)
			return
		}

		// Always allowed
		if isAlwaysAllowed(path) {
			w.WriteHeader(200)
			w.Write([]byte(`{"ApiVersion":"1.44"}`))
			return
		}

		// Default: 200 OK
		w.WriteHeader(200)
	}))
}

func TestHandleContainerCreate_Allowed(t *testing.T) {
	policy := testPolicy()
	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image": "postgres:16",
		"HostConfig": map[string]interface{}{
			"Binds": []string{"/workspace/testproj:/data"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-db", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 201 {
		t.Errorf("expected 201, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleContainerCreate_Denied(t *testing.T) {
	policy := testPolicy()
	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image": "alpine",
		"HostConfig": map[string]interface{}{
			"Binds": []string{"/etc/shadow:/mnt/shadow"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-evil", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for denied mount, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleContainerCreate_LabelInjection(t *testing.T) {
	policy := testPolicy()

	// Capture the request body sent to upstream to verify label injection.
	var capturedBody []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isContainerCreate(r.Method, r.URL.Path) {
			capturedBody, _ = io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			json.NewEncoder(w).Encode(map[string]string{
				"Id": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
			})
			return
		}
		w.WriteHeader(200)
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image":  "alpine",
		"Labels": map[string]interface{}{},
		"HostConfig": map[string]interface{}{
			"Binds": []string{"/workspace/testproj:/app"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-worker", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 201 {
		t.Fatalf("expected 201, got %d: %s", rr.Code, rr.Body.String())
	}

	// Check that the required label was injected
	var forwarded map[string]interface{}
	if err := json.Unmarshal(capturedBody, &forwarded); err != nil {
		t.Fatalf("failed to parse captured body: %v", err)
	}

	labels, ok := forwarded["Labels"].(map[string]interface{})
	if !ok {
		t.Fatal("expected Labels in forwarded request")
	}

	if labels["cco.project"] != "testproj" {
		t.Errorf("expected injected label cco.project=testproj, got %v", labels["cco.project"])
	}
}

func TestHandleContainerCreate_ReadonlyInjection(t *testing.T) {
	policy := testPolicy()
	policy.Mounts.ForceReadonly = true

	var capturedBody []byte
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if isContainerCreate(r.Method, r.URL.Path) {
			capturedBody, _ = io.ReadAll(r.Body)
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(201)
			json.NewEncoder(w).Encode(map[string]string{
				"Id": "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890",
			})
			return
		}
		w.WriteHeader(200)
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image": "alpine",
		"HostConfig": map[string]interface{}{
			"Binds": []string{"/workspace/testproj:/app"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-ro", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 201 {
		t.Fatalf("expected 201, got %d: %s", rr.Code, rr.Body.String())
	}

	// Check that the bind got :ro appended
	var forwarded map[string]interface{}
	if err := json.Unmarshal(capturedBody, &forwarded); err != nil {
		t.Fatalf("failed to parse captured body: %v", err)
	}

	hc, ok := forwarded["HostConfig"].(map[string]interface{})
	if !ok {
		t.Fatal("expected HostConfig")
	}

	binds, ok := hc["Binds"].([]interface{})
	if !ok || len(binds) == 0 {
		t.Fatal("expected Binds array")
	}

	bindStr, ok := binds[0].(string)
	if !ok {
		t.Fatal("expected bind to be a string")
	}

	if bindStr != "/workspace/testproj:/app:ro" {
		t.Errorf("expected bind with :ro suffix, got %q", bindStr)
	}
}

func TestContainerOp_AllowedContainer(t *testing.T) {
	policy := testPolicy()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(204)
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	// Pre-populate the cache with an allowed container
	containerID := "abcdef1234567890abcdef1234567890abcdef1234567890abcdef1234567890"
	p.cache.Add(containerID, "cc-testproj-db", map[string]string{"cco.project": "testproj"})

	req := httptest.NewRequest("POST", "/v1.44/containers/"+containerID+"/start", nil)
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	// Should pass through (not 403)
	if rr.Code == 403 {
		t.Errorf("expected allowed operation, got 403: %s", rr.Body.String())
	}
}

func TestContainerOp_DeniedContainer(t *testing.T) {
	policy := testPolicy()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(204)
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	// Add a container that does NOT match the project policy
	containerID := "deaddead1234567890abcdef1234567890abcdef1234567890abcdef12345678"
	p.cache.Add(containerID, "not-my-project", map[string]string{})

	req := httptest.NewRequest("POST", "/v1.44/containers/"+containerID+"/start", nil)
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for denied container, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestContainerList_FiltersResults(t *testing.T) {
	policy := testPolicy()

	// Upstream returns two containers: one allowed, one not
	containers := []map[string]interface{}{
		{
			"Id":     "aaaa1234567890abcdef1234567890abcdef1234567890abcdef1234567890aa",
			"Names":  []string{"/cc-testproj-db"},
			"Labels": map[string]string{"cco.project": "testproj"},
		},
		{
			"Id":     "bbbb1234567890abcdef1234567890abcdef1234567890abcdef1234567890bb",
			"Names":  []string{"/other-project-app"},
			"Labels": map[string]string{},
		},
	}

	upstream := mockDockerUpstream(containers)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	req := httptest.NewRequest("GET", "/v1.44/containers/json", nil)
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 200 {
		t.Fatalf("expected 200, got %d: %s", rr.Code, rr.Body.String())
	}

	var result []map[string]interface{}
	if err := json.Unmarshal(rr.Body.Bytes(), &result); err != nil {
		t.Fatalf("failed to parse response: %v", err)
	}

	if len(result) != 1 {
		t.Errorf("expected 1 filtered container, got %d", len(result))
	}

	if len(result) > 0 {
		names, ok := result[0]["Names"].([]interface{})
		if !ok || len(names) == 0 {
			t.Fatal("expected Names array")
		}
		if names[0] != "/cc-testproj-db" {
			t.Errorf("expected allowed container, got %v", names[0])
		}
	}
}

func TestAlwaysAllowedPaths(t *testing.T) {
	policy := testPolicy()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(200)
		w.Write([]byte(`{"ApiVersion":"1.44"}`))
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	paths := []string{
		"/_ping",
		"/v1.44/_ping",
		"/version",
		"/v1.44/version",
		"/info",
		"/v1.44/info",
	}

	for _, path := range paths {
		t.Run(path, func(t *testing.T) {
			req := httptest.NewRequest("GET", path, nil)
			rr := httptest.NewRecorder()

			p.ServeHTTP(rr, req)

			if rr.Code != 200 {
				t.Errorf("expected 200 for always-allowed path %s, got %d: %s", path, rr.Code, rr.Body.String())
			}
		})
	}
}

func TestHandleContainerCreate_NamePrefixDenied(t *testing.T) {
	policy := testPolicy()
	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image":      "alpine",
		"HostConfig": map[string]interface{}{},
	}
	bodyBytes, _ := json.Marshal(body)

	// Name without required prefix
	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=bad-name", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for bad container name prefix, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleContainerCreate_PrivilegedDenied(t *testing.T) {
	policy := testPolicy()
	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image": "alpine",
		"HostConfig": map[string]interface{}{
			"Privileged": true,
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-priv", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for privileged container, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleContainerCreate_MaxContainersReached(t *testing.T) {
	policy := testPolicy()
	policy.Security.MaxContainers = 1

	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	// Simulate one container already counted
	p.containerCount.Store(1)

	body := map[string]interface{}{
		"Image":      "alpine",
		"HostConfig": map[string]interface{}{},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-extra", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for max containers, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestUnknownWriteOperation_Denied(t *testing.T) {
	policy := testPolicy()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	// POST to an unknown path should be denied
	req := httptest.NewRequest("POST", "/v1.44/some/unknown/path", nil)
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for unknown write op, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestUnknownReadOperation_Allowed(t *testing.T) {
	policy := testPolicy()

	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(200)
		w.Write([]byte("ok"))
	}))
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	// GET to an unknown path should pass through
	req := httptest.NewRequest("GET", "/v1.44/some/unknown/path", nil)
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 200 {
		t.Errorf("expected 200 for unknown GET, got %d: %s", rr.Code, rr.Body.String())
	}
}

func TestHandleContainerCreate_SensitiveMountDenied(t *testing.T) {
	policy := testPolicy()
	upstream := mockDockerUpstream(nil)
	defer upstream.Close()

	p := newTestProxyReal(t, policy, upstream)

	body := map[string]interface{}{
		"Image": "alpine",
		"HostConfig": map[string]interface{}{
			"Binds": []string{"/proc:/host-proc"},
		},
	}
	bodyBytes, _ := json.Marshal(body)

	req := httptest.NewRequest("POST", "/v1.44/containers/create?name=cc-testproj-sens", bytes.NewReader(bodyBytes))
	req.Header.Set("Content-Type", "application/json")
	rr := httptest.NewRecorder()

	p.ServeHTTP(rr, req)

	if rr.Code != 403 {
		t.Errorf("expected 403 for sensitive mount, got %d: %s", rr.Code, rr.Body.String())
	}
}
