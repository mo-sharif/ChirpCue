<p align="center">
  <img src="Packaging/AppIcon-1024.png" width="150" alt="ChirpCue app icon">
</p>

<h1 align="center">ChirpCue</h1>

<p align="center">
  A private, consent-first macOS meeting coach that listens locally and gives you a natural sentence to say next.
</p>

<p align="center">
  <a href="https://github.com/mo-sharif/ChirpCue/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/mo-sharif/ChirpCue/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="Apache 2.0" src="https://img.shields.io/badge/license-Apache%202.0-blue.svg"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-black.svg">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138.svg">
</p>

![ChirpCue showing a synthetic transcript and staff-engineer response](docs/images/chirpcue-meeting.jpeg)

<table>
  <tr>
    <td width="50%"><img src="docs/images/chirpcue-setup.jpeg" alt="ChirpCue meeting setup with Google Chrome output and Codex via ChatGPT selected"></td>
    <td width="50%"><img src="docs/images/chirpcue-privacy.jpeg" alt="ChirpCue privacy and control disclosure"></td>
  </tr>
  <tr>
    <td align="center">Explicit source and provider setup</td>
    <td align="center">Privacy boundaries before capture</td>
  </tr>
</table>

All screenshots use synthetic preview data and initiate no capture or provider request.

ChirpCue captures your microphone and selected Mac meeting output into separate local transcript lanes. Every detected question immediately creates its own answer thread with a short, question-aware sentence you can say while two independent lanes continue. Fifty-two common frontend, JavaScript, systems, database, security, and delivery questions receive a reviewed direct Quick answer immediately; matching uses complete words and phrases and rejects ambiguous everyday wording. A matching fact from **About you** can also become that first Quick answer while the subscription runtime is still preparing, and a matching later result is not repeated. Follow-up questions start in parallel without canceling or replacing earlier answers. For an uncovered question, a safe opener appears immediately. Codex meetings dispatch subscription Quick without waiting for Apple's on-device model: Spark is preferred when advertised, with Sol, Luna, and mini fallbacks. Quick requests the lowest advertised reasoning effort and the fastest advertised subscription tier. Other providers retain the bounded three-second Apple attempt. The overall generated Quick lane has 15 seconds, while Deep continues independently for up to 90 seconds. Provider startup, rate limits, or network latency can never leave a response thread empty. Punctuation-only revisions update the transcript without duplicating work; a meaningfully expanded final question creates a follow-up thread.

When microphone speech is clearly attributed to you, ChirpCue keeps the visible Quick sentence stable while you talk and adds validated Deep underneath as soon as it is ready. A pending replacement for the sentence you are currently reading still waits for the speech boundary; a Deep answer bound to that replacement follows it in order. Deep is displayed after validation, not as unchecked token fragments. You always speak for yourself. ChirpCue never speaks, pastes, sends, clicks, joins a meeting, records secretly, or changes code.

## What makes it different

