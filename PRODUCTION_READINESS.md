# ChirpCue production-readiness ledger

This is the completion contract for the personal production build. A checked item has current local evidence. Opt-in subscription generation, signed-app audio, visual review, real-meeting latency, and distribution checks are intentionally separate from automated fixture coverage.

## Build and code health

- [x] SwiftPM project targets macOS 26 with Swift 6 strict concurrency.
- [x] Automated non-live Swift tests pass locally after the final release-hardening changes; opt-in subscription generation remains excluded.
- [x] Debug and release builds complete after the final release-hardening changes with the Xcode 26 toolchain.
- [x] Deterministic `.app` assembly, plist validation, ad hoc hardened-runtime signing, and code-signature verification pass after the final release-hardening changes.
- [x] The shipped bundle, Finder display name, bundle name, executable product, and Mach-O filename are all `ChirpCue`; migration-sensitive module, storage, and bundle identifiers remain internal.
- [ ] A clean-checkout test, lint, release build, package, and verification sequence passes at the final committed revision.
- [ ] Debug and release builds are confirmed warning-free from a clean checkout at the final committed revision.
- [x] Grounding test fixtures use throwing XCTest teardown blocks, so an owned temporary repository that cannot be removed fails visibly instead of leaving silent residue.

## Codex subscription path

- [x] Codex discovery accepts only the two official ChatGPT/Codex application-bundle paths and validates the OpenAI Team ID, `codex` signing identifier, executable path, symlink status, and tested version range without reading credentials.
- [x] Version and schema preflight subprocesses have timeout, output-cap, cancellation, force-kill, process-reaping, no-follow regular-file, and schema-size coverage.
- [x] The JSONL client, strict output decoding, handshake ordering, cancellation, process shutdown, and malformed-output paths have fixture coverage.
- [x] Required app-server methods, generated schema, and a zero-generation read-only lifecycle have been probed on the development environment.
- [x] The dedicated ChirpCue profile enforces Keychain credential storage, `history.persistence = "none"`, a scrubbed environment, restrictive features, and rejection of plaintext credential files.
- [x] Codex subprocesses keep the authoritative macOS `HOME` so Security.framework can resolve the default Keychain while `CODEX_HOME` remains isolated; inherited `HOME` values and profile-as-home regressions are covered.
- [x] Deep model routing is capability-discovered rather than assuming permanent model availability.
- [x] One-time ChatGPT sign-in is completed in the dedicated ChirpCue profile on the target Mac.
- [x] A zero-generation preflight proves the dedicated profile's account, model, permission, skill, thread create/delete, cleanup, and no-`auth.json` behavior.
- [x] Bounded real general and repository-grounded Deep generations pass on the target subscription, including strict schemas, evidence where required, latency capture, persistent-thread deletion, verified absence of ephemeral threads, profile sanitization, and canary audit.
- [ ] The Deep model route meets measured latency and quality targets on the target account.
- [x] Newer and unknown app-server versions fail closed. Any future version-range expansion requires the compatibility, schema, lifecycle, permission, and cleanup suites to pass before the policy changes.

## Claude subscription path

- [x] Claude discovery accepts only the official user-local launcher resolving directly to a versioned Anthropic-signed executable owned by the current user and not writable by group or world.
- [x] The installed binary must match Anthropic Team ID `Q6L2SF6YDW`, signing identifier `com.anthropic.claude-code`, and the tested `2.1.218..<2.2.0` range; a file-identity trust snapshot is revalidated immediately before launch.
- [x] Authentication parsing accepts only first-party personal `claude.ai` Pro or Max status and rejects Team, Enterprise, signed-out, API-key, Console, gateway, Bedrock, Vertex, Foundry, malformed, missing-identity, and unsupported-plan states.
- [x] Server-managed policy is excluded by the personal-plan gate; macOS managed preferences, system managed-settings files and drop-ins, and managed MCP configuration are rechecked and rejected before every Claude process launch.
- [x] The runtime derives `HOME`, `USER`, and `LOGNAME` from the current macOS account for Keychain access, inherits only validated locale values, and scrubs API credentials, auth tokens, cloud routes, proxies, custom headers, helpers, and configuration overrides.
- [x] Deep runs in Claude safe mode with no tools, MCP, hooks, plugins, skills, agents, ambient instructions, Chrome, or session persistence. One schema-bound turn receives meeting and evidence data only over bounded stdin.
- [x] Process coverage includes input, output, stderr, timeout, cancellation, termination, force-kill, and reaping limits without surfacing raw model or auth output in errors.
- [x] Claude grounding is host-selected from the sealed snapshot under deterministic count, line, pack, path, hash, and freshness limits; displayed claims still pass the shared local evidence verifier.
- [x] The auth-only smoke passes against the target Claude subscription without issuing a model request.
- [x] A fail-closed paid-production smoke harness exists and is skipped by default. Its exact-value `PACENOTE_RUN_PAID_CLAUDE_PRODUCTION_SMOKE` gate permits only two one-turn launches in fixed general-then-grounded order, has no retries, uses synthetic canaries, records latency only, and audits runtime deletion plus opaque metadata for Claude session-state changes without retaining model or auth output.
- [ ] One bounded paid general and one bounded paid repository-grounded Deep generation pass with tools/config leakage probes, latency capture, cancellation, runtime deletion, and no residual session state.
  Run this only with other Claude Code sessions closed: `PACENOTE_RUN_PAID_CLAUDE_PRODUCTION_SMOKE=RUN_EXACTLY_TWO_PAID_CLAUDE_TURNS ./Scripts/toolchain.sh swift test --filter ClaudePaidProductionSmokeTests/testExactlyTwoPaidClaudeTurnsThenDeleteEveryOwnedRuntime`. A successful run spends exactly two Claude subscription or Agent SDK turns. Do not retry automatically; inspect the generic failure and cleanup state first.
