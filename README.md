# PaceNote

PaceNote is a consent-first personal macOS meeting coach. It captures the microphone and Mac system output into separate local transcript lanes, shows a short sentence to say immediately, and then follows with either clearly labeled general guidance or a repository-specific answer backed by one explicitly selected sealed repository and optional read-only skill.

PaceNote never speaks, pastes, sends, joins a meeting, or changes code for you.

## Requirements

- Apple silicon Mac running macOS 26 or newer
- Xcode 26 with Swift 6.2 or newer
- ChatGPT account with Codex access
- The OpenAI-signed Codex binary at `/Applications/ChatGPT.app/Contents/Resources/codex` or `/Applications/Codex.app/Contents/Resources/codex`

PaceNote does not request or use an OpenAI API key. It runs the local Codex app-server through a dedicated PaceNote profile authenticated with your ChatGPT subscription. It verifies the executable's OpenAI code signature and tested version range before launch; binaries from `PATH`, Homebrew, symlinks, or other locations are rejected.

## Build and install for personal use

```sh
./Scripts/lint.sh
./Scripts/test.sh
./Scripts/toolchain.sh swift build -c release
./Scripts/package-app.sh
./Scripts/verify-app.sh
open dist/PaceNote.app
```

The package script creates `dist/PaceNote.app` with a local ad hoc hardened-runtime signature. That build is intended for the Mac that built it. Distribution to another Mac requires Developer ID signing and Apple notarization, which are not currently configured.

## First use

1. Open PaceNote and review the privacy disclosure. Do not approve it until you understand what is captured and sent to OpenAI.
2. Choose **Sign in with ChatGPT**. This is a one-time browser sign-in for PaceNote's dedicated Codex profile. PaceNote does not copy credentials from another Codex profile.
3. Grant microphone and system-audio permissions when macOS asks. PaceNote remains blocked when a required permission or cleanup check fails.
4. Select the meeting output source and capture lanes. Repository grounding is optional; when selected, one repository-local domain skill can also be chosen.
5. Confirm that meeting participants have been informed and that you have permission to capture and process the conversation, then start listening.

During a meeting, every eligible turn immediately shows the fixed local **SAY NOW** bridge “Let me think through that carefully for a second.” The production coordinator never runs or displays a model-written Quick answer, and Deep starts automatically. Without a repository, Deep can return only a `general_answer`, clarification, or abstention. General guidance has no evidence, is visibly labeled **verify before speaking**, and is rejected if it claims repository grounding. With a repository, an answer appears only after exact extractive evidence verification: it must match one verified basis claim while preserving punctuation, and that claim must copy one complete cited source line. For clarification or abstention, PaceNote ignores model prose and shows fixed local safe text. If validation fails, no Deep card appears; the bridge remains visible with a limited-mode status. No classifier or model flag can bypass the bridge or suppress Deep. Speak a suggestion yourself only if it is accurate and appropriate.

Use **Pause** to stop capture temporarily. Use **Stop** when the meeting ends so PaceNote can interrupt inference, clear in-memory content, delete meeting threads and snapshots, sanitize transient profile state, and audit cleanup.

## Troubleshooting

- **Signed out:** use **Sign in with ChatGPT** inside PaceNote. Signing into another Codex app does not authenticate PaceNote's dedicated profile.
- **Microphone or system audio denied:** open System Settings → Privacy & Security, enable the relevant permission for PaceNote, then reopen the app.
- **No meeting source:** keep the meeting audio routed through this Mac, reload sources, or choose the clearly labeled all-system-output fallback.
- **Deep answer unavailable:** check the visible Codex, rate-limit, or cleanup status. For codebase-specific answers, select a repository and resolve any approvable ambiguous sensitive-file review. High-confidence credential matches cannot be approved. PaceNote fails closed instead of reading the live working tree or broadening permissions.
- **Stop reports an incomplete audio teardown:** retry **Stop**. PaceNote clears visible meeting content immediately, keeps the red capture indicator on, and blocks Start, Resume, and Coach until Core Audio confirms that every owned handle is gone.
- **Dedicated Codex profile already in use:** quit the other PaceNote process or live profile probe. Only one process may own the profile at a time.
- **Cleanup remains blocked:** leave PaceNote open and retry its startup check. Do not start another meeting until the cleanup warning clears.
- **Wrong ChatGPT account:** stop the meeting, open Settings, choose **Sign Out and Forget Profile**, then sign in again.

## Privacy and current status

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and the [production-readiness ledger](PRODUCTION_READINESS.md) before real use. The architecture and product contract are in [CODEX_MEETING_COPILOT_SPEC.md](CODEX_MEETING_COPILOT_SPEC.md).

Automated tests, packaging, and packaged native-accessibility review are complete. Live target-account Deep generation, packaged meeting audio and transcription, real-meeting latency dogfood, and Developer ID/notarization for distribution are not yet complete. Treat this as a personal release candidate, not a production-verified build, and do not use it for confidential or policy-restricted meetings.
