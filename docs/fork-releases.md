# Fork releases

`main` remains synchronized with the upstream repository. The fork's independent application and release workflow live on `master`, which is intended to be the fork's default branch. The fork's `codex/auto-doubao-shortcut` branch remains the source of upstream PR #3; do not add the fork release workflow to that PR branch.

The release workflow runs only in `PengJunchen/DoubaoVoiceBridge`. It accepts `v*` tag pushes and manual runs, then requires a valid `vX.Y.Z` tag to match `CFBundleShortVersionString` in `Resources/Info.plist`. The tagged commit must be reachable from `master`. The release job checks the tag still points to the built commit, and uses the repository-provided `GITHUB_TOKEN` with `contents: write` only in that job to create a GitHub Release. No personal token or additional secret is needed.

## Publish from a tag

After the intended version is committed to `master`, create and push a tag matching the app version:

```bash
git switch master
git tag -a v0.1.0 -m "DoubaoVoiceBridge v0.1.0"
git push origin v0.1.0
```

The workflow builds x86_64 and arm64 Release binaries, creates the universal `.app`, runs the build script's self-test, verifies the ad-hoc signature and both architectures, then uploads a ZIP and SHA-256 file to the GitHub Release. The release title and notes include the version, build number, and source commit. A mismatched or malformed tag fails before packaging.

The published build is an ad-hoc signed convenience build. It has no Apple Developer ID signature and is not notarized. The workflow uploads only the app ZIP and its checksum; it does not upload runner diagnostics, screenshots, user logs, or dictation text.

## Run a verification build

Once this workflow is present on the fork's default branch, open **Actions → Fork release → Run workflow**, select `master`, and leave `dry_run` enabled (the default). With no `release_tag`, this builds the selected `master` commit and stores the ZIP plus checksum as a short-lived Actions artifact without creating a Release. To verify an existing release source tag, supply it as `release_tag`; the workflow validates its format, version, and ancestry before building it. Set `dry_run` to false only when deliberately publishing an existing matching tag.

GitHub requires a `workflow_dispatch` workflow file to exist on the default branch before it can be triggered; the workflow also rejects manual runs whose selected ref is not `master`. See [GitHub's workflow dispatch documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_dispatch).

The workflow does not listen to `pull_request` events. Its repository guard prevents creating a release from the upstream repository or any other fork.
