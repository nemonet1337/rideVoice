#!/usr/bin/env bash
set -euo pipefail

echo "== Flutter =="
cd app && flutter pub get && cd ..

echo "== Go =="
cd backend && go mod download && cd ..

echo "== Rust =="
cd rust && cargo fetch && cd ..

echo "rideVoice devcontainer ready."
echo "  Flutter:  cd app && flutter test"
echo "  Backend:  cd backend && go run ./cmd/server"
echo "  Rust:     cd rust && cargo test"
echo "  LiveKit:  docker compose -f backend/deploy/docker-compose.yml up -d"
echo "  Note:     iOS/Android device builds still need host Xcode/Android Studio."
