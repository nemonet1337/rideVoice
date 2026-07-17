package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func testServer() *httptest.Server {
	srv := newServer(Config{
		Port:             "0",
		LiveKitHost:      "http://localhost:7880",
		LiveKitAPIKey:    "test-api-key",
		LiveKitAPISecret: "test-api-secret-32-characters-xx",
		JWTSecret:        "test-jwt-secret",
	})
	mux := http.NewServeMux()
	srv.registerRoutes(mux)
	return httptest.NewServer(mux)
}

func doJSON(t *testing.T, method, url, token string, body interface{}) (*http.Response, map[string]interface{}) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		if err := json.NewEncoder(&buf).Encode(body); err != nil {
			t.Fatalf("encoding body: %v", err)
		}
	}
	req, err := http.NewRequest(method, url, &buf)
	if err != nil {
		t.Fatalf("building request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	defer resp.Body.Close()
	var decoded map[string]interface{}
	_ = json.NewDecoder(resp.Body).Decode(&decoded)
	return resp, decoded
}

func authToken(t *testing.T, ts *httptest.Server) string {
	t.Helper()
	resp, body := doJSON(t, http.MethodPost, ts.URL+"/auth", "", nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/auth returned %d", resp.StatusCode)
	}
	token, _ := body["token"].(string)
	if token == "" {
		t.Fatal("/auth returned empty token")
	}
	return token
}

func TestAuthRoomJoinTokenFlow(t *testing.T) {
	ts := testServer()
	defer ts.Close()
	token := authToken(t, ts)

	resp, room := doJSON(t, http.MethodPost, ts.URL+"/rooms", token, map[string]string{"name": "touring"})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("create room returned %d", resp.StatusCode)
	}
	roomID, _ := room["id"].(string)
	if roomID == "" {
		t.Fatal("room has no id")
	}

	resp, _ = doJSON(t, http.MethodGet, ts.URL+"/rooms/"+roomID, token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("get room returned %d", resp.StatusCode)
	}

	resp, jt := doJSON(t, http.MethodPost, ts.URL+"/rooms/"+roomID+"/join-token", token, map[string]string{})
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("join-token returned %d (%v)", resp.StatusCode, jt)
	}
	if jt["token"] == "" {
		t.Fatal("join-token response has no token")
	}
}

func TestJoinTokenForMissingRoom(t *testing.T) {
	ts := testServer()
	defer ts.Close()
	token := authToken(t, ts)

	resp, _ := doJSON(t, http.MethodPost, ts.URL+"/rooms/room-nope/join-token", token, map[string]string{})
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("join-token for missing room returned %d, want 404", resp.StatusCode)
	}
}

func TestProtectedEndpointsRejectMissingOrBadToken(t *testing.T) {
	ts := testServer()
	defer ts.Close()

	cases := []struct {
		name  string
		token string
	}{
		{"no token", ""},
		{"garbage token", "not-a-jwt"},
	}
	for _, tc := range cases {
		resp, _ := doJSON(t, http.MethodGet, ts.URL+"/rooms", tc.token, nil)
		if resp.StatusCode != http.StatusUnauthorized {
			t.Fatalf("%s: GET /rooms returned %d, want 401", tc.name, resp.StatusCode)
		}
	}

	// A token signed with a different secret must be rejected too.
	other := testServerWithSecret("other-secret")
	defer other.Close()
	foreign := authToken(t, other)
	resp, _ := doJSON(t, http.MethodGet, ts.URL+"/rooms", foreign, nil)
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("foreign-secret token accepted: %d", resp.StatusCode)
	}
}

func testServerWithSecret(secret string) *httptest.Server {
	srv := newServer(Config{JWTSecret: secret})
	mux := http.NewServeMux()
	srv.registerRoutes(mux)
	return httptest.NewServer(mux)
}

// Only the creator may delete a room (minimal per-user authorization).
func TestRoomDeleteOwnership(t *testing.T) {
	ts := testServer()
	defer ts.Close()
	owner := authToken(t, ts)
	stranger := authToken(t, ts)

	_, room := doJSON(t, http.MethodPost, ts.URL+"/rooms", owner, map[string]string{"name": "mine"})
	roomID, _ := room["id"].(string)

	resp, _ := doJSON(t, http.MethodDelete, ts.URL+"/rooms/"+roomID, stranger, nil)
	if resp.StatusCode != http.StatusForbidden {
		t.Fatalf("stranger delete returned %d, want 403", resp.StatusCode)
	}

	resp, _ = doJSON(t, http.MethodDelete, ts.URL+"/rooms/"+roomID, owner, nil)
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("owner delete returned %d, want 204", resp.StatusCode)
	}
}

func TestCreateRoomValidation(t *testing.T) {
	ts := testServer()
	defer ts.Close()
	token := authToken(t, ts)

	resp, _ := doJSON(t, http.MethodPost, ts.URL+"/rooms", token, map[string]string{"name": "  "})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("blank room name returned %d, want 400", resp.StatusCode)
	}
	resp, _ = doJSON(t, http.MethodPost, ts.URL+"/groups", token, map[string]string{})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("missing group name returned %d, want 400", resp.StatusCode)
	}
}

func TestGatewayRegistrationValidation(t *testing.T) {
	ts := testServer()
	defer ts.Close()
	token := authToken(t, ts)

	resp, _ := doJSON(t, http.MethodPost, ts.URL+"/gateway/register", token,
		map[string]interface{}{"id": "", "battery_pct": 80})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty gateway id returned %d, want 400", resp.StatusCode)
	}

	resp, _ = doJSON(t, http.MethodPost, ts.URL+"/gateway/register", token,
		map[string]interface{}{"id": "gw-1", "battery_pct": 150})
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("battery 150%% returned %d, want 400", resp.StatusCode)
	}

	resp, _ = doJSON(t, http.MethodPost, ts.URL+"/gateway/register", token,
		map[string]interface{}{"id": "gw-1", "battery_pct": 80, "connectivity": "online"})
	if resp.StatusCode != http.StatusCreated {
		t.Fatalf("valid gateway registration returned %d, want 201", resp.StatusCode)
	}

	resp, _ = doJSON(t, http.MethodGet, ts.URL+"/gateway/nodes", token, nil)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("list gateways returned %d", resp.StatusCode)
	}
}
