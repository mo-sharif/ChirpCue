# PaceNote privacy contract

PaceNote is a personal, consent-first meeting coach. It is not a covert recorder, meeting bot, or assessment-evasion tool.

## Before capture

- You manually start every session.
- PaceNote shows the selected microphone and Mac-output scope.
- You must confirm for every meeting that participants have been informed and that you have permission to capture and process the conversation.
- A persistent visible indicator remains on while either capture lane is active.

PaceNote cannot verify participant consent for you. You remain responsible for recording law, confidentiality agreements, employer policy, and assessment rules.

## Data kept in memory

- The raw-audio history ring is capped at 5 seconds and 8 MiB per capture lane for local transcription and echo comparison. Smaller transfer queues are also bounded. Evicted and cleared buffers are overwritten. PaceNote does not intentionally write raw audio to disk.
- The working transcript and suggestion cards remain in memory and are cleared when the meeting ends.
- Pause stops capture and clears buffered raw audio. Stop also interrupts active inference and clears transcript and suggestions.

“In memory” describes PaceNote's intentional storage design. It is not a guarantee against operating-system swap, crash artifacts, hardware compromise, or OpenAI-side processing.

## Dedicated Codex profile

PaceNote uses one stable, private Codex profile under its Application Support directory so a one-time ChatGPT sign-in can survive between meetings. It does not copy tokens or authentication files from another Codex installation. Codex is configured to keep credentials in the macOS Keychain, and PaceNote rejects plaintext credential files in the profile.

The profile configuration sets Codex history persistence to `none`. Transcript-bearing production Deep work runs in ephemeral forks; the production coordinator starts no model Quick or model reconciliation turn. Transcript-free bases may exist for grounded Deep context and lower-level compatibility plumbing; PaceNote registers and deletes all of them on Stop or startup recovery.

Codex can create transient local databases while the app-server is running even with history disabled. After a meeting, PaceNote terminates the app-server, removes the allowlisted transient state, restores the restrictive profile configuration, and scans the stable profile for meeting and repository canaries. The Keychain-backed sign-in and minimal profile configuration remain for the next meeting.

## Temporary meeting data

PaceNote creates a private per-meeting root containing sealed repository and skill snapshots plus content-free cleanup metadata. Repository access is read-only and never points Codex at the live working tree.

On Stop, PaceNote deletes app-created threads, snapshots, temporary context, and the complete meeting root, then audits the meeting root and stable profile before removing the cleanup-journal entry. If cleanup cannot be proven, the journal remains and new capture is blocked. On the next launch, the startup janitor retries deletion and auditing before sign-in or capture is allowed.

## Data processed by OpenAI

PaceNote sends the minimum recent transcript slice needed for a response through the local Codex app-server. A deeper technical answer can also cause Codex to read selected excerpts from the sealed repository snapshot, applicable `AGENTS.md` instructions, and one explicitly selected read-only skill.

This uses the ChatGPT account signed into PaceNote's dedicated Codex profile, not an OpenAI API key. OpenAI-side handling and usage limits follow that account and plan. PaceNote does not claim server-side zero retention.

## Data excluded from repository snapshots

- `.env` files and variants
- private keys, credential stores, token files, and dumps
- Git internals, dependency caches, build output, ignored files, symlinks, hard links, sockets, devices, and other non-regular files
- files flagged by the local sensitive-file scanner unless you approve a specific soft false positive for that meeting at its exact content hash

Private-key blocks, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks are hard-denied by content and cannot be approved. Only ambiguous credential-assignment warnings can be approved. The default grounding limits are 2 MiB per file, 5,000 accepted files, 32 MiB of accepted content, 192 MiB of scanned content, 50,000 traversed entries, 8 MiB of Git output, 10 seconds per Git command, and 30 seconds per top-level grounding operation. Snapshot creation shares one budget across its build, copy, rebuild, and retry phases. Freshness checks and evidence verification are separate bounded operations with fresh budgets. Every displayed repository answer must pass local path, line, hash, scope, grounding-fingerprint, freshness, claim-to-excerpt, and answer-to-claim checks.

For an answer to be displayed, its candidate sentence must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation. The claim must contain at least two informative terms and copy one complete cited source line exactly, apart from a leading code-comment or list marker. PaceNote rejects appended, combined, paraphrased, punctuation-changed, and negation-changed answer candidates.

## User control

- **Pause** stops both capture lanes and clears buffered raw audio.
- **Stop** interrupts inference, clears the transcript and suggestions, and begins verified cleanup.
- **Sign Out and Forget Profile** asks Codex to sign out, removes PaceNote's dedicated profile and local identity binding, and recreates an empty private profile after explicit confirmation.
- PaceNote never automatically speaks, pastes, posts, sends, joins a call, or changes repository files.

Do not use PaceNote for confidential employer meetings unless the employer has approved this exact workflow. Do not use it in an interview, examination, or assessment that forbids assistance.
