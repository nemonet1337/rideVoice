# rideVoice

P2P E2E communication system for motorcycle touring.

## Architecture

| Layer | Technology |
|-------|-----------|
| App | Flutter (iOS + Android) |
| Crypto Core | Rust (`rv-audio` + `rv-crypto` crates) |
| Online Backend | Go (REST + JWT + LiveKit SFU) |
| Offline Mesh | LAN overlay (mDNS/Bonjour + TCP/UDP) |

## Monorepo Structure

```
rideVoice/
  app/          Flutter app
  backend/      Go REST server
  rust/         Rust workspace (rv-audio, rv-crypto)
```

## Quick Start

### Prerequisites
- Flutter 3.x+
- Go 1.23+
- Rust 1.80+
- Docker (for local LiveKit)

### Bootstrap
```bash
# Flutter
cd app && flutter pub get

# Go backend
cd backend && go run ./cmd/server

# Rust core
cd rust && cargo test

# LiveKit (local dev)
docker compose -f backend/deploy/docker-compose.yml up -d
```

## License

Proprietary. All rights reserved.
