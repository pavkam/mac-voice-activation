<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Packaging

YapOps is a SwiftPM executable assembled into a macOS application
bundle by `scripts/build-app.sh`. Use the bundle for resources, signing,
permissions, Keychain identity, Service Management, and normal menu-bar
lifecycle; `swift run` does not exercise those boundaries.

## Build the app bundle

```bash
make setup-signing  # Once per Mac
make app
```

The script builds the `YapOps` product, replaces the previous bundle,
copies the required metadata and resources, signs it, and verifies the result.
The output is:

```text
.build/YapOps.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/YapOps
    └── Resources/
        ├── YapOps.icns
        ├── AgentThinking.wav
        ├── CaptureStart.wav
        ├── CaptureEnd.wav
        ├── ToolStart.wav
        ├── ToolComplete.wav
        └── ToolFailed.wav
```

## Choose a configuration

`CONFIGURATION` is passed to `swift build -c` and defaults to `release`. Use a
debug executable when attaching a debugger or iterating on a bundled manual
flow:

```bash
CONFIGURATION=debug make app
```

Changing configuration replaces the same `.build/YapOps.app` output.

## Include required resources

`Package.swift` excludes the plist, icon, and sound files from SwiftPM resource
handling because the packaging script places them at their macOS bundle paths.
When adding or renaming a required resource, update all of these together:

- `Package.swift` exclusions;
- `scripts/build-app.sh` copy operations;
- `REUSE.toml` for non-commentable binary files; and
- the CI bundle assertions in `.github/workflows/swift.yml`.

The checked-in `Info.plist` owns the bundle identifier, version, menu-bar agent
mode, minimum macOS version, icon, and privacy usage descriptions.

## App identity after the rename

YapOps uses `dev.alex.yapops` as its bundle identifier and optional ElevenLabs
Keychain service. The rename creates a new app identity: earlier builds'
preferences, saved session handles, and narration credentials are not imported
automatically. Existing data and Keychain items remain untouched.

Configure profiles in YapOps Settings and save the optional ElevenLabs key
again. Grant macOS privacy permissions to the new app when prompted, and enable
Launch at Login from the installed YapOps copy if needed.

## Sign the bundle

`SIGN_IDENTITY` defaults to **YapOps Local Development**, a persistent local
identity in the user's Keychain. Provision it once:

```bash
make setup-signing
make app
```

Setup creates a ten-year self-signed certificate for code signing. Its private
key is imported as non-exportable, with `/usr/bin/codesign` authorized to use it.
Certificate trust is limited to code signing in the user domain; it does not
add TLS or system-wide trust. Temporary key material is owner-only and removed
on exit. macOS may request Keychain authorization during setup or first use.
No private key or certificate password is stored in the repository.

Repeating setup reuses the existing identity. It never silently replaces a
missing, expired, or broken key. Regular builds never generate keys and never
fall back to ad-hoc signing. The previous app remains intact if signing or
verification fails; only a verified staged bundle replaces it.

`.build/YapOps.app`'s own bundle directory is created once and reused across
every rebuild; only its `Contents/` is replaced, and only after the staged
copy is signed and verified. Earlier builds instead swapped the whole `.app`
directory in with `mv`, which gave it a new directory inode on every build —
macOS Accessibility (and other privacy) trust for a locally signed dev build
can fail to carry over across that change even with this same, unchanging
signing identity. If a privacy grant stops working despite the identity being
stable, see "Accessibility or another privacy grant stops working after a
rebuild" in [Troubleshooting](troubleshooting.md), and `make reset-permissions`.

This identity supports local development. It is not an Apple Developer ID or a
notarization credential. To use an existing Apple identity, override it:

```bash
SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" make app
```

Disposable builds can explicitly opt into ad-hoc signing:

```bash
SIGN_IDENTITY=- make app
```

Ad-hoc rebuilds change the code identity and can invalidate privacy grants.
Do not alternate signing identities for the app you use day to day. The
repository does not create an Xcode project, archive, or distribution installer.

## Verify the bundle

The packaging script always runs plist and signature verification. These are
the direct checks used when diagnosing a bundle:

```bash
test -x .build/YapOps.app/Contents/MacOS/YapOps
plutil -lint .build/YapOps.app/Contents/Info.plist
codesign --verify --deep --strict .build/YapOps.app
codesign --display --verbose=4 .build/YapOps.app
```

Also confirm the icon and all six sound files exist under `Contents/Resources`
when a resource changed.

## Install a stable development copy

Quit an existing YapOps process, replace the copy under
`/Applications`, and always launch that same path when testing permissions or
login registration:

```bash
ditto .build/YapOps.app /Applications/YapOps.app
open /Applications/YapOps.app
```

Keep the same signing identity and installation path across updates. Moving
from an older ad-hoc build to the persistent identity may require one final
permission approval. An old Accessibility entry can still appear enabled while
its stored code requirement rejects the new app; re-add the newly signed copy
and relaunch it. Do not reset unrelated privacy permissions.

## Enable Launch at Login

Launch at Login uses `SMAppService.mainApp`; macOS is the source of truth for its
registration and approval status. Run the installed `/Applications` copy before
enabling it in Settings. If approval is required, allow YapOps under
**System Settings > General > Login Items**, then retry the toggle.

Do not register the temporary bundle under `.build`. Unit tests inject a fake
service and never modify the real login-item database.

## Store the optional narration key

Automated local provisioning may pass exactly one ElevenLabs key through
standard input to the signed application executable. The process stores it in
Keychain under that bundle identity and exits before creating the menu-bar UI:

```bash
read -r -s narration_key
printf '%s\n' "$narration_key" | \
  /Applications/YapOps.app/Contents/MacOS/YapOps \
  --store-elevenlabs-key-from-stdin
unset narration_key
```

Never put the key in a command-line argument, environment variable, fixture,
preferences file, diagnostic record, or repository file. Interactive users can
save it through Settings instead.

## CI packaging

The `📦 Package app` job runs only after repository quality, build-and-test, and
Thread Sanitizer jobs succeed. It explicitly sets `SIGN_IDENTITY=-` for
`make app`, then verifies the executable,
icon, capture sounds, `Info.plist`, and code signature. CI's ad-hoc signature
proves bundle integrity, not distribution readiness or notarization.

## Related guides

- [Getting started](getting-started.md)
- [Development](development.md)
- [Testing](testing.md)
- [Configuration reference](configuration.md)
- [Troubleshooting](troubleshooting.md)
