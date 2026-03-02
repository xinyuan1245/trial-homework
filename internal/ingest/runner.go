package ingest

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/go-redis/redis/v8"
	"github.com/twmb/franz-go/pkg/kgo"
)

type Mode string

const (
	ModeBids        Mode = "bids"
	ModeImpressions Mode = "impressions"
)

type Config struct {
	Mode         Mode
	Brokers      []string
	Topic        string
	GroupID      string
	RedisAddr    string
	KeyTTL       time.Duration
	Dimensions   []string
	LogEvery     int
	PollTimeout  time.Duration
	ResetToStart bool
}

func Run(ctx context.Context, cfg Config) error {
	rdb := redis.NewClient(&redis.Options{Addr: cfg.RedisAddr})
	if err := rdb.Ping(ctx).Err(); err != nil {
		return fmt.Errorf("redis ping failed: %w", err)
	}
	agg := NewRedisAggregator(rdb, cfg.KeyTTL)

	opts := []kgo.Opt{
		kgo.SeedBrokers(cfg.Brokers...),
		kgo.ConsumerGroup(cfg.GroupID),
		kgo.ConsumeTopics(cfg.Topic),
		kgo.DisableAutoCommit(),
	}
	if cfg.ResetToStart {
		opts = append(opts, kgo.ConsumeResetOffset(kgo.NewOffset().AtStart()))
	}

	cl, err := kgo.NewClient(opts...)
	if err != nil {
		return fmt.Errorf("kgo new client failed: %w", err)
	}
	defer cl.Close()

	log.Printf("ingester started mode=%s topic=%s group=%s brokers=%s redis=%s dims=%s",
		cfg.Mode, cfg.Topic, cfg.GroupID, strings.Join(cfg.Brokers, ","), cfg.RedisAddr, strings.Join(cfg.Dimensions, ","))

	processed := 0
	for {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}

		pollCtx, cancel := context.WithTimeout(ctx, cfg.PollTimeout)
		fetches := cl.PollFetches(pollCtx)
		cancel()

		if err := fetches.Err(); err != nil {
			// kgo uses context error when poll times out; treat as normal.
			if err == context.DeadlineExceeded {
				continue
			}
			log.Printf("poll error: %v", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		var processErr error
		fetches.EachRecord(func(r *kgo.Record) {
			if processErr != nil {
				return
			}

			switch cfg.Mode {
			case ModeBids:
				var ev BidEvent
				if err := json.Unmarshal(r.Value, &ev); err != nil {
					log.Printf("bad bid json: %v", err)
					return
				}
				_, err := agg.ProcessBid(ctx, ev, cfg.Dimensions)
				if err != nil {
					processErr = err
					return
				}
			case ModeImpressions:
				var ev ImpressionEvent
				if err := json.Unmarshal(r.Value, &ev); err != nil {
					log.Printf("bad impression json: %v", err)
					return
				}
				_, err := agg.ProcessImpression(ctx, ev, cfg.Dimensions)
				if err != nil {
					processErr = err
					return
				}
			default:
				processErr = fmt.Errorf("unknown mode: %s", cfg.Mode)
				return
			}

			processed++
			if cfg.LogEvery > 0 && processed%cfg.LogEvery == 0 {
				log.Printf("processed=%d mode=%s", processed, cfg.Mode)
			}
		})

		if processErr != nil {
			log.Printf("process error: %v", processErr)
			time.Sleep(500 * time.Millisecond)
			continue
		}

		if err := cl.CommitUncommittedOffsets(ctx); err != nil {
			log.Printf("commit error: %v", err)
			time.Sleep(500 * time.Millisecond)
			continue
		}
	}
}
