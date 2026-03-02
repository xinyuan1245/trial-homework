package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"bidsrv/internal/ingest"
)

func main() {
	mode := ingest.Mode(getEnv("MODE", string(ingest.ModeBids)))

	brokers := strings.Split(getEnv("KAFKA_BROKERS", "localhost:9092"), ",")
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")

	topic := getEnv("TOPIC", "")
	groupID := getEnv("GROUP_ID", "")
	dimensions := splitCSV(getEnv("DIMENSIONS", "campaign_id"))

	switch mode {
	case ingest.ModeBids:
		if topic == "" {
			topic = "bid-requests"
		}
		if groupID == "" {
			groupID = "ingester-bids"
		}
		// Default to a few low-cardinality dimensions; user_idfv is high-cardinality.
		if len(dimensions) == 0 || (len(dimensions) == 1 && dimensions[0] == "campaign_id") {
			dimensions = splitCSV(getEnv("DIMENSIONS", "campaign_id,placement_id,app_bundle"))
		}
	case ingest.ModeImpressions:
		if topic == "" {
			topic = "impressions"
		}
		if groupID == "" {
			groupID = "ingester-impressions"
		}
		if len(dimensions) == 0 {
			dimensions = []string{"campaign_id"}
		}
	default:
		log.Fatalf("unknown MODE=%s (expected bids|impressions)", mode)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	cfg := ingest.Config{
		Mode:         mode,
		Brokers:      brokers,
		Topic:        topic,
		GroupID:      groupID,
		RedisAddr:    redisAddr,
		KeyTTL:       24 * time.Hour,
		Dimensions:   dimensions,
		LogEvery:     5000,
		PollTimeout:  2 * time.Second,
		ResetToStart: true,
	}

	if err := ingest.Run(ctx, cfg); err != nil && err != context.Canceled {
		log.Fatalf("ingester failed: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}

func splitCSV(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		out = append(out, p)
	}
	return out
}
