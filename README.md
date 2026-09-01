# AgentAwake

Tiny macOS menu-bar app that keeps your laptop running with the lid closed, so long-running coding agents finish their work while you walk away.

## Features

- **Stay awake** — runs `caffeinate -ims` so the machine, display, and disk don't idle-sleep.
- **Awake with lid closed** — sets `pmset disablesleep 1` (asks for your admin password) so closing the lid doesn't sleep the machine.
- **Lock screen when lid reopens** — with sleep disabled, macOS never shows the lock screen on its own. AgentAwake watches the lid sensor and locks the screen the moment you reopen it, so you just type your password and everything is still running.
- **Agent mode** — turns all three on in one click. **Everything OFF** restores normal sleep.
- Menu-bar icon shows state at a glance: ☕️ caffeinated, 🔒 lid-closed awake, 😴 normal.

## Install

```sh
bash build.sh
open ~/Applications/AgentAwake.app
```

Needs Xcode command line tools (`swiftc`). Tested on macOS 26.

## Warnings

- **Do not put the laptop in a bag with "Awake with lid closed" on.** It stays on at full power and will get hot and drain the battery. Turn it off before you pack up.
- The lid-closed setting survives quitting the app. Use **Everything OFF** or `sudo pmset -a disablesleep 0` to restore normal sleep.
- Lock-on-reopen uses the same private system call as ⌃⌘Q. If a future macOS removes it, the app falls back to putting the display to sleep, which locks if "Require password after display is turned off" is set in Lock Screen settings.
