package rooms

import (
	"sync"
	"time"

	"github.com/google/uuid"
)

type Room struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedBy string    `json:"created_by"`
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

func (s *Service) Create(name, createdBy string) Room {
	s.mu.Lock()
	defer s.mu.Unlock()

	room := Room{
		ID:        "room-" + uuid.NewString(),
		Name:      name,
		CreatedBy: createdBy,
		CreatedAt: time.Now(),
	}
	s.rooms[room.ID] = room
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
