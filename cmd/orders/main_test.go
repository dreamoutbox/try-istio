package main

import (
	"encoding/base64"
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
		name             string
		url              string
		requestHeaders   map[string]string
		upstreamStatus   int
		upstreamBody     string
		upstreamDelay    time.Duration
		clientTimeout    time.Duration
		wantStatus       int
		wantSKU          string
		wantTraceForward bool
		checkPayload     bool
	}{
		{
			name:       "health check",
			url:        "/healthz",
			wantStatus: http.StatusOK,
		},
		{
			name: "success forward and embed inventory",
			url:  "/orders/sku-42",
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

// fakeJWT builds a minimal JWT with the given payload and a garbage signature.
// Sufficient for unit-testing jwtPayload and /whoami — neither verifies the sig.
func fakeJWT(payload map[string]any) string {
	header := base64.RawURLEncoding.EncodeToString([]byte(`{"alg":"RS256","typ":"JWT"}`))
	p, _ := json.Marshal(payload)
	pl := base64.RawURLEncoding.EncodeToString(p)
	return header + "." + pl + ".fakesig"
}

func TestJWTPayload(t *testing.T) {
	t.Run("valid token decodes claims", func(t *testing.T) {
		tok := fakeJWT(map[string]any{"iss": "testing@secure.istio.io", "sub": "alice"})
		got, err := jwtPayload(tok)
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		var claims map[string]any
		if err := json.Unmarshal(got, &claims); err != nil {
			t.Fatalf("result is not valid JSON: %v", err)
		}
		if claims["sub"] != "alice" {
			t.Errorf("expected sub=alice, got %v", claims["sub"])
		}
	})

	t.Run("wrong segment count", func(t *testing.T) {
		if _, err := jwtPayload("only.two"); err == nil {
			t.Error("expected error for 2-segment input")
		}
	})

	t.Run("bad base64 in payload", func(t *testing.T) {
		if _, err := jwtPayload("header.!!!.sig"); err == nil {
			t.Error("expected error for invalid base64")
		}
	})

	t.Run("payload not JSON", func(t *testing.T) {
		notJSON := base64.RawURLEncoding.EncodeToString([]byte("not-json"))
		if _, err := jwtPayload("h." + notJSON + ".s"); err == nil {
			t.Error("expected error for non-JSON payload")
		}
	})
}

func TestWhoamiHandler(t *testing.T) {
	handler := NewHandler(HandlerConfig{})

	t.Run("missing token returns 401", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusUnauthorized {
			t.Errorf("expected 401, got %d", w.Code)
		}
	})

	t.Run("valid token returns claims as JSON", func(t *testing.T) {
		tok := fakeJWT(map[string]any{
			"iss":   "testing@secure.istio.io",
			"sub":   "alice",
			"email": "alice@example.com",
		})
		req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
		req.Header.Set("Authorization", "Bearer "+tok)
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)

		if w.Code != http.StatusOK {
			t.Fatalf("expected 200, got %d; body: %s", w.Code, w.Body.String())
		}
		if ct := w.Header().Get("Content-Type"); ct != "application/json" {
			t.Errorf("expected application/json Content-Type, got %q", ct)
		}
		var claims map[string]any
		if err := json.Unmarshal(w.Body.Bytes(), &claims); err != nil {
			t.Fatalf("response is not valid JSON: %v", err)
		}
		if claims["sub"] != "alice" {
			t.Errorf("expected sub=alice, got %v", claims["sub"])
		}
	})

	t.Run("malformed token returns 400", func(t *testing.T) {
		req := httptest.NewRequest(http.MethodGet, "/whoami", nil)
		req.Header.Set("Authorization", "Bearer notavalidjwt")
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		if w.Code != http.StatusBadRequest {
			t.Errorf("expected 400, got %d", w.Code)
		}
	})
}
