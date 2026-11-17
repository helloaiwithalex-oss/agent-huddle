#!/bin/bash
# Agent Huddle installer (macOS). Safe to run again: it updates an existing install in place.
#   ./install.sh
# What it does:
#   1. builds the widget from source (app/main.swift) and copies it to ~/Applications
#   2. copies hook.js to ~/.agent-huddle/
#   3. adds the hooks to ~/.claude/settings.json (your other settings stay as they are; a backup is saved)
#   4. starts the widget now and at every login (launchd)
#   5. installs the small VS Code helper, if VS Code's `code` command is available
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.agenthuddle.widget"
STATE="$HOME/.agent-huddle"
APP="$HOME/Applications/Agent Huddle.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

say()  { printf '\033[1m%s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || fail "Agent Huddle is macOS only."
command -v swiftc >/dev/null || fail "Swift isn't installed. Run: xcode-select --install   then run ./install.sh again."
NODE="$(command -v node || true)"
[[ -n "$NODE" ]] || fail "Node.js isn't installed (Claude Code's hooks run it). Get it from https://nodejs.org, then run ./install.sh again."
[[ "$("$NODE" -p 'process.versions.node.split(".")[0]')" -ge 18 ]] || fail "Node.js 18 or newer is needed (you have $("$NODE" -v))."

say "1/5 Building the widget…"
BUILD_LOG="$(mktemp)"
if ! "$HERE/build.sh" >"$BUILD_LOG" 2>&1; then
  grep -E "error" "$BUILD_LOG" >&2 || cat "$BUILD_LOG" >&2
  fail "the build failed (full log: $BUILD_LOG)"
fi
rm -f "$BUILD_LOG"

say "2/5 Installing to ~/Applications…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "Agent Huddle.app/Contents/MacOS/AgentHuddle" 2>/dev/null || true
mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto "$HERE/Agent Huddle.app" "$APP"
mkdir -p "$STATE/commands"
chmod 700 "$STATE"
cp "$HERE/hook.js" "$STATE/hook.js"

say "3/5 Adding hooks to ~/.claude/settings.json…"
"$NODE" "$HERE/hooks.mjs" add "$NODE"

say "4/5 Starting the widget (and at every login)…"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$APP/Contents/MacOS/AgentHuddle</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$STATE/launchd.err</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$PLIST"
for _ in $(seq 1 30); do
  [[ -f "$STATE/server.json" ]] && pgrep -f "$APP/Contents/MacOS/AgentHuddle" >/dev/null && break
  sleep 0.5
done
pgrep -f "$APP/Contents/MacOS/AgentHuddle" >/dev/null || echo "  (still starting: macOS sometimes needs a few seconds the first time)"

say "5/5 VS Code helper…"
CODE="$(command -v code || true)"
[[ -z "$CODE" && -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]] && CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
if [[ -n "$CODE" ]]; then
  "$CODE" --install-extension "$HERE/vscode-ext/agent-huddle.vsix" --force >/dev/null 2>&1 && echo "  installed (open a new VS Code window or restart VS Code to turn it on)"
else
  echo "  skipped: VS Code not found. Jump/close for VS Code tabs needs it; everything else works without."
fi

echo
say "Done. Agent Huddle is running."
echo "Start a new Claude Code session (or restart open ones) and a bot appears for it."
echo "Uninstall any time with ./uninstall.sh"
