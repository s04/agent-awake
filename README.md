# AgentAwake

Tiny macOS menu-bar app that keeps your laptop running with the lid closed, so long-running coding agents finish their work while you walk away.

## Features

- **Stay awake** — runs `caffeinate -ims` so the machine, display, and disk don't idle-sleep.
- **Awake with lid closed** — sets `pmset disablesleep 1` so closing the lid doesn't sleep the machine.
- **Lock screen when lid reopens** — with sleep disabled, macOS never shows the lock screen on its own. AgentAwake watches the lid sensor and locks the screen the moment you reopen it, so you type your password and everything is still running.
- **Agent mode** — turns all of the above on in one click. **Everything OFF** restores normal sleep.
- **Timer** — awake for 30 minutes to 8 hours, then everything off.
- **Auto-off guards** — restore normal sleep and send a notification when:
  - the power cable is unplugged (off by default)
  - the battery drops below 20%
  - the machine hits serious thermal pressure with the lid closed
  - the last watched agent process exits (`claude`, `codex`, `cursor-agent`, `gemini`, `aider` by default, editable)
- **Agent hooks** — `agentawake://on`, `agentawake://off`, and `agentawake://lock` URLs, so your agent's own hooks can keep the machine awake exactly as long as it's working. See below.
- **Launch at login**, **Check for updates**, optional **Restore sleep on quit**.
- Menu-bar icon shows state at a glance: ☕️ caffeinated, 🔒 lid-closed awake, 😴 normal.

## Passwordless sleep toggle

Changing the lid-closed setting needs admin rights. By default AgentAwake asks for your password each time, which is fine when you're at the keyboard but useless when a guard fires while the laptop is in a bag. **Auto-off ▸ Allow sleep toggle without password…** installs a one-line sudoers rule that permits exactly two commands, `pmset -a disablesleep 0` and `pmset -a disablesleep 1`, and nothing else. Click the same item again to remove it. The rule lives in `/etc/sudoers.d/agentawake`.

## Hook it to your agent

Claude Code example, in `~/.claude/settings.json`. Awake while it works, normal sleep the moment it stops and waits for you:

```json
{
  "hooks": {
    "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "open -g agentawake://on" }] }],
    "Stop":             [{ "hooks": [{ "type": "command", "command": "open -g agentawake://off" }] }]
  }
}
```

Turn on the passwordless toggle first, or `on` will prompt for your password every time. The `-g` keeps the app from stealing focus. Any tool that can run a shell command on start and finish can do the same.

## Install

Download `AgentAwake.zip` from the [latest release](https://github.com/s04/agent-awake/releases/latest), unzip, and drag to Applications. Builds are not yet notarized, so on first launch right-click the app and choose **Open**.

Or build from source (needs Xcode command line tools, macOS 13+):

```sh
bash build.sh        # builds, ad-hoc signs, installs to ~/Applications, and launches
```

To ship a properly signed build, set `SIGN_IDENTITY` to your Developer ID and `NOTARY_PROFILE` to a `notarytool` keychain profile. See the comments in `build.sh`.

## Release

Push a tag and GitHub Actions builds and attaches the zip:

```sh
git tag v1.1.0 && git push --tags
```

## Warnings

- **Do not put the laptop in a bag with "Awake with lid closed" on.** It stays on at full power and will get hot and drain the battery. Turn it off before you pack up.
- The lid-closed setting survives quitting the app. Use **Everything OFF** or `sudo pmset -a disablesleep 0` to restore normal sleep.
- Lock-on-reopen uses the same private system call as ⌃⌘Q. If a future macOS removes it, the app falls back to putting the display to sleep, which locks if "Require password after display is turned off" is set in Lock Screen settings.
