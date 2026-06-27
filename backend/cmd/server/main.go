package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"time"

	"github.com/ridevoice/backend/internal/auth"
	"github.com/ridevoice/backend/internal/gateway"
	"github.com/ridevoice/backend/internal/groups"
	"github.com/ridevoice/backend/internal/livekit"
	"github.com/ridevoice/backend/internal/rooms"
)

type Config struct {
	Port           string
	LiveKitHost    string
	LiveKitAPIKey  string
	LiveKitAPISecret string
	JWTSecret      string
}

type Server struct {
	config   Config
	auth     *auth.Service
	rooms    *rooms.Service
	groups   *groups.Service
	gateway  *gateway.Registry
	livekit  *livekit.Client
}

func main() {
	cfg := Config{
		Port:           envOrDefault("PORT", "8080"),
		LiveKitHost:    envOrDefault("LIVEKIT_HOST", "http://localhost:7880"),
		LiveKitAPIKey:  os.Getenv("LIVEKIT_API_KEY"),
		LiveKitAPISecret: os.Getenv("LIVEKIT_API_SECRET"),
		JWTSecret:      envOrDefault("JWT_SECRET", "ridevoice-dev-secret"),
	}

	livekitClient := livekit.NewClient(cfg.LiveKitHost, cfg.LiveKitAPIKey, cfg.LiveKitAPISecret)

	srv := &Server{
		config:  cfg,
		auth:    auth.NewService(cfg.JWTSecret),
		rooms:   rooms.NewService(),
		groups:  groups.NewService(),
		gateway: gateway.NewRegistry(),
		livekit: livekitClient,
	}

	mux := http.NewServeMux()
	srv.registerRoutes(mux)

	addr := ":" + cfg.Port
	log.Printf("rideVoice backend starting on %s", addr)

	httpServer := &http.Server{
		Addr:         addr,
		Handler:      loggingMiddleware(mux),
		ReadTimeout:  15 * time.Second,
		WriteTimeout: 15 * time.Second,
		IdleTimeout:  60 * time.Second,
	}

	if err := httpServer.ListenAndServe(); err != nil {
		log.Fatalf("server failed: %v", err)
	}
}

func (s *Server) registerRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /health", s.handleHealth)

	mux.HandleFunc("POST /auth", s.handleAuth)

	mux.HandleFunc("POST /rooms", s.authMiddleware(s.handleCreateRoom))
	mux.HandleFunc("GET /rooms", s.authMiddleware(s.handleListRooms))
	mux.HandleFunc("GET /rooms/{id}", s.authMiddleware(s.handleGetRoom))
	mux.HandleFunc("DELETE /rooms/{id}", s.authMiddleware(s.handleDeleteRoom))
	mux.HandleFunc("POST /rooms/{id}/join-token", s.authMiddleware(s.handleJoinToken))

	mux.HandleFunc("POST /groups", s.authMiddleware(s.handleCreateGroup))
	mux.HandleFunc("GET /groups", s.authMiddleware(s.handleListGroups))
	mux.HandleFunc("GET /groups/{id}", s.authMiddleware(s.handleGetGroup))

	mux.HandleFunc("POST /gateway/register", s.authMiddleware(s.handleRegisterGateway))
	mux.HandleFunc("GET /gateway/nodes", s.authMiddleware(s.handleListGateways))
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) handleAuth(w http.ResponseWriter, r *http.Request) {
	token, err := s.auth.IssueToken("user-" + generateID())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

func (s *Server) handleCreateRoom(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	room := s.rooms.Create(req.Name)
	writeJSON(w, http.StatusCreated, room)
}

func (s *Server) handleListRooms(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.rooms.List())
}

func (s *Server) handleGetRoom(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	room, ok := s.rooms.Get(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "room not found"})
		return
	}
	writeJSON(w, http.StatusOK, room)
}

func (s *Server) handleDeleteRoom(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	if !s.rooms.Delete(id) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "room not found"})
		return
	}
	writeJSON(w, http.StatusNoContent, nil)
}

func (s *Server) handleJoinToken(w http.ResponseWriter, r *http.Request) {
	roomID := r.PathValue("id")
	var req struct {
		UserID string `json:"user_id"`
	}
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	token, err := s.livekit.MintJoinToken(roomID, req.UserID)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"token": token})
}

func (s *Server) handleCreateGroup(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Name string `json:"name"`
	}
	json.NewDecoder(r.Body).Decode(&req)
	group := s.groups.Create(req.Name)
	writeJSON(w, http.StatusCreated, group)
}

func (s *Server) handleListGroups(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, s.groups.List())
}

func (s *Server) handleGetGroup(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	group, ok := s.groups.Get(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "group not found"})
		return
	}
	writeJSON(w, http.StatusOK, group)
}

func (s *Server) handleRegisterGateway(w http.ResponseWriter, r *http.Request) {
	var req gateway.Node
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	s.gateway.Register(req)
	writeJSON(w, http.StatusCreated, map[string]string{"status": "registered"})
}

func (s *Server) handleListGateways(w http.ResponseWriter, r *http.Request) {
	nodes := s.gateway.List()
	if nodes == nil {
		nodes = []gateway.Node{}
	}
	writeJSON(w, http.StatusOK, nodes)
}

func (s *Server) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		token := r.Header.Get("Authorization")
		if token == "" || len(token) < 8 || token[:7] != "Bearer " {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		token = token[7:]
		if _, err := s.auth.ValidateToken(token); err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, data interface{}) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if data != nil {
		json.NewEncoder(w).Encode(data)
	}
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s %s", r.Method, r.URL.Path, time.Since(start))
	})
}

func generateID() string {
	return time.Now().Format("20060102150405") + randomString(6)
}

func randomString(n int) string {
	const letters = "abcdefghijklmnopqrstuvwxyz0123456789"
	b := make([]byte, n)
	for i := range b {
		b[i] = letters[time.Now().UnixNano()%int64(len(letters))]
		time.Sleep(1) // weak but avoids identical runs
	}
	return string(b)
}

func envOrDefault(key, defaultVal string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return defaultVal
}

func init() {
	log.SetFlags(log.LstdFlags | log.Lshortfile)
}
