package gateway

import (
	"sync"
	"time"
)

type Node struct {
	ID          string  `json:"id"`
	BatteryPct  float64 `json:"battery_pct"`
	Connectivity string  `json:"connectivity"`
	RegisteredAt time.Time `json:"registered_at"`
}

type Registry struct {
	mu    sync.RWMutex
	nodes map[string]Node
}

func NewRegistry() *Registry {
	return &Registry{
		nodes: make(map[string]Node),
	}
}

func (r *Registry) Register(node Node) {
	r.mu.Lock()
	defer r.mu.Unlock()
	node.RegisteredAt = time.Now()
	r.nodes[node.ID] = node
}

func (r *Registry) List() []Node {
	r.mu.RLock()
	defer r.mu.RUnlock()
	result := make([]Node, 0, len(r.nodes))
	for _, n := range r.nodes {
		result = append(result, n)
	}
	return result
}
