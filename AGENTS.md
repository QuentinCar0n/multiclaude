# AGENTS.md

Notes for coding agents working in this repository. Human contributors: see [CONTRIBUTING.md](CONTRIBUTING.md), which this file follows.

## What this is

MultiClaude is a macOS menu bar app (Swift) that runs several Claude desktop accounts side by side, plus a command line tool, `multiclaude` (Go). It is unofficial and not affiliated with Anthropic.

## Layout

| Path | What it holds |
| --- | --- |
| `main.swift` | The whole app: SwiftUI views inside an AppKit menu bar panel, profiles, sign-in relay, updater, usage, keep-awake, and the `--selftest-*` checks |
| `Groups.swift` | Account groups and their Claude Code folders |
| `cli/` | The `multiclaude` command (Go module `github.com/QuentinCar0n/multiclaude/cli`) and its tests |
| `build.sh` | Builds the universal app and CLI; sets `VERSION` and `BUILD` |
| `assets/AppIcon.png` | App icon source |
| `.github/workflows/release.yml` | Tag-driven release: test, build, sign, publish, bump the Homebrew cask |
| `docs/index.html` | The GitHub Pages site |
| `docs/guides/` | One-question guides linked from the README |
| `preview/`, `docs/img/` | Screenshots for the README and the site |
| `specs/` | Design notes |

## Build and test

```bash
./build.sh              # build, install to ~/Applications and launch
./build.sh --no-install # stop after build/MultiClaude-<version>.zip
cd cli && gofmt -l . && go vet ./... && go test ./...
```

Needs Xcode command line tools with Swift 6 and Go 1.26. CI also runs the app's self-tests on the built bundle:

```bash
build/MultiClaude.app/Contents/MacOS/MultiClaude --selftest-update
# also: --selftest-version --selftest-profiles --selftest-signin --selftest-launchers
#       --selftest-awake --selftest-usage --selftest-groups
```

Screenshots come from demo mode: `MULTICLAUDE_DEMO=1 MULTICLAUDE_PREVIEW=panel MULTICLAUDE_APPEARANCE=dark`.

## Conventions

- Keep it small: two Swift files, no Swift dependencies. The CLI depends on `golang.org/x/sys` only.
- Match the style of `main.swift`: short names, few comments that say why.
- The app and the CLI share one profile list and the same folder rules (for example `Profile.codeConfigDir` in Swift and `CodeConfigDir` in `cli/profiles.go`, group slugs in `Groups.swift` and `cli/profiles.go`). Change both sides together, with tests on both.
- Add a line under an `## Unreleased` heading in `CHANGELOG.md` for user-visible changes.
- Check visible changes in light and dark mode.

## Do not touch

- `updatePublicKey` in `main.swift` and the signing steps in `release.yml`: installed copies only accept updates signed with the matching private key.
- Claude.app itself: MultiClaude never modifies it, and profile copies keep Anthropic's signed contents.
- The `VERSION`/`BUILD` defaults in `build.sh` without a matching `CHANGELOG.md` entry.
- The design of `docs/index.html`.
