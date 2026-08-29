# ChirpCue privacy contract

ChirpCue is a personal, consent-first meeting coach. It is not a covert recorder, meeting bot, or assessment-evasion tool.

## Before capture

- You manually start every session.
- ChirpCue shows whether the microphone lane is enabled and the selected Mac-output scope. The microphone lane uses the current macOS default input; ChirpCue does not enumerate or display an exact microphone device before capture.
- You must confirm for every meeting that participants have been informed and that you have permission to capture and process the conversation.
- A persistent visible indicator remains on while either capture lane is active or its teardown has not yet been verified.

ChirpCue cannot verify participant consent for you. You remain responsible for recording law, confidentiality agreements, employer policy, and assessment rules.

## Data kept in memory

- The raw-audio history ring is capped at 5 seconds and 8 MiB per capture lane for local transcription and echo comparison. Smaller transfer queues are also bounded. Evicted and cleared buffers are overwritten. ChirpCue does not intentionally write raw audio to disk.
- The working transcript and suggestion cards remain in memory and are cleared when the meeting ends.
- Pause stops capture and clears buffered raw audio. Stop also interrupts active inference and clears transcript and suggestions.

“In memory” describes ChirpCue's intentional storage design. It is not a guarantee against operating-system swap, crash artifacts, hardware compromise, or provider-side processing.

## Optional speaker brief

The **About you** brief is optional factual background you enter in Settings, such as years of experience, recent work, and your role. It is stored in the app's local preferences until you clear it. ChirpCue includes the bounded brief with meeting inference so the selected provider can answer personal-background questions without inventing facts. The brief is treated as data, never model instruction.

## Dedicated Codex profile

ChirpCue uses one stable, private Codex profile under its Application Support directory so a one-time ChatGPT sign-in can survive between meetings. It does not copy tokens or authentication files from another Codex installation. Codex is configured to keep credentials in the macOS Keychain, and ChirpCue rejects plaintext credential files in the profile.

The profile configuration sets Codex history persistence to `none`. Transcript-bearing production Deep work runs in ephemeral forks; the production coordinator starts no model Quick or model reconciliation turn. Transcript-free bases may exist for general or grounded Deep context and lower-level compatibility plumbing; ChirpCue registers and deletes all of them on Stop or startup recovery.

Codex can create transient local databases while the app-server is running even with history disabled. After a meeting, ChirpCue terminates the app-server, removes the allowlisted transient state, restores the restrictive profile configuration, and scans the stable profile for meeting and repository canaries. A clean graceful Quit also removes transcript-free preflight databases when no meeting, pending setup, or cleanup-journal owner remains. The Keychain-backed sign-in and minimal profile configuration remain for the next meeting.

## Claude subscription path

Claude uses only a first-party personal Claude.ai Pro or Max login stored by Claude Code in the encrypted macOS Keychain. Team, Enterprise, and endpoint-managed Claude configurations fail closed because managed settings can override command-line isolation. ChirpCue passes an OS-derived `HOME`, `USER`, and `LOGNAME` so Keychain lookup works, while discarding inherited API keys, auth tokens, gateways, cloud-provider credentials, proxy variables, and credential helpers. Console and API-key billing are not accepted.

Every Claude request runs in an empty private per-meeting directory with safe mode, no built-in tools, no MCP, no hooks, no plugins, no agents, no skills, no ambient instruction files, and no session persistence. Meeting transcript and evidence payloads are sent over stdin rather than process arguments. Standard output, standard error, input size, wall time, cancellation, termination, and process reaping are bounded. The Claude runtime directory is removed with the meeting root.

## Temporary meeting data

ChirpCue creates a private per-meeting root containing the sealed repository, any Codex-only selected skill snapshot, provider runtime directories, and content-free cleanup metadata. Repository access is read-only and neither provider receives the live working tree.

On Stop, ChirpCue deletes app-created threads, snapshots, temporary context, and the complete meeting root, then audits the meeting root and stable profile before removing the cleanup-journal entry. If cleanup cannot be proven, the journal remains and new capture is blocked. On the next launch, the startup janitor retries deletion and auditing before sign-in or capture is allowed.

