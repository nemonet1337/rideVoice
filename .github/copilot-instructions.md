# GitHub Copilot Instructions for rideVoice

This file contains project-specific instructions for GitHub Copilot, combining AGENTS.md, CLAUDE.md, Kilo configuration, and RTK hooks.

---

## Project Overview (from AGENTS.md)

**rideVoice** — P2P E2E voice communication app for motorcycle touring.
- **Flutter** (iOS + Android) — audio pipeline, mesh transport, crypto wrappers, UI
- **Go backend** — REST (auth/JWT, LiveKit room-token minting, user/room CRUD, gateway registry)
- **Rust core** — rv-audio (RNNoise + Opus + resample), rv-crypto (X25519/HKDF/AES-GCM)

---

## Build & Test Commands

```bash
# Flutter (app)
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

### Build Prerequisites

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
- `cargo test -p rv-audio --features opus-codec`: Opus encode/decode (requires CMake)
- `cargo test -p rv-audio --features rnnoise-denoise`: RNNoise denoising
- `cargo test -p rv-audio --all-features`: Full audio pipeline

---

## Architecture

| Component | Responsibility |
|-----------|----------------|
| **app/** | Flutter frontend (audio pipeline, mesh transport, crypto wrappers, UI) |
| **backend/** | Go REST (auth/JWT, LiveKit room-token minting, user/room CRUD, gateway registry) |
| **rust/** | Native code (rv-audio: RNNoise+Opus+resample; rv-crypto: X25519/HKDF/AES-GCM) |

---

## Key Design Decisions

- **Online audio**: LiveKit SFU via `livekit_client`
- **Offline audio**: Platform native DSP → Rust RNNoise → Rust Opus → Rust AES-GCM
- **Cross-OS mesh**: LAN overlay (mDNS/Bonjour + TCP/UDP) — requires shared WiFi/hotspot
- **iOS background**: CallKit + `audio` UIBackgroundMode (best-effort for mesh re-discovery)
- **Android background**: Foreground service (mic/network/connected-devices)
- **No custom WS signaling server** (LiveKit handles WebRTC signaling)
- **No `flutter_blue_plus`** (HFP via OS audio routing)

---

## CLAUDE.md / RTK Configuration

### RTK (Rust Token Killer) — Required Hook

**Always prefix shell commands with `rtk` to minimize token consumption (60-90% savings).**

```bash
# Correct usage
rtk git status
rtk cargo test
rtk ls src/
rtk grep "pattern" src/
rtk find "*.rs" .
rtk docker ps
rtk gh pr list

# Meta commands (always use rtk directly)
rtk gain              # Show token savings
rtk gain --history    # Command history with savings
rtk discover          # Find missed RTK opportunities
rtk proxy <cmd>       # Run raw (no filtering, for debugging)
```

**Hook behavior**: All shell commands are automatically rewritten by the Claude Code hook.
Example: `git status` → `rtk git status` (transparent, 0 token overhead).

**Installation verification:**
```bash
rtk --version         # Should show: rtk X.Y.Z
rtk gain              # Should work (not "command not found")
which rtk             # Verify correct binary
```

⚠️ **Name collision**: If `rtk gain` fails, you may have `reachingforthejack/rtk` (Rust Type Kit) installed instead.

---

## Kilo Configuration

### Global Config (`~/.config/kilo/kilo.json`)

```json
{
  "$schema": "https://app.kilo.ai/config.json",
  "mcp": {
    "cloudflare": {
      "type": "local",
      "command": ["npx", "mcp-remote", "https://docs.mcp.cloudflare.com/sse"]
    },
    "github": {
      "type": "local",
      "command": ["npx", "-y", "@modelcontextprotocol/server-github"],
      "environment": {
        "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_PERSONAL_ACCESS_TOKEN}"
      }
    }
  }
}
```

### Project Config (`.kilo/`)

No project-specific `.kilo/` directory exists yet. Create one if you need:
- Custom commands (`.kilo/command/*.md`)
- Custom agents (`.kilo/agent/*.md`)
- Project-specific MCP servers
- TUI settings
- Agent Manager worktree setup/run scripts

---

## Available Skills (Auto-loaded based on task)

The following skills are available and auto-load when relevant:

| Skill | Use When |
|-------|----------|
| `agents-sdk` | Building AI agents on Cloudflare Workers (stateful agents, durable workflows, WebSocket apps, scheduled tasks, MCP servers, chat/voice agents) |
| `cloudflare` | Any Cloudflare development (Workers, Pages, KV, D1, R2, AI, etc.) |
| `cloudflare-email-service` | Sending/receiving transactional emails via Cloudflare |
| `cloudflare-one` | Cloudflare One Zero Trust / SASE (Access, Gateway, WARP, Tunnel, etc.) |
| `cloudflare-one-migrations` | Migrating from Zscaler, Palo Alto, legacy VPN, SWG, SASE to Cloudflare One |
| `context7-mcp` | Library/framework API references, code examples (React, Vue, Next.js, Prisma, Supabase, etc.) |
| `durable-objects` | Building stateful coordination with Cloudflare Durable Objects |
| `kilo-config` | Kilo configuration questions, Agent Manager worktree setup |
| `sandbox-sdk` | Sandboxed code execution, code interpreters, CI/CD, dev environments |
| `turnstile-spin` | Cloudflare Turnstile CAPTCHA setup end-to-end |
| `web-perf` | Web performance auditing (Core Web Vitals, Lighthouse, Chrome DevTools) |
| `workers-best-practices` | Writing/reviewing Cloudflare Workers code (streaming, promises, secrets, observability) |
| `wrangler` | Before running wrangler commands (deploy, dev, KV, R2, D1, etc.) |

**Usage**: Load with the `skill` tool when the task matches a skill description.

---

## Development Workflow Reminders

1. **Always use `rtk` prefix** for shell commands (handled by hook automatically)
2. **Load relevant skills** before starting specialized tasks
3. **Run lint/typecheck** after changes:
   - Flutter: `flutter analyze`
   - Go: `go vet ./...` and `go test ./...`
   - Rust: `cargo fmt --check && cargo clippy -- -D warnings`
4. **Check AGENTS.md** for project-specific build/test commands
5. **Follow existing code conventions** in each component (app/, backend/, rust/)