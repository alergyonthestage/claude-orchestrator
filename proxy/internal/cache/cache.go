// Package cache maintains a local cache of container ID → name/labels mappings
// to avoid extra Docker API calls for every request.
package cache

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

// ContainerInfo holds the essential identifying information for a container.
type ContainerInfo struct {
	ID     string
	Name   string
	Labels map[string]string
}

// Cache provides thread-safe container ID/name resolution.
type Cache struct {
	mu       sync.RWMutex
	byID     map[string]*ContainerInfo // full 64-char ID
	byPrefix map[string]*ContainerInfo // first 12 chars
	byName   map[string]*ContainerInfo // name without leading /
	client   *http.Client
}

// New creates a new container cache connected to the given upstream Docker socket.
func New(upstreamSocket string) *Cache {
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return net.DialTimeout("unix", upstreamSocket, 5*time.Second)
		},
	}

	return &Cache{
		byID:     make(map[string]*ContainerInfo),
		byPrefix: make(map[string]*ContainerInfo),
		byName:   make(map[string]*ContainerInfo),
		client: &http.Client{
			Transport: transport,
			Timeout:   10 * time.Second,
		},
	}
}

// Refresh fetches the current container list from Docker and updates the cache.
func (c *Cache) Refresh() error {
	req, err := http.NewRequest("GET", "http://localhost/v1.44/containers/json?all=true", nil)
	if err != nil {
		return fmt.Errorf("create request: %w", err)
	}

	resp, err := c.client.Do(req)
	if err != nil {
		return fmt.Errorf("list containers: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return fmt.Errorf("read response: %w", err)
	}

	var containers []struct {
		ID     string            `json:"Id"`
		Names  []string          `json:"Names"`
		Labels map[string]string `json:"Labels"`
	}
	if err := json.Unmarshal(body, &containers); err != nil {
		return fmt.Errorf("parse containers: %w", err)
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// Reset maps
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

// StartPeriodicRefresh runs Refresh every interval in a background goroutine.
func (c *Cache) StartPeriodicRefresh(ctx context.Context, interval time.Duration) {
	go func() {
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				_ = c.Refresh() // best-effort
			}
		}
	}()
}

// Resolve looks up a container by ID (full or short), or by name.
func (c *Cache) Resolve(idOrName string) (*ContainerInfo, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()

	// Try full ID
	if info, ok := c.byID[idOrName]; ok {
		return info, true
	}
	// Try short ID (12 chars)
	if info, ok := c.byPrefix[idOrName]; ok {
		return info, true
	}
	// Try name
	if info, ok := c.byName[idOrName]; ok {
		return info, true
	}
	return nil, false
}

// Add registers a newly created container in the cache.
func (c *Cache) Add(id, name string, labels map[string]string) {
	info := &ContainerInfo{ID: id, Name: name, Labels: labels}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.byID[id] = info
	if len(id) >= 12 {
		c.byPrefix[id[:12]] = info
	}
	if name != "" {
		c.byName[name] = info
	}
}

// Remove deletes a container from the cache.
func (c *Cache) Remove(idOrName string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	// Find the info first
	var info *ContainerInfo
	if i, ok := c.byID[idOrName]; ok {
		info = i
	} else if i, ok := c.byPrefix[idOrName]; ok {
		info = i
	} else if i, ok := c.byName[idOrName]; ok {
		info = i
	}

	if info == nil {
		return
	}

	delete(c.byID, info.ID)
	if len(info.ID) >= 12 {
		delete(c.byPrefix, info.ID[:12])
	}
	if info.Name != "" {
		delete(c.byName, info.Name)
	}
}

// Count returns the number of containers in the cache.
func (c *Cache) Count() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.byID)
}

// All returns a copy of all cached container info.
func (c *Cache) All() []*ContainerInfo {
	c.mu.RLock()
	defer c.mu.RUnlock()

	result := make([]*ContainerInfo, 0, len(c.byID))
	for _, info := range c.byID {
		result = append(result, info)
	}
	return result
}
