# Releasing

Releases are driven entirely by two version fields. Bump one, merge to
`master`, and CI does the rest — after every test job is green.

| Bump this | Gets you |
|---|---|
| `app/pubspec.yaml` → `version:` | A GitHub release tagged `v<version>` with the APKs, the Windows and Linux desktop bundles, and the native libraries |
| `splitcore_sdk/pubspec.yaml` → `version:` | A `splitcore_sdk` publish to pub.dev |

Bump both to ship both. Bump neither and a push to `master` just runs the
tests: the `gate` job checks whether the tag and the pub.dev version already
exist and skips whatever is already out there, so re-running the workflow is
always safe.

Remember to add the new version to `splitcore_sdk/CHANGELOG.md` — pub.dev
shows that file on the package page, and a missing entry is a publish
warning.

## Release artifacts

- `slicepay-<version>-arm64-v8a.apk` — what nearly every real phone wants
- `slicepay-<version>-armeabi-v7a.apk` — older 32-bit devices
- `slicepay-<version>-x86_64.apk` — emulators
- `slicepay-<version>-windows-x64.zip` — the desktop app with `splitcore.dll` beside the `.exe`
- `slicepay-<version>-linux-x64.tar.gz` — the desktop bundle with `libsplitcore.so` in `lib/`
- `splitcore-native-v<version>.zip` — `libsplitcore` for every Android ABI, Linux and Windows, for anyone consuming `splitcore_sdk` from pub.dev

> The APKs are signed with the **debug** keystore (see the TODO in
> `app/android/app/build.gradle.kts`). They install fine by sideloading but
> cannot go to the Play Store, and a real signing key will change the
> package signature — so switch before you have users, not after.

## One-time setup

### 1. pub.dev account

pub.dev has no separate sign-up — you log in with a Google account, and the
account is created on first publish.

### 2. Publish `splitcore_sdk` 0.1.0 by hand

Automated publishing needs the package to already exist, so the first
version goes out from your machine:

```bash
cd splitcore_sdk
dart pub publish --dry-run   # fix anything it complains about
dart pub publish
```

It prints a URL, you authorize in the browser, and the package is yours.
**Package names are permanent and versions cannot be unpublished** (only
retracted, within 7 days), so read the dry-run file list before confirming.

### 3. Add the `PUB_CREDENTIALS` secret

Step 2 wrote a credentials file. Copy it into a repository secret named
`PUB_CREDENTIALS`:

```bash
gh secret set PUB_CREDENTIALS < ~/.config/dart/pub-credentials.json
```

On Windows that file is `%APPDATA%\dart\pub-credentials.json`; on macOS,
`~/Library/Application Support/dart/pub-credentials.json`.

It holds a long-lived OAuth refresh token for your pub.dev account — treat
it like a password. If it leaks, run `dart pub logout` and publish once more
to mint a new one, then reset the secret.

<details>
<summary>Why not pub.dev's OIDC automated publishing?</summary>

pub.dev's GitHub Actions integration only trusts workflow runs triggered by
a **tag push** matching a configured pattern. This pipeline triggers on
pushes to `master`, and a tag pushed by `GITHUB_TOKEN` deliberately does not
start another workflow run — so there is no tag-triggered run to publish
from without adding a personal access token to break the loop. The
credentials file is the supported alternative and costs one secret instead
of a second token plus a second workflow.

If you would rather have OIDC, switch the trigger to `push: tags: ['v*']`,
push tags by hand, and drop the `PUB_CREDENTIALS` step.
</details>

## Building locally

```bash
make apk    # per-ABI release APKs in app/build/app/outputs/flutter-apk/
```
