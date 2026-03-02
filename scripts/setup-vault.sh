#!/usr/bin/env bash
set -euo pipefail

# Interactive setup for obsidian-headless sync
# Walks through login, vault selection, sync setup, and config
# Usage: bash scripts/setup-vault.sh <vault-path>

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OB="$(cd "$SCRIPT_DIR/.." && pwd)/cli.js"

die() { echo "Error: $*" >&2; exit 1; }

[[ -f "$OB" ]] || die "cli.js not found at: $OB"
command -v node &>/dev/null || die "node not found. Install Node.js 22+ from https://nodejs.org"

ob() { node "$OB" "$@"; }

vault_path="${1:-}"
[[ -n "$vault_path" ]] || die "Usage: $0 <vault-path>"
vault_path="$(cd "$vault_path" 2>/dev/null && pwd)" || die "Path does not exist: $1"

echo "=== Obsidian Headless Vault Setup ==="
echo ""
echo "Vault path: $vault_path"
echo ""

# --- Step 1: Login ---

echo "Step 1: Authentication"
echo ""

if ! ob login 2>&1 | grep -q "Logged in"; then
  die "Not logged in. Run 'ob login' first, then re-run this script."
fi

ob login

echo ""

# --- Step 2: Select or create remote vault ---

echo "Step 2: Remote vault"
echo ""
ob sync-list-remote
echo ""
read -rp "Enter vault name or ID (or 'new' to create one): " vault_name

if [[ "$(echo "$vault_name" | tr '[:upper:]' '[:lower:]')" == "new" ]]; then
  echo ""
  read -rp "New vault name: " new_vault_name
  [[ -n "$new_vault_name" ]] || die "Vault name cannot be empty."

  echo ""
  echo "Encryption type:"
  echo "  1) standard  — managed encryption"
  echo "  2) e2ee      — end-to-end encryption (requires a password)"
  read -rp "Choose [1/2]: " enc_choice

  case "$enc_choice" in
    2|e2ee) ob sync-create-remote --name "$new_vault_name" --encryption e2ee ;;
    *)      ob sync-create-remote --name "$new_vault_name" --encryption standard ;;
  esac

  vault_name="$new_vault_name"
fi

# --- Step 3: Device name ---

echo ""
echo "Step 3: Device name"
echo ""
device_name="$(scutil --get ComputerName 2>/dev/null || hostname)"

# --- Step 4: Sync setup ---

echo ""
echo "Step 4: Setting up sync"
echo ""
ob sync-setup --vault "$vault_name" --path "$vault_path" --device-name "$device_name"
echo ""

# --- Step 5: Configure to sync everything ---

echo "Step 5: Configuring sync (all file types, all configs, merge conflicts)"
echo ""
ob sync-config --path "$vault_path" \
  --file-types "image,audio,video,pdf,unsupported" \
  --configs "app,appearance,appearance-data,hotkey,core-plugin,core-plugin-data,community-plugin,community-plugin-data" \
  --conflict-strategy merge \
  --device-name "$device_name"
echo ""

# --- Step 6: Offer daemon install (macOS only) ---

if [[ "$(uname -s)" == "Darwin" ]]; then
  echo "Step 6: Background sync (macOS LaunchAgent)"
  echo ""
  read -rp "Install as a background daemon? [Y/n] " daemon_answer
  if [[ "$(echo "$daemon_answer" | tr '[:upper:]' '[:lower:]')" != "n" ]]; then
    bash "$SCRIPT_DIR/macos-daemon.sh" install "$vault_path"
  fi
  echo ""
fi

echo "Done! Vault is configured and ready to sync."
