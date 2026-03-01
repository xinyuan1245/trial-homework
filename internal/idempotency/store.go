package idempotency

import (
	"context"
	"fmt"
	"time"

	"github.com/go-redis/redis/v8"
)

// Store handles idempotency logic using Redis
type Store struct {
	client *redis.Client
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
