# PaceNote production-readiness ledger

This is the completion contract for the personal production build. A checked item has current local evidence. Opt-in subscription generation, signed-app audio, visual review, real-meeting latency, and distribution checks are intentionally separate from automated fixture coverage.

## Build and code health

- [x] SwiftPM project targets macOS 26 with Swift 6 strict concurrency.
- [x] Automated non-live Swift tests pass locally; opt-in subscription generation remains excluded.
- [x] Debug and release builds complete with the Xcode 26 toolchain.
- [x] Deterministic `.app` assembly, plist validation, ad hoc hardened-runtime signing, and code-signature verification run locally.
- [x] A clean-checkout test, lint, release build, package, and verification sequence passes.
- [x] Debug and release builds are confirmed warning-free from a clean checkout.

## Codex subscription path

- [x] Codex discovery accepts only the two official ChatGPT/Codex application-bundle paths and validates the OpenAI Team ID, `codex` signing identifier, executable path, symlink status, and tested version range without reading credentials.
- [x] Version and schema preflight subprocesses have timeout, output-cap, cancellation, force-kill, process-reaping, no-follow regular-file, and schema-size coverage.
- [x] The JSONL client, strict output decoding, handshake ordering, cancellation, process shutdown, and malformed-output paths have fixture coverage.
- [x] Required app-server methods, generated schema, and a zero-generation read-only lifecycle have been probed on the development environment.
- [x] The dedicated PaceNote profile enforces Keychain credential storage, `history.persistence = "none"`, a scrubbed environment, restrictive features, and rejection of plaintext credential files.
- [x] Deep model routing is capability-discovered rather than assuming permanent model availability.
- [ ] One-time ChatGPT sign-in is completed in the dedicated PaceNote profile on the target Mac.
- [ ] A zero-generation preflight proves the dedicated profile's account, model, permission, skill, thread create/delete, cleanup, and no-`auth.json` behavior.
- [ ] A bounded real Deep generation passes on the target subscription, including strict schema, evidence, latency capture, thread deletion, profile sanitization, and canary audit.
- [ ] The Deep model route meets measured latency and quality targets on the target account.
- [ ] A newer or unknown app-server version is accepted only after the compatibility suite passes.

## Audio and transcription

- [x] Core Audio process taps, AVAudioEngine, SpeechAnalyzer, and SpeechTranscriber compile against the target SDK.
- [x] Raw-audio history is capped at 5 seconds and 8 MiB per lane; eviction, overflow, stop, and clear paths have automated zeroization coverage.
- [x] The current locale's speech-asset requirement is checked before capture.
- [ ] Microphone and selected-process output capture work in the packaged app after TCC approval.
- [ ] Global-output fallback excludes PaceNote output.
- [ ] Google Meet in Chrome and at least one native meeting app pass capture tests.
- [ ] Headphone, speaker echo, browser-helper restart, device switch, permission denial, and permission revocation cases pass.
- [ ] Two-lane host-clock skew stays within the specification target for 30 minutes.
- [ ] Progressive and final transcription work for both lanes in a live signed-app session without audio disk writes.

## Response behavior

- [x] Every eligible production turn immediately shows the exact deterministic local bridge, keeps it immutable, and starts automatic Deep without invoking a classifier, model Quick, model reconciliation, or a model-controlled `needsDeep` value.
- [x] Cue-bound Deep results, word budgets, TTL, stale-generation cancellation, and proof that lower-level Quick and reconciliation stubs are not invoked by the production coordinator have automated coverage.
- [x] A Deep answer candidate must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation; each claim must contain at least two informative terms and copy one complete freshly verified source line, apart from a leading comment or list marker. Appended, combined, paraphrased, punctuation-changed, and negation-changed candidates fail closed.
- [x] Strict Deep and evidence schemas reject unknown or malformed fields. Lower-level Quick and reconciliation schema fixtures remain compatibility tests, not production response paths.
- [x] Deep completion, evidence rejection, rate-governor, turn-detector, gap, pause, route-loss, transcriber-failure, and user-interruption paths have fixture or controller coverage.
- [ ] A live meeting proves the bridge appears before the user replies and a later Deep continuation or clarification remains natural to speak.
- [ ] Dogfood meets measured bridge-visibility, Deep, stale-card, and speakability targets.

