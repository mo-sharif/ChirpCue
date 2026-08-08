# ChirpCue

ChirpCue is a consent-first personal macOS meeting coach. It captures the microphone and Mac system output into separate local transcript lanes, shows a short sentence to say immediately, and then follows with either clearly labeled general guidance or a repository-specific answer backed by one explicitly selected sealed repository. Codex can additionally use one reviewed read-only repository skill; Claude v1 is deliberately tool-free and skill-free.

Its original glass sidekick is **Chirp**: a quiet visual companion that appears when you need a cue, without pretending to be a participant or responding for you.

ChirpCue never speaks, pastes, sends, joins a meeting, or changes code for you.

## Requirements

- Apple silicon Mac running macOS 26 or newer
- Xcode 26 with Swift 6.2 or newer
- At least one supported subscription path:
  - a ChatGPT account with Codex access and the OpenAI-signed Codex binary at `/Applications/ChatGPT.app/Contents/Resources/codex` or `/Applications/Codex.app/Contents/Resources/codex`; or
  - a personal Claude Pro or Max account and the official Anthropic-signed Claude Code launcher at `~/.local/bin/claude`; Team, Enterprise, and endpoint-managed Claude configurations fail closed because administrator policy can override command-line isolation

ChirpCue never requests or uses an OpenAI or Anthropic API key. Codex runs through an app-owned profile authenticated by your ChatGPT subscription. Claude uses only first-party `claude.ai` subscription authentication already stored in macOS Keychain; Console, API-key, gateway, Bedrock, Vertex, and Foundry authentication are rejected. Both executable paths, signatures, and tested version ranges are verified before launch.

