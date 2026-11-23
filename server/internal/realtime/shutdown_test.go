package realtime

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

// An open /events stream (every Vesper window keeps one) must not hold
// http.Server.Shutdown until its deadline: quitting the Mac app waited ~10s and
// was then SIGKILLed before the runner and Postgres could stop.
func TestShutdownWithAnOpenStreamReturnsPromptly(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hub := New()
	hs := &http.Server{Handler: hub}
	hs.RegisterOnShutdown(hub.Close)
	served := make(chan error, 1)
	go func() { served <- hs.Serve(ln) }()

	resp, err := http.Get("http://" + ln.Addr().String() + "/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body := bufio.NewReader(resp.Body)
	if _, err := body.ReadString('\n'); err != nil { // the initial reset: the stream is open
		t.Fatal(err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	start := time.Now()
	if err := hs.Shutdown(ctx); err != nil {
		t.Fatalf("Shutdown after %v: %v", time.Since(start), err)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("Shutdown took %v with an open stream", took)
	}
	if _, err := io.ReadAll(body); err != nil {
		t.Fatalf("stream didn't end cleanly: %v", err)
	}
	if err := <-served; err != http.ErrServerClosed {
		t.Fatalf("Serve: %v", err)
	}
}

func TestClosedHubRefusesNewStreams(t *testing.T) {
	hub := New()
	hub.Close()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	hs := &http.Server{Handler: hub}
	go func() { _ = hs.Serve(ln) }()
	defer hs.Close()

	resp, err := http.Get("http://" + ln.Addr().String() + "/events")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status %d, want 503", resp.StatusCode)
	}
}
