package ingest

// BidEvent mirrors the JSON schema in internal/event.BidEvent.
// Keep this local to avoid importing producer-side packages.
type BidEvent struct {
	BidID       string `json:"bid_id"`
	UserIDFV    string `json:"user_idfv"`
	CampaignID  string `json:"campaign_id"`
	PlacementID string `json:"placement_id"`
	AppBundle   string `json:"app_bundle"`
	Timestamp   int64  `json:"timestamp"`
}

// ImpressionEvent mirrors the JSON schema in internal/event.ImpressionEvent.
type ImpressionEvent struct {
	BidID      string `json:"bid_id"`
	CampaignID string `json:"campaign_id"`
	UserIDFV   string `json:"user_idfv"`
	Timestamp  int64  `json:"timestamp"`
}
