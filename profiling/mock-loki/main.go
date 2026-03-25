package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/golang/snappy"
	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	registry = prometheus.NewRegistry()

	eventsReceivedTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mock_loki_events_received_total",
		Help: "Total number of log events received",
	})

	bytesReceivedTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mock_loki_bytes_received_total",
		Help: "Total number of bytes received (compressed)",
	})

	pushRequestsTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mock_loki_push_requests_total",
		Help: "Total number of push requests received",
	})

	pushErrorsTotal = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "mock_loki_push_errors_total",
		Help: "Total number of push errors returned",
	})

	// Shadow counters for periodic stats logging
	shadowEvents atomic.Int64
	shadowBytes  atomic.Int64
	shadowReqs   atomic.Int64
	shadowErrors atomic.Int64
)

// lokiPushRequest represents the JSON structure of a Loki push request.
type lokiPushRequest struct {
	Streams []lokiStream `json:"streams"`
}

type lokiStream struct {
	Stream map[string]string `json:"stream"`
	Values [][]string        `json:"values"`
}

func init() {
	registry.MustRegister(eventsReceivedTotal)
	registry.MustRegister(bytesReceivedTotal)
	registry.MustRegister(pushRequestsTotal)
	registry.MustRegister(pushErrorsTotal)
}

func getEnv(key, defaultVal string) string {
	if val, ok := os.LookupEnv(key); ok {
		return val
	}
	return defaultVal
}

func getEnvFloat(key string, defaultVal float64) float64 {
	val, ok := os.LookupEnv(key)
	if !ok {
		return defaultVal
	}
	f, err := strconv.ParseFloat(val, 64)
	if err != nil {
		log.Printf("WARN: invalid value for %s=%q, using default %.2f", key, val, defaultVal)
		return defaultVal
	}
	return f
}

func getEnvInt(key string, defaultVal int) int {
	val, ok := os.LookupEnv(key)
	if !ok {
		return defaultVal
	}
	i, err := strconv.Atoi(val)
	if err != nil {
		log.Printf("WARN: invalid value for %s=%q, using default %d", key, val, defaultVal)
		return defaultVal
	}
	return i
}

func main() {
	listenAddr := getEnv("LISTEN_ADDR", ":3100")
	responseLatencyMs := getEnvInt("RESPONSE_LATENCY_MS", 0)
	errorRate := getEnvFloat("ERROR_RATE", 0.0)

	log.Printf("Starting mock-loki server on %s", listenAddr)
	log.Printf("  RESPONSE_LATENCY_MS=%d", responseLatencyMs)
	log.Printf("  ERROR_RATE=%.4f", errorRate)

	mux := http.NewServeMux()

	mux.HandleFunc("/loki/api/v1/push", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		pushRequestsTotal.Inc()
		shadowReqs.Add(1)

		// Simulate error rate
		if errorRate > 0 && rand.Float64() < errorRate {
			pushErrorsTotal.Inc()
			shadowErrors.Add(1)
			http.Error(w, "simulated error", http.StatusInternalServerError)
			return
		}

		// Simulate response latency
		if responseLatencyMs > 0 {
			time.Sleep(time.Duration(responseLatencyMs) * time.Millisecond)
		}

		body, err := io.ReadAll(r.Body)
		if err != nil {
			pushErrorsTotal.Inc()
			shadowErrors.Add(1)
			http.Error(w, fmt.Sprintf("failed to read body: %v", err), http.StatusBadRequest)
			return
		}
		defer r.Body.Close()

		compressedSize := int64(len(body))
		bytesReceivedTotal.Add(float64(compressedSize))
		shadowBytes.Add(compressedSize)

		decoded, err := snappy.Decode(nil, body)
		if err != nil {
			pushErrorsTotal.Inc()
			shadowErrors.Add(1)
			http.Error(w, fmt.Sprintf("failed to decompress snappy: %v", err), http.StatusBadRequest)
			return
		}

		var pushReq lokiPushRequest
		if err := json.Unmarshal(decoded, &pushReq); err != nil {
			pushErrorsTotal.Inc()
			shadowErrors.Add(1)
			http.Error(w, fmt.Sprintf("failed to unmarshal JSON: %v", err), http.StatusBadRequest)
			return
		}

		var eventCount int64
		for _, stream := range pushReq.Streams {
			eventCount += int64(len(stream.Values))
		}

		eventsReceivedTotal.Add(float64(eventCount))
		shadowEvents.Add(eventCount)

		w.WriteHeader(http.StatusNoContent)
	})

	mux.HandleFunc("/ready", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		fmt.Fprintln(w, "ready")
	})

	mux.Handle("/metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))

	server := &http.Server{
		Addr:         listenAddr,
		Handler:      mux,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
		IdleTimeout:  120 * time.Second,
	}

	// Periodic stats logging
	statsTicker := time.NewTicker(10 * time.Second)
	go func() {
		for range statsTicker.C {
			log.Printf("stats: events=%d bytes=%d requests=%d errors=%d",
				shadowEvents.Load(),
				shadowBytes.Load(),
				shadowReqs.Load(),
				shadowErrors.Load(),
			)
		}
	}()

	// Graceful shutdown
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigCh
		log.Printf("Received signal %v, shutting down...", sig)
		statsTicker.Stop()

		log.Printf("final stats: events=%d bytes=%d requests=%d errors=%d",
			shadowEvents.Load(),
			shadowBytes.Load(),
			shadowReqs.Load(),
			shadowErrors.Load(),
		)

		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()

		if err := server.Shutdown(shutdownCtx); err != nil {
			log.Printf("HTTP server shutdown error: %v", err)
		}
	}()

	log.Printf("Listening on %s", listenAddr)
	if err := server.ListenAndServe(); err != http.ErrServerClosed {
		log.Fatalf("HTTP server error: %v", err)
	}

	log.Println("Server stopped")
}
