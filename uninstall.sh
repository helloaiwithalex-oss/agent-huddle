#!/bin/bash
# Removes everything install.sh added: the widget, its login item, its hooks and the VS Code helper.
# Your other Claude Code settings are left as they are.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="com.agenthuddle.widget"
STATE="$HOME/.agent-huddle"
APP="$HOME/Applications/Agent Huddle.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
pkill -f "Agent Huddle.app/Contents/MacOS/AgentHuddle" 2>/dev/null
rm -f "$PLIST"
rm -rf "$APP"
echo "removed the widget and its login item"

if command -v node >/dev/null; then
  node "$HERE/hooks.mjs" remove
else
  echo "Node.js not found: remove the entries that run .agent-huddle/hook.js from ~/.claude/settings.json by hand"
fi

CODE="$(command -v code || true)"
[[ -z "$CODE" && -x "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" ]] && CODE="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
if [[ -n "$CODE" ]] && "$CODE" --list-extensions 2>/dev/null | grep -qi "^agent-huddle.agent-huddle$"; then
  "$CODE" --uninstall-extension agent-huddle.agent-huddle >/dev/null 2>&1 && echo "removed the VS Code helper"
fi
rm -rf "$HOME/.vscode/extensions"/agent-huddle.agent-huddle-* 2>/dev/null
defaults delete "$LABEL" 2>/dev/null   # the widget's saved window position

rm -rf "$STATE"
echo "Agent Huddle is uninstalled."
