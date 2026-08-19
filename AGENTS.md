# ChirpCue contributor guide

## Product boundaries

- ChirpCue is a consent-first personal meeting coach. Never add covert capture, automatic speaking, automatic sending, or interview-assessment evasion.
- Meeting audio and transcripts are ephemeral by default.
- Repository access is read-only and limited to a sealed snapshot. Never give a model ambient access to the live working tree or credentials.
- Inference must use the ChatGPT-authenticated Codex app-server, first-party Claude.ai subscription authentication, or Google sign-in through the official Antigravity CLI. Never add API-key, Console, gateway, Google Cloud, or other cloud-provider billing without an explicit product decision.
- Claude runs tool-free with safe mode, no ambient settings, hooks, MCP, skills, agents, or session persistence. It may receive only host-selected bounded text from the sealed snapshot; Codex remains the only provider allowed to invoke reviewed repository skills.
- Gemini runs in an app-owned Antigravity profile with a custom agent limited to opening one private input file. Commands, URLs, MCP, plugins, skills, subagents, ambient repository access, and live-working-tree access remain denied. It may receive only transcript slices and host-selected bounded text from the sealed snapshot.

## Engineering rules

- Target macOS 26 and Swift 6 strict concurrency.
- Prefer Foundation, AppKit, SwiftUI, AVFoundation, Speech, CoreAudio, and CryptoKit over third-party packages.
- Keep UI state on `@MainActor`; keep subprocess, audio, and filesystem work in actors or explicitly Sendable services.
- Do not log transcript text, repository excerpts, auth details, or absolute home-directory paths.
- Every displayed repository claim must pass local evidence verification.

## Verification

Run before committing:

```sh
./Scripts/lint.sh
swift test
swift build -c release
./Scripts/package-app.sh
./Scripts/verify-app.sh
```
