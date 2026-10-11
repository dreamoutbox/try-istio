FROM golang:1.24-alpine AS builder

WORKDIR /src
COPY go.mod ./
COPY . .

ARG SERVICE
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /bin/app ./cmd/${SERVICE}

FROM gcr.io/distroless/static:nonroot

WORKDIR /
COPY --from=builder /bin/app /bin/app
USER nonroot:nonroot

ENTRYPOINT ["/bin/app"]
