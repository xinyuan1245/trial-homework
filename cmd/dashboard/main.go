package main

import (
	"context"
	"log"
	"os"
	"os/signal"
	"syscall"

	"bidsrv/internal/dashboard"
)

func main() {
	redisAddr := getEnv("REDIS_ADDR", "localhost:6379")
	port := getEnv("PORT", "8082")

	s, err := dashboard.NewServer(redisAddr, ":"+port)
	if err != nil {
		log.Fatalf("dashboard init failed: %v", err)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := s.Run(ctx); err != nil && err != context.Canceled {
		log.Fatalf("dashboard failed: %v", err)
	}
}

func getEnv(key, fallback string) string {
	if value, exists := os.LookupEnv(key); exists {
		return value
	}
	return fallback
}
