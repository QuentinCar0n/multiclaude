# Contributing to MultiClaude

Thanks for helping. MultiClaude stays small on purpose: one Swift file, no dependencies, nothing that touches the network or Claude's data folders.

## Report a bug

Open an issue with:

- your macOS version and Mac (Apple silicon or Intel),
- the MultiClaude version (About in the panel),
- what you did, what you expected, what happened,
- the output of `~/Applications/MultiClaude.app/Contents/MacOS/MultiClaude --list` if a profile shows the wrong status. Remove any folder names you'd rather keep private.

## Suggest a feature

Open an issue that starts with the problem, not the solution. "I keep opening the wrong account" helps more than "add colors".

## Send a pull request

1. Fork and branch from `main`.
2. Build with `./build.sh` and check the panel by hand, in light and dark mode.
3. Match the style of `main.swift`: short names, few comments that say why, SwiftUI inside the existing AppKit panel.
4. Add a line under an `## Unreleased` heading in `CHANGELOG.md`.
5. Open the pull request with a screenshot for any visible change. `MULTICLAUDE_DEMO=1 MULTICLAUDE_PREVIEW=panel` opens the panel with sample profiles.

Contributions are licensed under the [Apache License 2.0](LICENSE), like the rest of the project.
