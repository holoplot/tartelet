# Holoplot fork changes

This fork tracks [framna-dk/tartelet](https://github.com/framna-dk/tartelet) with
changes required for parity with GitHub-hosted macOS runners.

## Runner startup: LaunchAgent instead of Terminal

Upstream Tartelet starts ephemeral VM jobs with:

```swift
open -a Terminal ~/start-runner.sh
```

That routes AppleEvents (e.g. Tauri `bundle_dmg.sh` → Finder) through
**Terminal.app**, which is not in GitHub's pre-seeded TCC database. Jobs hang
on modal permission prompts or time out.

Holoplot starts the same script via a **LaunchAgent in the auto-login user's
`gui/` domain**, matching how GitHub-hosted runners run `Runner.Listener` as a
background process in an active WindowServer session.

Runner logs: `~/Library/Logs/tartelet/actions-runner.log` inside the VM.

LaunchAgents default to working directory `/`; the plist sets `WorkingDirectory`
to the auto-login user's home (Terminal.app did this implicitly).

Holoplot releases wait for the `gui/UID` launchd domain, log bootstrap output to
`~/.tartelet/launchagent-bootstrap.log`, and start the runner via LaunchAgent
with a direct `nohup` fallback when bootstrap fails.

Older Holoplot VM images may ship a **root-owned** `~/actions-runner` TCC
placeholder; `v0.12.0-holoplot.14+` removes it with `sudo rm -rf` before
downloading actions-runner.

## Keychain (Holoplot ad-hoc releases)

Upstream Tartelet uses Shape's Apple Developer keychain access group
(`566MC7D8D4.dk.shape.Tartelet`). Holoplot release builds are ad-hoc signed
without that team ID, so this fork uses the default app keychain instead.

The GitHub App PEM is stored as a generic keychain password (not a SecKey item).
Upstream stores RSA keys as `kSecClassKey`, which requires a developer team
entitlement and fails with `-34018` on ad-hoc signed builds.

## Releases

Build and tag from this fork; `sw__ci_infra` installs
`holoplot/tartelet` release zips on macOS runner hosts (see
`bare-metal/ansible/roles/macos-tartelet`).
