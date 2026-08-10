# ChirpCue security policy

Report suspected vulnerabilities through a [private GitHub security advisory](https://github.com/mo-sharif/ChirpCue/security/advisories/new). Do not open a public issue and do not include meeting transcripts, credentials, repository excerpts, auth links, email addresses, absolute home paths, or other sensitive material.

## Security invariants

- Inference uses either the ChatGPT-authenticated Codex app-server or first-party Claude.ai subscription authentication. ChirpCue does not request, store, or fall back to OpenAI or Anthropic API keys, Console billing, gateways, or cloud-provider credentials.
- ChirpCue accepts only `/Applications/ChatGPT.app/Contents/Resources/codex` or `/Applications/Codex.app/Contents/Resources/codex`, rejects symlinks and alternate locations, and checks OpenAI Team ID `2DC432GLL2` plus signing identifier `codex` before use. Version and schema probes have fixed time, output, file-type, and file-size limits and terminate and reap failed subprocesses.
- Codex runs from a dedicated ChirpCue profile with Keychain credential storage, history persistence set to `none`, analytics and memories disabled, and no ambient apps, MCP services, browser, hooks, or computer-use tools.
- A process-wide advisory lease on a stable lock file outside the sanitizable profile prevents ChirpCue and opt-in probes from concurrently mutating the same dedicated Codex profile. The lock path rejects symlinks, non-regular files, hard links, and foreign ownership, and forces the lock file to owner-only mode.
- ChirpCue never reads or copies Codex tokens. A plaintext `auth.json` or other credential file in the dedicated profile is treated as a hard failure.
- Model tools receive a verified read-only, network-disabled permission profile rooted at either an empty private general-coaching context or a sealed repository snapshot, plus the packaged meeting skill and at most one selected repository skill. The app-server itself retains outbound access to OpenAI for inference.
- The model never receives ambient access to the live working tree, user home directory, credentials, temporary directories, or write paths.
- Claude Code must resolve to the official user-local versioned executable, be owned by the current user, be non-writable by group or world, carry Anthropic Team ID `Q6L2SF6YDW` and signing identifier `com.anthropic.claude-code`, and fall inside the tested version range. Its inode, device, size, and modification-time trust snapshot is revalidated before launch.
- Claude accepts only personal first-party Pro or Max status. Team, Enterprise, MDM preferences, system managed-settings files, drop-ins, and managed MCP configuration fail closed because administrator policy can survive safe mode and override command-line isolation.
- Claude runs in safe mode from an empty app-owned meeting directory with an OS-derived Keychain identity, a strict environment allowlist, tools disabled, an empty strict MCP configuration, skills and slash commands disabled, no Chrome, no session persistence, one turn, and schema-bound output. Meeting and evidence data enter only through bounded stdin.
- Claude repository grounding is host-selected from the sealed snapshot. Instruction files, `.claude` state, MCP configuration, skills, plugins, hooks, agents, and live repository paths are excluded before prompt construction. Codex remains the only provider allowed to invoke a reviewed packaged or repository skill.
- Meeting transcript is untrusted data. It cannot change approval policy, permissions, skill selection, or tool policy.
- Every eligible production turn immediately uses the same fixed local bridge and starts automatic Deep. The production coordinator starts no model Quick or model reconciliation turn, and no classifier or model-controlled `needsDeep` value can alter that path.
- Repository-specific Deep answers are displayed only after local path, line, hash, scope, grounding-fingerprint, and freshness checks. The answer candidate must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation. That claim must copy one complete cited source line, apart from a leading comment or list marker; appended, combined, paraphrased, punctuation-changed, or negation-changed candidates fail closed.
- Without a repository, Deep may return only a schema-bound `general_answer`, clarification, or abstention from an empty private context. A general answer must have a null grounding fingerprint and empty basis, begin with a locally accepted qualified or proposal frame, and pass deterministic rejection of explicit codebase, organization, or production-state claims. It is visibly labeled as unverified guidance and cannot be presented as repository evidence. It has no tool or network access.
- Grounding defaults to 2 MiB per file, 5,000 accepted files, 32 MiB accepted content, 192 MiB scanned content, 50,000 traversed entries, 8 MiB Git output, 10 seconds per Git command, and 30 seconds per top-level grounding operation. Snapshot creation shares one budget across its build, copy, rebuild, and retry phases. Freshness checks and evidence verification are separate bounded operations with fresh budgets. Private keys, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks are hard exclusions with no approval path; only ambiguous assignment warnings can be approved at an exact content hash.
- Unexpected approval, tool, skill, permission-profile, protocol, or external-service requests fail closed.
- ChirpCue never automatically speaks, pastes, sends, joins a call, or mutates a repository.
- The required check gate rejects production use of speech synthesis, audio playback, clipboard mutation, UI automation, Apple Events, and ambient network-client APIs. Packaged-app verification also rejects Apple Events and debug entitlements.
- Logs and operational metrics must not contain transcript text, repository excerpts, auth URLs, email addresses, tokens, or absolute home-directory paths.

## Session isolation and cleanup

Each meeting gets a private temporary root and a content-free cleanup-journal entry. Transcript-bearing Codex Deep requests use ephemeral forks; Claude runs one non-persistent Deep process per turn. The production coordinator starts no model Quick or reconciliation turn for either provider. Transcript-free Codex bases used for general or grounded Deep context and lower-level compatibility plumbing are registered for deletion.

Stop performs bounded turn interruption and app-server shutdown, removes registered threads and meeting artifacts, sanitizes allowlisted transient state from the stable ChirpCue Codex profile, restores the canonical restrictive configuration, deletes the complete meeting root, and scans app-owned meeting and profile paths for bounded normalized fragments retained from transcript, displayed, held, queued, dismissed, and late-arriving response content. Generation tasks are canceled and joined before that in-memory audit ledger is snapshotted and zeroed. Audit overflow or failure preserves the journal and fails closed; the journal entry is removed only after the full sequence succeeds.

If ChirpCue crashes or cleanup is incomplete, startup recovery repeats thread lookup, deletion, profile sanitization, meeting-root removal, and residual auditing before capture is permitted. Cleanup failure is a visible blocking state, not a warning that can be bypassed.

Signed-out environment preflight can also create transcript-free Codex databases. A clean graceful Quit removes that transient state immediately when there is no active meeting, pending setup, or cleanup-journal owner. Recovery state is preserved whenever any owner remains.

System-output teardown is staged and retryable: stop the aggregate device, destroy its IOProc, destroy the aggregate, then destroy the process tap. A completed step is never repeated. Capture rings reject new realtime writes and are overwritten before teardown begins; queued and historical audio are also scrubbed. ChirpCue emits a stopped event only after every owned handle is verified destroyed. Permission-probe taps use the same fail-closed ownership rule.

Microphone and system-output transcript lanes maintain a bounded source-frame-to-Core-Audio-host-time transform around Speech input. Speech receives a contiguous source-frame timebase, then result ranges map back into the shared host-time domain. Analyzer buffers may receive only a small bounded forward correction for conversion overlap; a cadence, regression, timestamp, or range discontinuity blocks that lane, emits a visible gap, and prevents receipt-time fallback from guessing speaker attribution.

## Trust boundaries

- Apple Core Audio, AVFoundation, and Speech perform local capture and transcription.
- OpenAI processes the transcript slices and selected repository excerpts sent through the user's ChatGPT Codex account. ChirpCue does not claim server-side zero retention.
- Anthropic processes transcript slices and bounded host-selected sealed-snapshot lines sent through the user's Claude.ai subscription when Claude is selected. ChirpCue does not claim server-side zero retention.
- macOS Keychain, the Codex app-server, and Claude Code own authentication material and refresh behavior for their respective provider paths.
- The user owns participant disclosure, legal consent, employer approval, and the decision to speak a suggestion.

## Supported versions and distribution

Security fixes are made on `main`. Until the first signed public release, source builds from other branches and forks are unsupported.

The current source-build path creates a locally ad hoc signed app intended only for the Mac that built it. A cross-Mac binary must not be published until Developer ID signing, Apple notarization, stapling, Gatekeeper verification, provenance attestation, and the remaining production-readiness gates pass. Never work around Gatekeeper with quarantine removal or disabled security settings.

The release workflow is manual, accepts only a tag whose peeled commit exactly equals the explicitly approved current `origin/main` SHA, runs tests before loading credentials, uses a protected `production` environment, and attests the release archive before publication.
