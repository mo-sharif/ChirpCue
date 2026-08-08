# PaceNote Design Exploration

Date: 2026-08-07
Status: Historical exploration; superseded by [the product specification](./CODEX_MEETING_COPILOT_SPEC.md)

This document preserves the divergent design work that led to PaceNote. Some explored flows below use a model-written Quick stage. That is not the shipped production architecture: every eligible production turn now receives one deterministic local bridge, and grounded Deep starts automatically. The specification and production-readiness ledger are normative.

## Brief

Design a personal, native macOS coach that can listen to microphone and meeting-output audio, show a source-aware transcript, provide a sentence the user can say immediately, and automatically follow with a technically grounded answer from selected repositories and skills. It must use ChatGPT-managed Codex subscription access, stay read-only, keep meeting context ephemeral, and remain useful under real latency and rate-limit pressure.

## Exploration method

The concept was attacked from five deliberately different frames:

- hardware engineer: clocks, buses, buffering, scheduling, and physical trust boundaries;
- regulator: proof, consent, provenance, retention, and auditable failure;
- game designer: pacing, cognitive load, player agency, and restrained rewards;
- on-call SRE: stale work, brownouts, gaps, cancellation, and observability;
- assumption removal: delete one apparently fixed premise at a time.

Thirty ideas were then clustered and scored for novelty, viability, and fit. Scores are reviewer judgments on a 10-point scale, not measurement results.

## Cluster map

| Cluster | Principle | Idea IDs |
|---|---|---|
| Audio truth layer | Treat timing, source, feedback, and missing audio as evidence with uncertainty. | H1, H2, R4, R5, O3, O5, X1 |
| Two-speed answer pipeline | Deliver a turn-scoped cue immediately while a preemptible worker builds a traceable deeper answer. | H3, H4, R3, G2, G6, O2, O6, X3 |
| Grounded context lifecycle | Prepare an explicit evidence set, then refresh or narrow it as the conversation changes. | R2, G3, O4, X5 |
| Proof-carrying privacy | Use supported subscription auth while enforcing source, permission, retention, and redaction boundaries. | H5, R1, R6, G4, X6 |
| Restrained adaptation | Reward useful silence and retain content only through explicit user action. | G1, G5, X2 |
| Operational legibility | Make system state and degradation visible in an unobtrusive surface. | H6, O1, X4 |

## Wide set

Legend: N = novelty, V = viability, F = fit. Weighted score uses N 0.35 + V 0.40 + F 0.25. Trap means the raw formulation must not ship unchanged.

### Audio truth layer

- H1 [N5 V9 F9 · 7.60] Preserve host timestamps and correct drift between independent audio clocks.
- H2 [N8 V9 F8 · 8.40] Infer speaker identity directly from the physical mic or output bus. TRAP
- R4 [N6 V9 F9 · 7.95] Detect self-ingestion and downgrade attribution when uncertain.
- R5 [N7 V9 F10 · 8.55] Treat audio and transcript gaps as evidence that constrains the answer.
- O3 [N9 V5 F6 · 6.65] Inject an inaudible canary to verify the live audio path. TRAP
- O5 [N7 V9 F10 · 8.55] Emit typed degraded-transcript events instead of silently joining across a gap.
- X1 [N9 V6 F6 · 7.05] Keep competing speaker hypotheses and rewrite earlier attribution later. TRAP

### Two-speed answer pipeline

- H3 [N8 V8 F10 · 8.50] Keep a small context set hot and page repo evidence asynchronously.
- H4 [N7 V7 F10 · 7.75] Give Quick a hard real-time interrupt lane and Deep a preemptible worker lane. TRAP
- R3 [N8 V9 F10 · 8.90] Make Quick and Deep immutable stages with explicit correction.
- G2 [N7 V8 F9 · 7.90] Promise a repo explanation one conversational bend after the pacenote. TRAP
- G6 [N6 V10 F9 · 8.35] Freeze the current cue while deeper work keeps progressing.
- O2 [N5 V9 F9 · 7.60] Join supervised Quick and Deep workers by immutable turn IDs.
- O6 [N6 V8 F8 · 7.30] Shed optional work automatically to protect latency. TRAP if silent
- X3 [N7 V9 F10 · 8.55] Separate the paced, speakable cue from deeper evidence notes.

### Grounded context lifecycle

- R2 [N8 V8 F9 · 8.25] Attach a repo, AGENTS, skill, and evidence manifest to each grounded answer.
- G3 [N7 V7 F7 · 7.00] Lock a complete AGENTS and skill loadout before the meeting. TRAP
- O4 [N7 V7 F9 · 7.50] Snapshot context in a fresh Git worktree. TRAP
- X5 [N8 V8 F9 · 8.25] Infer a temporary evidence set from meeting terms, symbols, and filenames.

### Proof-carrying privacy

