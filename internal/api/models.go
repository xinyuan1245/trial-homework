package api

// BidRequest represents the input for POST /v1/bid
type BidRequest struct {
	UserIDFV    string `json:"user_idfv"`
	AppBundle   string `json:"app_bundle"`
	PlacementID string `json:"placement_id"`
	Timestamp   int64  `json:"timestamp"`
}

// BidResponse represents the output for POST /v1/bid
type BidResponse struct {
	RequestID   string `json:"request_id"`
	BidID       string `json:"bid_id"`
	CampaignID  string `json:"campaign_id"`
	CreativeURL string `json:"creative_url"`
	BillingURL  string `json:"billing_url"`
}

// BillingRequest represents the input for POST /v1/billing
type BillingRequest struct {
	BidID     string `json:"bid_id"`
	Timestamp int64  `json:"timestamp"`
}
