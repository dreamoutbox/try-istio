package main

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestInventoryHandler(t *testing.T) {
	tests := []struct {
		name         string
		url          string
		headers      map[string]string
		failRate     float64
		randVal      float64
		wantStatus   int
		wantSKU      string
		wantVersion  string
		wantPod      string
		wantXFCC     string
		checkPayload bool
	}{
		{
			name:       "health check",
			url:        "/healthz",
			wantStatus: http.StatusOK,
		},
		{
			name: "stock item found without xfcc",
			url:  "/stock/sku-100",
			headers: map[string]string{
				"User-Agent": "test",
			},
			failRate:     0,
			randVal:      0.5,
			wantStatus:   http.StatusOK,
			wantSKU:      "sku-100",
			wantVersion:  "v1",
			wantPod:      "test-pod",
			wantXFCC:     "",
			checkPayload: true,
		},
		{
			name: "stock item echoes xfcc header",
			url:  "/stock/sku-xyz",
			headers: map[string]string{
				"X-Forwarded-Client-Cert": "By=spiffe://cluster.local/ns/demo/sa/inventory;Hash=123",
			},
			failRate:     0,
			randVal:      0.5,
			wantStatus:   http.StatusOK,
			wantSKU:      "sku-xyz",
			wantVersion:  "v1",
			wantPod:      "test-pod",
			wantXFCC:     "By=spiffe://cluster.local/ns/demo/sa/inventory;Hash=123",
			checkPayload: true,
		},
		{
			name:         "simulated failure via fail rate",
			url:          "/stock/sku-fail",
			failRate:     0.5,
			randVal:      0.2, // 0.2 < 0.5 triggers failure
			wantStatus:   http.StatusServiceUnavailable,
			checkPayload: false,
		},
		{
			name:         "simulated failure avoided",
			url:          "/stock/sku-ok",
			failRate:     0.5,
			randVal:      0.8, // 0.8 >= 0.5 avoids failure
			wantStatus:   http.StatusOK,
			wantSKU:      "sku-ok",
			wantVersion:  "v1",
			wantPod:      "test-pod",
			checkPayload: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			handler := NewHandler(HandlerConfig{
				Version:   "v1",
				PodName:   "test-pod",
				FailRate:  tc.failRate,
				RandFloat: func() float64 { return tc.randVal },
			})

			req := httptest.NewRequest(http.MethodGet, tc.url, nil)
			for k, v := range tc.headers {
				req.Header.Set(k, v)
			}

			w := httptest.NewRecorder()
			handler.ServeHTTP(w, req)

			resp := w.Result()
			defer resp.Body.Close()

			if resp.StatusCode != tc.wantStatus {
				t.Fatalf("expected status %d, got %d", tc.wantStatus, resp.StatusCode)
			}

			if tc.checkPayload {
				body, err := io.ReadAll(resp.Body)
				if err != nil {
					t.Fatalf("failed to read response body: %v", err)
				}

				var stock StockResponse
				if err := json.Unmarshal(body, &stock); err != nil {
					t.Fatalf("failed to unmarshal JSON: %v, raw: %s", err, string(body))
				}

				if stock.SKU != tc.wantSKU {
					t.Errorf("expected SKU %q, got %q", tc.wantSKU, stock.SKU)
				}
				if stock.Version != tc.wantVersion {
					t.Errorf("expected Version %q, got %q", tc.wantVersion, stock.Version)
				}
				if stock.Pod != tc.wantPod {
					t.Errorf("expected Pod %q, got %q", tc.wantPod, stock.Pod)
				}
				if stock.XFCC != tc.wantXFCC {
					t.Errorf("expected XFCC %q, got %q", tc.wantXFCC, stock.XFCC)
				}
				if stock.Qty <= 0 {
					t.Errorf("expected positive Qty, got %d", stock.Qty)
				}
			}
		})
	}
}