- [x] Newer and unknown Claude Code builds fail closed. Any future version-range expansion requires the compatibility, safe-mode, auth, structured-output, process, and adversarial-isolation suites to pass before the policy changes.

## Gemini subscription path

- [x] Gemini uses Google sign-in through the official Antigravity CLI at `~/.local/bin/agy`; API keys, Google Cloud credentials, inherited proxy settings, and alternate executable paths are excluded.
- [x] The executable must be owned by the current user, not group/world writable, signed by Google Team ID `EQHXZ8M8AV` with identifier `cli`, and inside the tested `1.1.12..<1.2.0` range. It is revalidated before every inference launch.
- [x] The interactive sign-in helper uses a scrubbed app-owned profile only to complete Google OAuth. Preflight and every meeting use fresh disposable homes and accept only the resulting Keychain session; file-token fallback and accumulated CLI customization state are therefore never reused for inference. The custom agent has only `view_file`, subagents are disabled, and commands, URLs, writes, MCP, plugins, skills, ambient repository access, and live-working-tree access are denied.
- [x] Meeting and evidence data is written only to one bounded private `input.json`; arguments and environment values remain transcript-free. The input and per-meeting runtime are cleared on completion and Stop.
- [x] Gemini grounding reuses the deterministic host-side bounded sealed-snapshot pack and the local freshness, path, hash, fingerprint, and exact-answer verifier. Gemini cannot invoke repository skills.
- [x] Automated tests cover model-access parsing, environment scrubbing, version policy, static arguments, structured output, file-only input, response validation, and runtime deletion.
- [x] An opt-in authentication-only smoke is available without issuing a model request: `PACENOTE_RUN_GEMINI_AUTH_SMOKE=1 ./Scripts/toolchain.sh swift test --filter GeminiSubscriptionAuthSmokeTests`.
- [ ] Complete one real app-owned Google sign-in and one synthetic general-plus-grounded Gemini production smoke on the tested signed CLI. Confirm Keychain persistence, no ambient customization, no retained conversation state, and exact output-envelope behavior before calling Gemini production-ready.

## Audio and transcription

- [x] Core Audio process taps, AVAudioEngine, SpeechAnalyzer, and SpeechTranscriber compile against the target SDK.
- [x] Raw-audio history is capped at 5 seconds and 8 MiB per lane; eviction, overflow, stop, and clear paths have automated zeroization coverage.
- [x] Core Audio teardown is staged, retryable, and idempotent; failed setup and Stop retain exact handle ownership, seal realtime writers, scrub queued and historical buffers, preserve the failed lane, and block every meeting action except retrying Stop.
- [x] The system-audio permission probe retains and retries a tap whose destruction fails instead of silently dropping its handle.
- [x] The current locale's speech-asset requirement is checked before capture.
- [x] Microphone and selected-process output capture work in the packaged app after TCC approval.
- [x] Global-output fallback construction always adds ChirpCue's current PID and bundle ID to the exclusion set; injected unit tests cover both bundle-present and bundle-absent paths.
- [x] Both lanes maintain a bounded source-frame-to-Core-Audio-host-time transform around Speech input, feed Speech a contiguous non-overlapping source-frame timeline, map result ranges back to verified host time, fail closed with an explicit clock-discontinuity gap, and refuse receipt-time attribution when verified host ranges are missing. A deterministic logical 30-minute dual-clock fixture exercises the production mapping path, drift, and discontinuity behavior without claiming live hardware evidence.
- [ ] A live global-output fallback confirms ChirpCue output is absent from the captured lane.
- [x] Google Meet in Chrome passes packaged capture and transcript testing.
- [ ] At least one native meeting app passes packaged capture and transcript testing.
- [ ] Headphone, speaker echo, browser-helper restart, device switch, permission denial, and permission revocation cases pass.
- [ ] Two-lane host-clock skew stays within the specification target for 30 minutes.
- [ ] Progressive and final transcription work for both lanes in a live signed-app session without audio disk writes.