- **Universal Mac audio:** works with Google Meet, Zoom, Teams, or another meeting app by capturing the selected app's output.
- **Three-stage help:** a reviewed concept answer or matching user-written fact is a completed Quick answer immediately; uncovered questions get a safe opener while an Apple on-device or Codex subscription Quick answer can replace it within 15 seconds; and Codex, Claude, or Gemini continues the higher-reasoning Deep answer independently for up to 90 seconds.
- **Automatic threaded follow-ups:** no coaching click is required. Each detected question stays visible as its own Quick-and-Deep thread while later questions run alongside it. The Retry Latest control is only a manual fallback for a missed boundary.
- **Quick-first scheduling:** reviewed answers avoid a model turn entirely. For uncovered Codex questions, subscription Quick uses a compact one-field, tool-free response on a prewarmed ephemeral thread and keeps a one-second provider-queue head start over Deep. Other providers give Apple a three-second improvement budget; one timeout opens a meeting-scoped circuit so later questions bypass that attempt. The experimental realtime endpoint remains disabled.
- **Failure-resilient turns:** request-scoped Quick or Deep failures are labeled precisely and clear when the next question starts. A temporary cleanup failure gets one automatic provider replacement and verified journal cleanup before coaching resumes; unresolved cleanup and provider-capacity failures remain visible and fail closed.
- **Quota-resilient listening:** a provider-capacity warning does not block meeting capture or transcription, and no model launch occurs until a bounded capacity recheck passes.
- **Natural speaking prompts:** Quick gives a broad, question-specific opening in at most 24 words. General Deep answers aim for 120–180 words with an explanation, concrete example, and useful tradeoff, up to 220 words. Simple questions can be shorter. Longer answers appear in short paragraphs for reading aloud. Verified repository quotations keep their separate extractive limits.
- **More reliable follow-ups:** conversational lead-ins such as “Okay, so…” and “My next question is…” trigger automatic coaching even without a question mark. A busy Deep lane waits up to 15 seconds for an earlier answer to finish; subscription quotas still apply. Safe, specific clarifying questions stay intact, and provider Quick failures remain visible alongside the existing cue.
- **Factual personal answers:** an optional local **About you and your examples** profile holds up to 8,000 characters of background and real project stories. Start with a short summary: subscription Quick receives the first 1,500 characters, while Deep receives a larger bounded profile. Deep prefers a matching supplied story when asked for an example and must label an invented scenario as hypothetical. A relevant, already-speakable user sentence can still become the first Quick answer locally. ChatGPT memories and this Codex chat are not imported.
- **More context for Deep:** Quick keeps the recent 45-second context window. Deep can use up to three minutes of the current conversation, capped at 32 segments; Codex receives at most 12,000 transcript characters and other providers use smaller payload bounds. This remains rolling, in-memory context, not persistent meeting memory.
- **Optional codebase grounding:** one exact read-only sealed snapshot, with local evidence verification before a repository claim is shown.
- **Subscription sign-in:** ChatGPT-authenticated Codex, a first-party personal Claude.ai Pro/Max login, or Gemini through Google sign-in in the official Antigravity CLI. No API keys.
- **Astra for detailed answers:** Codex Quick prefers Spark with the lightest supported effort, followed by Sol, Luna, and mini. Deep prefers GPT-6 Astra at medium effort for both general and repository-grounded questions. When the signed-in account does not advertise Astra Medium, ChirpCue falls back to Sol, then Terra. Subscription limits still apply.
- **Ephemeral by default:** bounded in-memory audio and transcript state, verified teardown, deletion, and residual auditing.

## Install on your Mac

The easiest supported path today builds ChirpCue locally. You need an Apple silicon Mac, macOS 26 or newer, and Xcode 26 with Swift 6.2 or newer.

```sh
git clone https://github.com/mo-sharif/ChirpCue.git
cd ChirpCue
./Scripts/build-and-install.sh
open /Applications/ChirpCue.app
```

The script builds a hardened-runtime app, verifies its bundle and privacy entitlements, and installs it into `/Applications` without overwriting an existing copy.

There is not yet a downloadable cross-Mac `.app`. Apple requires Developer ID signing and notarization for that distribution path, and ChirpCue will not ask users to bypass Gatekeeper. See [the installation guide](docs/INSTALL.md) for updates and replacement steps.

## Provider setup

Choose a provider in ChirpCue Settings:

