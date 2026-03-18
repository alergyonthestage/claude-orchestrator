package cache

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// dockerContainer mirrors the JSON structure returned by Docker's /containers/json endpoint.
type dockerContainer struct {
	ID     string            `json:"Id"`
	Names  []string          `json:"Names"`
	Labels map[string]string `json:"Labels"`
}

// newTestServer creates an httptest.Server that responds to /containers/json
// with the given container list.
func newTestServer(containers []dockerContainer) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.Contains(r.URL.Path, "/containers/json") {
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(containers)
			return
		}
		w.WriteHeader(404)
	}))
}

// newCacheWithHTTPClient creates a Cache that uses an http.Client pointed at
// the given test server URL (over TCP, not a Unix socket).
func newCacheWithHTTPClient(serverURL string) *Cache {
	return &Cache{
		byID:     make(map[string]*ContainerInfo),
		byPrefix: make(map[string]*ContainerInfo),
		byName:   make(map[string]*ContainerInfo),
		client:   &http.Client{},
	}
}

// refreshFromServer performs a Refresh against a test HTTP server instead of
// a Unix socket. It re-implements the Refresh logic with a custom base URL.
func refreshFromServer(c *Cache, serverURL string) error {
	resp, err := c.client.Get(serverURL + "/v1.44/containers/json?all=true")
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	var containers []struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		Labels map[string]string `json:"Labels"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&containers); err != nil {
		return err
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.byID = make(map[string]*ContainerInfo, len(containers))
	c.byPrefix = make(map[string]*ContainerInfo, len(containers))
	c.byName = make(map[string]*ContainerInfo, len(containers))

	for _, ct := range containers {
		name := ""
		if len(ct.Names) > 0 {
			name = strings.TrimPrefix(ct.Names[0], "/")
		}
		info := &ContainerInfo{
			ID:     ct.ID,
			Name:   name,
			Labels: ct.Labels,
		}
		c.byID[ct.ID] = info
		if len(ct.ID) >= 12 {
			c.byPrefix[ct.ID[:12]] = info
		}
		if name != "" {
			c.byName[name] = info
		}
	}

	return nil
}

func TestNew(t *testing.T) {
	c := New("/tmp/fake.sock")
	if c == nil {
		t.Fatal("New returned nil")
	}
	if c.byID == nil || c.byPrefix == nil || c.byName == nil {
		t.Fatal("maps were not initialized")
	}
	if c.client == nil {
		t.Fatal("client was not initialized")
	}
	if c.Count() != 0 {
		t.Errorf("expected empty cache, got %d", c.Count())
	}
}

func TestRefresh(t *testing.T) {
	containers := []dockerContainer{
		{
			ID:     "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd",
			Names:  []string{"/my-postgres"},
			Labels: map[string]string{"cco.project": "test"},
		},
		{
			ID:     "1122334455667788990011223344556677889900112233445566778899001122",
			Names:  []string{"/my-redis"},
			Labels: map[string]string{"cco.project": "test"},
		},
	}

	srv := newTestServer(containers)
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	if err := refreshFromServer(c, srv.URL); err != nil {
		t.Fatalf("Refresh failed: %v", err)
	}

	if c.Count() != 2 {
		t.Errorf("expected 2 containers, got %d", c.Count())
	}
}

func TestResolve_ByID(t *testing.T) {
	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	containers := []dockerContainer{
		{ID: fullID, Names: []string{"/my-app"}, Labels: map[string]string{}},
	}

	srv := newTestServer(containers)
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	refreshFromServer(c, srv.URL)

	info, found := c.Resolve(fullID)
	if !found {
		t.Fatal("expected to find container by full ID")
	}
	if info.ID != fullID {
		t.Errorf("expected ID %q, got %q", fullID, info.ID)
	}
	if info.Name != "my-app" {
		t.Errorf("expected name %q, got %q", "my-app", info.Name)
	}
}

func TestResolve_ByShortID(t *testing.T) {
	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	shortID := fullID[:12]
	containers := []dockerContainer{
		{ID: fullID, Names: []string{"/my-app"}, Labels: map[string]string{}},
	}

	srv := newTestServer(containers)
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	refreshFromServer(c, srv.URL)

	info, found := c.Resolve(shortID)
	if !found {
		t.Fatal("expected to find container by short ID")
	}
	if info.ID != fullID {
		t.Errorf("expected full ID %q, got %q", fullID, info.ID)
	}
}

func TestResolve_ByName(t *testing.T) {
	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	containers := []dockerContainer{
		{ID: fullID, Names: []string{"/my-app"}, Labels: map[string]string{}},
	}

	srv := newTestServer(containers)
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	refreshFromServer(c, srv.URL)

	info, found := c.Resolve("my-app")
	if !found {
		t.Fatal("expected to find container by name")
	}
	if info.ID != fullID {
		t.Errorf("expected ID %q, got %q", fullID, info.ID)
	}
}

func TestResolve_NotFound(t *testing.T) {
	srv := newTestServer([]dockerContainer{})
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	refreshFromServer(c, srv.URL)

	info, found := c.Resolve("nonexistent")
	if found {
		t.Error("expected not found for unknown container")
	}
	if info != nil {
		t.Error("expected nil info for unknown container")
	}
}

func TestAdd(t *testing.T) {
	c := New("/tmp/fake.sock")

	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	labels := map[string]string{"env": "test"}
	c.Add(fullID, "test-container", labels)

	if c.Count() != 1 {
		t.Errorf("expected count 1, got %d", c.Count())
	}

	// Resolve by full ID
	info, found := c.Resolve(fullID)
	if !found {
		t.Fatal("expected to find added container by full ID")
	}
	if info.Name != "test-container" {
		t.Errorf("expected name %q, got %q", "test-container", info.Name)
	}
	if info.Labels["env"] != "test" {
		t.Errorf("expected label env=test, got %q", info.Labels["env"])
	}

	// Resolve by short ID
	_, found = c.Resolve(fullID[:12])
	if !found {
		t.Fatal("expected to find added container by short ID")
	}

	// Resolve by name
	_, found = c.Resolve("test-container")
	if !found {
		t.Fatal("expected to find added container by name")
	}
}

func TestRemove(t *testing.T) {
	c := New("/tmp/fake.sock")

	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	c.Add(fullID, "removable", map[string]string{})

	if c.Count() != 1 {
		t.Fatalf("expected count 1 after add, got %d", c.Count())
	}

	// Remove by full ID
	c.Remove(fullID)

	if c.Count() != 0 {
		t.Errorf("expected count 0 after remove, got %d", c.Count())
	}

	_, found := c.Resolve(fullID)
	if found {
		t.Error("expected not found after remove by full ID")
	}

	_, found = c.Resolve(fullID[:12])
	if found {
		t.Error("expected not found by short ID after remove")
	}

	_, found = c.Resolve("removable")
	if found {
		t.Error("expected not found by name after remove")
	}
}

func TestRemove_ByName(t *testing.T) {
	c := New("/tmp/fake.sock")

	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	c.Add(fullID, "my-container", map[string]string{})

	c.Remove("my-container")

	if c.Count() != 0 {
		t.Errorf("expected count 0 after remove by name, got %d", c.Count())
	}

	_, found := c.Resolve(fullID)
	if found {
		t.Error("expected not found after remove by name")
	}
}

func TestRemove_ByShortID(t *testing.T) {
	c := New("/tmp/fake.sock")

	fullID := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	c.Add(fullID, "short-id-test", map[string]string{})

	c.Remove(fullID[:12])

	if c.Count() != 0 {
		t.Errorf("expected count 0 after remove by short ID, got %d", c.Count())
	}
}

func TestRemove_NonExistent(t *testing.T) {
	c := New("/tmp/fake.sock")
	// Should not panic
	c.Remove("nonexistent")
	if c.Count() != 0 {
		t.Error("expected count 0")
	}
}

func TestRefresh_UpdatesExisting(t *testing.T) {
	// Initial state: one container
	initialContainers := []dockerContainer{
		{
			ID:     "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd",
			Names:  []string{"/old-name"},
			Labels: map[string]string{"version": "1"},
		},
	}

	srv := newTestServer(initialContainers)
	defer srv.Close()

	c := newCacheWithHTTPClient(srv.URL)
	refreshFromServer(c, srv.URL)

	info, found := c.Resolve("old-name")
	if !found {
		t.Fatal("expected to find container with old name")
	}
	if info.Labels["version"] != "1" {
		t.Errorf("expected version 1, got %q", info.Labels["version"])
	}

	// Stop old server, start new one with updated data
	srv.Close()

	updatedContainers := []dockerContainer{
		{
			ID:     "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd",
			Names:  []string{"/new-name"},
			Labels: map[string]string{"version": "2"},
		},
		{
			ID:     "1122334455667788990011223344556677889900112233445566778899001122",
			Names:  []string{"/brand-new"},
			Labels: map[string]string{},
		},
	}

	srv2 := newTestServer(updatedContainers)
	defer srv2.Close()

	// Point cache client to new server
	c.client = &http.Client{}
	if err := refreshFromServer(c, srv2.URL); err != nil {
		t.Fatalf("second Refresh failed: %v", err)
	}

	// Old name should be gone
	_, found = c.Resolve("old-name")
	if found {
		t.Error("expected old-name to be gone after refresh")
	}

	// New name should resolve
	info, found = c.Resolve("new-name")
	if !found {
		t.Fatal("expected to find container with new name")
	}
	if info.Labels["version"] != "2" {
		t.Errorf("expected version 2, got %q", info.Labels["version"])
	}

	// Brand new container should be present
	_, found = c.Resolve("brand-new")
	if !found {
		t.Error("expected to find brand-new container")
	}

	if c.Count() != 2 {
		t.Errorf("expected 2 containers after refresh, got %d", c.Count())
	}
}

func TestAll(t *testing.T) {
	c := New("/tmp/fake.sock")

	id1 := "aabbccddee112233445566778899aabbccddee112233445566778899aabbccdd"
	id2 := "1122334455667788990011223344556677889900112233445566778899001122"
	c.Add(id1, "container-1", map[string]string{})
	c.Add(id2, "container-2", map[string]string{})

	all := c.All()
	if len(all) != 2 {
		t.Errorf("expected 2 containers from All(), got %d", len(all))
	}
}
