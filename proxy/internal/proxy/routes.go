package proxy

import (
	"regexp"
	"strings"
)

// Docker API path patterns (handles versioned paths like /v1.44/containers/json)

var (
	// /v1.XX/ prefix pattern
	versionPrefix = regexp.MustCompile(`^(/v\d+\.\d+)?`)

	// Container endpoints
	containerCreatePath  = regexp.MustCompile(`^(/v\d+\.\d+)?/containers/create$`)
	containerListPath    = regexp.MustCompile(`^(/v\d+\.\d+)?/containers/json$`)
	containerOpPath      = regexp.MustCompile(`^(/v\d+\.\d+)?/containers/([^/]+)(/.*)?$`)

	// Network endpoints
	networkCreatePath    = regexp.MustCompile(`^(/v\d+\.\d+)?/networks/create$`)
	networkConnectPath   = regexp.MustCompile(`^(/v\d+\.\d+)?/networks/([^/]+)/connect$`)
	networkListPath      = regexp.MustCompile(`^(/v\d+\.\d+)?/networks$`)

	// Always allowed
	alwaysAllowedPaths = []string{"/_ping", "/version", "/info"}
)

// cleanPath strips the API version prefix for matching.
func cleanPath(path string) string {
	return path
}

func isAlwaysAllowed(path string) bool {
	stripped := versionPrefix.ReplaceAllString(path, "")
	for _, allowed := range alwaysAllowedPaths {
		if stripped == allowed {
			return true
		}
	}
	return false
}

func isContainerCreate(method, path string) bool {
	return method == "POST" && containerCreatePath.MatchString(path)
}

func isContainerList(method, path string) bool {
	return method == "GET" && containerListPath.MatchString(path)
}

func isContainerOp(method, path string) bool {
	if !containerOpPath.MatchString(path) {
		return false
	}
	// Exclude create and list (handled separately)
	stripped := versionPrefix.ReplaceAllString(path, "")
	if stripped == "/containers/create" || stripped == "/containers/json" {
		return false
	}
	return method == "GET" || method == "POST" || method == "HEAD"
}

func isContainerDelete(method, path string) bool {
	if method != "DELETE" {
		return false
	}
	return containerOpPath.MatchString(path)
}

func isNetworkCreate(method, path string) bool {
	return method == "POST" && networkCreatePath.MatchString(path)
}

func isNetworkConnect(method, path string) bool {
	return method == "POST" && networkConnectPath.MatchString(path)
}

func isNetworkList(method, path string) bool {
	return method == "GET" && networkListPath.MatchString(path)
}

func isImageOp(path string) bool {
	stripped := versionPrefix.ReplaceAllString(path, "")
	return strings.HasPrefix(stripped, "/images") || strings.HasPrefix(stripped, "/build")
}

func isVolumeOp(path string) bool {
	stripped := versionPrefix.ReplaceAllString(path, "")
	return strings.HasPrefix(stripped, "/volumes")
}

// extractContainerID extracts the container ID or name from a path like
// /v1.44/containers/{id}/start or /containers/{id}/json
func extractContainerID(path string) string {
	matches := containerOpPath.FindStringSubmatch(path)
	if len(matches) >= 3 {
		return matches[2]
	}
	return ""
}
