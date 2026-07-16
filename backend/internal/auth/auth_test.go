package auth

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
)

func TestIssueAndValidate(t *testing.T) {
	svc := NewService("test-secret")
	token, err := svc.IssueToken("user-1")
	if err != nil {
		t.Fatalf("IssueToken: %v", err)
	}
	if token == "" {
		t.Fatal("token is empty")
	}

	sub, err := svc.ValidateToken(token)
	if err != nil {
		t.Fatalf("ValidateToken: %v", err)
	}
	if sub != "user-1" {
		t.Fatalf("expected subject user-1, got %q", sub)
	}
}

func TestValidateInvalidToken(t *testing.T) {
	svc := NewService("test-secret")
	if _, err := svc.ValidateToken("invalid-token"); err == nil {
		t.Fatal("expected error for invalid token")
	}
}

func TestValidateWrongSecret(t *testing.T) {
	svc1 := NewService("secret-1")
	token, _ := svc1.IssueToken("user-1")

	svc2 := NewService("secret-2")
	if _, err := svc2.ValidateToken(token); err == nil {
		t.Fatal("expected error for token from different secret")
	}
}

func TestValidateExpiredToken(t *testing.T) {
	svc := NewService("test-secret")
	token, err := svc.issueTokenWithTTL("user-1", -time.Minute)
	if err != nil {
		t.Fatalf("issueTokenWithTTL: %v", err)
	}
	if _, err := svc.ValidateToken(token); err == nil {
		t.Fatal("expected error for expired token")
	}
}

func TestValidateTamperedSignature(t *testing.T) {
	svc := NewService("test-secret")
	token, _ := svc.IssueToken("user-1")

	// Flip a character in the signature segment.
	parts := strings.Split(token, ".")
	sig := []byte(parts[2])
	if sig[0] == 'A' {
		sig[0] = 'B'
	} else {
		sig[0] = 'A'
	}
	tampered := parts[0] + "." + parts[1] + "." + string(sig)
	if _, err := svc.ValidateToken(tampered); err == nil {
		t.Fatal("expected error for tampered signature")
	}
}

// Algorithm-confusion: a token declaring alg=none must never validate.
func TestValidateRejectsAlgNone(t *testing.T) {
	svc := NewService("test-secret")

	claims := jwt.MapClaims{
		"sub": "attacker",
		"exp": time.Now().Add(time.Hour).Unix(),
	}
	token := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	signed, err := token.SignedString(jwt.UnsafeAllowNoneSignatureType)
	if err != nil {
		t.Fatalf("signing alg=none token: %v", err)
	}
	if _, err := svc.ValidateToken(signed); err == nil {
		t.Fatal("alg=none token was accepted")
	}
}

// Algorithm-confusion: a forged token claiming RS256 (with garbage
// signature) must be rejected by the pinned-method check, not attempted
// against the HMAC secret.
func TestValidateRejectsForeignAlgorithm(t *testing.T) {
	svc := NewService("test-secret")

	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	payload := base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"attacker","exp":4102444800}`))
	forged := header + "." + payload + "." + base64.RawURLEncoding.EncodeToString([]byte("sig"))
	if _, err := svc.ValidateToken(forged); err == nil {
		t.Fatal("RS256-declared token was accepted")
	}

	// HS512 is HMAC but not the pinned method either.
	hs512 := jwt.NewWithClaims(jwt.SigningMethodHS512, jwt.MapClaims{
		"sub": "attacker",
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	signed, err := hs512.SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatalf("signing HS512 token: %v", err)
	}
	if _, err := svc.ValidateToken(signed); err == nil {
		t.Fatal("HS512 token was accepted despite HS256 pinning")
	}
}

func TestValidateRejectsMissingExpiry(t *testing.T) {
	svc := NewService("test-secret")
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{"sub": "user-1"})
	signed, err := token.SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatalf("signing: %v", err)
	}
	if _, err := svc.ValidateToken(signed); err == nil {
		t.Fatal("token without exp was accepted")
	}
}

func TestValidateRejectsMissingSubject(t *testing.T) {
	svc := NewService("test-secret")
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"exp": time.Now().Add(time.Hour).Unix(),
	})
	signed, err := token.SignedString([]byte("test-secret"))
	if err != nil {
		t.Fatalf("signing: %v", err)
	}
	if _, err := svc.ValidateToken(signed); err == nil {
		t.Fatal("token without sub was accepted")
	}
}
