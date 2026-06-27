package groups

import (
	"sync"
	"time"
)

type Group struct {
	ID        string    `json:"id"`
	Name      string    `json:"name"`
	CreatedAt time.Time `json:"created_at"`
}

type Service struct {
	mu     sync.RWMutex
	groups map[string]Group
}

func NewService() *Service {
	return &Service{
		groups: make(map[string]Group),
	}
}

func (s *Service) Create(name string) Group {
	s.mu.Lock()
	defer s.mu.Unlock()

	id := "group-" + time.Now().Format("20060102150405")
	g := Group{
		ID:        id,
		Name:      name,
		CreatedAt: time.Now(),
	}
	s.groups[id] = g
	return g
}

func (s *Service) Get(id string) (Group, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	g, ok := s.groups[id]
	return g, ok
}

func (s *Service) List() []Group {
	s.mu.RLock()
	defer s.mu.RUnlock()
	result := make([]Group, 0, len(s.groups))
	for _, g := range s.groups {
		result = append(result, g)
	}
	return result
}