- H5 [N6 V9 F10 · 8.20] Put repo and skill access behind a least-privilege capability boundary.
- R1 [N8 V5 F8 · 6.80] Treat a local execution receipt as proof of the remote subscription path. TRAP
- R6 [N8 V5 F8 · 6.80] Deny every subprocess and claim that as proof no write can occur. TRAP
- G4 [N6 V9 F10 · 8.20] Save only explicitly promoted, redacted moments and default to ephemeral.
- X6 [N8 V8 F10 · 8.50] Give mic and system audio distinct permission, attribution, and retention rules.

### Restrained adaptation

- G1 [N7 V9 F9 · 8.30] Reward restraint and withhold weak suggestions.
- G5 [N8 V5 F6 · 6.30] Learn conversational turn shapes without retaining content. TRAP
- X2 [N7 V9 F8 · 8.05] Let the user explicitly promote a useful moment instead of retaining a meeting.

### Operational legibility

- H6 [N7 V9 F10 · 8.55] Use a visible brownout state machine instead of pretending every dependency is healthy.
- O1 [N5 V8 F8 · 6.95] Keep an append-only local event log for replay and incident analysis. TRAP if content-bearing
- X4 [N5 V9 F9 · 7.60] Use an ambient menu-bar panel that expands into an inspector only on demand.

## Duplicate merges

- R5 and O5 become one typed audio-gap contract.
- G2 and X3 become one speech-first versus evidence-first presentation model, without promising a fixed conversational deadline.
- R2 and G3 become a grounding manifest that is prepared early but revalidated at answer time.
- H6 and O6 become one visible brownout policy. Load shedding may never hide provenance loss.
- H4 and O2 become one deadline-budgeted worker topology with cancellation and stale-result rejection.
- H5 and R6 become one read-only capability boundary. It blocks writes without disabling every legitimate read-only subprocess.

## Converge

1. Honest two-stage cue: R3, X3, H3, and O2 directly solve the cognitive problem. The user gets one stable sentence now while deeper work remains independently cancellable.
2. ★ Sanitized evidence fork: R2, H5, X5, and X6 turn a generic meeting assistant into a technical coach that can defend repo claims without exposing the live filesystem. This is the non-obvious but viable wedge.
3. Deadline-budgeted brownout pipeline: H6, R5, G6, and O5 make the app honest under audio loss, stale turns, model limits, and repo changes.

Traps excluded from the shortlist:

- H2: a physical bus identifies a source, not a person.
- G2 and H4: network inference cannot promise a conversational or hard real-time deadline.
- O4: a Git worktree mutates metadata and can miss dirty or untracked truth.
- O6: silent load shedding hides correctness loss.
- X1: retroactive identity rewrites destabilize answers.
- G3: a locked pre-meeting context becomes stale.
- O1: a content-bearing event log becomes another sensitive transcript.
- R1: a local receipt cannot attest remote billing or retention.
- R6: denying all subprocesses breaks legitimate read-only inspection.
- O3: an inaudible canary can route incorrectly and give false confidence.
- G5: a learned representation can retain content even when raw text is gone.

## Focus 1: honest two-stage cue

When a stable meeting-output turn looks like a question, the app launches eligible Quick and Deep jobs under one immutable turn ID. Quick receives only recent transcript and speaking preferences, then returns one honest sentence short enough to say in a breath. The first valid Quick result or two-second deterministic fallback becomes the one immutable displayed cue; any late Quick is discarded. Deep works against a sanitized repo snapshot while the interface shows visible progress, and its continuation or correction is bound to the displayed cue's ID and hash before display. If Deep contradicts Quick, the UI never rewrites history and instead says, “Let me correct one detail.” When the conversation advances, generation counters cancel or hide stale output, and the current card freezes while the user is speaking.

Load-bearing risk: the fast cue may sound confident enough to repeat even when Deep later disproves its premise. Quick must be structurally prevented from making repo-specific claims and calibrated without becoming empty filler.

First step: build a text-only concurrent Quick and Deep spike with strict schemas and fixtures for every Quick, fallback, Deep, reconciliation, timeout, and stale-turn completion ordering.

Subideas:

- Use an approved deterministic bridge when Quick misses its budget.
- Cap Quick at 24 words and Deep's speak-next text at 40 words.
- Freeze the cue through a hotkey or automatic local-speech detection.
- Show confidence through wording, not percentages.
- Track correction and unsupported-claim rates during dogfood.

## Focus 2: sanitized evidence fork

