package tracing

import (
	"net/http"
	"strings"
)

// Known standard trace propagation headers.
var knownTraceHeaders = []string{
	"x-request-id",
	"traceparent",
	"tracestate",
}

// ForwardHeaders copies trace propagation headers (x-request-id, traceparent, tracestate, and x-b3-*)
// from the inbound HTTP request to the outbound HTTP request.
func ForwardHeaders(src, dst http.Header) {
	for _, h := range knownTraceHeaders {
		if val := src.Get(h); val != "" {
			dst.Set(h, val)
		}
	}
	for k, vals := range src {
		if strings.HasPrefix(strings.ToLower(k), "x-b3-") {
			for _, v := range vals {
				dst.Add(k, v)
			}
		}
	}
}
