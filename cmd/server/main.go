package main

import (
	"log"
	"net/http"
	"os"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"bidsrv/internal/api"
	"bidsrv/internal/campaign"
	"bidsrv/internal/event"
	"bidsrv/internal/idempotency"
)

func main() {
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	kafkaBrokers := getEnv("KAFKA_BROKERS", "localhost:9092")
	port := getEnv("PORT", "8080")
	baseURL := getEnv("BASE_URL", "http://localhost:8080")

	// 1. Init Redis
	store, err := idempotency.NewStore(redisAddr)
	if err != nil {
		log.Fatalf("failed to init redis: %v", err)
	}

	// 2. Init Kafka Producer
	brokers := strings.Split(kafkaBrokers, ",")
	producer, err := event.NewProducer(brokers)
	if err != nil {
		log.Fatalf("failed to init redpanda producer: %v", err)
	}
	defer producer.Close()

	// 3. Init Campaign Manager
	campaignMgr := campaign.NewManager()

	// 4. Init Handlers
	handler := api.NewHandler(campaignMgr, store, producer, baseURL)

	// 5. Setup Router
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	r.Get("/healthz", handler.HandleHealthz)
	r.Post("/v1/bid", handler.HandleBid)
	r.Post("/v1/billing", handler.HandleBilling)

	log.Printf("Server starting on port %s", port)
	if err := http.ListenAndServe(":"+port, r); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}
