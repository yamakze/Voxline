# Release workflow

## Version and build identity

`Version.xcconfig` defines `MARKETING_VERSION` for both platform applications. Set it to the intended public version before creating a tag. Development build numbers remain monotonically increasing and device Bundle IDs remain fixed; they are independent of release tags.

Tags use `v<major>.<minor>.<patch>` and may include a prerelease suffix, for example `v0.1.0-rc.1`. The tag's base version must match the tagged `Version.xcconfig`. Existing development milestone tags are not evidence of a published installation package.

## Automated change notes

[Release changelog](../.github/workflows/changelog.yml) runs when a version tag is pushed, or manually for an existing tag containing this configuration. It fetches full Git history and uses pinned [git-cliff](https://git-cliff.org/docs/github-actions/git-cliff-action/) tooling and `cliff.toml`.

The workflow produces complete `CHANGELOG.md` and tag-specific `RELEASE_NOTES.md`, uploads both as workflow artifacts, and creates or updates a GitHub Release draft. The complete changelog is attached to the draft. It preserves already published release notes. Review generated notes for user-facing wording, breaking changes, and known limitations before publishing. Committed changelog snapshots are not maintained separately.

Local preview with git-cliff 2.14.2:

```sh
git-cliff --config cliff.toml --use-branch-tags --output tmp/CHANGELOG.md
git-cliff --config cliff.toml --unreleased --strip header --output tmp/RELEASE_NOTES.md
```

The [CI workflow](../.github/workflows/ci.yml) checks shared domain, protocol, persistence, queue, and editing-session tests, builds unsigned iOS code, and checks compiler-extracted localization. Native playback/export, actual model inference, system translation, and device UI acceptance require their corresponding local or device checks.

## Resources and source archive

Module language tables stay with their owning modules. iOS uses its asset catalog's link to the single `Resources/AppIcon.png`; Mac uses `Resources/AppIcon.icns`. Both application packages include the root MIT license and third-party notices. Model weights are downloaded separately. Engineering documents, private media, credentials, and logs are excluded from application packages.

`docs/` remains contributor documentation in Git. Current architecture, ADRs, development commands, product scope, and active dependency plans stay maintained. Completed audits and historical validation documents move to `docs/archive/` and retain their original baseline. Private evidence stays in ignored `tmp/`; archiving a document does not make a private sample redistributable.

## Distribution requirements

Public source availability and an installable application release are separate deliverables. Before the first installation package is published:

- Choose the public version and platform distribution channels. Mac builds currently use the host architecture; declare the supported architecture or prepare and test other architectures.
- For direct Mac distribution, use Developer ID Application signing, hardened runtime, secure timestamps, notarization, and ticket stapling. Current local scripts use development signing options and do not produce a notarized distribution. Follow [Apple's distribution guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
- Decide whether iOS uses TestFlight / App Store distribution or a clearly documented self-signing route. An unsigned IPA cannot be installed directly on a normal device.
- Verify privacy manifests and required-reason APIs, SDK notices, model licenses, and privacy disclosures for the selected channel. The [data handling document](privacy.md) describes current behavior; store submissions need their own matching declarations.
- Test a fresh installation and an upgrade with tasks, downloaded models, and credentials preserved. Record supported system and device coverage, including Liquid Glass and optional two-device iCloud sync.
- Prepare screenshots with synthetic or redistributable media. Explain subtitle-export and background-processing limitations in release notes.
- Package versioned files and checksums, review the draft notes and assets, then publish the Release.

Actual preparation and acceptance results are tracked by VXL-064 in the [GitHub Project](https://github.com/users/yamakze/projects/1).
