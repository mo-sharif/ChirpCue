# Contributing to ChirpCue

Thanks for helping make private, user-controlled meeting coaching better.

## Start with the product boundaries

Every contribution must preserve these rules:

- Capture starts only after an informed user confirms participant disclosure and permission.
- ChirpCue never speaks, sends, pastes, joins calls, or helps evade interview or assessment rules.
- Audio and transcripts remain ephemeral by default and must never enter logs, fixtures, screenshots, issues, or pull requests.
- Repository access is read-only and limited to an exact sealed snapshot. Models never receive the live working tree, credentials, or ambient home-directory access.
- Inference uses only ChatGPT-authenticated Codex or first-party Claude.ai subscription authentication. Do not add API keys, gateways, Console billing, or cloud-provider fallbacks.
- Claude stays tool-free, skill-free, MCP-free, hook-free, agent-free, and session-free. Codex may use only explicitly reviewed read-only skills.

Changes that cross one of these boundaries need a public design discussion before code.

## Development setup

You need an Apple silicon Mac, macOS 26 or newer, and Xcode 26 with Swift 6.2 or newer.

```sh
git clone https://github.com/mo-sharif/ChirpCue.git
cd ChirpCue
./Scripts/check.sh
```

Provider and paid smoke tests are opt-in. Never run them with real meeting content, private repositories, employer credentials, or an account you are not authorized to use.

Before opening a pull request, run:

```sh
./Scripts/lint.sh
swift test
swift build -c release
./Scripts/package-app.sh
./Scripts/verify-app.sh
./Scripts/scan-secrets.sh
```

## Pull requests

- Keep changes focused and explain the user-visible outcome.
- Add deterministic tests for security boundaries, cancellation, cleanup, and concurrency changes.
- Use synthetic transcripts, repositories, accounts, and screenshots only.
- Do not include secrets, auth output, home-directory paths, email addresses, meeting content, or proprietary code.
- Update `PRIVACY.md`, `SECURITY.md`, and the readiness ledger when a trust boundary changes.

By intentionally submitting a contribution, you agree that it is licensed under the Apache License 2.0 as described in [LICENSE](LICENSE).
