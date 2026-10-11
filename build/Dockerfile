FROM golang:1.24-alpine AS builder

WORKDIR /src
# No external dependencies, so no go.sum. Copy go.mod only for module context.
COPY go.mod ./

COPY . .

ARG SERVICE
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/app ./cmd/${SERVICE}

FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=builder /bin/app /bin/app
USER nonroot:nonroot

ENTRYPOINT ["/bin/app"]
