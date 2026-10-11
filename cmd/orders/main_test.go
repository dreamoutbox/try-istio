package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestOrdersHandler(t *testing.T) {
	tests := []struct {
		name              string
		url               string
		requestHeaders    map[string]string
		upstreamStatus    int
		upstreamBody      string
		upstreamDelay     time.Duration
		clientTimeout     time.Duration
		wantStatus        int
		wantSKU           string
		wantTraceForward  bool
		checkPayload      bool
	}{
		{
			name:       "health check",
			url:        "/healthz",
			wantStatus: http.StatusOK,
		},
		{
			name:           "success forward and embed inventory",
			url:            "/orders/sku-42",
			requestHeaders: map[string]string{
				"x-request-id": "req-123",
				"traceparent":  "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01",
				"x-b3-traceid": "abc1234",
			},
			upstreamStatus:   http.StatusOK,
			upstreamBody:     `{"sku":"sku-42","qty":100,"version":"v1","pod":"inv-pod","xfcc":""}`,
			clientTimeout:    1 * time.Second,
			wantStatus:       http.StatusOK,
			wantSKU:          "sku-42",
			wantTraceForward: true,
			checkPayload:     true,
		},
		{
			name:           "upstream failure 503 returns 502",
			url:            "/orders/sku-err",
			upstreamStatus: http.StatusServiceUnavailable,
			upstreamBody:   `{"error":"unavailable"}`,
			clientTimeout:  1 * time.Second,
			wantStatus:     http.StatusBadGateway,
		},
		{
			name:           "upstream timeout returns 502",
			url:            "/orders/sku-slow",
			upstreamStatus: http.StatusOK,
			upstreamBody:   `{"sku":"sku-slow"}`,
			upstreamDelay:  200 * time.Millisecond,
			clientTimeout:  50 * time.Millisecond,
			wantStatus:     http.StatusBadGateway,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			var recordedHeaders http.Header

			upstreamServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				recordedHeaders = r.Header.Clone()
				if tc.upstreamDelay > 0 {
					time.Sleep(tc.upstreamDelay)
				}
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.upstreamStatus)
				_, _ = w.Write([]byte(tc.upstreamBody))
			}))
			defer upstreamServer.Close()

			handler := NewHandler(HandlerConfig{
				InventoryURL:    upstreamServer.URL + "/stock/{sku}",
				HTTPClient:      upstreamServer.Client(),
				UpstreamTimeout: tc.clientTimeout,
			})

			req := httptest.NewRequest(http.MethodGet, tc.url, nil)
			for k, v := range tc.requestHeaders {
				req.Header.Set(k, v)
			}

			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)

			resp := w.Result()
			defer resp.Body.Close()

			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("expected status %d, got %d", tc.wantStatus, resp.StatusCode)
			}

			if tc.wantTraceForward {
				for k, v := range tc.requestHeaders {
					if recordedHeaders.Get(k) != v {
						t.Errorf("expected header %s=%s, got %s", k, v, recordedHeaders.Get(k))
					}
				}
			}

			if tc.checkPayload {
				body, err := io.ReadAll(resp.Body)
				if err != nil {
					t.Fatalf("failed to read body: %v", err)
				}

				var orderResp OrderResponse
				if err := json.Unmarshal(body, &orderResp); err != nil {
					t.Fatalf("failed to unmarshal JSON: %v, raw: %s", err, string(body))
				}

				if orderResp.SKU != tc.wantSKU {
					t.Errorf("expected SKU %q, got %q", tc.wantSKU, orderResp.SKU)
				}

				if !strings.Contains(string(orderResp.Inventory), tc.wantSKU) {
					t.Errorf("expected inventory to contain %q, got %s", tc.wantSKU, string(orderResp.Inventory))
				}
			}
		})
	}
}
