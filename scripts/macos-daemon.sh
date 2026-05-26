#!/usr/bin/env bash
set -euo pipefail

# macOS LaunchAgent manager for obsidian-headless sync
# Usage: bash scripts/macos-daemon.sh <command> [vault-path]

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
CONFIG_BASE="$HOME/.obsidian-headless/sync"
LABEL_PREFIX="md.obsidian.sync"

# --- Helpers ---

die() { echo "Error: $*" >&2; exit 1; }

check_macos() {
  [[ "$(uname -s)" == "Darwin" ]] || die "This command is only supported on macOS."
}

slugify() {
  # Lowercase, replace non-alphanumeric with underscore, collapse multiple underscores, trim edges
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g; s/__*/_/g; s/^_//; s/_$//'
}

resolve_vault() {
  local vault_path="$1"
  # Resolve to absolute path
  vault_path="$(cd "$vault_path" 2>/dev/null && pwd)" || die "Vault path does not exist: $1"

  local found=0
  local vault_name=""
  local vault_id=""

  for config in "$CONFIG_BASE"/*/config.json; do
    [[ -f "$config" ]] || continue
    # Parse JSON without jq — extract vaultPath and vaultName
    local cfg_path cfg_name cfg_id
    cfg_path="$(grep -o '"vaultPath"[[:space:]]*:[[:space:]]*"[^"]*"' "$config" | head -1 | sed 's/.*"vaultPath"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    cfg_name="$(grep -o '"vaultName"[[:space:]]*:[[:space:]]*"[^"]*"' "$config" | head -1 | sed 's/.*"vaultName"[[:space:]]*:[[:space:]]*"//; s/"$//')"
    cfg_id="$(grep -o '"vaultId"[[:space:]]*:[[:space:]]*"[^"]*"' "$config" | head -1 | sed 's/.*"vaultId"[[:space:]]*:[[:space:]]*"//; s/"$//')"

    if [[ "$cfg_path" == "$vault_path" ]]; then
      vault_name="$cfg_name"
      vault_id="$cfg_id"
      found=1
      break
    fi
  done

  if [[ $found -eq 0 ]]; then
    die "No sync configuration found for vault at: $vault_path
Run 'ob sync-setup' first to configure this vault for syncing."
  fi

  VAULT_PATH="$vault_path"
  VAULT_NAME="$vault_name"
  VAULT_ID="$vault_id"
  VAULT_SLUG="$(slugify "$vault_name")"
  PLIST_LABEL="${LABEL_PREFIX}.${VAULT_SLUG}"
  PLIST_FILE="${LAUNCH_AGENTS_DIR}/${PLIST_LABEL}.plist"
  SYNC_LOG="${CONFIG_BASE}/${VAULT_ID}/sync.log"
}

find_node() {
  local node_path candidate
  # Prefer a pinned, keg-only Homebrew Node LTS that the native deps (better-sqlite3)
  # support. The default `node` symlink follows Homebrew upgrades and can jump to a
  # major those deps don't support yet, which silently breaks sync at runtime.
  for candidate in \
    /opt/homebrew/opt/node@24/bin/node \
    /usr/local/opt/node@24/bin/node \
    /opt/homebrew/opt/node@22/bin/node \
    /usr/local/opt/node@22/bin/node; do
    [[ -x "$candidate" ]] && { echo "$candidate"; return 0; }
  done
  node_path="$(command -v node 2>/dev/null)" || die "node not found in PATH.
Install a supported Node.js LTS ('brew install node@24') or get it from https://nodejs.org."
  echo "$node_path"
}

find_cli() {
  # Find cli.js relative to this script (scripts/ is sibling of cli.js)
  local script_dir cli_path
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  cli_path="$(cd "$script_dir/.." && pwd)/cli.js"
  [[ -f "$cli_path" ]] || die "cli.js not found at: $cli_path"
  echo "$cli_path"
}

# --- Commands ---

cmd_install() {
  [[ $# -ge 1 ]] || die "Usage: $0 install <vault-path>"

  resolve_vault "$1"

  if [[ -f "$PLIST_FILE" ]]; then
    echo "LaunchAgent already installed for vault \"$VAULT_NAME\" ($PLIST_LABEL)."
    echo "Use 'restart' to reload, or 'uninstall' first to reinstall."
    exit 0
  fi

  local node_path cli_path
  node_path="$(find_node)"
  cli_path="$(find_cli)"

  mkdir -p "$LAUNCH_AGENTS_DIR"

  # Build environment variables section
  local env_vars="" node_bin_dir
  # Put the chosen node's own bin dir first so any child node it spawns matches.
  node_bin_dir="$(dirname "$node_path")"
  env_vars+="        <key>HOME</key>
        <string>$HOME</string>
        <key>PATH</key>
        <string>${node_bin_dir}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>"

  if [[ -n "${OBSIDIAN_AUTH_TOKEN:-}" ]]; then
    env_vars+="
        <key>OBSIDIAN_AUTH_TOKEN</key>
        <string>$OBSIDIAN_AUTH_TOKEN</string>"
  fi

  cat > "$PLIST_FILE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$PLIST_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$node_path</string>
        <string>$cli_path</string>
        <string>sync</string>
        <string>--continuous</string>
        <string>--path</string>
        <string>$VAULT_PATH</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$VAULT_PATH</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>EnvironmentVariables</key>
    <dict>
$env_vars
    </dict>
</dict>
</plist>
EOF

  launchctl load "$PLIST_FILE"
  echo "Installed and started LaunchAgent for vault \"$VAULT_NAME\"."
  echo "  Label: $PLIST_LABEL"
  echo "  Plist: $PLIST_FILE"
  echo "  Logs:  $SYNC_LOG"
}

cmd_uninstall() {
  [[ $# -ge 1 ]] || die "Usage: $0 uninstall <vault-path>"

  resolve_vault "$1"

  if [[ ! -f "$PLIST_FILE" ]]; then
    die "No LaunchAgent installed for vault \"$VAULT_NAME\" ($PLIST_LABEL)."
  fi

  launchctl unload "$PLIST_FILE" 2>/dev/null || true
  rm -f "$PLIST_FILE"
  echo "Uninstalled LaunchAgent for vault \"$VAULT_NAME\" ($PLIST_LABEL)."
}

cmd_status() {
  echo "Obsidian Sync LaunchAgents:"
  echo ""

  local found=0
  for plist in "$LAUNCH_AGENTS_DIR"/${LABEL_PREFIX}.*.plist; do
    [[ -f "$plist" ]] || continue
    found=1

    local label
    label="$(basename "$plist" .plist)"
    local slug="${label#${LABEL_PREFIX}.}"

    # Extract vault path from plist
    local vault_path
    vault_path="$(/usr/libexec/PlistBuddy -c "Print :WorkingDirectory" "$plist" 2>/dev/null || echo "unknown")"

    # Check if running — parse the PID/status/label table from `launchctl list`
    local status
    local line
    line="$(launchctl list 2>/dev/null | grep "	${label}$")" || true
    if [[ -n "$line" ]]; then
      local pid
      pid="$(echo "$line" | awk '{print $1}')"
      if [[ "$pid" == "-" ]]; then
        status="loaded (not running)"
      else
        status="running (PID $pid)"
      fi
    else
      status="not loaded"
    fi

    echo "  $label"
    echo "    Vault: $vault_path"
    echo "    Status: $status"
    echo ""
  done

  if [[ $found -eq 0 ]]; then
    echo "  No Obsidian Sync agents installed."
    echo "  Use '$0 install <vault-path>' to set one up."
  fi
}

cmd_logs() {
  [[ $# -ge 1 ]] || die "Usage: $0 logs <vault-path>"

  resolve_vault "$1"

  [[ -f "$SYNC_LOG" ]] || die "No log file found for vault \"$VAULT_NAME\".
Expected at: $SYNC_LOG"

  echo "Tailing logs for vault \"$VAULT_NAME\" (Ctrl+C to stop)..."
  echo ""
  tail -f "$SYNC_LOG"
}

cmd_restart() {
  [[ $# -ge 1 ]] || die "Usage: $0 restart <vault-path>"

  resolve_vault "$1"

  if [[ ! -f "$PLIST_FILE" ]]; then
    die "No LaunchAgent installed for vault \"$VAULT_NAME\" ($PLIST_LABEL).
Use 'install' first."
  fi

  launchctl unload "$PLIST_FILE" 2>/dev/null || true
  launchctl load "$PLIST_FILE"
  echo "Restarted LaunchAgent for vault \"$VAULT_NAME\" ($PLIST_LABEL)."
}

# --- Main ---

check_macos

command="${1:-}"
shift || true

case "$command" in
  install)   cmd_install "$@" ;;
  uninstall) cmd_uninstall "$@" ;;
  status)    cmd_status ;;
  logs)      cmd_logs "$@" ;;
  restart)   cmd_restart "$@" ;;
  *)
    echo "Usage: $0 <command> [vault-path]"
    echo ""
    echo "Commands:"
    echo "  install <vault-path>    Install and start a LaunchAgent for a vault"
    echo "  uninstall <vault-path>  Stop and remove the LaunchAgent"
    echo "  status                  List all installed Obsidian Sync agents"
    echo "  logs <vault-path>       Tail log files for a vault"
    echo "  restart <vault-path>    Restart the LaunchAgent for a vault"
    exit 1
    ;;
esac
