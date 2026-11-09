# Autocorrect for Mac

Menu bar app that fixes typos as you type, in any app, with our small on-device language model (same decoder as the
Android keyboard). Nothing you type leaves the Mac.

Apple Silicon only, macOS 13+.

## Install

1. Download `Autocorrect-mac-<version>.zip` from the
   [releases](https://github.com/Mostlime12195/autocorrect-models/releases?q=mac-v) and unzip it.
2. Move `Autocorrect.app` to Applications.
3. First launch: the app is ad-hoc signed, not notarized, so macOS blocks a double-click. Either
   right-click the app → **Open** → **Open** (on macOS 15: try once, then System Settings → Privacy & Security →
   **Open Anyway**), or run `xattr -dr com.apple.quarantine /Applications/Autocorrect.app` and open it normally.
4. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility). The setup window closes by
   itself once it's on. After an update macOS may ask again: remove the old entry and re-add the app.
5. The model downloads on first run (about 79 MB for m2, 42 MB for m1).

Turn off macOS's own "Correct spelling automatically" (Keyboard → Text Input → Edit) so the two don't fight.

## Use

- Corrections happen when you finish a word (space, punctuation, return).
- Backspace right after a correction undoes it; the word is remembered as "not a typo".
- Menu: on/off, pause in the current app, model (m2 106M int4 default, m1 34M lighter), personal dictionary and
  excluded apps, check for updates. Terminals, IDEs and password managers are excluded by default; password fields and
  secure input are always skipped.

## Build

```
scripts/fetch_ort.sh                     # onnxruntime 1.31.1 (osx-arm64) -> vendor/
scripts/fetch_models.sh models           # graphs for the parity tests
AC_MODEL_DIR=$PWD/models swift test -c release -Xswiftc -enable-testing
scripts/build_app.sh 0.1.0               # dist/Autocorrect.app + zip
```

CI (macos-14) runs the tests, including decoder parity against the Python reference on both models, builds the app,
self-tests the bundle and attaches the zip to `mac-v*` tags. `scripts/publish.sh <version>` mirrors a release to the
public models repo and updates the updater's `mac-latest.json`.
