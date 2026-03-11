// cco-docker-proxy is a filtering HTTP proxy for the Docker socket.
// It intercepts Docker API calls and enforces container access, mount,
// and security policies defined in a policy.json file.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/claude-orchestrator/proxy/internal/config"
	"github.com/claude-orchestrator/proxy/internal/proxy"
)

func main() {
	var (
		listenSocket   string
		upstreamSocket string
		policyFile     string
		logDenied      bool
	)

	flag.StringVar(&listenSocket, "listen", "/var/run/docker-proxy.sock", "Unix socket to listen on")
	flag.StringVar(&upstreamSocket, "upstream", "/var/run/docker.sock", "Upstream Docker socket")
	flag.StringVar(&policyFile, "policy", "/etc/cco/policy.json", "Policy JSON file")
	flag.BoolVar(&logDenied, "log-denied", false, "Log denied requests to stderr")
	flag.Parse()

	// Load policy
	policy, err := config.Load(policyFile)
	if err != nil {
		log.Fatalf("failed to load policy: %v", err)
	}

	log.Printf("cco-docker-proxy: loaded policy for project %q (containers=%s, mounts=%s)",
		policy.ProjectName, policy.Containers.Policy, policy.Mounts.Policy)

	// Create proxy
	p := proxy.New(policy, upstreamSocket, logDenied)

	// Initialize cache
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if err := p.Init(ctx); err != nil {
		log.Fatalf("failed to initialize proxy: %v", err)
	}

	// Clean up old socket file if it exists
	os.Remove(listenSocket)

	// Listen on Unix socket
	listener, err := net.Listen("unix", listenSocket)
	if err != nil {
		log.Fatalf("failed to listen on %s: %v", listenSocket, err)
	}
	defer listener.Close()

	log.Printf("cco-docker-proxy: listening on %s → %s", listenSocket, upstreamSocket)

	// HTTP server
	server := &http.Server{Handler: p}

	// Graceful shutdown on SIGTERM/SIGINT
	done := make(chan struct{})
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, syscall.SIGTERM, syscall.SIGINT)
		<-sigCh

		log.Println("cco-docker-proxy: shutting down...")
		cancel()
		server.Shutdown(context.Background())
		close(done)
	}()

	if err := server.Serve(listener); err != http.ErrServerClosed {
		log.Fatalf("server error: %v", err)
	}

	<-done
	fmt.Println("cco-docker-proxy: stopped")
}
