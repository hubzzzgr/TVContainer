# TVContainer

Standalone LiveContainer port for Apple TV (tvOS 17 or later, arm64).

The tvOS build uses a separate SwiftUI interface and the upstream in-process
hosting runtime. It does not build or package SideStore, the iPhone interface,
ShareExtension, LaunchAppExtension, or LiveProcess. The original iOS project is
retained as upstream source; build the **TVContainer** scheme in the generated
**TVContainer.xcodeproj**.

## Build

On a Mac with Xcode and XcodeGen:

```sh
brew install xcodegen
git submodule update --init --recursive
bash scripts/generate_project.sh
xcodebuild archive -project TVContainer.xcodeproj -scheme TVContainer \
  -sdk appletvos -destination 'generic/platform=tvOS' \
  -configuration Release -archivePath build/TVContainer.xcarchive \
  CODE_SIGNING_ALLOWED=NO
bash .github/build_github.sh
```

GitHub Actions runs archive extraction tests and builds only the standalone
`TVContainer.ipa`. The artifact is unsigned. Sign it with an Apple TV development
provisioning profile for your device, preserving `get-task-allow` and the supplied
keychain groups. The host and imported P12 signing identity must use the same
developer team. A successful build does not establish device compatibility of
private dyld hooks or the system relaunch API; test on a provisioned Apple TV.

The supplied TVContainer artwork is kept in `TVContainer/Artwork/TVContainerIcon.jpg`.
The project generator exports its layered Apple TV icon and Top Shelf renditions.
App and certificate downloads display progress in B, KB, MB, GB, or larger units
with fixed-width tabular counters. Known-length downloads keep the unit selected
from the total size; servers without a content length show an indeterminate bar.
The small QR button beside Search apps opens a two-column popup with
scannable GitHub QR codes. Press Back on the remote to dismiss it.

## Use

Settings also offers an optional **SideTVStore TCP Server** with a persisted
toggle, live listener status, device name and port. Pairing uses mutual TLS with
Apple TV approval and certificate fingerprints, followed by separate confirmation
for each incoming IPA or P12. Existing signing certificates cannot be replaced
through TCP. See [the shared sender/receiver contract](../docs/SIDETVSTORE-RECEIVER.md)
for the SideTVStore handshake and exact wire framing.

1. Open Settings and enter a direct P12 certificate download URL and its password.
   The identity is validated and saved in the device Keychain.
2. Open Install from URL and enter a direct download link to a decrypted tvOS IPA.
   ZIP downloads containing one IPA are also supported, including `.ipa.zip`.
3. Select an app card, then Launch, or press Play/Pause in the details screen.
4. Inside a guest, hold Play/Pause for two seconds to request a return to the library.

Normal Back and Select presses stay with the guest's native tvOS focus engine.
The launcher provides explicit focusable controls for every action, including
app deletion, download cancellation, and certificate removal. Deep links of the
form `tvcontainer://install?url=<percent-encoded-download-url>` prefill the URL
form without installing automatically.

## Hosting and limitations

The installer verifies arm64 tvOS platform commands and rejects encrypted,
simulator and iOS binaries. Universal device executables and embedded libraries are thinned to their arm64 slice before patching and signing. It patches the executable to a dylib with
`LCPatchExecSlice`, signs the staged app with ZSign, and publishes it only after
signing succeeds. On relaunch, `LCBootstrap` redirects the main bundle, executable
path, preferences, home directory, app groups, and keychain access before entering
the guest's `LC_MAIN` entry point. No iPhone rotation, file picker, multitasking,
or WebKit cookie workaround is injected into tvOS guests.

On tvOS, main-bundle access uses an Objective-C method hook and CoreFoundation
import rebinding for existing and newly loaded libraries. The private CF cache
is updated only when its symbol resolves to the original bundle. This avoids
depending on the iOS TBZ/TBNZ instruction patterns, which differ on tvOS 27.2.
Guest artwork is read from its own bundle, including layered assets and catalogs.

This does **not** emulate iOS frameworks. An iPhone IPA must be rebuilt or ported
for tvOS by its author. Bundled dylibs in Tweaks or Dylibs and filtered dylibs in Frameworks are loaded before the guest entry point; failures report the library name and loader error. Existing injected load commands are retained. Guest extensions and arbitrary external tweaks are not
supported in the initial standalone tvOS target.

The iOS LiveProcess mmap workaround and chained-fixup exception workaround use
Mach APIs unavailable on tvOS and are excluded. Apps needing that chained-fixup
workaround are rejected with an explanation. The launcher checks both known
system relaunch selectors and leaves the selected guest queued for a manual
close/reopen if the system does not permit automatic relaunch.

tvOS permits purgeable local cache storage. Apps and containers live under
`Library/Caches/TVContainer/Documents`; they can be removed by tvOS when storage
is low. The signing identity remains in Keychain. Keep original IPAs and external
backups of important guest data.

Device validation checklist: import a valid/wrong-password P12, install a small
decrypted tvOS test app, navigate every control with the remote, launch the guest,
write and reload guest preferences, return with long Play/Pause, reject an iOS
IPA, cancel a download, and remove a guest and its data.
