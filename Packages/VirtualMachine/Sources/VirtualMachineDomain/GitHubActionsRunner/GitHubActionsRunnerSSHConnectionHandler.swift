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
        let startRunnerScriptFilePath = "~/start-runner.sh"
        try await connection.executeCommand("touch \(startRunnerScriptFilePath)")
        try await connection.executeCommand("""
cat > \(startRunnerScriptFilePath) << EOF
#!/bin/zsh
cd "\\$HOME"
RUNNER_DIR="\\$HOME/actions-runner"
RUNNER_ARCHIVE="\\$HOME/actions-runner.tar.gz"

# Ensure the virtual machine is restarted when a job is done.
set -e pipefail
function onexit {
  status=\\$?
  echo "start-runner.sh exiting with status \\$status at \\$(date)" >> "\\$HOME/Library/Logs/tartelet/actions-runner.log"
  sudo shutdown -h now
}
trap onexit EXIT

mkdir -p "\\$HOME/Library/Logs/tartelet"

# Wait until we can connect to GitHub.
until curl -Is https://github.com &>/dev/null; do :; done

# Image build must not ship a partial actions-runner tree; install if missing.
if [[ ! -x "\\$RUNNER_DIR/run.sh" ]]; then
  rm -rf "\\$RUNNER_DIR"
  curl -fLo "\\$RUNNER_ARCHIVE" -L "\(runnerDownloadURL)"
  mkdir -p "\\$RUNNER_DIR"
  tar xzf "\\$RUNNER_ARCHIVE" --directory "\\$RUNNER_DIR"
fi

if [[ ! -x "\\$RUNNER_DIR/run.sh" ]]; then
  echo "actions-runner install failed: \\$RUNNER_DIR/run.sh missing after extract" >&2
  ls -la "\\$RUNNER_DIR" >&2 || true
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

# Create .env file in runner's diectory.
if [[ "\\$RUNNER_ENV" != "" ]]; then
  echo "\\$RUNNER_ENV" >> "\\$RUNNER_DIR/.env"
fi

# Configure and run the runner.
cd "\\$RUNNER_DIR"
./config.sh\\\\
  --url "\(runnerURL)"\\\\
  --unattended\\\\
  --ephemeral\\\\
  --replace\\\\
  --labels "\(configuration.runnerLabels)"\\\\
  --name "\(runnerName(for: virtualMachine))"\\\\
  --runnergroup "\(configuration.runnerGroup)"\\\\
  --work "_work"\\\\
  --token "\(runnerToken.rawValue)"\\\\
  \(configuration.runnerDisableUpdates ? "--disableupdate" : "")\\\\
  \(configuration.runnerDisableDefaultLabels ? "--no-default-labels" : "")
./run.sh
EOF
""")
        try await connection.executeCommand("chmod +x \(startRunnerScriptFilePath)")
        // Start the runner in the auto-login user's GUI session via launchd,
        // not Terminal.app. Upstream GitHub-hosted macOS runners execute
        // Runner.Listener headlessly; Terminal as the automation parent breaks
        // TCC attribution (osascript → Finder prompts during DMG bundling).
        try await connection.executeCommand("""
home=$(cd ~ && pwd)
mkdir -p "$home/Library/LaunchAgents" "$home/Library/Logs/tartelet"
cat > "$home/Library/LaunchAgents/net.tartelet.actions-runner.plist" << EOF
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
  <key>StandardOutPath</key>
  <string>$home/Library/Logs/tartelet/actions-runner.log</string>
  <key>StandardErrorPath</key>
  <string>$home/Library/Logs/tartelet/actions-runner.log</string>
</dict>
</plist>
EOF
uid=$(id -u)
until launchctl print "gui/${uid}" &>/dev/null; do sleep 1; done
launchctl bootout "gui/${uid}/net.tartelet.actions-runner" 2>/dev/null || true
launchctl bootstrap "gui/${uid}" "$home/Library/LaunchAgents/net.tartelet.actions-runner.plist"
launchctl kickstart -k "gui/${uid}/net.tartelet.actions-runner"
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
