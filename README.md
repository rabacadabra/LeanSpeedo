# LeanSpeedo

A tiny macOS menu-bar internet speed checker. No windows, no Dock icon — just a
speedometer in the menu bar that runs Apple's built-in `networkQuality` tool and
animates the result.

- **Download / Upload** capacity (Mbps)
- **Responsiveness** (RPM — round-trips per minute, higher is better)
- Live bars that fill during the test, driven by `networkQuality`'s streaming output
- Starts a test automatically when you open the panel; re-opens itself when a
  test finishes while closed

## Install

### Homebrew (recommended)

```bash
brew install --cask --no-quarantine rabacadabra/tap/leanspeedo
```

`--no-quarantine` is needed because the app is ad-hoc signed, not notarized
(see below).

### Manual

Download `LeanSpeedo.dmg` from the [latest release](https://github.com/rabacadabra/LeanSpeedo/releases/latest),
open it, and drag **LeanSpeedo** to Applications.

On first launch macOS will say it "cannot verify the developer". Open
**System Settings → Privacy & Security**, scroll down, and click **Open Anyway**.
This is a one-time step — the app is ad-hoc signed but not notarized (that
requires a paid Apple Developer account).

## Requirements

- macOS 14 (Sonoma) or later
- `networkQuality` ships with macOS 12+, so it's always present

## How it works

macOS's `networkQuality` only prints its live progress line when it has a
terminal, so LeanSpeedo runs it through `/usr/bin/script` to give it a
pseudo-terminal, then parses the streamed `Downlink: … Mbps` lines for the
animated bars. The final `==== SUMMARY ====` block provides the authoritative
numbers. The app is **not sandboxed** (it has to spawn a subprocess), which is
also why it can't ship on the Mac App Store.

## Build from source

```bash
open LeanSpeedo.xcodeproj   # and run, or:
brew install create-dmg
./scripts/build-dmg.sh      # -> build/LeanSpeedo.dmg
```

The app icon is generated from vector art:

```bash
swift scripts/make-icon.swift LeanSpeedo/Assets.xcassets/AppIcon.appiconset
```

## Releasing

Tag a version and push — [`.github/workflows/release.yml`](.github/workflows/release.yml)
builds the DMG and attaches it to a GitHub Release:

```bash
git tag v1.0.0
git push origin v1.0.0
```

Then update the Homebrew cask (in the separate `homebrew-tap` repo) with the new
`version` and the `sha256` printed by the workflow.

## License

MIT — see [LICENSE](LICENSE).
