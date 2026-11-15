# Agent Huddle helper

Small VS Code extension that goes with the Agent Huddle widget. The widget can't click things inside VS Code, so it leaves request files in `~/.agent-huddle/commands/`, and this extension carries them out:

- **Jump (↗):** shows the session's terminal, or opens its Claude chat tab.
- **Close (×):** closes that terminal, or that Claude chat tab (it only ever closes Claude chat tabs).

It only acts in the window that owns the terminal or has the session's folder open, and it never types anything.