## Response behavior

- [x] Every eligible production turn immediately shows the exact deterministic local bridge, keeps it immutable, and starts automatic Deep without invoking a classifier, model Quick, model reconciliation, or a model-controlled `needsDeep` value.
- [x] Cue-bound Deep results, word budgets, TTL, stale-generation cancellation, and proof that lower-level Quick and reconciliation stubs are not invoked by the production coordinator have automated coverage.
- [x] Repository-free Deep uses a distinct `general_answer` kind from an empty private context, requires a null grounding fingerprint and empty basis, rejects repository-answer kinds and explicit local codebase or production-state claims, and reaches the UI with an explicit unverified-guidance label.
- [x] A repository Deep answer candidate must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation; each claim must contain at least two informative terms and copy one complete freshly verified source line, apart from a leading comment or list marker. Appended, combined, paraphrased, punctuation-changed, and negation-changed candidates fail closed.
- [x] Strict Deep and evidence schemas reject unknown or malformed fields. Lower-level Quick and reconciliation schema fixtures remain compatibility tests, not production response paths.
- [x] Deep completion, evidence rejection, rate-governor, turn-detector, gap, pause, route-loss, transcriber-failure, and user-interruption paths have fixture or controller coverage.
- [x] Speaking the displayed bridge no longer cancels Deep. Volatile exact or omission-tolerant bridge speech freezes the visible card, queues a mid-speech Deep result, and releases it only after the final bridge transcript; a bridge plus substantive reply still invalidates stale work.
- [x] A bounded content-free timing ledger measures turn-stable-to-controller-ready bridge latency, signed bridge-to-confirmed-speech margin, controller acceptance of verified Deep, stale outcomes, and user dismissals. Empty samples remain explicitly not evaluated, and Stop returns the snapshot before clearing live metrics. SwiftUI render acknowledgement and the distinct turn-boundary p95 remain live dogfood gates below.
- [x] Dismiss clears only the identity-bound suggestion, cancels and joins its generation, leaves capture and transcript active, and remains independent from Stop. A bounded in-memory cleanup ledger retains normalized fragments from transcript, displayed, held, queued, dismissed, and late-arriving response content until Stop audits app-owned provider state; overflow and audit failure preserve the cleanup journal and fail closed.
- [ ] A live meeting proves the bridge appears before the user replies and a later Deep continuation or clarification remains natural to speak.
- [ ] Dogfood meets measured bridge-visibility, Deep, stale-card, and speakability targets.

## Repository and skill isolation

- [x] Sealed snapshot tests cover tracked, dirty, allowed-untracked, rename, delete, symlink, hard-link, special-file, sensitive-path, and concurrent-mutation behavior.
- [x] The model reads a sealed snapshot rather than the live working tree; hard-denied secrets cannot be approved and soft approvals are path-and-hash bound.
- [x] Grounding accepts up to 8 MiB per file and visibly excludes larger candidates from both providers without blocking the repository. It still enforces 5,000 reviewed files, 32 MiB accepted content, 192 MiB scanned content, 50,000 traversed entries, 8 MiB Git output, 10 seconds per Git command, and 30 seconds per top-level operation. Snapshot creation shares one budget across build, copy, rebuild, and retries; freshness and evidence verification are separate bounded operations.
- [x] Automated fixtures cover hard exclusion of private keys, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks; only ambiguous credential assignments can enter exact-hash soft approval.
- [x] Nested `AGENTS.md` scope selection, packaged meeting-coach skill integrity, and at-most-one selected domain skill have automated checks.
- [x] Displayed evidence is gated on repository alias, relative path, line range, file hash, claim, grounding fingerprint, and live-source freshness.
- [ ] The live pinned permission profile blocks parent traversal, absolute-path escape, shell and interpreter escape, writes, temporary files, tool network, and unexpected skills on the target Mac.
- [ ] A live adversarial permission-profile run demonstrates no secret-pattern fixture reaches a model-readable turn; automated snapshot fixtures already prove hard-pattern exclusion before sealing.

