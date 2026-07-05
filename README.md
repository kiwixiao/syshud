# syshud

A tiny macOS overlay that shows live system usage as background text at the
top-right of your screen:

    CPU 23%   GPU 8%   RAM 61%

- Updates every second, using the same kernel counters Activity Monitor reads.
- Fully click-through and not selectable — it never blocks your mouse.
- No Dock icon, no menu bar icon, no window chrome.
- Builds with the free Apple Command Line Tools. No Xcode, no paid Apple
  Developer account.

## Current setup on this Mac (as of 2026-07-05)

- syshud is **installed as a login item** and runs in **front mode** (always
  on top): the LaunchAgent `~/Library/LaunchAgents/local.syshud.plist` runs
  `~/monitoring/syshud front` at every login. It shows up in
  **System Settings → General → Login Items & Extensions**.
- The cheat sheet (run from `~/monitoring`):

```bash
./autostart.sh status          # is auto-start installed? is syshud running?
pkill syshud                   # hide the overlay until next login
./autostart.sh install front   # (re)start now + keep front mode at login
./autostart.sh install back    # switch to behind-windows mode instead
./autostart.sh uninstall       # permanent off: stop + remove login item
```

- Remember: `pkill syshud` is temporary — the login item brings it back at
  the next login. `./autostart.sh uninstall` is the permanent stop.
- Front mode draws over full-screen apps too (e.g. during presentations or
  video). If that bothers you, switch with `./autostart.sh install back`.

## Quick start

```bash
./build.sh          # compile (only needed once, or after editing syshud.swift)
./syshud &          # start in the default "back" mode
```

To stop it at any time:

```bash
pkill syshud
```

## The two display modes

| Command | Mode | Behavior |
|---------|------|----------|
| `./syshud &` | **back** (default) | Text sits just above the wallpaper and desktop icons, **behind all windows**. You see it whenever that corner of the desktop is visible. |
| `./syshud front &` | **front** | Text floats **above every window**, including full-screen apps, and follows you across Spaces. Clicks still pass straight through it. |

`back`/`--back` and `front`/`--front` are both accepted.

## Start automatically at login

```bash
./autostart.sh install front   # auto-start in front mode (starts it now too)
./autostart.sh install back    # or auto-start in back mode
./autostart.sh status          # is the auto-start installed? is syshud running?
./autostart.sh uninstall       # stop syshud and remove the auto-start
```

This installs a per-user LaunchAgent at
`~/Library/LaunchAgents/local.syshud.plist` — no admin rights needed. macOS
lists it under **System Settings → General → Login Items & Extensions**. The
agent points at the `syshud` binary in this folder, so if you move the folder,
run `./autostart.sh install <mode>` again.

Note: `pkill syshud` stops the overlay until the next login; the LaunchAgent
starts it again when you log back in. To stop it permanently, use
`./autostart.sh uninstall`.

## Check stats from the terminal

```bash
./syshud --sample
```

Prints one stats line and exits — handy for scripts or a quick look over SSH.

## How the numbers are computed

- **CPU** — busy ÷ total tick deltas across all cores
  (`host_processor_info`), sampled over the refresh interval.
- **RAM** — Activity Monitor's "Memory Used": app memory + wired +
  compressed (`host_statistics64`), as % of physical RAM.
- **GPU** — `Device Utilization %` from the graphics driver's
  `PerformanceStatistics` in the IORegistry (Apple Silicon `AGXAccelerator`).

A metric that can't be read shows `–` instead of a number; the overlay keeps
running.

## Troubleshooting

- **I don't see the text (back mode)** — a window is covering that corner;
  back mode draws behind windows by design. Reveal the desktop or use
  `front` mode.
- **Two overlays after login** — you launched one manually while the
  LaunchAgent was installed. `pkill syshud` kills all of them; the agent
  relaunches one at next login.
- **After a macOS update the build fails** — reinstall the toolchain with
  `xcode-select --install`, then `./build.sh`.
