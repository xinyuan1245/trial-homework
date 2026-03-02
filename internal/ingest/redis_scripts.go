package ingest

import (
	"context"
	"fmt"
	"time"

	"github.com/go-redis/redis/v8"
)

type RedisAggregator struct {
	rdb *redis.Client
	ttl time.Duration

	bidScript redis.Script
	impScript redis.Script
}

func NewRedisAggregator(rdb *redis.Client, ttl time.Duration) *RedisAggregator {
	// KEYS:
	// 1 seenBid
	// 2 pendingImp
	// 3 aggBidTotal
	// 4 aggUnknownImp
	// 5..N bid dimension agg keys
	// ARGV:
	// 1 ttlSeconds
	bidLua := `
local ok = redis.call("SETNX", KEYS[1], "1")
if ok == 0 then
  return 0
end
redis.call("EXPIRE", KEYS[1], tonumber(ARGV[1]))

redis.call("INCR", KEYS[3])
for i=5,#KEYS do
  redis.call("INCR", KEYS[i])
end

local deleted = redis.call("DEL", KEYS[2])
if deleted > 0 then
  redis.call("DECR", KEYS[4])
end
return 1
`

	// KEYS:
	// 1 seenImp
	// 2 seenBid
	// 3 pendingImp
	// 4 aggImpTotal
	// 5 aggUnknownImp
	// 6..N impression dimension agg keys
	// ARGV:
	// 1 ttlSeconds
	impLua := `
local ok = redis.call("SETNX", KEYS[1], "1")
if ok == 0 then
  return 0
end
redis.call("EXPIRE", KEYS[1], tonumber(ARGV[1]))

redis.call("INCR", KEYS[4])
for i=6,#KEYS do
  redis.call("INCR", KEYS[i])
end

local hasBid = redis.call("EXISTS", KEYS[2])
if hasBid == 0 then
  local pend = redis.call("SETNX", KEYS[3], "1")
  if pend == 1 then
    redis.call("EXPIRE", KEYS[3], tonumber(ARGV[1]))
    redis.call("INCR", KEYS[5])
  end
end
return 1
`

	return &RedisAggregator{
		rdb:       rdb,
		ttl:       ttl,
		bidScript: *redis.NewScript(bidLua),
		impScript: *redis.NewScript(impLua),
	}
}

func (a *RedisAggregator) ttlSeconds() string {
	return fmt.Sprintf("%d", int64(a.ttl.Seconds()))
}

func (a *RedisAggregator) addDimensionValues(ctx context.Context, dims map[string]string) {
	// Best-effort: dimension sets are for UI enumeration, not correctness of aggregates.
	pipe := a.rdb.Pipeline()
	for dim, val := range dims {
		if val == "" {
			val = "unknown"
		}
		pipe.SAdd(ctx, dimSetKey(dim), val)
	}
	_, _ = pipe.Exec(ctx)
}

func (a *RedisAggregator) ProcessBid(ctx context.Context, ev BidEvent, dimensions []string) (bool, error) {
	if ev.BidID == "" {
		return false, nil
	}

	metric := "bids"
	keys := []string{
		seenBidKey(ev.BidID),
		pendingImpKey(ev.BidID),
		aggBidTotalKey(),
		aggUnknownImpKey(),
	}

	dimValues := make(map[string]string, 3)
	for _, d := range dimensions {
		switch d {
		case "campaign_id":
			keys = append(keys, aggDimKey("campaign", ev.CampaignID, metric))
			dimValues["campaign"] = ev.CampaignID
		case "placement_id":
			keys = append(keys, aggDimKey("placement", ev.PlacementID, metric))
			dimValues["placement"] = ev.PlacementID
		case "app_bundle":
			keys = append(keys, aggDimKey("app_bundle", ev.AppBundle, metric))
			dimValues["app_bundle"] = ev.AppBundle
		}
	}

	res, err := a.bidScript.Run(ctx, a.rdb, keys, a.ttlSeconds()).Int()
	if err != nil {
		return false, err
	}
	processed := res == 1
	if processed && len(dimValues) > 0 {
		a.addDimensionValues(ctx, dimValues)
	}
	return processed, nil
}

func (a *RedisAggregator) ProcessImpression(ctx context.Context, ev ImpressionEvent, dimensions []string) (bool, error) {
	if ev.BidID == "" {
		return false, nil
	}

	metric := "impressions_dedup"
	keys := []string{
		seenImpKey(ev.BidID),
		seenBidKey(ev.BidID),
		pendingImpKey(ev.BidID),
		aggImpTotalKey(),
		aggUnknownImpKey(),
	}

	dimValues := make(map[string]string, 1)
	for _, d := range dimensions {
		switch d {
		case "campaign_id":
			keys = append(keys, aggDimKey("campaign", ev.CampaignID, metric))
			dimValues["campaign"] = ev.CampaignID
		}
	}

	res, err := a.impScript.Run(ctx, a.rdb, keys, a.ttlSeconds()).Int()
	if err != nil {
		return false, err
	}
	processed := res == 1
	if processed && len(dimValues) > 0 {
		a.addDimensionValues(ctx, dimValues)
	}
	return processed, nil
}
