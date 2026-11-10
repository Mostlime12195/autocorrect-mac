# Keylime for Mac (preview)

Keylime and its models are a preview, released to show what they can do and to gather feedback and data.

Menu bar app that fixes typos as you type, in any app, with our small on-device language model (same decoder as the
Android keyboard). Nothing you type leaves the Mac, unless you turn on **Share correction data** in Settings (off by
default): then only scrubbed, word-level correction events are uploaded, as described in
[docs/upload-schema.md](docs/upload-schema.md). A second switch, **Include sentence context** (also off by default),
adds the scrubbed sentence around each correction to those events.

Apple Silicon only, macOS 13+.

## Install

1. Download `Keylime-mac-<version>.zip` from the
   [releases](https://github.com/Mostlime12195/keylime-models/releases?q=mac-v) and unzip it.
2. Move `Keylime.app` to Applications. (Coming from 0.1.x: quit and delete the old `Autocorrect.app`.)
3. First launch: the app is self-signed, not notarized, so macOS blocks a double-click. Either right-click the app →
   **Open** → **Open** (on macOS 15: try once, then System Settings → Privacy & Security → **Open Anyway**), or run
   `xattr -dr com.apple.quarantine /Applications/Keylime.app` and open it normally.
4. Grant **Accessibility** when asked (System Settings → Privacy & Security → Accessibility). Remove an old
   "Autocorrect" entry if there is one. The setup window closes by itself once it's on.
5. The model downloads on first run from Hugging Face (about 79 MB for m2, 42 MB for m1).

From 0.2.0 on, updates install themselves (menu → Check for Updates…, or the daily check) and keep the Accessibility
grant: every build is signed with the same certificate.

## Use

- **Suggest only** (default; a mode you picked earlier is kept): underlines likely typos, never changes the text.
- **Fix confident typos, underline the rest**: when you finish a word, a fix the model is sure about is
  applied in place (a short highlight shows it; click the word within a few seconds, or press backspace right away, to
  undo). Words it's unsure about get a dotted underline. After a 1 s pause the sentence is checked again with the words
  that came after it.
- Click an underlined word: up to 3 fixes, **Ignore**, **Add to Dictionary**.
- Optional: a preview bubble with the fix the current word is about to get (Space accepts, Esc cancels).
- **Style** (Settings → General, m2 only): Casual, Standard or Formal. Casual keeps "i" in lowercase. Formal adds
  capitals at the start of a sentence and commas while you type. It also adds full stops after a pause. Formal changes
  the text only in the "Fix confident typos" mode. A new style starts to work immediately.
- Settings can turn off macOS's own "Correct spelling automatically" so the two don't fight (open apps may need a
  restart).
- Menu: mode, pause in the current app, model (m2 106M int4 default, m1 34M lighter), personal dictionary and excluded
  apps, updates. Terminals, IDEs and password managers are excluded by default; password fields and secure input are
  always skipped.

How it works: the event tap only times things (word ends, pauses); the text is read and written through Accessibility
(the word is selected and replaced in one edit, caret put back, result verified). Where an app doesn't expose its text
that way, Keylime falls back to typing the fix as keystrokes, with no underlines.

## Build

```
scripts/fetch_ort.sh                     # onnxruntime 1.31.1 (osx-arm64) -> vendor/
scripts/fetch_models.sh models           # graphs for the parity tests
AC_MODEL_DIR=$PWD/models swift test -c release -Xswiftc -enable-testing
scripts/build_app.sh 0.2.0               # dist/Keylime.app + zip (SIGN_IDENTITY=<sha1> to sign; ad-hoc otherwise)
```

CI (macos-15) runs the tests, including decoder parity against the Python reference on both models, signs the app with
the "Keylime Self-Signed" certificate (secrets `MAC_SIGNING_P12` / `MAC_SIGNING_PASSWORD`), checks the designated
requirement is certificate-based, self-tests the bundle and attaches the zip to `mac-v*` tags.
`scripts/publish.sh <version>` mirrors a release to the public models repo and updates the updater's `mac-latest.json`.

## License

Code: MIT (see `LICENSE`). Model weights on Hugging Face ([keylime-m2-preview](https://huggingface.co/MostLime/keylime-m2-preview), [keylime-m1-preview](https://huggingface.co/MostLime/keylime-m1-preview)): CC BY 4.0.
