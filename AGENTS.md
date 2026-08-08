# PaceNote contributor guide

## Product boundaries

- PaceNote is a consent-first personal meeting coach. Never add covert capture, automatic speaking, automatic sending, or interview-assessment evasion.
- Meeting audio and transcripts are ephemeral by default.
- Repository access is read-only and limited to a sealed snapshot. Never give a model ambient access to the live working tree or credentials.
- ChatGPT-authenticated Codex app-server is the only inference path. Do not add API-key billing without an explicit product decision.

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
