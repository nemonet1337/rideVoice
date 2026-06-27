package livekit

import (
	"fmt"

	"github.com/livekit/protocol/auth"
)

type Client struct {
	host       string
	apiKey     string
	apiSecret  string
}

func NewClient(host, apiKey, apiSecret string) *Client {
	return &Client{
		host:      host,
		apiKey:    apiKey,
		apiSecret: apiSecret,
	}
}

func (c *Client) MintJoinToken(roomName, participantID string) (string, error) {
	at := auth.NewAccessToken(c.apiKey, c.apiSecret)
	grant := &auth.VideoGrant{
		RoomJoin: true,
		Room:     roomName,
	}
	at.AddGrant(grant).
		SetIdentity(participantID).
		SetValidFor(24 * 3600)

	return at.ToJWT()
}

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
