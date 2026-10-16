# Fork releases

`main` remains synchronized with the upstream repository. The fork's independent application and release workflow live on `master`, the fork's default branch. The fork's `codex/auto-doubao-shortcut` branch remains the source of upstream PR #3; the fork release workflow is kept off that PR branch.

The release workflow runs only in `PengJunchen/DoubaoVoiceBridge`. A tag push must use `vX.Y.Z` and match `CFBundleShortVersionString` in `Resources/Info.plist`; a manual dry run may build the current default branch without a tag, while a manual publish run must supply an existing matching tag. A tagged commit must be reachable from `master`. The release job checks the tag still points to the built commit, and uses the repository-provided `GITHUB_TOKEN` with `contents: write` only in that job to create a GitHub Release. No personal token or additional secret is needed.

## Publish from a tag

Each new version committed to `master` is released by pushing a new `vX.Y.Z` tag that matches the app version in `Resources/Info.plist`:

```bash
git switch master
release_tag="v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
git tag -a "$release_tag" -m "DoubaoVoiceBridge $release_tag"
git push origin "$release_tag"
```

The workflow builds x86_64 and arm64 Release binaries and creates three `.app` ZIPs: Apple Silicon/M-series (`arm64`), Intel (`x86_64`), and universal. Each ZIP has a companion SHA-256 file. The package script strictly checks the source app, thins the two single-architecture binaries, re-signs them ad-hoc with the existing bundle identifier requirement, then validates each app's architecture, signature, version, bundle identifier, and bundled LICENSE. `--self-test` runs on the runner's matching thin package; the other architecture receives structural and signature checks only. The release notes provide a chip-selection download table, version/build, and source commit. A mismatched or malformed tag fails before packaging.

The tag workflow packages the checked-out app using the release packager copied to the runner's temporary directory before switching to the selected tag. This also lets a manual dry run build an older source tag that predates `scripts/package-release.sh`.

The published builds are ad-hoc signed convenience packages. They have no Apple Developer ID signature and are not notarized. The workflow uploads only the three app ZIPs and their checksums; it does not upload runner diagnostics, screenshots, user logs, or dictation text.

## Run a verification build

Once this workflow is present on the fork's default `master` branch, open **Actions → Fork release → Run workflow**, select `master`, and leave `dry_run` enabled (the default). With no `release_tag`, this builds the selected `master` commit and stores all six ZIP/checksum files as a short-lived Actions artifact without creating a Release. To verify an existing release source tag, supply it as `release_tag`; the workflow validates its format, version, and ancestry before building it. Set `dry_run` to false only when deliberately publishing an existing matching tag.

GitHub requires a `workflow_dispatch` workflow file to exist on the default branch before it can be triggered; the workflow also rejects manual runs whose selected ref is not `master`. See [GitHub's workflow dispatch documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).

The workflow does not listen to `pull_request` events. Its repository guard prevents creating a release from the upstream repository or any other fork.
