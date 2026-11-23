// Package realtime fans out commit notifications. Clients always refetch on
// connect: NOTIFY is deliberately an invalidation hint, not a durable log.
package realtime

import (
	"context"
	"fmt"
	"net/http"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Hub struct {
	mu      sync.Mutex
	clients map[chan string]struct{}
	closed  bool
}

func New() *Hub { return &Hub{clients: make(map[chan string]struct{})} }

// Close ends every open stream and refuses new ones. Register it with
// http.Server.RegisterOnShutdown: Shutdown waits for connections to go idle and
// doesn't cancel request contexts, so an open stream would otherwise hold it
// until its deadline.
func (h *Hub) Close() {
	h.mu.Lock()
	defer h.mu.Unlock()
	h.closed = true
	for ch := range h.clients {
		close(ch)
		delete(h.clients, ch)
	}
}
func (h *Hub) publish(message string) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for ch := range h.clients {
		select {
		case ch <- message:
		default:
			// A slow client must reconnect and refetch rather than silently miss changes.
			close(ch)
			delete(h.clients, ch)
		}
	}
}
func (h *Hub) Run(ctx context.Context, pool *pgxpool.Pool) {
	for ctx.Err() == nil {
		h.listen(ctx, pool)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}
func (h *Hub) listen(ctx context.Context, pool *pgxpool.Pool) {
	conn, err := pool.Acquire(ctx)
	if err != nil {
		return
	}
	defer conn.Release()
	if _, err = conn.Exec(ctx, "LISTEN lazyagents_changes"); err != nil {
		return
	}
	// Also recover changes missed while the listener was disconnected.
	h.publish(`{"type":"reset","ids":[]}`)
	for {
		n, err := conn.Conn().WaitForNotification(ctx)
		if err != nil {
			// Don't return a broken/listening connection to the general pool.
			conn.Conn().Close(context.Background())
			return
		}
		h.publish(n.Payload)
	}
}
func (h *Hub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ch := make(chan string, 32)
	h.mu.Lock()
	if h.closed {
		h.mu.Unlock()
		http.Error(w, "shutting down", http.StatusServiceUnavailable)
		return
	}
	h.clients[ch] = struct{}{}
	h.mu.Unlock()
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache, no-transform")
	w.Header().Set("X-Accel-Buffering", "no")
	defer func() { h.mu.Lock(); delete(h.clients, ch); h.mu.Unlock() }()
	rc := http.NewResponseController(w)
	send := func(s string) error {
		_ = rc.SetWriteDeadline(time.Now().Add(10 * time.Second))
		if _, err := fmt.Fprint(w, s); err != nil {
			return err
		}
		return rc.Flush()
	}
	if send("data: {\"type\":\"reset\",\"ids\":[]}\n\n") != nil {
		return
	}
	tick := time.NewTicker(45 * time.Second)
	defer tick.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			if send("data: "+msg+"\n\n") != nil {
				return
			}
		case <-tick.C:
			if send(": heartbeat\n\n") != nil {
				return
			}
		}
	}
}
