# PaceNote security policy

PaceNote is a private personal project. Report a suspected vulnerability through a private GitHub issue or GitHub security advisory in `mo-sharif/PaceNote`. Do not include meeting transcripts, credentials, repository excerpts, auth links, or other sensitive material in a report.

## Security invariants

- ChatGPT-authenticated Codex app-server is the only inference path. PaceNote does not request, store, or fall back to an OpenAI API key.
- PaceNote accepts only `/Applications/ChatGPT.app/Contents/Resources/codex` or `/Applications/Codex.app/Contents/Resources/codex`, rejects symlinks and alternate locations, and checks OpenAI Team ID `2DC432GLL2` plus signing identifier `codex` before use. Version and schema probes have fixed time, output, file-type, and file-size limits and terminate and reap failed subprocesses.
- Codex runs from a dedicated PaceNote profile with Keychain credential storage, history persistence set to `none`, analytics and memories disabled, and no ambient apps, MCP services, browser, hooks, or computer-use tools.
- PaceNote never reads or copies Codex tokens. A plaintext `auth.json` or other credential file in the dedicated profile is treated as a hard failure.
- Model tools receive a verified read-only, network-disabled permission profile rooted at a sealed repository and skill snapshot. The app-server itself retains outbound access to OpenAI for inference.
- The model never receives ambient access to the live working tree, user home directory, credentials, temporary directories, or write paths.
- Meeting transcript is untrusted data. It cannot change approval policy, permissions, skill selection, or tool policy.
- Every eligible production turn immediately uses the same fixed local bridge and starts automatic Deep. The production coordinator starts no model Quick or model reconciliation turn, and no classifier or model-controlled `needsDeep` value can alter that path.
- Deep answers are displayed only after local path, line, hash, scope, grounding-fingerprint, and freshness checks. The answer candidate must exactly match one verified basis claim after case and whitespace normalization while preserving punctuation. That claim must copy one complete cited source line, apart from a leading comment or list marker; appended, combined, paraphrased, punctuation-changed, or negation-changed candidates fail closed.
- Grounding defaults to 2 MiB per file, 5,000 accepted files, 32 MiB accepted content, 192 MiB scanned content, 50,000 traversed entries, 8 MiB Git output, 10 seconds per Git command, and 30 seconds per top-level grounding operation. Snapshot creation shares one budget across its build, copy, rebuild, and retry phases. Freshness checks and evidence verification are separate bounded operations with fresh budgets. Private keys, major provider tokens, bearer tokens, JWTs, and Slack or Discord webhooks are hard exclusions with no approval path; only ambiguous assignment warnings can be approved at an exact content hash.
- Unexpected approval, tool, skill, permission-profile, protocol, or external-service requests fail closed.
- PaceNote never automatically speaks, pastes, sends, joins a call, or mutates a repository.
- Logs and operational metrics must not contain transcript text, repository excerpts, auth URLs, email addresses, tokens, or absolute home-directory paths.

## Session isolation and cleanup

Each meeting gets a private temporary root and a content-free cleanup-journal entry. Transcript-bearing production Deep requests use ephemeral forks. The production coordinator starts no model Quick or reconciliation turn. Transcript-free bases used for grounded Deep context and lower-level compatibility plumbing are registered for deletion.

Stop performs bounded turn interruption and app-server shutdown, removes registered threads and meeting artifacts, sanitizes allowlisted transient state from the stable PaceNote Codex profile, restores the canonical restrictive configuration, deletes the complete meeting root, and scans app-owned meeting and profile paths for seeded transcript and repository canaries. The journal entry is removed only after that sequence succeeds.

If PaceNote crashes or cleanup is incomplete, startup recovery repeats thread lookup, deletion, profile sanitization, meeting-root removal, and residual auditing before capture is permitted. Cleanup failure is a visible blocking state, not a warning that can be bypassed.

## Trust boundaries

- Apple Core Audio, AVFoundation, and Speech perform local capture and transcription.
- OpenAI processes the transcript slices and selected repository excerpts sent through the user's ChatGPT Codex account. PaceNote does not claim server-side zero retention.
- macOS Keychain and the Codex app-server own authentication material and refresh behavior.
- The user owns participant disclosure, legal consent, employer approval, and the decision to speak a suggestion.

## Supported distribution

The current personal build is locally ad hoc signed and is intended only for the Mac that built it. Distribution beyond that Mac is unsupported until Developer ID signing, Apple notarization, stapling, Gatekeeper verification, a fresh Codex integration review, and the remaining production-readiness gates all pass.
