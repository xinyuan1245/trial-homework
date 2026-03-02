package ingest

import "fmt"

func seenBidKey(bidID string) string { return fmt.Sprintf("seen:bid:%s", bidID) }
func seenImpKey(bidID string) string { return fmt.Sprintf("seen:imp:%s", bidID) }

func pendingImpKey(bidID string) string { return fmt.Sprintf("pending:imp:%s", bidID) }

func aggBidTotalKey() string   { return "agg:bid_requests" }
func aggImpTotalKey() string   { return "agg:deduped_impressions" }
func aggUnknownImpKey() string { return "agg:unknown_impressions" }

func dimSetKey(dimension string) string {
	// Examples:
	// - dim:campaign
	// - dim:placement
	// - dim:app_bundle
	return fmt.Sprintf("dim:%s", dimension)
}

func aggDimKey(dimension, value, metric string) string {
	// Examples:
	// - agg:campaign:campaign1:bids
	// - agg:placement:placement-3:bids
	// - agg:app_bundle:com.zarli.sample.2:bids
	// - agg:campaign:campaign1:impressions_dedup
	if value == "" {
		value = "unknown"
	}
	return fmt.Sprintf("agg:%s:%s:%s", dimension, value, metric)
}
