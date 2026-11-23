package media

import (
	"fmt"
	"slices"
	"sync"
)

// Entry binds a provider Descriptor to its availability check and constructor.
type Entry struct {
	Descriptor        Descriptor
	CheckAvailability func(ResolvedConfig) (available bool, reason string)
	New               func(ResolvedConfig) (Provider, error)
}

// Registry holds explicitly registered media providers in registration order.
type Registry struct {
	mu      sync.RWMutex
	order   []string
	entries map[string]Entry
}

// NewRegistry returns an empty provider registry.
func NewRegistry() *Registry {
	return &Registry{entries: map[string]Entry{}}
}

// Register adds or replaces a provider entry in the registry.
func (r *Registry) Register(e Entry) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !slices.Contains(r.order, e.Descriptor.ID) {
		r.order = append(r.order, e.Descriptor.ID)
	}
	r.entries[e.Descriptor.ID] = e
}

// Entries returns all registered entries in registration order.
func (r *Registry) Entries() []Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]Entry, 0, len(r.order))
	for _, id := range r.order {
		out = append(out, r.entries[id])
	}
	return out
}

// Lookup returns the registered entry for id, if any.
func (r *Registry) Lookup(id string) (Entry, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	e, ok := r.entries[id]
	return e, ok
}

// Build constructs a Provider instance for id from cfg.
func (r *Registry) Build(id string, cfg ResolvedConfig) (Provider, error) {
	e, ok := r.Lookup(id)
	if !ok || e.New == nil {
		return nil, fmt.Errorf("media: unknown provider %q", id)
	}
	return e.New(cfg)
}

// HasCapability reports whether provider id is registered and supports cap.
func (r *Registry) HasCapability(id string, cap Capability) bool {
	e, ok := r.Lookup(id)
	return ok && e.Descriptor.Supports(cap)
}

// EntriesForCapability returns all registered entries that advertise cap, in
// registration order.
func (r *Registry) EntriesForCapability(cap Capability) []Entry {
	r.mu.RLock()
	defer r.mu.RUnlock()
	var out []Entry
	for _, id := range r.order {
		if e := r.entries[id]; e.Descriptor.Supports(cap) {
			out = append(out, e)
		}
	}
	return out
}

// BuildMusic constructs a MusicGenerator instance for id from cfg.
func (r *Registry) BuildMusic(id string, cfg ResolvedConfig) (MusicGenerator, error) {
	p, err := r.Build(id, cfg)
	if err != nil {
		return nil, err
	}
	gen, ok := p.(MusicGenerator)
	if !ok {
		return nil, fmt.Errorf("media: provider %q does not implement MusicGenerator", id)
	}
	return gen, nil
}

// BuildVideo constructs a VideoGenerator instance for id from cfg.
func (r *Registry) BuildVideo(id string, cfg ResolvedConfig) (VideoGenerator, error) {
	p, err := r.Build(id, cfg)
	if err != nil {
		return nil, err
	}
	gen, ok := p.(VideoGenerator)
	if !ok {
		return nil, fmt.Errorf("media: provider %q does not implement VideoGenerator", id)
	}
	return gen, nil
}

// BuildImage constructs an ImageGenerator instance for id from cfg.
func (r *Registry) BuildImage(id string, cfg ResolvedConfig) (ImageGenerator, error) {
	p, err := r.Build(id, cfg)
	if err != nil {
		return nil, err
	}
	gen, ok := p.(ImageGenerator)
	if !ok {
		return nil, fmt.Errorf("media: provider %q does not implement ImageGenerator", id)
	}
	return gen, nil
}

// RegisterLocalMLXPlaceholder registers the extensible Local MLX slot shown in
// Settings so future Apple Silicon adapters slot in cleanly.
func RegisterLocalMLXPlaceholder(reg *Registry) {
	if reg == nil {
		return
	}
	reg.Register(Entry{
		Descriptor: Descriptor{
			ID:           "local-mlx",
			Label:        "Local MLX (Apple Silicon)",
			Description:  "Extensible adapter slot · Not yet installed",
			Capabilities: []Capability{CapMusic},
			ComingSoon:   true,
		},
		CheckAvailability: func(ResolvedConfig) (bool, string) {
			return false, "Local MLX adapter is not installed yet"
		},
	})
}
