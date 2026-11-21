# How to install MultiClaude with Homebrew

Run `brew install --cask quentincar0n/tap/multiclaude`. The cask installs MultiClaude.app and puts the `multiclaude` command on your `PATH`. MultiClaude needs macOS 15 or later (Apple silicon or Intel) and the Claude desktop app in `/Applications`.

## Install

```bash
brew install --cask quentincar0n/tap/multiclaude
```

The cask lives in [QuentinCar0n/homebrew-tap](https://github.com/QuentinCar0n/homebrew-tap). Each release bumps its version and SHA-256 automatically.

Then click the ✳ icon in the menu bar, or run:

```console
$ multiclaude list
```

## Manual install

1. Download `MultiClaude-<version>.zip` from [Releases](https://github.com/QuentinCar0n/multiclaude/releases/latest) and unzip it.
2. Move `MultiClaude.app` to Applications.
3. MultiClaude is not notarized by Apple yet, so macOS blocks the first launch. Right-click the app and choose **Open**, or run:

   ```bash
   xattr -dr com.apple.quarantine /Applications/MultiClaude.app
   ```

4. Optional, for the command line tool:

   ```bash
   ln -s /Applications/MultiClaude.app/Contents/Helpers/multiclaude /usr/local/bin/multiclaude
   ```

## Updating

MultiClaude updates itself once a day by default, and each download is signature-checked (see [How MultiClaude updates are verified](how-multiclaude-updates-are-verified.md)). You can also run `multiclaude update`, choose **Check for Updates…** in the panel, or use `brew upgrade`. Pre-releases (tags like `v1.7-rc1`) are ignored by the cask and the updater.

## Build from source

```bash
git clone https://github.com/QuentinCar0n/multiclaude.git
cd multiclaude
./build.sh              # builds, installs to ~/Applications and launches
./build.sh --no-install # stops after build/MultiClaude-<version>.zip
```

Needs Xcode command line tools with Swift 6 and Go 1.26.

## Related

- [How to use two Claude accounts at the same time on a Mac](use-two-claude-accounts-at-the-same-time-on-mac.md)
- [multiclaude command line reference](multiclaude-cli-reference.md)
- [README](../../README.md)
