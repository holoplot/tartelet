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

## Releases

Build and tag from this fork; `sw__ci_infra` installs
`holoplot/tartelet` release zips on macOS runner hosts (see
`bare-metal/ansible/roles/macos-tartelet`).