## Repository and skill isolation

- [x] Sealed snapshot tests cover tracked, dirty, allowed-untracked, rename, delete, symlink, hard-link, special-file, sensitive-path, and concurrent-mutation behavior.
- [x] The model reads a sealed snapshot rather than the live working tree; hard-denied secrets cannot be approved and soft approvals are path-and-hash bound.
- [x] Grounding enforces 2 MiB per file, 5,000 accepted files, 32 MiB accepted content, 192 MiB scanned content, 50,000 traversed entries, 8 MiB Git output, 10 seconds per Git command, and 30 seconds per top-level operation. Snapshot creation shares one budget across build, copy, rebuild, and retries; freshness and evidence verification are separate bounded operations.
- [x] Automated fixtures cover hard exclusion of private keys, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks; only ambiguous credential assignments can enter exact-hash soft approval.
- [x] Nested `AGENTS.md` scope selection, packaged meeting-coach skill integrity, and at-most-one selected domain skill have automated checks.
- [x] Displayed evidence is gated on repository alias, relative path, line range, file hash, claim, grounding fingerprint, and live-source freshness.
- [ ] The live pinned permission profile blocks parent traversal, absolute-path escape, shell and interpreter escape, writes, temporary files, tool network, and unexpected skills on the target Mac.
- [ ] A live adversarial permission-profile run demonstrates no secret-pattern fixture reaches a model-readable turn; automated snapshot fixtures already prove hard-pattern exclusion before sealing.

## Privacy and lifecycle

- [x] Product privacy and security contracts document ChatGPT processing, consent, retention limits, and failure boundaries.
- [x] Transcript-bearing model work is designed as ephemeral forks; base threads are transcript-free and journaled for deletion.
- [x] Automated cleanup tests cover journal recovery, expected-cwd lookup, thread deletion, snapshot and private-root deletion, stable-profile sanitization, residual scanning, and fail-closed reports.
- [x] The canonical dedicated-profile configuration disables history persistence, analytics, memories, agents, apps, hooks, browser, and computer-use surfaces.
- [x] First-run and per-meeting consent UI is manually reviewed in the packaged app; every consent control exposes a nonempty label, checkbox value, enabled state, stable identifier, and press action without activating consent during review.
- [ ] Pause, Stop, crash, relaunch janitor, logout, and Sign Out and Forget Profile pass in the packaged app with the real dedicated profile.
- [ ] Post-session audit proves app-owned meeting roots, stable-profile transient state, logs, diagnostics, crash reports, and snapshots contain no seeded transcript or grounding canaries.
- [ ] Every live brownout is visible and bounded; there are no silent infinite retries.

## Native UX

- [x] Restored window frames are clamped into the visible display; focused placement tests and a packaged-app bad-frame relaunch prove the main window remains fully reachable.
- [x] Packaged first-run, meeting setup, main controls, settings tabs, and menu-bar controls expose named native accessibility roles, enabled states, values where applicable, and press actions. AppKit accessibility proxies cover the macOS 26 SwiftUI control-label regression.
- [x] The packaged coaching window opts out of macOS window capture; capture-by-window-ID fails after packaging. The user must still verify the meeting application's sharing preview.
- [ ] Setup, transcript, bridge, Deep, degraded, paused, and ended states render correctly in the packaged app.
- [ ] The capture indicator remains visible during listening, bridge, Deep, suggesting, and brownout states.
- [ ] Keyboard navigation, VoiceOver labels, text scaling, contrast, reduced motion, and screen-share-safe behavior pass manual review.
- [ ] Menu-bar controls and the floating window work across Spaces and meeting apps without stealing focus.
- [ ] Manual observation confirms the app never auto-speaks, auto-pastes, or auto-sends.

## Distribution and ownership

- [x] Private GitHub repository exists at `mo-sharif/PaceNote`.
- [ ] Current source, tests, documentation, and CI are committed and pushed to `main`.
- [ ] Private-repository CI passes from a clean checkout.
- [ ] The local ad hoc build opens on the target Mac and its expected Gatekeeper behavior is documented.
- [ ] Developer ID and notarization credentials are configured if distribution beyond this Mac is desired.
- [ ] A Developer ID signed, notarized, stapled release and checksum are attached to a private GitHub release if distribution beyond this Mac is desired.
