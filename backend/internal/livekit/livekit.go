package livekit

import (
	"errors"
	"fmt"
	"time"

	"github.com/livekit/protocol/auth"
)

// JoinTokenTTL bounds how long a minted room join token stays usable.
const JoinTokenTTL = 6 * time.Hour

type Client struct {
	host      string
	apiKey    string
	apiSecret string
}

func NewClient(host, apiKey, apiSecret string) *Client {
	return &Client{
		host:      host,
		apiKey:    apiKey,
		apiSecret: apiSecret,
	}
}

func (c *Client) MintJoinToken(roomName, participantID string) (string, error) {
	if c.apiKey == "" || c.apiSecret == "" {
		return "", errors.New("LiveKit API credentials are not configured")
	}
	if roomName == "" || participantID == "" {
		return "", errors.New("room name and participant ID are required")
	}
	at := auth.NewAccessToken(c.apiKey, c.apiSecret)
	grant := &auth.VideoGrant{
		RoomJoin: true,
		Room:     roomName,
	}
	at.AddGrant(grant).
		SetIdentity(participantID).
		SetValidFor(JoinTokenTTL)

	return at.ToJWT()
}

// CreateRoom / DeleteRoom are intentionally no-ops for now: LiveKit
// auto-creates rooms on first join, and this backend has no SFU
// admin credentials in local dev. Wire RoomServiceClient here when
// server-side room lifecycle management is needed.
func (c *Client) CreateRoom(roomName string) (string, error) {
	return roomName, nil
}

func (c *Client) DeleteRoom(roomName string) error {
	_ = roomName
	return nil
}

func (c *Client) ListRooms() ([]string, error) {
	return nil, fmt.Errorf("not implemented")
}
