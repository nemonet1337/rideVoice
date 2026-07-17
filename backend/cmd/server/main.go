package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/ridevoice/backend/internal/auth"
	"github.com/ridevoice/backend/internal/gateway"
	"github.com/ridevoice/backend/internal/groups"
	"github.com/ridevoice/backend/internal/livekit"
	"github.com/ridevoice/backend/internal/rooms"
)

type Config struct {
	Port             string
	LiveKitHost      string
	LiveKitAPIKey    string
	LiveKitAPISecret string
	JWTSecret        string
}

type Server struct {
	config  Config
	auth    *auth.Service
	rooms   *rooms.Service
	groups  *groups.Service
	gateway *gateway.Registry
	livekit *livekit.Client
}

type contextKey string

const userIDKey contextKey = "userID"

func main() {
	cfg := Config{
		Port:             envOrDefault("PORT", "8080"),
		LiveKitHost:      envOrDefault("LIVEKIT_HOST", "http://localhost:7880"),
		LiveKitAPIKey:    os.Getenv("LIVEKIT_API_KEY"),
		LiveKitAPISecret: os.Getenv("LIVEKIT_API_SECRET"),
		JWTSecret:        os.Getenv("JWT_SECRET"),
	}
	// Refuse to start with a missing signing secret rather than silently
	// falling back to a guessable default.
	if cfg.JWTSecret == "" {
		log.Fatal("JWT_SECRET is not set; refusing to start with no token signing secret")
	}

	srv := newServer(cfg)
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

func newServer(cfg Config) *Server {
	return &Server{
		config:  cfg,
		auth:    auth.NewService(cfg.JWTSecret),
		rooms:   rooms.NewService(),
		groups:  groups.NewService(),
		gateway: gateway.NewRegistry(),
		livekit: livekit.NewClient(cfg.LiveKitHost, cfg.LiveKitAPIKey, cfg.LiveKitAPISecret),
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

// handleAuth issues a token for an anonymous device identity. This is a
// development-stage placeholder — see docs/DESIGN_DEVIATIONS.md for the
// limitation and the planned device-registration flow.
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
	if strings.TrimSpace(req.Name) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
	room := s.rooms.Create(req.Name, userIDFrom(r))
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
	room, ok := s.rooms.Get(id)
	if !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "room not found"})
		return
	}
	if room.CreatedBy != userIDFrom(r) {
		writeJSON(w, http.StatusForbidden, map[string]string{"error": "only the room creator can delete it"})
		return
	}
	s.rooms.Delete(id)
	writeJSON(w, http.StatusNoContent, nil)
}

func (s *Server) handleJoinToken(w http.ResponseWriter, r *http.Request) {
	roomID := r.PathValue("id")
	if _, ok := s.rooms.Get(roomID); !ok {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "room not found"})
		return
	}
	// The LiveKit identity is the authenticated user, not a
	// client-chosen name, so tokens cannot impersonate other riders.
	token, err := s.livekit.MintJoinToken(roomID, userIDFrom(r))
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
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "invalid body"})
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "name is required"})
		return
	}
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
	if strings.TrimSpace(req.ID) == "" {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "id is required"})
		return
	}
	if req.BatteryPct < 0 || req.BatteryPct > 100 {
		writeJSON(w, http.StatusBadRequest, map[string]string{"error": "battery_pct must be 0-100"})
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
		header := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(header, "Bearer ")
		if !ok || token == "" {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
			return
		}
		userID, err := s.auth.ValidateToken(token)
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"error": "invalid token"})
			return
		}
		next(w, r.WithContext(context.WithValue(r.Context(), userIDKey, userID)))
	}
}

func userIDFrom(r *http.Request) string {
	id, _ := r.Context().Value(userIDKey).(string)
	return id
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
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		log.Fatalf("crypto/rand unavailable: %v", err)
	}
	return hex.EncodeToString(b)
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
