package idempotency

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/go-redis/redis/v8"
)

// Store handles idempotency logic using Redis
type Store struct {
	client *redis.Client
}

// BidMetadata stores bid fields needed to enrich impression events.
type BidMetadata struct {
	CampaignID string `json:"campaign_id"`
	UserIDFV   string `json:"user_idfv"`
}

// NewStore creates a new idempotency Store
func NewStore(addr string) (*Store, error) {
	client := redis.NewClient(&redis.Options{
		Addr: addr,
	})

	// Test connection
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.Ping(ctx).Err(); err != nil {
		return nil, fmt.Errorf("redis ping failed: %w", err)
	}

	return &Store{client: client}, nil
}

// LockBilling attempts to acquire a lock for a given bidID.
// It returns true if the lock was successfully acquired (meaning this is the first billing request),
// and false if the lock already exists (meaning this is a duplicate request).
func (s *Store) LockBilling(ctx context.Context, bidID string) (bool, error) {
	key := fmt.Sprintf("billing:%s", bidID)
	// 24 hours TTL per requirements
	ttl := 24 * time.Hour

	// SETNX: Set if Not eXists
	acquired, err := s.client.SetNX(ctx, key, "1", ttl).Result()
	if err != nil {
		return false, fmt.Errorf("failed to setnx on redis: %w", err)
	}

	return acquired, nil
}

// UnlockBilling deletes the idempotency lock so billing can be retried after downstream failures.
func (s *Store) UnlockBilling(ctx context.Context, bidID string) error {
	key := fmt.Sprintf("billing:%s", bidID)
	if err := s.client.Del(ctx, key).Err(); err != nil {
		return fmt.Errorf("failed to delete billing lock: %w", err)
	}
	return nil
}

// SaveBidMetadata stores campaign/user metadata by bidID to enrich future impression events.
func (s *Store) SaveBidMetadata(ctx context.Context, bidID string, metadata BidMetadata) error {
	key := fmt.Sprintf("bidmeta:%s", bidID)
	ttl := 24 * time.Hour

	val, err := json.Marshal(metadata)
	if err != nil {
		return fmt.Errorf("failed to marshal bid metadata: %w", err)
	}

	if err := s.client.Set(ctx, key, val, ttl).Err(); err != nil {
		return fmt.Errorf("failed to save bid metadata: %w", err)
	}

	return nil
}

// GetBidMetadata retrieves bid metadata by bidID.
// Returns found=false when the bidID has no matching metadata.
func (s *Store) GetBidMetadata(ctx context.Context, bidID string) (BidMetadata, bool, error) {
	key := fmt.Sprintf("bidmeta:%s", bidID)

	val, err := s.client.Get(ctx, key).Result()
	if err == redis.Nil {
		return BidMetadata{}, false, nil
	}
	if err != nil {
		return BidMetadata{}, false, fmt.Errorf("failed to load bid metadata: %w", err)
	}

	var metadata BidMetadata
	if err := json.Unmarshal([]byte(val), &metadata); err != nil {
		return BidMetadata{}, false, fmt.Errorf("failed to unmarshal bid metadata: %w", err)
	}

	return metadata, true, nil
}
