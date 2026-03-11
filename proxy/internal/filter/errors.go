package filter

import "fmt"

// DeniedError represents a policy violation that should result in a 403 response.
type DeniedError struct {
	Reason string
}

func (e *DeniedError) Error() string {
	return fmt.Sprintf("cco-docker-proxy: denied — %s", e.Reason)
}

// IsDenied checks if an error is a policy denial.
func IsDenied(err error) bool {
	_, ok := err.(*DeniedError)
	return ok
}
