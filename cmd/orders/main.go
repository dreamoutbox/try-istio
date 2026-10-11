package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"time"

	"try-istio/internal/server"
	"try-istio/internal/tracing"
)

// OrderResponse represents the response containing the requested SKU and upstream inventory details.
type OrderResponse struct {
	SKU       string          `json:"sku"`
	Inventory json.RawMessage `json:"inventory"`
}

// HandlerConfig configures the orders HTTP handler.
type HandlerConfig struct {
	InventoryURL    string
	HTTPClient      *http.Client
	Logger          *slog.Logger
	UpstreamTimeout time.Duration
}

// buildInventoryURL formats the inventory URL for a given SKU.
func buildInventoryURL(template, sku string) string {
	if strings.Contains(template, "{sku}") {
		return strings.ReplaceAll(template, "{sku}", sku)
	}
	return fmt.Sprintf("%s/%s", strings.TrimSuffix(template, "/"), sku)
}

// NewHandler builds the HTTP handler for the orders service.
func NewHandler(cfg HandlerConfig) http.Handler {
	if cfg.InventoryURL == "" {
		cfg.InventoryURL = "http://inventory/stock/{sku}"
	}
	if cfg.HTTPClient == nil {
		cfg.HTTPClient = &http.Client{}
	}
	if cfg.Logger == nil {
		cfg.Logger = slog.Default()
	}
	if cfg.UpstreamTimeout <= 0 {
		cfg.UpstreamTimeout = 2 * time.Second
	}

	mux := http.NewServeMux()

	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok\n"))
	})

	// GET /whoami — returns the JWT claims forwarded by the Istio sidecar.
	// Istio's RequestAuthentication validates the token before the request
	// reaches this handler, so we only need to base64-decode the payload.
	mux.HandleFunc("GET /whoami", func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") {
			// Should not happen: Istio authz policy requires a valid token,
			// but handle defensively.
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"missing bearer token"}` + "\n"))
			return
		}

		claims, err := jwtPayload(strings.TrimPrefix(auth, "Bearer "))
		if err != nil {
			cfg.Logger.Warn("failed to decode jwt payload", slog.Any("error", err))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadRequest)
			_, _ = w.Write([]byte(`{"error":"malformed token"}` + "\n"))
			return
		}

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(append(claims, '\n'))
	})

	mux.HandleFunc("GET /orders/{sku}", func(w http.ResponseWriter, r *http.Request) {
		sku := r.PathValue("sku")
		targetURL := buildInventoryURL(cfg.InventoryURL, sku)

		ctx, cancel := context.WithTimeout(r.Context(), cfg.UpstreamTimeout)
		defer cancel()

		req, err := http.NewRequestWithContext(ctx, http.MethodGet, targetURL, nil)
		if err != nil {
			cfg.Logger.Error("failed to create upstream request", slog.Any("error", err))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":"failed to create upstream request"}` + "\n"))
			return
		}

		tracing.ForwardHeaders(r.Header, req.Header)

		resp, err := cfg.HTTPClient.Do(req)
		if err != nil {
			cfg.Logger.Warn("upstream inventory request failed", slog.String("sku", sku), slog.Any("error", err))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":"inventory request failed"}` + "\n"))
			return
		}
		defer resp.Body.Close()

		if resp.StatusCode != http.StatusOK {
			cfg.Logger.Warn("upstream inventory returned non-200", slog.String("sku", sku), slog.Int("statusCode", resp.StatusCode))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":"inventory returned non-200 status"}` + "\n"))
			return
		}

		body, err := io.ReadAll(resp.Body)
		if err != nil {
			cfg.Logger.Error("failed to read upstream response body", slog.Any("error", err))
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusBadGateway)
			_, _ = w.Write([]byte(`{"error":"failed to read inventory response"}` + "\n"))
			return
		}

		orderResp := OrderResponse{
			SKU:       sku,
			Inventory: json.RawMessage(body),
		}

		data, err := json.Marshal(orderResp)
		if err != nil {
			cfg.Logger.Error("failed to marshal order response", slog.Any("error", err))
			w.WriteHeader(http.StatusInternalServerError)
			return
		}

		w.Header().Set("Connection", "close")
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(append(data, '\n'))
	})

	return mux
}

// jwtPayload base64url-decodes the payload segment of a JWT.
// It does NOT verify the signature — Istio's sidecar already did that.
func jwtPayload(token string) (json.RawMessage, error) {
	parts := strings.SplitN(token, ".", 3)
	if len(parts) != 3 {
		return nil, fmt.Errorf("expected 3 dot-separated segments, got %d", len(parts))
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, fmt.Errorf("base64 decode: %w", err)
	}
	// Validate that it is valid JSON before returning.
	if !json.Valid(payload) {
		return nil, fmt.Errorf("payload is not valid JSON")
	}
	return json.RawMessage(payload), nil
}

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	slog.SetDefault(logger)

	invURL := os.Getenv("INVENTORY_URL")
	if invURL == "" {
		invURL = "http://inventory/stock/{sku}"
	}

	h := NewHandler(HandlerConfig{
		InventoryURL:    invURL,
		HTTPClient:      &http.Client{},
		Logger:          logger,
		UpstreamTimeout: 2 * time.Second,
	})

	srvCfg := server.DefaultConfig("8080")
	if err := server.Run(srvCfg, h, logger); err != nil {
		logger.Error("server exited with error", slog.Any("error", err))
		os.Exit(1)
	}
}
