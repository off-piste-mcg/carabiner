# Developer ID distribution — design

**Date:** 2026-08-10
**Phase:** 4 of `2026-07-29-carabiner-mac-app-design.md` ("Distribution")
**Status:** designed; unverifiable until a Developer ID Application certificate exists

## Goal

A teammate downloads a DMG, drags `Carabiner.app` to Applications, opens it, and clicks
Allow two or three times. No Gatekeeper warning, no Terminal, no Homebrew, no clone.

That is the whole phase. Auto-update (Sparkle) is phase 5 and is deliberately not here.

## Why now

Organization enrolment for OFF-PISTE B.V. completed. Until it did, the only signing
identity on the machine was `Apple Development` — a certificate scoped to the developer's
own Macs, whose failure mode on someone else's machine is silent (no notifications, per
gotcha #11). Handing that build to the team was ruled out on 2026-07-30.

## Preconditions (manual, outside this design)

These need an interactive Apple login and cannot be scripted here:

1. A **Developer ID Application** certificate in the login keychain
   (Xcode → Settings → Accounts → the org team → Manage Certificates → **+**). Requires
   the Account Holder role.
2. A stored notarytool credential profile named `carabiner`:
   `xcrun notarytool store-credentials carabiner` with an app-specific password from
   appleid.apple.com.

`scripts/release.sh` checks both up front and refuses to build without them, with the
exact command to fix each.

## The defect this phase must fix first

`app/project.yml` signs every bundled Mach-O with `--timestamp=none`:

```sh
codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
  --options runtime --timestamp=none "$f"
```

**Notarization requires a secure timestamp on every signature.** All ~117 nested Mach-Os
under `Resources/bin` would be rejected. The flag is nonetheless correct for Debug: a
secure timestamp is a network round-trip to Apple's timestamp authority *per file*, and
paying that 117 times on every dev build is exactly the kind of friction that gets a
build script abandoned.

So it branches on `$CONFIGURATION` rather than flipping globally. Debug keeps
`--timestamp=none`; Release uses `--timestamp`.

This is a real defect in committed code, found while designing around it — not a new
requirement. It has been invisible because nothing has ever been notarized.

## Build configuration

XcodeGen writes `${VAR}` through to the pbxproj **literally**; `xcodebuild` expands it as
a build setting at build time. Verified against xcodegen 2.46.0. Two consequences that
shape this design:

- A Release config can reference a *different* team variable than Debug, and the same
  generated project serves both. No regeneration to switch.
- The variable must be set in the environment at `xcodebuild` time, not (only) at
  `xcodegen generate` time. `CLAUDE.md`'s snippet implies generate-time; both work in
  practice because it is the same shell, but `release.sh` sets it for the build.

| Setting | Debug (unchanged) | Release (new) |
|---|---|---|
| `CODE_SIGN_IDENTITY` | `Apple Development` | `Developer ID Application` |
| `CODE_SIGN_STYLE` | `Automatic` | `Manual` |
| `DEVELOPMENT_TEAM` | `${CARABINER_TEAM_ID}` | `${CARABINER_RELEASE_TEAM_ID}` |
| `OTHER_CODE_SIGN_FLAGS` | — | `--timestamp` |

**Two team variables, not one.** The existing `CARABINER_TEAM_ID` is derived from the
`Apple Development` certificate, which on this machine belongs to a *personal* team. The
Developer ID certificate belongs to the OFF-PISTE B.V. org team and carries a different
OU. One variable cannot be both. They may converge later if the development certificate
is reissued under the org team; the design does not depend on that.

**Manual signing for Release.** Automatic signing from the command line wants
`-allowProvisioningUpdates` and a network round-trip, and can silently pick a different
identity than intended. Developer ID distribution needs no provisioning profile —
`com.apple.security.automation.apple-events` is a Hardened Runtime entitlement, not a
capability requiring a profile — so manual signing is both deterministic and sufficient.

