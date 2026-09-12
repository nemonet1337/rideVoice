# REVIEW.md

## What matters in this repository
- Keep E2E crypto: X25519 / HKDF-SHA256 (`ridevoice-session-key`) / AES-256-GCM. Deterministic nonce is sender-id 4B + counter 8B; nonce reuse is high-risk.
- No owned backend, TURN, or signaling server. Do not add a relay that can see plaintext audio.
- `hop_count` is excluded from AES-GCM AAD because relays decrement it.
- Transport is LAN UDP overlay + AODV, not Nearby Connections or MultipeerConnectivity. Crypto stays pure Dart (`package:cryptography`); no Rust FFI.
- QR / group membership is the trust boundary. Joining without proximity or QR is high-risk.
- Prefer small, explicit fixes over broad refactors.

## Severity calibration
- Critical: nonce reuse, group-key leak, unauthenticated join, plaintext audio path.
- Warning: AODV routing loops, missing `key_epoch` handling, untested packet types.
- Do not flag Dart formatting when tooling already enforces it.

## Verification expectations
- Crypto, AODV, group, packet, and pipeline changes need `flutter test` (`app/test/*`).
- Packet-format changes must keep AAD coverage (header through `key_epoch`, not `hop_count`) and existing test vectors green.
- UI or transport additions should not introduce a server that can observe call content.
