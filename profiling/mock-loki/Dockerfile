FROM golang:1.22-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY main.go .

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /mock-loki main.go

FROM alpine:3.19

RUN apk add --no-cache wget

COPY --from=builder /mock-loki /usr/local/bin/mock-loki

EXPOSE 3100

HEALTHCHECK --interval=5s --timeout=3s --start-period=5s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:3100/ready || exit 1

ENTRYPOINT ["/usr/local/bin/mock-loki"]