`ENABLE_HARDENED_RUNTIME`, the entitlements file, and the post-build script *order*
(gotcha #13: the xattr strip stays last) are already correct and are not touched.

The `CarabinerTests` target keeps its `Apple Development` identity. Release builds do not
build it, and it is never distributed.

## `scripts/release.sh`

One command, run from the repo root: `./scripts/release.sh [version]`.

Stages, in order:

1. **Preconditions.** Assert the Developer ID Application identity exists in the keychain
   and the `carabiner` notarytool profile is stored. Derive `CARABINER_RELEASE_TEAM_ID`
   from the certificate's **OU field** — the same trap as gotcha #12, on a different
   certificate: the parenthetical in the identity name is the agent ID and signing fails
   with it.
2. **Dependencies.** `scripts/fetch-deps.sh` (idempotent; a release without
   `Resources/bin` would be an app that silently depends on the recipient having
   Homebrew, which is the entire point of bundling).
3. **Build.** `xcodegen generate`, then `xcodebuild -configuration Release` to a
   throwaway derived-data path.
4. **Preflight gate.** See below. This is the substance of the script.
5. **Notarize the app.** Zip with `ditto -c -k --keepParent`, `notarytool submit --wait`,
   `stapler staple` the `.app`.
6. **Build the DMG.** `hdiutil create` over a staging directory containing the stapled
   app and an `/Applications` symlink. Plain, unstyled.
7. **Notarize the DMG.** Submit, staple.
8. **Verify.** `spctl -a -vvv -t install` on the app and `stapler validate` on both.

**Two notarization passes**, app and DMG, so the app carries its own stapled ticket after
being dragged out of the DMG. Stapling only the DMG leaves the installed app relying on
an online Gatekeeper check — which works, until the first colleague opens it offline.

**Staging happens in a temp directory, not the repo.** This repo lives under
`~/Documents`, which is iCloud-synced, and the file provider stamps `com.apple.FinderInfo`
onto anything that sits there (gotcha #13). The finished DMG is copied to a gitignored
`dist/` at the end.

### The preflight gate

Run against the built bundle *before* anything is uploaded. Each check fails the script
with a named cause:

- **Hardened Runtime** — `codesign -dv` reports `flags=0x10000(runtime)`.
- **No `get-task-allow`** — Xcode injects it into Debug builds and notarization rejects
  any binary carrying it (gotcha #16). This is the single most likely way to waste a
  round-trip, because a Debug build is otherwise indistinguishable from a Release one at
  a glance.
- **Every `Resources/bin` Mach-O is timestamped** — i.e. the `$CONFIGURATION` branch above
  actually took the Release path. Checks the signature, not the build setting, because
  the build setting is what we *think* happened.
- **Identity is Developer ID, not Apple Development** — a `CARABINER_RELEASE_TEAM_ID` that
  silently expanded to empty produces a build signed with whatever came to hand.

The gate exists because notarytool's rejection output is a JSON log behind a URL, and
reading it to discover a flag we could have checked in two seconds locally is a poor
trade. Fail before the upload, with the reason in plain English.

## README

A new "Download the app" section, placed **above** the existing clone-and-go instructions
so the non-technical path is the first one a reader meets: download the DMG from the
latest GitHub Release, drag to Applications, open, and let the Setup & Permissions window
walk the Allow prompts.

The clone-and-go script path and the Shortcut stay documented — they remain the fallback,
and the Shortcut is still the zero-install option. The README must keep saying that the
app and the Shortcut cannot share a hotkey (gotcha #14).

This also closes the outstanding item from phase 2 task 7 step 5 ("README install
instructions for app users, better written once the DMG exists").

## Out of scope

- **Sparkle auto-update and the appcast** — phase 5. It is the answer to "yt-dlp breaks
  monthly", and it is a larger piece of work than this one.
- **A styled DMG** (background image, icon placement) — needs `create-dmg` from Homebrew
  or a fragile AppleScript, against this repo's dependency-light convention. `hdiutil`
  plus an `/Applications` symlink is the familiar drag-to-install layout.
- **GitHub Actions release workflow** — would require exporting the Developer ID private
  key as a repo secret. The local script is written as the single source of truth so a
  workflow could call it unchanged later, but that is a deliberate later.
- **Publishing the release** — `gh release create` is a one-liner run by hand once the
  DMG is verified. Automating the upload adds a failure mode (a half-published release)
  for no gain at this frequency.

## Verification, honestly

Nothing in this design can be verified before the certificate exists. The script is
unexecuted code and the Release build configuration has never produced a binary.

What *can* be checked without a certificate, and will be:

- `bash -n scripts/release.sh` and a shellcheck pass.
- `xcodegen generate` succeeds and the generated pbxproj carries the expected Release
  settings.
- The `$CONFIGURATION` branch in the bundled-binary signing script is exercised by a
  Debug build, confirming the Debug path is unchanged.
- The precondition checks fire correctly *right now*, because the preconditions are
  genuinely absent — a script that refuses to run for the stated reason is the one thing
  here that can be tested honestly today.

The first real run is the test. Expect it to fail at least once; the gates are there to
make the failure legible.