Before a meeting, the app creates a sanitized, immutable copy-on-write snapshot containing allowed dirty and untracked repo content, every nested AGENTS scope, and exactly the selected skill dependency tree. A local preflight excludes ignored files, .git, credentials, key material, token files, dumps, and secret-scan findings before any model can read them. It starts a transcript-free Codex base thread in the applicable instruction scope under a dedicated CODEX_HOME and a named permission profile that denies the filesystem root, writes, tool network, and every non-snapshot path. Each technical question gets an ephemeral fork, receives only the minimum transcript window, and returns speakable text plus file-and-line evidence. A local verifier rejects wrong-scope citations, stale fingerprints, changed live-source files, missing lines, unsupported claims, and any unexpected skill or tool event. Only transcript-free base threads may persist locally; every app-created thread is journaled for stop and crash cleanup, and every transcript-bearing fork is audited for disk leakage.

Load-bearing risk: freshness and latency pull in opposite directions. A stale context can produce confidently outdated advice, while rebuilding too aggressively makes the coach unusably slow.

First step: select one repo, build and secret-scan its sealed snapshot, verify instructionSources and the named permission profile, invoke one allowlisted skill, validate one synthetic answer, and prove secret, symlink, subprocess, network, and write attempts fail.

Subideas:

- Add a content-free grounding receipt containing repo alias, fingerprint, instruction sources, skills, and evidence timestamp.
- Precompute filenames, symbols, manifests, recent diffs, and architecture docs without a model call.
- Allow one primary and one secondary repo, but route each question to exactly one.
- Interrupt in-flight work when the repo fingerprint changes.
- Isolate personal and work profiles completely.

## Focus 3: deadline-budgeted brownout pipeline

Each stable meeting-output turn receives an immutable turn ID and generation, then launches a constrained Quick worker and an eligible grounded Deep worker concurrently. Quick has a short deadline and may return only a speakable cue without repo claims; if it misses, the UI seals an honest local bridge. Deep continues asynchronously and returns an evidence-backed continuation, correction, clarification, or abstention bound to that sealed cue. When the turn expires or conversation state changes, the coordinator increments the generation, interrupts obsolete work where possible, and rejects every late result whose identity no longer matches. Audio loss, transcript uncertainty, authentication failures, rate limits, and repo changes become visible brownout states with timestamped gaps. Runtime availability feeds a versioned, benchmarked routing policy or the app enters transcript-only mode without claiming hard real-time behavior.

Load-bearing risk: end-of-turn detection. A late boundary delays both workers, while an early boundary produces incomplete prompts, wasted subscription use, and stale suggestions.

First step: replay timestamped text fixtures against a pinned app-server schema and prove deadlines, concurrency, cancellation, stale rejection, fallbacks, and simulated rate-limit transitions before adding audio.

Subideas:

- Track separate budgets for boundary detection, Quick, first Deep evidence, and completion.
- Queue Deep as a continuation when local speech freezes the current card.
- Carry typed audio and transcript discontinuities into answer confidence.
- Shed work in an explicit order and never drop evidence validation.
- Keep content-free timing records keyed by randomized turn IDs.

## Traps kept out of the product

### Physical source is not identity

Mic versus system output distinguishes physical capture lanes, not people. The mic can hear a bystander or private aside, and global output can contain media or notifications. The UI uses MIC and OUTPUT unless the user has confirmed a process-scoped meeting setup, then it may show YOU and THEM.

### Network inference is not hard real-time

Quick has a deadline and a deterministic fallback. The product cannot promise that a remote model will always answer before the user needs to speak.

### A fresh worktree is not read-only truth

Creating a Git worktree changes repo metadata and can exclude dirty or untracked context. The app instead builds a sanitized copy-on-write snapshot when supported, or a regular private copy otherwise, and exposes only that sealed state to Codex.

### Silent load shedding corrupts trust

The coordinator can skip optional enrichment or ask which repo applies, but it cannot silently remove citations, ignore an audio gap, or present a weaker route as equally certain.

### Local receipts are not remote attestation

The app can display observed account type, selected model, repo fingerprint, instruction sources, and blocked actions. It cannot independently prove OpenAI's remote billing or retention path.

### Derived logs can still leak meeting content

The timing ledger stores event types and durations only. It does not store transcripts, generated sentences, filenames, claims, or embeddings.

### “Learning without content” is underspecified

Embeddings, preferences, and learned representations can encode meeting content. Cross-meeting learning stays out of the MVP until its privacy model and deletion behavior are explicit.

## Provocation

What if the fastest trustworthy suggestion is silence?

The most useful coach may intentionally say nothing on most turns, surface a bridge only when it buys time, and reserve technical claims for evidence it can defend. The success metric should therefore be “helpful words the user would actually say,” not answer volume.

## Final convergence

The selected product evolved from the intersection of the three concepts. The final production shape is:

1. one fixed, local one-breath bridge with no model Quick turn;
2. automatically arriving, evidence-gated Deep response;
3. ephemeral, sanitized, deny-by-default grounding with cancellation and visible degradation.

That combination is more defensible than a single fast model call, a meeting bot, an always-on recorder, or an unconstrained coding agent hidden behind a transcript UI.
