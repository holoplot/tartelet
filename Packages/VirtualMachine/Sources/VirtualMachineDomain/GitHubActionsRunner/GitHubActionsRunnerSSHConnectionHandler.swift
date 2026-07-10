import Foundation
import GitHubDomain
import LoggingDomain
import SSHDomain

private enum GitHubActionsRunnerSSHConnectionHandlerError: LocalizedError {
    case organizationNameUnavailable
    case invalidRunnerURL

    var errorDescription: String? {
        switch self {
        case .organizationNameUnavailable:
            return "The organization name is unavailable"
        case .invalidRunnerURL:
            return "The runner URL is invalid. Ensure the organization name is correct"
        }
    }
}

public struct GitHubActionsRunnerSSHConnectionHandler: VirtualMachineSSHConnectionHandler {
    private let logger: Logger
    private let client: GitHubClient
    private let credentialsStore: GitHubCredentialsStore
    private let configuration: GitHubActionsRunnerConfiguration

    public init(
        logger: Logger,
        client: GitHubClient,
        credentialsStore: GitHubCredentialsStore,
        configuration: GitHubActionsRunnerConfiguration
    ) {
        self.logger = logger
        self.client = client
        self.credentialsStore = credentialsStore
        self.configuration = configuration
    }

    // swiftlint:disable:next function_body_length
    public func didConnect(to virtualMachine: VirtualMachine, through connection: SSHConnection) async throws {
        let runnerURL = try await getRunnerURL()
        let appAccessToken = try await client.getAppAccessToken(runnerScope: configuration.runnerScope)
        let runnerToken = try await client.getRunnerRegistrationToken(
            with: appAccessToken,
            runnerScope: configuration.runnerScope
        )
        let runnerDownloadURL = try await client.getRunnerDownloadURL(
            with: appAccessToken,
            runnerScope: configuration.runnerScope
        )
        let configFlags = [
            configuration.runnerDisableUpdates ? "--disableupdate" : nil,
            configuration.runnerDisableDefaultLabels ? "--no-default-labels" : nil
        ].compactMap { $0 }.joined(separator: " ")
        let configCommand = """
./config.sh --url "\(runnerURL)" --unattended --ephemeral --replace --labels "\(configuration.runnerLabels)" --name "\(runnerName(for: virtualMachine))" --runnergroup "\(configuration.runnerGroup)" --work "_work" --token "\(runnerToken.rawValue)"\(configFlags.isEmpty ? "" : " \(configFlags)")
"""
        let startRunnerScriptFilePath = "~/start-runner.sh"
        try await connection.executeCommand("touch \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
cat > \(startRunnerScriptFilePath) << EOF
#!/bin/zsh
cd "\\$HOME"
RUNNER_DIR="\\$HOME/actions-runner"
RUNNER_ARCHIVE="\\$HOME/actions-runner.tar.gz"
LOG="\\$HOME/Library/Logs/tartelet/actions-runner.log"

mkdir -p "\\$HOME/Library/Logs/tartelet"
exec >> "\\$LOG" 2>&1
echo "=== start-runner.sh begin \\$(date) ==="
set -e pipefail
set -x

function onexit {
  exit_status=\\$?
  echo "=== start-runner.sh exiting with status \\$exit_status at \\$(date) ==="
  sudo shutdown -h now
}
trap onexit EXIT

# Wait for GitHub (max ~5 minutes).
for _ in \\$(seq 1 60); do
  if curl -Is https://github.com &>/dev/null; then
    break
  fi
  sleep 5
done
curl -Is https://github.com &>/dev/null

# Install actions-runner when not registered yet (handles partial image trees).
if [[ ! -f "\\$RUNNER_DIR/.runner" ]]; then
  echo "No .runner registration; installing actions-runner into \\$RUNNER_DIR"
  # Holoplot images <= 20260710 may ship a root-owned TCC placeholder here.
  sudo rm -rf "\\$RUNNER_DIR"
  curl -fLo "\\$RUNNER_ARCHIVE" -L "\(runnerDownloadURL)"
  mkdir -p "\\$RUNNER_DIR"
  tar xzf "\\$RUNNER_ARCHIVE" --directory "\\$RUNNER_DIR"
  xattr -dr com.apple.quarantine "\\$RUNNER_ARCHIVE" "\\$RUNNER_DIR" 2>/dev/null || true
fi

if [[ ! -x "\\$RUNNER_DIR/run.sh" ]]; then
  echo "actions-runner install failed: \\$RUNNER_DIR/run.sh missing after extract"
  ls -la "\\$RUNNER_DIR" || true
  exit 1
fi

# Holds environment passed to runner.
RUNNER_ENV=""

# Configure pre-run script.
PRE_RUN_SCRIPT_PATH="\\$HOME/.tartelet/pre-run.sh"
if [[ -f "\\$PRE_RUN_SCRIPT_PATH" ]]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_STARTED=\\${PRE_RUN_SCRIPT_PATH}\\n"
fi

# Configure post-run script.
POST_RUN_SCRIPT_PATH="\\$HOME/.tartelet/post-run.sh"
if [[ -f "\\$POST_RUN_SCRIPT_PATH" ]]; then
  RUNNER_ENV="\\${RUNNER_ENV}ACTIONS_RUNNER_HOOK_JOB_COMPLETED=\\${POST_RUN_SCRIPT_PATH}\\n"
fi

if [[ "\\$RUNNER_ENV" != "" ]]; then
  printf '%b' "\\$RUNNER_ENV" >> "\\$RUNNER_DIR/.env"
fi

cd "\\$RUNNER_DIR"
echo "Registering runner: \(runnerName(for: virtualMachine))"
\(configCommand)
if [[ ! -f "\\$RUNNER_DIR/.runner" ]]; then
  echo "config.sh finished but \\$RUNNER_DIR/.runner is missing"
  ls -la "\\$RUNNER_DIR" || true
  exit 1
fi
echo "Starting run.sh"
./run.sh
EOF
""")
        try await connection.executeCommand("chmod +x \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
home=$(cd ~ && pwd)
mkdir -p "$home/Library/LaunchAgents" "$home/Library/Logs/tartelet" "$home/.tartelet"
bootstrap_log="$home/.tartelet/launchagent-bootstrap.log"
{
  echo "=== launchagent bootstrap $(date) ==="
  echo "home=$home uid=$(id -u)"

  # Drop root-owned TCC placeholder trees from older Holoplot VM images.
  if [ -d "$home/actions-runner" ] && [ ! -f "$home/actions-runner/.runner" ]; then
    sudo rm -rf "$home/actions-runner"
  fi

  if ! zsh -n "$home/start-runner.sh" 2>&1; then
    echo "warning: start-runner.sh syntax check failed; continuing anyway" >&2
  fi

  cat > "$home/Library/LaunchAgents/net.tartelet.actions-runner.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>net.tartelet.actions-runner</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>$home/start-runner.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$home</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$home/Library/Logs/tartelet/actions-runner.log</string>
  <key>StandardErrorPath</key>
  <string>$home/Library/Logs/tartelet/actions-runner.log</string>
</dict>
</plist>
PLIST

  uid=$(id -u)
  echo "Waiting for GUI launchd domain (uid=$uid)..."
  for attempt in $(seq 1 90); do
    if launchctl print "gui/${uid}" &>/dev/null; then
      echo "GUI launchd domain ready after ${attempt}s"
      break
    fi
    sleep 2
  done
  if ! launchctl print "gui/${uid}" &>/dev/null; then
    echo "warning: gui/${uid} unavailable; auto-login may still be in progress" >&2
  fi
  sleep 10

  agent_running=false
  launchctl bootout "gui/${uid}/net.tartelet.actions-runner" 2>/dev/null || true
  if launchctl print "gui/${uid}" &>/dev/null; then
    launchctl bootstrap "gui/${uid}" "$home/Library/LaunchAgents/net.tartelet.actions-runner.plist"
    for attempt in 1 2 3; do
      launchctl kickstart -k "gui/${uid}/net.tartelet.actions-runner" || true
      sleep 3
      if launchctl print "gui/${uid}/net.tartelet.actions-runner" 2>/dev/null | grep -q 'state = running'; then
        echo "LaunchAgent running after attempt ${attempt}"
        agent_running=true
        break
      fi
      echo "LaunchAgent not running after attempt ${attempt}; retrying kickstart"
    done
    if [ "$agent_running" = false ]; then
      echo "warning: LaunchAgent did not reach running state" >&2
      launchctl print "gui/${uid}/net.tartelet.actions-runner" || true
    fi
  else
    echo "warning: skipped LaunchAgent bootstrap because gui/${uid} is unavailable" >&2
  fi

  if [ "$agent_running" = false ]; then
    echo "Starting runner directly as bootstrap fallback"
    nohup /bin/zsh "$home/start-runner.sh" >> "$home/Library/Logs/tartelet/actions-runner.log" 2>&1 &
    sleep 2
    if pgrep -f "[s]tart-runner.sh" >/dev/null || pgrep -f "[R]unner.Listener" >/dev/null; then
      echo "Fallback runner process started"
    else
      echo "warning: fallback runner process not detected yet" >&2
      tail -n 50 "$home/Library/Logs/tartelet/actions-runner.log" 2>/dev/null || true
    fi
  fi
} >> "$bootstrap_log" 2>&1
""")
    }
    private func runnerName(for virtualMachine: VirtualMachine) -> String {
        let configuredRunnerName = configuration.runnerName

        // If no custom runner name is configured, use the VM name as-is
        if configuredRunnerName.isEmpty {
            return virtualMachine.name
        }

        // Extract the index suffix from VM names like "baseVM-1", "baseVM-2"
        let vmName = virtualMachine.name
        if let lastDashIndex = vmName.lastIndex(of: "-") {
            let indexString = String(vmName[vmName.index(after: lastDashIndex)...])
            if !indexString.isEmpty, Int(indexString) != nil {
                return "\(configuredRunnerName) \(indexString)"
            }
        }
        // Fallback to just the runner name if we can't extract an index
        return configuredRunnerName
    }
}

private extension GitHubActionsRunnerSSHConnectionHandler {
    private func getRunnerURL() async throws -> URL {
        switch configuration.runnerScope {
        case .organization:
            let organizationName = try await getOrganizationName()
            guard let runnerURL = URL(string: "https://github.com/" + organizationName) else {
                logger.info("Invalid runner URL for organization with name \(organizationName)")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        case .repo:
            guard
                let ownerName = credentialsStore.ownerName,
                let repositoryName = credentialsStore.repositoryName,
                let runnerURL = URL(string: "https://github.com/\(ownerName)/\(repositoryName)")
            else {
                logger.info("Invalid runner URL for repository")
                throw GitHubActionsRunnerSSHConnectionHandlerError.invalidRunnerURL
            }
            return runnerURL
        }
    }

    private func getOrganizationName() async throws -> String {
        guard let organizationName = credentialsStore.organizationName else {
            logger.info("The GitHub organization name is not available")
            throw GitHubActionsRunnerSSHConnectionHandlerError.organizationNameUnavailable
        }
        return organizationName
    }
}
