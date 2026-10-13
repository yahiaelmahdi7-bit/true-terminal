# True

A fast, native macOS terminal with tabs and splits, plus a Hub for running Claude Code agents side by side.

- **Terminal**: tabs, split panes, session restore, drag-and-drop of files and screenshots into a pane.
- **Hub**: see every agent and builder session at a glance, what each is doing, and which ones are waiting on you.
- **Overseer**: shows a verdict badge after each Claude turn (verified, unverified, and so on). It needs a judging service that this build does not include, so the badges stay empty until you wire one in (see `Sources/True/Agents/JevClient.swift`).
- **Command bar (⌘K)**: type a line and True routes it: open a project, jump to a seat, run a shell command, start an agent. Without a judging service it uses its plain prefix rules and defaults.
- **Remote access (optional, off by default)**: a phone view served over your own Tailscale network.

## Requirements

- macOS 15 or newer
- Apple Silicon or Intel
- To build from source: Xcode 26 or its Command Line Tools (the macOS 26 SDK)

## Install

Download `True-macOS.zip` from the [Releases](../../releases) page, unzip it, and move `True.app` to `/Applications`.

Builds are ad-hoc signed, not notarized, so macOS blocks the first launch. Open `True.app` once, then go to **System Settings → Privacy & Security** and click **Open Anyway**. Or run:

```sh
xattr -dr com.apple.quarantine /Applications/True.app
```

Each release also publishes `True-macOS.zip.sha256`.

## Build from source

```sh
git clone <this repository>
cd true-terminal
swift build -c release          # binary at .build/release/True
swift test                      # run the test suite
scripts/package.sh release      # assemble True.app (ad-hoc signed) in the current directory
```

To produce the universal (arm64 + x86_64) release zip:

```sh
TRUE_VERSION=1.2.3 scripts/make-release.sh   # writes dist/True-macOS.zip and dist/True-macOS.zip.sha256
```

If `swift test` cannot find the Testing framework with only the Command Line Tools installed, add the framework paths:

```sh
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test -Xswiftc -F$FW -Xlinker -F$FW -Xlinker -rpath -Xlinker $FW -Xlinker -rpath -Xlinker $LIB
```

## Releasing

Push a tag like `v1.2.3`. The `release` workflow builds the universal app, takes the version from the tag, and attaches the zip and its checksum to a GitHub Release.

## License

MIT. See [LICENSE](LICENSE).
