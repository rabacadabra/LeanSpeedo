# Contributing

## Build from source

Open the project in Xcode and run:

```bash
open LeanSpeedo.xcodeproj
```

Or build a distributable DMG from the command line:

```bash
brew install create-dmg
./scripts/build-dmg.sh      # -> build/LeanSpeedo.dmg
```

`build-dmg.sh` builds Release, ad-hoc signs the app, packages the DMG, and prints
its SHA-256.

### App icon

The icon is generated from vector art rather than checked-in source art:

```bash
swift scripts/make-icon.swift LeanSpeedo/Assets.xcassets/AppIcon.appiconset
```

Tweak the colors/geometry near the top of `drawIcon` in that script and re-run.

## Releasing (maintainers)

Releases are cut by pushing a `v*` tag. This requires push access to the repo —
[`.github/workflows/release.yml`](.github/workflows/release.yml) then builds the
DMG, versions it from the tag, and attaches it to a GitHub Release.

```bash
git tag v1.2.0
git push origin v1.2.0
```

### Homebrew cask

The cask lives in the separate `rabacadabra/homebrew-tap` repo. After a release:

- If the `TAP_TOKEN` secret is set on this repo, the workflow bumps the cask
  automatically.
- Otherwise, edit `Casks/leanspeedo.rb` in the tap: set `version` and paste the
  `sha256` printed at the end of the release workflow log.

## Notes

- The app is **not sandboxed** — it spawns `/usr/bin/script` and
  `/usr/bin/networkQuality` — so it can't ship on the Mac App Store, and the
  App Sandbox build setting must stay off.
- Deployment target is macOS 14. Keep API usage within that.
- Distribution is ad-hoc signed, not notarized (no paid Apple Developer account).