- **Codex via ChatGPT:** ChirpCue opens a one-time sign-in for its dedicated local Codex profile. It accepts only the OpenAI-signed Codex executable bundled with ChatGPT or Codex.
- **Claude via Claude.ai:** install the official Claude Code launcher and run `claude auth login --claudeai`, then choose **Recheck**. ChirpCue accepts only first-party personal Pro or Max authentication. Console, API key, cloud, gateway, Team, Enterprise, and managed-policy paths fail closed.
- **Gemini via Google AI:** install the [official Antigravity CLI](https://antigravity.google/docs/cli/install), choose **Sign in with Google** in ChirpCue, complete the official terminal/browser flow, then choose **Recheck Accounts**. ChirpCue uses a scrubbed sign-in helper plus a fresh disposable inference home and never asks for a Gemini API key or Google Cloud credentials.

Claude programmatic use can follow separate Agent SDK allowance and extra-usage terms. ChirpCue does not promise that it uses the same allowance as interactive Claude Code. Local rolling limits prevent duplicate or excessive launches, but they cannot remove provider-enforced subscription quotas, restore remote capacity, or guarantee that provider-side usage is refunded after cancellation.

Codex Quick prefers Spark only when the signed-in account advertises it; otherwise it uses the supported fallback catalog. Spark has its own usage limits, and subscription Fast mode can consume credits faster. See the [official Codex speed documentation](https://learn.chatgpt.com/docs/agent-configuration/speed). ChirpCue does not bypass either allowance or promise instant model responses.

## First meeting

1. Read the in-app privacy disclosure.
2. Grant microphone, system-audio, and on-device speech permissions.
3. Select the meeting app output, such as Google Chrome for Google Meet.
4. Optionally add factual background under **Settings → Response → About you**. This is stored locally on the Mac and sent only with meeting inference so experience questions can use your real details.
5. Optionally inspect and seal one repository. Codex may use one reviewed read-only skill; Claude and Gemini remain tool-restricted and receive only bounded host-selected lines.
   ChirpCue shows the grounding ceilings during review, accepts files up to 8 MiB, and visibly excludes larger files instead of rejecting the whole repository.
6. Confirm that participants have been informed and that you have permission to process the conversation.
7. Start the meeting. ChirpCue automatically coaches likely questions; speak, edit, dismiss, retry, or ignore every suggestion yourself.

Use **Pause** to stop capture temporarily. Use **Dismiss** to clear the current answer while transcription continues. Use **Stop** at the end so ChirpCue can join provider work, scrub memory, delete temporary state, and verify cleanup. A validated Quick answer can appear while its private fork cleanup is still tracked. If that cleanup fails, ChirpCue makes one automatic replacement-and-reconciliation attempt; it resumes queued provider work only after cleanup is proven, otherwise it shows the failure and blocks further inference.

## Safety boundaries

ChirpCue is for permitted personal meeting assistance. Do not use it for covert recording, confidential work without approval, or an interview, exam, or assessment that forbids assistance.

Meeting text and repository content are untrusted data. They cannot change permissions, provider identity, tool policy, consent, or repository scope. Every grounded claim must pass local path, line, hash, freshness, and exact-claim checks.

Read the full [privacy contract](PRIVACY.md), [security policy](SECURITY.md), and [production-readiness ledger](PRODUCTION_READINESS.md).

## Contributing

Contributions are welcome, especially for accessibility, local audio reliability, natural response quality, deterministic cleanup, and privacy-preserving UX.

Start with [CONTRIBUTING.md](CONTRIBUTING.md) and the product boundaries in [AGENTS.md](AGENTS.md). Use synthetic meeting and repository data only.

```sh
./Scripts/check.sh
./Scripts/scan-secrets.sh
```

ChirpCue is licensed under the [Apache License 2.0](LICENSE). Community participation follows the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities through a [private security advisory](https://github.com/mo-sharif/ChirpCue/security/advisories/new), never a public issue.

## Current status

Version 0.3.13 fixes the Codex subscription stall that could leave response-template creation idle until ChirpCue timed out. Codex now starts with a clean child-process signal state, verified meeting startup no longer waits for transcript-free Quick and Deep templates, and a failed cold template can be cleaned up and retried without stopping capture. GPT-5.6 Sol is used at low effort for Quick and medium effort for narrow technical Deep answers when the installed subscription advertises those capabilities. The final repository-free subscription smoke returned Quick inside its eight-second provider lane and completed strict validation plus two-thread cleanup in 14.0 seconds end to end; Deep completed strict validation and cleanup in 17.1 seconds. A matching **About you** fact or one of 52 reviewed technical responses still appears immediately while generated answers warm in parallel. Natural staff-level responses are accepted without relying on a brittle opening-word list, while private-system claims, prompt leakage, fragments, and invented personal facts remain blocked. Every response thread remains ephemeral and deleted after use. This remains an early personal release candidate.

ChirpCue is an independent open-source project and is not affiliated with or endorsed by Apple, Anthropic, Google, Microsoft, OpenAI, or Zoom.
