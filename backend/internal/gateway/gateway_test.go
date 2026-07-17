package gateway

import "testing"

func TestRegisterAndList(t *testing.T) {
	r := NewRegistry()
	r.Register(Node{ID: "gw-1", BatteryPct: 90, Connectivity: "online"})
	r.Register(Node{ID: "gw-2", BatteryPct: 60, Connectivity: "offline"})

	nodes := r.List()
	if len(nodes) != 2 {
		t.Fatalf("expected 2 nodes, got %d", len(nodes))
	}
	for _, n := range nodes {
		if n.RegisteredAt.IsZero() {
			t.Fatalf("node %s has zero RegisteredAt", n.ID)
		}
	}
}

func TestRegisterUpserts(t *testing.T) {
	r := NewRegistry()
	r.Register(Node{ID: "gw-1", BatteryPct: 90})
	r.Register(Node{ID: "gw-1", BatteryPct: 40})

	nodes := r.List()
	if len(nodes) != 1 {
		t.Fatalf("expected 1 node after upsert, got %d", len(nodes))
	}
	if nodes[0].BatteryPct != 40 {
		t.Fatalf("expected updated battery 40, got %v", nodes[0].BatteryPct)
	}
}
