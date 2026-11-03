# Setup

## Install

1. Pair the MiniToo in macOS System Settings.
2. Install Xcode Command Line Tools with `xcode-select --install` if needed.
3. Run `./setup.sh` from the project root.
4. Run `./minitoo setup`. Follow the Bluetooth and hidden password prompts.
5. Check that `./minitoo face working` changes the physical screen.

`setup.sh` creates a local Python environment. The `minitoo` launcher uses it
automatically. Run all commands from the project root unless a guide says otherwise.

Rebuilding the Bluetooth helper can invalidate its macOS Bluetooth permission.
Reapprove `divoom-send` in System Settings > Privacy & Security > Bluetooth.

## Your working checkout

Use this checkout for ongoing code and documentation changes. Device settings
live in `~/.clauddy/config`; personal cloud settings and message logs also stay
outside version control. Share the GitHub repository, keeping your local
settings private.

If you configured `--core-dir` to reuse an approved Bluetooth helper, keep that
helper directory in place until you have tested its replacement. You can keep
editing this checkout while it uses the existing helper.

## Automatic character status

Clauddy is the character-status app. Manual face switching works independently
of any AI tool. Automatic switching requires that tool's lifecycle hooks.

For Claude Code, merge the following into its settings. Replace `PROJECT_PATH`
with the absolute path to this checkout. Preserve any hooks already configured.

```json
{
  "hooks": {
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "PROJECT_PATH/apps/clauddy/clauddy-hook.sh working"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "PROJECT_PATH/apps/clauddy/clauddy-hook.sh chilling"}]}],
    "Notification": [{"matcher": "permission_prompt", "hooks": [{"type": "command", "command": "PROJECT_PATH/apps/clauddy/clauddy-hook.sh alerting"}]}],
    "SessionEnd": [{"hooks": [{"type": "command", "command": "PROJECT_PATH/apps/clauddy/clauddy-hook.sh default"}]}]
  }
}
```

### Codex

Run `./minitoo codex install`, then open **Codex Settings > Hooks** and review
and trust the Clauddy hooks. The installer merges them into `~/.codex/hooks.json`
and preserves other hooks. Start a new chat after reviewing if the current chat
does not pick up the change.

The five events are UserPromptSubmit, PermissionRequest, PostToolUse, Stop and
Interrupt. Opening or closing a chat does not change the screen.

Vibin' means working. Alerting means an approval or response is needed.
Chillin' means the turn finished. These use the same installed character faces
as Claude Code. Studio, Pomodoro and manual pauses still take priority.

To reuse a Bluetooth helper already approved on this Mac, add
`--core-dir /path/to/existing/core` when installing. This stores the path only in
`~/.clauddy/codex-config.json`, outside the repository. The main launcher and
Codex hooks use it without rebuilding the helper.

Run `./minitoo codex remove` to remove only these hooks. The adapter never grants
or denies tool approvals. It does not save prompts or assistant messages.

Reference: [Codex hooks](https://learn.chatgpt.com/docs/hooks).

Optional: install `blueutil` to skip automatic hook activity when the device
is disconnected. If Homebrew cannot install it on your Mac, manual commands
still work; this dependency is optional.

## Optional audio guard

If macOS keeps selecting the MiniToo as your microphone or speaker, run
`./core/install-audio-guard.sh install`. This installs a user LaunchAgent.
Remove it with `./core/install-audio-guard.sh uninstall`.

For Pomodoro music, install `brew install switchaudio-osx`, start a playlist in
Music once, and run `./minitoo pomodoro 25 5 1`. The timer restores your previous
audio output when it exits. Set the MiniToo's volume with its physical controls.
