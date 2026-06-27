package rooms

import (
	"testing"
)

func TestCreateAndGet(t *testing.T) {
	svc := NewService()
	room := svc.Create("test-room")
	if room.ID == "" {
		t.Fatal("room ID is empty")
	}
	if room.Name != "test-room" {
		t.Fatalf("expected test-room, got %s", room.Name)
	}

	got, ok := svc.Get(room.ID)
	if !ok {
		t.Fatal("room not found after create")
	}
	if got.ID != room.ID {
		t.Fatalf("expected %s, got %s", room.ID, got.ID)
	}
}

func TestList(t *testing.T) {
	svc := NewService()
	svc.Create("room-1")
	svc.Create("room-2")

	rooms := svc.List()
	if len(rooms) != 2 {
		t.Fatalf("expected 2 rooms, got %d", len(rooms))
	}
}

func TestDelete(t *testing.T) {
	svc := NewService()
	room := svc.Create("test")

	if !svc.Delete(room.ID) {
		t.Fatal("delete returned false for existing room")
	}
	if _, ok := svc.Get(room.ID); ok {
		t.Fatal("room still exists after delete")
	}

	if svc.Delete("nonexistent") {
		t.Fatal("delete returned true for nonexistent room")
	}
}