## Privacy and lifecycle

- [x] Product privacy and security contracts document OpenAI and Anthropic subscription processing, consent, retention limits, and failure boundaries.
- [x] Transcript-bearing model work is designed as ephemeral forks; base threads are transcript-free and journaled for deletion.
- [x] Automated cleanup tests cover journal recovery, expected-cwd lookup, thread deletion, snapshot and private-root deletion, stable-profile sanitization, residual scanning, and fail-closed reports.
- [x] The dedicated stable Codex profile has an exclusive cross-process lease outside the sanitizer root; runtime and opt-in profile probes reject concurrent ownership.
- [x] Packaged signed-out preflight followed by graceful Quit removes all transient stable-profile databases, while unit coverage preserves them whenever an active, pending, or journal recovery owner remains.
- [x] The canonical dedicated-profile configuration disables history persistence, analytics, memories, agents, apps, hooks, browser, and computer-use surfaces.
- [x] First-run and per-meeting consent UI is manually reviewed in the packaged app; every consent control exposes a nonempty label, checkbox value, enabled state, stable identifier, and press action without activating consent during review.
- [ ] Pause, Stop, crash, relaunch janitor, logout, and Sign Out and Forget Profile pass in the packaged app with the real dedicated profile.
- [ ] Post-session audit proves app-owned meeting roots, stable-profile transient state, logs, diagnostics, crash reports, and snapshots contain no seeded transcript or grounding canaries.
- [ ] Every live brownout is visible and bounded; there are no silent infinite retries.

## Native UX

- [x] Restored window frames are clamped into the visible display; focused placement tests and a packaged-app bad-frame relaunch prove the main window remains fully reachable.
- [x] Packaged first-run, meeting setup, main controls, settings tabs, and menu-bar controls expose named native accessibility roles, enabled states, values where applicable, and press actions. AppKit accessibility proxies cover the macOS 26 SwiftUI control-label regression.
- [x] The packaged coaching window opts out of macOS window capture; capture-by-window-ID fails after packaging. The user must still verify the meeting application's sharing preview.
- [x] The coaching window is configured to join every Space, remain available beside full-screen apps, stay visible when another app activates, and retain window-capture protection.
- [x] Main-window and menu-bar status indicators derive from the capture ownership flag rather than response phase, so active capture remains red while thinking, suggesting, or in a brownout; model lifecycle tests cover the ownership transitions.
- [x] Decorative banner transitions and transcript auto-scroll honor SwiftUI Reduce Motion, and the glass backdrop already honors Reduce Transparency.
- [ ] Setup, transcript, bridge, Deep, degraded, paused, and ended states render correctly in the packaged app.
- [ ] The packaged app visually confirms the capture indicator across listening, bridge, Deep, suggesting, and brownout states.
- [ ] Keyboard navigation, VoiceOver labels, text scaling, contrast, reduced motion, and screen-share-safe behavior pass manual review.
- [ ] Menu-bar controls and the floating window work across Spaces and meeting apps without stealing focus.
- [x] CI rejects production references to speech output, audio playback, clipboard mutation, UI automation, Apple Events, and ambient network clients. Packaged-app verification rejects Apple Events/debug entitlements and the app has no auto-speak, auto-paste, or auto-send control path.

## Distribution and ownership

- [x] GitHub source repository exists at `mo-sharif/ChirpCue`.
- [x] Apache 2.0 licensing, notice, contribution guide, code of conduct, security reporting, ownership, issue forms, and pull-request guidance are present.
- [x] The README includes synthetic native screenshots for coaching, meeting setup, and privacy disclosure; release verification rejects the DEBUG-only showcase environment and code.
- [x] Full-history secret scanning runs locally and in CI with exact suppressions only for two historical synthetic test fixtures.
- [x] The pre-publication repository security review is complete and its eleven findings have focused remediations and validation coverage.
- [ ] Current source, tests, and documentation are committed and pushed to `main`.
- [ ] CI passes for the final pushed revision from a clean checkout.
- [x] Repository Actions are limited to selected GitHub-owned actions and require full commit-SHA pinning; both workflows use the pinned checkout action.
- [x] The local ad hoc build opens on the target Mac and its expected Gatekeeper behavior is documented.
- [ ] Developer ID and notarization credentials are configured if distribution beyond this Mac is desired.
- [ ] A Developer ID signed, notarized, stapled release and checksum are attached to a private GitHub release if distribution beyond this Mac is desired.
