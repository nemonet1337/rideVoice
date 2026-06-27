# AGENTS.md — rideVoice

## Project Overview
P2P E2E voice communication app for motorcycle touring. Flutter (iOS+Android), Go backend, Rust crypto+audio core.

## Build & Test Commands
```bash
# Flutter
cd app
flutter pub get
flutter analyze
flutter test

# Go backend
cd backend
go test ./...
go run ./cmd/server

# Rust core
cd rust
cargo test
cargo fmt --check
cargo clippy -- -D warnings

# flutter_rust_bridge codegen
cd app
flutter_rust_bridge_codegen generate
```

## Build Prerequisites

| Tool | Required For | Version |
|------|-------------|---------|
| Flutter | App | 3.24+ |
| Go | Backend | 1.23+ |
| Rust | Core (rv-audio, rv-crypto) | 1.80+ |
| CMake | Full `rv-audio` (Opus from source) | 3.x |
| Docker | Local LiveKit dev | 24+ |

**On Windows without CMake:** Build rv-audio without opus/rnnoise features:
```bash
cd rust
cargo test -p rv-audio          # resample only
cargo test -p rv-crypto         # full crypto suite
```

**rv-audio features:**
- Default (`cargo test -p rv-audio`): resample only (no system deps)
- `cargo test -p rv-audio --features opus-codec` : Opus encode/decode (requires CMake)
- `cargo test -p rv-audio --features rnnoise-denoise` : RNNoise denoising
- `cargo test -p rv-audio --all-features` : Full audio pipeline

## Architecture
- **app/**: Flutter frontend (audio pipeline, mesh transport, crypto wrappers, UI)
- **backend/**: Go REST (auth/JWT, LiveKit room-token minting, user/room CRUD, gateway registry)
- **rust/**: Native code (rv-audio: RNNoise+Opus+resample; rv-crypto: X25519/HKDF/AES-GCM)

## Key Design Decisions
- Online audio: LiveKit SFU via `livekit_client`
- Offline audio: Platform native DSP → Rust RNNoise → Rust Opus → Rust AES-GCM
- Cross-OS mesh: LAN overlay (mDNS/Bonjour + TCP/UDP) — requires shared WiFi/hotspot
- iOS background: CallKit + `audio` UIBackgroundMode (best-effort for mesh re-discovery)
- Android background: Foreground service (mic/network/connected-devices)
- No custom WS signaling server (LiveKit handles WebRTC signaling)
- No `flutter_blue_plus` (HFP via OS audio routing)
