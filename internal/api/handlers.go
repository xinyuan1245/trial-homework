package api

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"time"

	"github.com/google/uuid"

	"bidsrv/internal/campaign"
	"bidsrv/internal/event"
	"bidsrv/internal/idempotency"
)

// Handler holds dependencies for the HTTP handlers
type Handler struct {
	campaignMgr *campaign.Manager
	store       *idempotency.Store
	producer    *event.Producer
	baseURL     string
}

// NewHandler creates a new Handler
func NewHandler(bm *campaign.Manager, s *idempotency.Store, p *event.Producer, baseURL string) *Handler {
	return &Handler{
		campaignMgr: bm,
		store:       s,
		producer:    p,
		baseURL:     baseURL,
	}
}

// HandleHealthz responds with 200 OK
func (h *Handler) HandleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("ok"))
}

// HandleBid handles POST /v1/bid
func (h *Handler) HandleBid(w http.ResponseWriter, r *http.Request) {
	var req BidRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	requestID := uuid.New().String()

	// 1. Choose campaign
	camp := h.campaignMgr.SelectCampaign(req.UserIDFV)
	if camp == nil {
		// No fill
		w.WriteHeader(http.StatusNoContent)
		return
	}

	// 2. Generate bid ID
	bidID := uuid.New().String()

	metadata := idempotency.BidMetadata{
		CampaignID: camp.ID,
		UserIDFV:   req.UserIDFV,
	}
	if err := h.store.SaveBidMetadata(r.Context(), bidID, metadata); err != nil {
		log.Printf("error saving bid metadata: %v", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// 3. Log to Redpanda
	bidEvent := event.BidEvent{
		RequestID:   requestID,
		BidID:       bidID,
		UserIDFV:    req.UserIDFV,
		CampaignID:  camp.ID,
		AppBundle:   req.AppBundle,
		PlacementID: req.PlacementID,
		Timestamp:   time.Now().Unix(),
	}

	// Using background context because we don't want to fail if the HTTP request is canceled
	if err := h.producer.ProduceBid(r.Context(), bidEvent); err != nil {
		log.Printf("error producing bid to kafka: %v", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	// 4. Return successful response
	resp := BidResponse{
		RequestID:   requestID,
		BidID:       bidID,
		CampaignID:  camp.ID,
		CreativeURL: camp.CreativeURL,
		BillingURL:  fmt.Sprintf("%s/v1/billing", h.baseURL),
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(resp)
}

// HandleBilling handles POST /v1/billing
func (h *Handler) HandleBilling(w http.ResponseWriter, r *http.Request) {
	var req BillingRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		http.Error(w, "invalid request body", http.StatusBadRequest)
		return
	}

	if req.BidID == "" {
		http.Error(w, "bid_id is required", http.StatusBadRequest)
		return
	}

	// 1. Idempotency Check
	acquired, err := h.store.LockBilling(r.Context(), req.BidID)
	if err != nil {
		log.Printf("error checking idempotency: %v", err)
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	if !acquired {
		// Duplicate recognized, return 200 OK immediately
		log.Printf("duplicate billing for bid_id=%s, ignoring", req.BidID)
		w.WriteHeader(http.StatusOK)
		return
	}

	metadata, found, err := h.store.GetBidMetadata(r.Context(), req.BidID)
	if err != nil {
		log.Printf("error loading bid metadata: %v", err)
		if unlockErr := h.store.UnlockBilling(r.Context(), req.BidID); unlockErr != nil {
			log.Printf("error unlocking billing key after metadata failure: %v", unlockErr)
		}
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	timestamp := req.Timestamp
	if timestamp <= 0 {
		timestamp = time.Now().Unix()
	}

	campaignID := "unknown"
	userIDFV := "unknown"
	if found {
		campaignID = metadata.CampaignID
		userIDFV = metadata.UserIDFV
	}

	impressionEvent := event.ImpressionEvent{
		BidID:      req.BidID,
		CampaignID: campaignID,
		UserIDFV:   userIDFV,
		Timestamp:  timestamp,
	}

	if err := h.producer.ProduceImpression(r.Context(), impressionEvent); err != nil {
		log.Printf("error producing impression to kafka: %v", err)
		if unlockErr := h.store.UnlockBilling(r.Context(), req.BidID); unlockErr != nil {
			log.Printf("error unlocking billing key after produce failure: %v", unlockErr)
		}
		http.Error(w, "internal server error", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusOK)
}
