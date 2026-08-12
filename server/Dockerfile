# Build from the repository root:  docker build -f server/Dockerfile .
# The build context must be the repo root because server/go.mod replaces
# the splitcore module with ../splitcore.
FROM golang:1.26-alpine AS build

WORKDIR /src

# Copy manifests first so dependency download caches independently of
# source edits.
COPY go.work ./
COPY splitcore/go.mod ./splitcore/
COPY server/go.mod server/go.sum ./server/
RUN go mod download

COPY splitcore ./splitcore
COPY server ./server

# PocketBase uses modernc.org/sqlite (pure Go), so no cgo and no libc
# dependency — the result is a static binary that runs on scratch/alpine.
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" \
    -o /out/splitcore-server ./server

FROM alpine:3.20

# ca-certificates: outbound TLS (SMTP for password reset, S3 backups).
# wget: the compose health check.
RUN apk add --no-cache ca-certificates wget tzdata \
    && adduser -D -u 10001 splitcore

WORKDIR /app
COPY --from=build /out/splitcore-server /app/splitcore-server

# pb_data holds the SQLite database and every uploaded receipt. It MUST be
# a volume — losing it loses all user data.
RUN mkdir -p /app/pb_data && chown -R splitcore:splitcore /app
USER splitcore

EXPOSE 8090
VOLUME ["/app/pb_data"]

# Automigrate is off for a compiled binary (see server/main.go), so apply
# migrations explicitly before serving.
ENTRYPOINT ["/bin/sh", "-c", "/app/splitcore-server migrate up && exec /app/splitcore-server serve --http=0.0.0.0:8090 \"$@\"", "--"]
