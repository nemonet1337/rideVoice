package livekit

import (
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

const (
	testKey    = "test-api-key"
	testSecret = "test-api-secret-32-characters-xx"
)

// LiveKit access tokens are HS256 JWTs signed with the API secret; decode
// one and verify the grants actually restrict the client to the requested
// room and identity.
func TestMintJoinTokenGrants(t *testing.T) {
	c := NewClient("http://localhost:7880", testKey, testSecret)

	tokenStr, err := c.MintJoinToken("room-42", "rider-7")
	if err != nil {
		t.Fatalf("MintJoinToken: %v", err)
	}

	token, err := jwt.Parse(
		tokenStr,
		func(tk *jwt.Token) (interface{}, error) { return []byte(testSecret), nil },
		jwt.WithValidMethods([]string{"HS256"}),
	)
	if err != nil {
		t.Fatalf("parsing minted token: %v", err)
	}
	claims, ok := token.Claims.(jwt.MapClaims)
	if !ok {
		t.Fatal("unexpected claims type")
	}

	if iss, _ := claims["iss"].(string); iss != testKey {
		t.Fatalf("issuer = %q, want API key", iss)
	}
	if sub, _ := claims.GetSubject(); sub != "rider-7" {
		t.Fatalf("subject = %q, want rider-7", sub)
	}

	video, ok := claims["video"].(map[string]interface{})
	if !ok {
		t.Fatal("token has no video grant")
	}
	if video["room"] != "room-42" {
		t.Fatalf("grant room = %v, want room-42", video["room"])
	}
	if video["roomJoin"] != true {
		t.Fatalf("grant roomJoin = %v, want true", video["roomJoin"])
	}

	// Expiry must be bounded (a former bug passed 24*3600 nanoseconds,
	// producing an instantly-expired token).
	exp, err := claims.GetExpirationTime()
	if err != nil || exp == nil {
		t.Fatalf("token has no exp: %v", err)
	}
	ttl := time.Until(exp.Time)
	if ttl < time.Hour || ttl > JoinTokenTTL+time.Minute {
		t.Fatalf("token TTL %v outside expected range (0, %v]", ttl, JoinTokenTTL)
	}
}

func TestMintJoinTokenRequiresCredentials(t *testing.T) {
	c := NewClient("http://localhost:7880", "", "")
	if _, err := c.MintJoinToken("room", "user"); err == nil {
		t.Fatal("expected error with empty credentials")
	}
}

func TestMintJoinTokenRequiresRoomAndIdentity(t *testing.T) {
	c := NewClient("http://localhost:7880", testKey, testSecret)
	if _, err := c.MintJoinToken("", "user"); err == nil {
		t.Fatal("expected error with empty room")
	}
	if _, err := c.MintJoinToken("room", ""); err == nil {
		t.Fatal("expected error with empty participant")
	}
}
