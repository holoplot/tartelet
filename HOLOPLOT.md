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
Bootstrap logs: `~/.tartelet/launchagent-bootstrap.log`.

LaunchAgents default to working directory `/`; the plist sets `WorkingDirectory`
to the auto-login user's home (Terminal.app did this implicitly).

## Signing and keychain

Holoplot releases are **Developer ID signed and notarized** (`com.holoplot.Tartelet`).
Keychain credentials use the app's access group (same pattern as upstream Shape
builds, with Holoplot's team ID).

Re-enter GitHub App PEM and VM SSH credentials after upgrading from ad-hoc
releases or upstream Shape builds — each signing identity uses a separate
keychain access group.

### Release CI secrets

Repository → Settings → Secrets → Actions:

| Secret | Purpose |
|--------|---------|
| `APPLE_CERTIFICATE_P12` | Base64 Developer ID Application `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | `.p12` export password |
| `APPLE_TEAM_ID` | 10-character team ID |
| `APPLE_ID` + `APPLE_APP_SPECIFIC_PASSWORD` | Notarization (legacy) |
| `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID`, `APPLE_API_KEY_P8` | Notarization (preferred) |

Create environment **`apple-signing`** with required reviewers (Settings →
Environments). The release workflow pauses there before importing the certificate.

## Upstreaming

Before opening a PR to framna-dk/tartelet, discuss LaunchAgent startup with
maintainers. Signing/keychain changes are Holoplot-specific; the behavioral fix
is LaunchAgent + VM image TCC seeding (see `sw__ci_infra`).

## Releases

Build and tag from this fork; `sw__ci_infra` installs release zips on macOS
runner hosts (`bare-metal/ansible/roles/macos-tartelet`).
