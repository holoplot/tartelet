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

Uses the same Holoplot **organization secrets** as `sw__holocloud` / holoforge:

| Secret | Purpose |
|--------|---------|
| `DEVELOPERID_APPLICATION_P12_BASE64` | Developer ID Application `.p12` |
| `DEVELOPERID_APPLICATION_P12_PSW` | `.p12` export password |
| `APPLE_NOTARIZE_ISSUER_ID` | App Store Connect API issuer |
| `APPLE_NOTARIZE_KEY_ID` | API key ID |
| `APPLE_NOTARIZE_KEY_P8_BASE64` | Base64 `.p8` key |

Optional notarization fallback: `APPLE_ID`, `APPLE_NOTARIZATION_PASSWORD`.

Grant **holoplot/tartelet** access to these org secrets. Create environment
**`apple-signing`** with required reviewers.

## Upstreaming

Before opening a PR to framna-dk/tartelet, discuss LaunchAgent startup with
maintainers. Signing/keychain changes are Holoplot-specific; the behavioral fix
is LaunchAgent + VM image TCC seeding (see `sw__ci_infra`).

## Releases

Build and tag from this fork; `sw__ci_infra` installs release zips on macOS
runner hosts (`bare-metal/ansible/roles/macos-tartelet`).
