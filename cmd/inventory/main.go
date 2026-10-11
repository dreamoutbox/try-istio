package main

import (
	"encoding/json"
	"log/slog"
	"math/rand/v2"
	"net/http"
	"os"
	"strconv"

	"try-istio/internal/server"
)

// StockResponse represents the inventory payload.
type StockResponse struct {
	SKU     string `json:"sku"`
	Qty     int    `json:"qty"`
	Version string `json:"version"`
	Pod     string `json:"pod"`
	XFCC    string `json:"xfcc"`
}

// HandlerConfig configures the inventory HTTP handler.
type HandlerConfig struct {
	Version   string
	PodName   string
	FailRate  float64
	RandFloat func() float64
	Logger    *slog.Logger
}

// NewHandler builds the HTTP handler for the inventory service.
func NewHandler(cfg HandlerConfig) http.Handler {
	if cfg.RandFloat == nil {
		cfg.RandFloat = rand.Float64
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}

	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	mux.HandleFunc("GET /stock/{sku}", func(w http.ResponseWriter, r *http.Request) {
		sku := r.PathValue("sku")

		// Dynamic FAIL_RATE override support if env changed or configured.
		failRate := cfg.FailRate
		if envVal := os.Getenv("FAIL_RATE"); envVal != "" {
			if parsed, err := strconv.ParseFloat(envVal, 64); err == nil {
				failRate = parsed
			}
		}

		if failRate > 0 && cfg.RandFloat() < failRate {
			cfg.Logger.Warn("injected failure triggered", slog.String("sku", sku), slog.Float64("failRate", failRate))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"error":"simulated failure"}` + "\n"))
			return
		}

		xfcc := r.Header.Get("X-Forwarded-Client-Cert")
		resp := StockResponse{
			SKU:     sku,
			Qty:     100,
			Version: cfg.Version,
			Pod:     cfg.PodName,
			XFCC:    xfcc,
		}

		data, err := json.Marshal(resp)
		if err != nil {
			cfg.Logger.Error("failed to marshal stock response", slog.Any("error", err))
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(append(data, '\n'))
	})

	return mux
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	version := os.Getenv("VERSION")
	if version == "" {
		version = "v1"
	}

	hostname := os.Getenv("HOSTNAME")
	if hostname == "" {
		hostname = "unknown"
	}

	failRate := 0.0
	if frStr := os.Getenv("FAIL_RATE"); frStr != "" {
		if fr, err := strconv.ParseFloat(frStr, 64); err == nil {
			failRate = fr
		}
	}

	h := NewHandler(HandlerConfig{
		Version:  version,
		PodName:  hostname,
		FailRate: failRate,
		Logger:   logger,
	})

	srvCfg := server.DefaultConfig("8080")
	if err := server.Run(srvCfg, h, logger); err != nil {
		logger.Error("server exited with error", slog.Any("error", err))
		os.Exit(1)
	}
}