## Data processed by OpenAI

ChirpCue sends the optional speaker brief and minimum recent transcript slice needed for a response through the local Codex app-server. Without a repository, the model receives no repository files and any useful response is visibly labeled as unverified general guidance. When repository grounding is selected, a deeper technical answer can also cause Codex to read selected excerpts from the sealed snapshot, applicable `AGENTS.md` instructions, and one explicitly selected read-only skill.

This uses the ChatGPT account signed into ChirpCue's dedicated Codex profile, not an OpenAI API key. OpenAI-side handling and usage limits follow that account and plan. ChirpCue does not claim server-side zero retention.

## Data processed by Anthropic

When Claude is selected, ChirpCue sends the optional speaker brief, recent transcript slice, and, if grounding is enabled, a small deterministic pack of bounded exact lines selected locally from the reviewed sealed snapshot. Claude receives no `AGENTS.md`, `CLAUDE.md`, `.claude` configuration, repository skill, tool output, live repository path, or ambient home-directory context. A repository claim is still displayed only after the same local source-freshness, path, line, hash, fingerprint, claim, and exact-answer verification used for Codex.

This uses the Claude.ai subscription login stored by Claude Code, not an Anthropic API key or Console account. Anthropic-side handling, Agent SDK credits, usage limits, and any extra-usage terms follow that account and plan. ChirpCue does not claim server-side zero retention.

## Data excluded from repository snapshots

- `.env` files and variants
- private keys, credential stores, token files, and dumps
- Git internals, dependency caches, build output, ignored files, symlinks, hard links, sockets, devices, and other non-regular files
- files flagged by the local sensitive-file scanner unless you approve a specific soft false positive for that meeting at its exact content hash

Private-key blocks, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks are hard-denied by content and cannot be approved. Only ambiguous credential-assignment warnings can be approved. The default grounding limits are 2 MiB per file, 5,000 accepted files, 32 MiB of accepted content, 192 MiB of scanned content, 50,000 traversed entries, 8 MiB of Git output, 10 seconds per Git command, and 30 seconds per top-level grounding operation. Snapshot creation shares one budget across its build, copy, rebuild, and retry phases. Freshness checks and evidence verification are separate bounded operations with fresh budgets. Every displayed repository answer must pass local path, line, hash, scope, grounding-fingerprint, freshness, claim-to-excerpt, and answer-to-claim checks.

For a repository answer to be displayed, its candidate sentence must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation. The claim must contain at least two informative terms and copy one complete cited source line exactly, apart from a leading code-comment or list marker. ChirpCue rejects appended, combined, paraphrased, punctuation-changed, and negation-changed repository answer candidates. A `general_answer`, including one returned while a repository is attached, must instead carry a null grounding fingerprint, empty evidence basis, a qualified or proposal-style opening, and no explicit local codebase, organization, or production-state claim. The UI marks it **verify before speaking** because it remains model guidance, not verified implementation evidence.

## User control

- **Pause** stops both capture lanes and clears buffered raw audio. It does not claim success until the underlying capture handles are released.
- **Stop** clears transcript and suggestions immediately, then interrupts inference and begins verified cleanup. If an audio handle cannot be destroyed, ChirpCue keeps the red indicator on, retains the exact teardown state for retry, and disables every meeting action except Stop.
- **Sign Out and Forget Profile** asks Codex to sign out, removes ChirpCue's dedicated Codex profile and local identity binding, and recreates an empty private profile after explicit confirmation. Claude sign-in remains owned by Claude Code and is changed from its user-visible terminal login flow.
- **Use Current Claude Account** first validates the active first-party Claude subscription, then replaces ChirpCue's local identity binding only after explicit confirmation and a successful check. It clears provider-processing consent so the new account must be approved for the next meeting.
- ChirpCue never automatically speaks, pastes, posts, sends, joins a call, or changes repository files.

Do not use ChirpCue for confidential employer meetings unless the employer has approved this exact workflow. Do not use it in an interview, examination, or assessment that forbids assistance.
