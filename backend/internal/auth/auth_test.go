package auth

import (
	"testing"
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

	parsed, err := svc.ValidateToken(token)
	if err != nil {
		t.Fatalf("ValidateToken: %v", err)
	}
	if !parsed.Valid {
		t.Fatal("token is not valid")
	}
}

func TestValidateInvalidToken(t *testing.T) {
	svc := NewService("test-secret")
	_, err := svc.ValidateToken("invalid-token")
	if err == nil {
		t.Fatal("expected error for invalid token")
	}
}

func TestValidateWrongSecret(t *testing.T) {
	svc1 := NewService("secret-1")
	token, _ := svc1.IssueToken("user-1")

	svc2 := NewService("secret-2")
	_, err := svc2.ValidateToken(token)
	if err == nil {
		t.Fatal("expected error for token from different secret")
	}
}
