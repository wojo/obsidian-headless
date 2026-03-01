# macOS Background Sync Daemon

Run Obsidian Sync continuously as a background service using macOS launchd. The daemon starts on login and auto-restarts on failure.

## Prerequisites

- macOS
- Node.js 22+
- A vault configured with `ob sync-setup`

You can use the interactive setup script to handle everything at once:

```bash
bash scripts/setup-vault.sh <vault-path>
```

## Install

```bash
bash scripts/macos-daemon.sh install <vault-path>
```

This creates a LaunchAgent at `~/Library/LaunchAgents/md.obsidian.sync.<slug>.plist`, loads it immediately, and configures it to start on login.

Example:

```bash
bash scripts/macos-daemon.sh install ~/Obsidian\ Vaults/Personal
```

If `OBSIDIAN_AUTH_TOKEN` is set in your environment at install time, it is baked into the plist so the daemon can authenticate without `ob login`.

## Uninstall

```bash
bash scripts/macos-daemon.sh uninstall <vault-path>
```

Stops the agent and removes the plist.

## Status

```bash
bash scripts/macos-daemon.sh status
```

Lists all installed Obsidian Sync agents with their running state and PID.

## Logs

```bash
bash scripts/macos-daemon.sh logs <vault-path>
```

Tails the app's sync log at `~/.obsidian-headless/sync/<vault-id>/sync.log`. Press Ctrl+C to stop.

## Restart

```bash
bash scripts/macos-daemon.sh restart <vault-path>
```

Unloads and reloads the LaunchAgent. Useful after updating obsidian-headless or changing configuration.

## How it works

The daemon script generates a macOS LaunchAgent plist per vault. Each plist runs `node cli.js sync --continuous --path <vault-path>` with:

- **RunAtLoad** — starts automatically on login
- **KeepAlive** — restarts automatically if the process exits
- **ThrottleInterval: 10s** — waits 10 seconds before restarting after a crash
- **Absolute paths** to `node` and `cli.js` to avoid launchd PATH issues

Vault configuration is resolved by scanning `~/.obsidian-headless/sync/*/config.json` to match the provided vault path to its name and ID.

## Troubleshooting

### Daemon is "loaded (not running)"

The process is crashing on start. Check the sync log:

```bash
bash scripts/macos-daemon.sh logs <vault-path>
```

Common causes:
- Missing `node_modules` — run `npm install` in the obsidian-headless directory
- Vault not configured — run `ob sync-setup` first
- Authentication expired — run `ob login` or set `OBSIDIAN_AUTH_TOKEN` and reinstall

### Reinstalling after an update

```bash
bash scripts/macos-daemon.sh uninstall <vault-path>
bash scripts/macos-daemon.sh install <vault-path>
```

This regenerates the plist with current paths to `node` and `cli.js`.

### Viewing launchd state directly

```bash
launchctl list | grep md.obsidian.sync
```

The three columns are PID (or `-` if not running), last exit status, and label.
