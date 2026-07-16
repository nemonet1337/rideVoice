package groups

import "testing"

func TestCreateAndGet(t *testing.T) {
	svc := NewService()
	g := svc.Create("touring-crew")
	if g.ID == "" {
		t.Fatal("group ID is empty")
	}
	if g.Name != "touring-crew" {
		t.Fatalf("expected touring-crew, got %s", g.Name)
	}

	got, ok := svc.Get(g.ID)
	if !ok {
		t.Fatal("group not found after create")
	}
	if got.ID != g.ID {
		t.Fatalf("expected %s, got %s", g.ID, got.ID)
	}
}

func TestList(t *testing.T) {
	svc := NewService()
	svc.Create("g1")
	svc.Create("g2")
	if len(svc.List()) != 2 {
		t.Fatalf("expected 2 groups, got %d", len(svc.List()))
	}
}

func TestIDUniquenessUnderBurst(t *testing.T) {
	svc := NewService()
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		g := svc.Create("burst")
		if seen[g.ID] {
			t.Fatalf("duplicate group ID generated: %s", g.ID)
		}
		seen[g.ID] = true
	}
}