Claude `-p` usage is subscription-authenticated, but Anthropic currently assigns programmatic calls a separate monthly Agent SDK credit and plan limits or extra-usage terms can apply. ChirpCue does not promise that Claude requests consume the same allowance as interactive Claude Code. See [Anthropic's programmatic-usage documentation](https://code.claude.com/docs/en/headless).

## Build and install for personal use

```sh
./Scripts/lint.sh
./Scripts/test.sh
./Scripts/toolchain.sh swift build -c release
./Scripts/package-app.sh
./Scripts/verify-app.sh
./Scripts/install-personal-app.sh
open /Applications/ChirpCue.app
```

The package script creates `dist/ChirpCue.app` with a local ad hoc hardened-runtime signature. The installer verifies that bundle again, refuses to overwrite an existing `/Applications/ChirpCue.app`, and installs it only on this Mac. Remove an old copy deliberately before installing a replacement. Distribution to another Mac requires Developer ID signing and Apple notarization, which are not currently configured.

## First use

1. Open ChirpCue and review the privacy disclosure. Do not approve it until you understand what is captured and which selected provider processes it.
2. Choose **Codex via ChatGPT** or **Claude via Claude subscription** in Settings.
   - Codex uses a one-time in-app browser sign-in for ChirpCue's dedicated profile.
   - Claude reuses the first-party Claude Code subscription login in your macOS Keychain. If needed, run `claude auth login --claudeai` in Terminal, then choose **Recheck** in ChirpCue.
3. Grant microphone and system-audio permissions when macOS asks. ChirpCue remains blocked when a required permission or cleanup check fails.
4. Select the meeting output source and capture lanes. Repository grounding is optional. One repository-local skill may be chosen only with Codex; Claude receives only bounded host-selected lines from the reviewed sealed snapshot.
5. Confirm that meeting participants have been informed and that you have permission to capture and process the conversation, then start listening.

During a meeting, every eligible turn immediately shows the fixed local **SAY NOW** bridge “Let me think through that carefully for a second.” The production coordinator never runs or displays a model-written Quick answer, and Deep starts automatically. Without a repository, Deep can return only a `general_answer`, clarification, or abstention. General guidance is written as a short, pragmatic staff-engineer response: it leads with the decision-driving clarification when one is needed, then gives a concrete default instead of a generic checklist. It has no evidence, is visibly labeled **verify before speaking**, and is rejected if it claims repository grounding. With a repository, an answer appears only after exact extractive evidence verification: it must match one verified basis claim while preserving punctuation, and that claim must copy one complete cited source line. For clarification or abstention, ChirpCue ignores model prose and shows fixed local safe text. If Deep reaches a terminal failure, ChirpCue stops the spinner, shows the accurate failure state, preserves the question, and offers **Retry Answer**. No classifier or model flag can bypass the bridge or suppress Deep. Speak a suggestion yourself only if it is accurate and appropriate.

Use **Dismiss** to stop only the current answer while capture and transcript continue. Use **Pause** to stop capture temporarily. Use **Stop** when the meeting ends so ChirpCue can join inference, clear and zero in-memory content, delete Codex threads, remove Claude runtime data and sealed snapshots, sanitize transient profile state, and audit app-owned state for bounded fragments of meeting and response content, including dismissed or late-arriving answers.

## Troubleshooting

- **Codex signed out:** use **Sign in with ChatGPT** inside ChirpCue. Signing into another Codex profile does not authenticate ChirpCue's dedicated profile.
- **Codex sign-in reports `persist_failed`:** install this revision and retry. ChirpCue now keeps the real macOS `HOME` for Security.framework while isolating Codex state under `CODEX_HOME`, so the login Keychain remains resolvable without allowing plaintext credentials.
- **Claude signed out:** run `claude auth login --claudeai` in Terminal, confirm the Claude subscription account, then choose **Recheck**. ChirpCue rejects Console and API-key billing paths.
- **Wrong Claude account:** sign in to the intended account with Claude Code, choose **Recheck**, then use **Use Current Claude Account** only after confirming the identity shown in Settings.
- **Microphone or system audio denied:** open System Settings → Privacy & Security, enable the relevant permission for ChirpCue, then reopen the app.
- **No meeting source:** keep the meeting audio routed through this Mac, reload sources, or choose the clearly labeled all-system-output fallback.
- **Deep answer unavailable:** use **Retry Answer** after checking the selected provider, subscription allowance, or cleanup status. ChirpCue retains the same detected question for that retry instead of waiting for another transcript turn. For codebase-specific answers, select a repository and resolve any approvable ambiguous sensitive-file review. High-confidence credential matches cannot be approved. ChirpCue fails closed instead of reading the live working tree or broadening permissions.
- **ChirpCue local Deep limit:** Codex permits six Deep starts in a rolling minute while Claude remains at two. Wait up to one minute, then use **Retry Answer**. This local pause does not mean the provider subscription is exhausted.
- **Stop reports an incomplete audio teardown:** retry **Stop**. ChirpCue clears visible meeting content immediately, keeps the red capture indicator on, and blocks Start, Resume, and Coach until Core Audio confirms that every owned handle is gone.
- **Dedicated Codex profile already in use:** quit the other ChirpCue process or live profile probe. Only one process may own the profile at a time.
- **Cleanup remains blocked:** leave ChirpCue open and retry its startup check. Do not start another meeting until the cleanup warning clears.
- **Wrong ChatGPT account:** stop the meeting, open Settings, choose **Sign Out and Forget Profile**, then sign in again.

## Privacy and current status

Read [PRIVACY.md](PRIVACY.md), [SECURITY.md](SECURITY.md), and the [production-readiness ledger](PRODUCTION_READINESS.md) before real use. The architecture and product contract are in [CODEX_MEETING_COPILOT_SPEC.md](CODEX_MEETING_COPILOT_SPEC.md).

Automated tests, packaging, packaged native-accessibility review, Google Meet microphone/output transcription, and bounded target-account Codex general and grounded Deep smokes are complete. Auth-only checks do not consume model allowance. Paid Claude generation, extended audio/device cases, real-meeting latency dogfood, and Developer ID/notarization for distribution remain explicit manual gates. Treat this as a personal release candidate, not a production-verified build, and do not use it for confidential or policy-restricted meetings.
