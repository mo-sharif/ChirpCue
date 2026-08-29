# Install ChirpCue

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Xcode 26 with Swift 6.2 or newer
- Git
- One supported provider: ChatGPT with Codex access; a personal Claude.ai Pro/Max subscription with official Claude Code; or Google sign-in through the official Antigravity CLI

## One-command source install

```sh
git clone https://github.com/mo-sharif/ChirpCue.git
cd ChirpCue
./Scripts/build-and-install.sh
open /Applications/ChirpCue.app
```

`build-and-install.sh` builds the release configuration, packages the native app, applies an ad hoc hardened-runtime signature, verifies the exact bundle and entitlements, stages the copy under `/Applications`, and refuses to replace an existing app.

The resulting app is supported only on the Mac that built it. Do not copy it to another Mac and do not remove quarantine attributes or disable Gatekeeper.

## Update an existing installation

1. Stop any active meeting and quit ChirpCue.
2. Move the existing ChirpCue app from Applications to Trash using Finder.
3. Pull the reviewed revision and run the installer again:

```sh
git pull --ff-only
./Scripts/build-and-install.sh
```

The installer deliberately does not overwrite an app because a destination race or mistaken path should fail safely.

## Future signed download

A downloadable ZIP will be added only after the project has a Developer ID Application certificate and Apple notarization credentials. The release workflow will then publish a signed, notarized, stapled, Gatekeeper-accepted archive, checksum, and GitHub provenance attestation from an approved `main` commit.

Until those gates pass, GitHub source archives are downloads of the source code, not ready-to-run Mac applications.

## Common setup issues

- **Codex sign-in cannot save credentials:** use the latest revision. ChirpCue isolates `CODEX_HOME` while preserving the real macOS `HOME` so Security.framework can resolve the default Keychain.
- **Claude signed out:** run `claude auth login --claudeai`, confirm the personal subscription, then choose **Recheck**.
- **Gemini signed out:** choose **Sign in with Google** in ChirpCue, complete the official Antigravity terminal and browser flow, then choose **Recheck Accounts**.
- **No meeting output:** open the meeting first, route its audio through this Mac, choose **Reload Sources**, and select the meeting app or the explicit all-system-output fallback.
- **No transcript:** grant Microphone, System Audio Recording, and Speech Recognition permission in System Settings, then quit and reopen ChirpCue.
- **Quick stays on the instant opener:** Apple's generated on-device Quick answer requires Apple Intelligence to be enabled and ready on the Mac. With Codex selected, ChirpCue also routes the fallback Quick turn to GPT-5.6 Sol at low effort and automatically requests the subscription Fast tier when the signed-in catalog advertises it. If no generated answer finishes within 15 seconds, the opener stays visible while Deep continues for up to 90 seconds.
- **A follow-up question arrives before the first answer finishes:** no action is required. ChirpCue keeps the first answer visible and starts a second question thread automatically so both can finish independently.
- **Deep is rate-limited:** wait for the rolling local limit and choose **Retry Answer**. This does not necessarily mean the provider subscription is exhausted.
