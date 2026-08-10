# Release ChirpCue

ChirpCue has two different release paths. Keep them separate.

## Personal same-Mac build

```sh
./Scripts/lint.sh
swift test
swift build -c release
./Scripts/package-app.sh
./Scripts/verify-app.sh
```

This produces an ad hoc signed `dist/ChirpCue.app` for the Mac that built it. It is not a distributable public binary.

## Public signed release

Before publishing a cross-Mac build:

1. Complete every required checkbox in `PRODUCTION_READINESS.md`.
2. Configure the GitHub `production` environment with required maintainer review and deployment restricted to protected release tags.
3. Add the Developer ID and notarization secrets referenced by `.github/workflows/release.yml`.
4. Run CI and the full-history secret scan on the exact `main` commit.
5. Update `VERSION`, merge it to protected `main`, and record the exact 40-character commit SHA.
6. Create the matching immutable tag on that exact commit.
7. Manually dispatch **Signed release** with the tag and the exact approved `main` SHA.
8. Verify the published ZIP, checksum, provenance attestation, Developer ID team, notarization ticket, stapler result, and Gatekeeper result on a second Mac.

The workflow refuses a tag whose peeled commit differs from the supplied approved SHA or current `origin/main`. Tests run before signing or notarization credentials are materialized.

Never publish an ad hoc app, ask users to remove quarantine, or disable Gatekeeper.
