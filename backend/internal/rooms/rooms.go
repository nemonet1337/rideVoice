package rooms

import (
	"sync"
	"time"
)

type Room struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Service struct {
	mu    sync.RWMutex
	rooms map[string]Room
}

func NewService() *Service {
	return &Service{
		rooms: make(map[string]Room),
	}
}

func (s *Service) Create(name string) Room {
	s.mu.Lock()
	defer s.mu.Unlock()

	id := "room-" + time.Now().Format("20060102150405")
	room := Room{
		ID:        id,
		Name:      name,
		CreatedAt: time.Now(),
	}
	s.rooms[id] = room
	return room
}

func (s *Service) Get(id string) (Room, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	r, ok := s.rooms[id]
	return r, ok
}

func (s *Service) List() []Room {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]Room, 0, len(s.rooms))
	for _, r := range s.rooms {
		result = append(result, r)
	}
	return result
}

func (s *Service) Delete(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, ok := s.rooms[id]
	if ok {
		delete(s.rooms, id)
	}
	return ok
}
