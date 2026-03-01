package event

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"time"

	"github.com/twmb/franz-go/pkg/kgo"
)

// Producer handles producing messages to Redpanda
type Producer struct {
	client *kgo.Client
}

// NewProducer creates a new Producer
func NewProducer(brokers []string) (*Producer, error) {
	opts := []kgo.Opt{
		kgo.SeedBrokers(brokers...),
	}

	client, err := kgo.NewClient(opts...)
	if err != nil {
		return nil, fmt.Errorf("unable to create redpanda client: %w", err)
	}

	// Test connection with retries
	var pingErr error
	for i := 0; i < 10; i++ {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		pingErr = client.Ping(ctx)
		cancel()
		if pingErr == nil {
			break
		}
		log.Printf("redpanda ping failed, retrying in 2s... (%v)", pingErr)
		time.Sleep(2 * time.Second)
	}

	if pingErr != nil {
		return nil, fmt.Errorf("redpanda ping failed after retries: %w", pingErr)
	}

	return &Producer{client: client}, nil
}

// Close closes the producer client
func (p *Producer) Close() {
	p.client.Close()
}

// BidEvent represents the schema for topic 'bid-requests'
type BidEvent struct {
	RequestID   string `json:"request_id"`
	BidID       string `json:"bid_id"`
	UserIDFV    string `json:"user_idfv"`
	CampaignID  string `json:"campaign_id"`
	PlacementID string `json:"placement_id"`
	Timestamp   int64  `json:"timestamp"`
}

// ProduceBid sends a BidEvent to the 'bid-requests' topic
func (p *Producer) ProduceBid(ctx context.Context, event BidEvent) error {
	val, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal bid event: %w", err)
	}

	record := &kgo.Record{
		Topic: "bid-requests",
		Key:   []byte(event.BidID),
		Value: val,
	}

	// Producer sync
	results := p.client.ProduceSync(ctx, record)
	if results.FirstErr() != nil {
		return fmt.Errorf("produce bid error: %w", results.FirstErr())
	}

	log.Printf("Produced bid-requests message for bid_id=%s", event.BidID)
	return nil
}

// ImpressionEvent represents the schema for topic 'impressions'
type ImpressionEvent struct {
	BidID      string `json:"bid_id"`
	CampaignID string `json:"campaign_id"`
	UserIDFV   string `json:"user_idfv"`
	Timestamp  int64  `json:"timestamp"`
}

// ProduceImpression sends an ImpressionEvent to the 'impressions' topic
func (p *Producer) ProduceImpression(ctx context.Context, event ImpressionEvent) error {
	val, err := json.Marshal(event)
	if err != nil {
		return fmt.Errorf("failed to marshal impression event: %w", err)
	}

	record := &kgo.Record{
		Topic: "impressions",
		Key:   []byte(event.BidID), // use bid_id as partitioning key
		Value: val,
	}

	results := p.client.ProduceSync(ctx, record)
	if results.FirstErr() != nil {
		return fmt.Errorf("produce impression error: %w", results.FirstErr())
	}

	log.Printf("Produced impressions message for bid_id=%s", event.BidID)
	return nil
}
