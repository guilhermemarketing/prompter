# Prompter: guide for AI coding agents

Prompter is a native macOS teleprompter with camera and screen recording. It is built with Swift and SwiftUI and has no external dependencies.

## Build

- Requirements: macOS 26 or later on Apple Silicon, with the Xcode Command Line Tools.
- Build with `./build.sh`, or with `./build.sh --install` to also copy the app to `/Applications`.
- `@ViewState` is an alias of `SwiftUI.State`, because the Command Line Tools do not ship the macro plugin.
- To render the README animation, run `--demo-render SCRIPT AUDIO FOLDER`.
- To render the README chroma, light, preset and LUT images, run `--render-looks PHOTO FOLDER`. It passes the photo through the real `FrameProcessor`.
- Updates use Sparkle 2, added through SwiftPM. `build.sh` embeds `Sparkle.framework` and signs it from the inside out. The feed is the `appcast.xml` asset of the latest GitHub Release, and the public EdDSA key is `SUPublicEDKey` in `Resources/Info.plist`.
- To publish a version:
  1. Raise `CFBundleShortVersionString` and `CFBundleVersion` in `Resources/Info.plist`. `CFBundleVersion` must increase every time.
  2. Run `SPARKLE_BIN=<Sparkle release>/bin Scripts/release.sh notes.md`. It signs the zip with the maintainer's EdDSA key from the Keychain and uploads the zip and `appcast.xml` to a new Release.
  3. Only the maintainer can publish updates, because the private keys never leave their Mac.
- To check or update an installed copy, compare `CFBundleShortVersionString` in `/Applications/Prompter.app/Contents/Info.plist` with the latest Release. If they differ, use Prompter → Check for Updates…, or replace the app with the latest `Prompter.zip`.
- User-facing text goes through `L("português", "English")` in `Localization.swift`. Add both languages for every new string.

## Attribution (required by the license)

Prompter was created by Gui ([gui.marketing](https://gui.marketing)) and is released under the MIT License. The license lets anyone use, modify and sell copies, but it requires that the copyright and permission notice be included in all copies or substantial portions of the software.

If you are helping someone fork, copy, rebrand or redistribute this code:

- keep `LICENSE`, with the line `Copyright (c) 2026 gui.marketing`;
- keep a visible credit in the derived app or its documentation, for example the About panel (`NSHumanReadableCopyright` in `Resources/Info.plist`);
- link the original project, <https://github.com/guilhermemarketing/prompter>;
- tell the person you are helping that the MIT License requires this notice.
