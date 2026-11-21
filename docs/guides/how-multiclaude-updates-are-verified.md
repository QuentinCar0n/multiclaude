# How MultiClaude updates are verified (Ed25519 signatures)

Every MultiClaude release zip is signed with an Ed25519 private key that is kept outside the repository, and the app only installs an update whose signature matches the public key built into it. It also checks the downloaded app's bundle identifier, its version and its code signature before swapping itself. HTTPS alone would trust whoever controls the GitHub repository; the signature check adds a key that never leaves the release environment.

## The update check

1. Once a day (and at launch), MultiClaude asks `https://api.github.com/repos/QuentinCar0n/multiclaude/releases/latest` for the latest release.
2. It looks for the `.zip` asset and its `.zip.sig` companion. Download URLs must be `https://github.com/QuentinCar0n/multiclaude/releases/download/...`; anything else is ignored.
3. Pre-release tags (with a suffix such as `-rc1`) are never offered as updates over a release.

## What is checked before install

| Check | Detail |
| --- | --- |
| Size | the zip must be under 64 MB |
| Signature | Ed25519 (`Curve25519.Signing` in CryptoKit) over the zip's exact bytes, against the public key compiled into `main.swift` |
| Same bytes | the zip that is unpacked is the very bytes whose signature was checked |
| Bundle | `CFBundleIdentifier` must be `me.somalabs.multiclaude` |
| Version | `CFBundleShortVersionString` must equal the release version |
| Code signature | `codesign --verify --deep --strict` must pass |

Only then is the running bundle replaced. The restart waits until the panel is closed and no sign-in is in progress. Claude windows stay open.

## How releases are signed

Pushing a `v*` tag runs [the release workflow](../../.github/workflows/release.yml):

- The build job builds a universal app, runs `gofmt`, `go vet` and `go test` on the CLI, and the app's built-in self-tests (`--selftest-update`, `--selftest-signin` and others). It never sees the signing key.
- The release job runs in a `release` environment that only `v*` tags can use. It signs the zip with `MultiClaude --sign-update`, checks it with `--verify-update`, and publishes `MultiClaude-<version>.zip` and `MultiClaude-<version>.zip.sig`.
- Actions are pinned to commits, so an upstream change can't reach the key.

## Check a release yourself

With MultiClaude installed:

```bash
/Applications/MultiClaude.app/Contents/MacOS/MultiClaude --verify-update MultiClaude-1.11.zip MultiClaude-1.11.zip.sig
```

It prints `valid` and exits 0, or prints `INVALID` and exits 1.

## Control updates

**Update MultiClaude** in Settings has three modes: Automatically (default), Ask First (a window with the release notes and Install, Later or Skip This Version) and Off. **Check for Updates…** in the panel and `multiclaude update` check right away in any mode; `multiclaude update --check` only looks.

## Note on notarization

MultiClaude is not notarized by Apple yet, so the first manual launch needs right-click, **Open**. Later updates go through the checks above.

## Related

- [Install MultiClaude with Homebrew](install-multiclaude-with-homebrew.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
