<!--
SPDX-FileCopyrightText: 2026 Alexandru Ciobanu (alex+git@ciobanu.org)
SPDX-License-Identifier: MIT
-->

# Resetting environment state

A reset destroys the evidence that would have identified the bug. Prove the
state is genuinely stale before clearing it, and prefer the narrowest reset that
can explain the symptom.

## Decide what is actually stale

| Symptom | Prove it first | Then reset |
| --- | --- | --- |
| Fix appears to do nothing | Running PID, executable path, configuration, fresh `session_id` | Build output; the old bundle was answering |
| Stale symbols, resources, or plist in the bundle | `codesign -d --verbose=4`, `plutil -lint`, resource listing | Build output |
| Signing fails or the identity is missing | `security find-identity -v -p codesigning` | Signing identity |
| Privacy grant on in System Settings, denied in-app | The app's own authorization API result | Privacy grants, by the user |
| Wrong profile, hotkey, locale, or terminal phrase | The persisted preference value | Preferences |
| Login item or permission behaves unlike the installed copy | Bundle path under test | Installed copy |

## Build output

Safe to run without asking. Nothing here touches user state.

```bash
rm -rf .build/YapOps.app
CONFIGURATION=debug make app
```

`swift package clean` or removing `.build` entirely is a slow last resort; use
it only when SwiftPM itself is inconsistent, not to chase a runtime bug.

Deleting `.build/YapOps.app` gives the bundle directory a new inode, which is
the one thing known to disturb this app's Accessibility grant. Do it when the
bundle is suspect; do not do it routinely, and expect a re-grant afterwards.

## Privacy grants (TCC)

**Never run `tccutil` yourself.** It changes a macOS security setting and
revokes access the user granted deliberately. Hand the user the command:

```bash
make reset-permissions
```

`scripts/reset-tcc.sh` clears Accessibility, Microphone, and Speech Recognition
for `dev.alex.yapops` and prints how to re-grant each. It is deliberately not
part of `make check`.

Reach for it only after the app's own API disagrees with System Settings. On
2026-09-13 `AXIsProcessTrusted()` returned `false` seven consecutive times for a
correctly signed, correctly wired process while the Accessibility toggle read
On, with a single entry in the list. Duplicate entries, app wiring, and signing
instability were each ruled out first — `codesign -d -r-` showed the designated
requirement pinning a stable certificate leaf hash, unchanged across rebuilds.
The state was stale inside TCC, not in the app. The reset fixed it immediately.

That this is an OS-side fault does not make it unreproducible. Bundle directory
churn aggravates it: `scripts/build-app.sh` used to swap the whole `.app` in
with `mv`, giving `.build/YapOps.app` a new directory inode on every build. It
now creates that directory once and replaces only `Contents/`, after the staged
copy signs and verifies. `scripts/test-build-app.py` guards the stable bundle
directory, the persistent default identity, the explicit ad-hoc opt-in, and
preservation of the previous `Contents/` when signing or verification fails.

So before blaming TCC, confirm the identity really is stable. A grant lost
across an ad-hoc rebuild, an identity change, or a move between `.build` and
`/Applications` is expected behavior, not staleness, and resetting only hides it.

## Signing identity

```bash
security find-identity -v -p codesigning   # expect: YapOps Local Development
make setup-signing                         # provisions it once per Mac
```

Setup reuses an existing identity and never silently replaces a missing,
expired, or broken key. Regular builds never generate keys and never fall back
to ad-hoc signing. Do not alternate identities for the app used day to day.

## Preferences and profiles

Preferences are user data. Read them before clearing, prefer changing the one
wrong value in Settings, and never clear them to make a test pass. Unit tests
must inject their own store rather than touching the real domain.

## Installed copy

Permission, login-item, and menu-bar lifecycle behavior belongs to a stable
path. Quit the running app first, then replace the copy and launch that path:

```bash
pkill -x YapOps
ditto .build/YapOps.app /Applications/YapOps.app
open /Applications/YapOps.app
```

Keep one path and one identity across updates. Testing permissions from
`.build` one day and `/Applications` the next produces two grants and a
diagnosis that fits neither.

## Never reset

- Any privacy grant, login item, or Keychain item, without the user doing it.
- Unrelated apps' TCC entries. `tccutil reset Accessibility` with no bundle
  identifier clears the entire system. `scripts/reset-tcc.sh` always scopes.
- The user's dirty working tree, stashes, or branches.
- Anything at all as a first response to a failing test. The reset that makes a
  red test green without an explanation has removed the symptom and kept the bug.
