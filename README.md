# syshud

A minimal macOS system monitor. Live CPU, GPU, and RAM usage shown in exactly
one place at a time — your choice:

- **Menu bar mode** (default): compact `12 8 61` in the menu bar, with a
  dropdown for details and controls.
- **Overlay mode**: a line of click-through text at the top-right of your
  screen — `CPU 23%   GPU 8%   RAM 61%` — either in front of all windows or
  behind them. In overlay mode there is **no menu bar item at all**, so your
  menu bar space is freed.

Updates every second using the same kernel counters Activity Monitor reads.
No Dock icon. Builds with the free Apple Command Line Tools — no Xcode, no
paid Apple Developer account.

## Install

With Homebrew:

```bash
brew install kiwixiao/tap/syshud
brew services start syshud       # optional: auto-start at login (menu bar mode)
```

The formula compiles from source on your machine in about 30 seconds — no
Gatekeeper warnings, since locally built binaries are never quarantined.

Requirements:

- Homebrew (which already ships the Command Line Tools the build needs).
- macOS 12 or newer.
- Apple Silicon or Intel. On Intel, the GPU metric depends on what the
  graphics driver exposes — if `Device Utilization %` is unavailable, GPU
  shows `–` and CPU/RAM keep working.

To remove: `brew services stop syshud && brew uninstall syshud`.

Or from source:

```bash
git clone https://github.com/kiwixiao/syshud
cd syshud && ./build.sh
./autostart.sh install           # optional: auto-start at login
```

## Current setup on this Mac (as of 2026-07-06)

- syshud is installed as a login item in **menubar mode** via the LaunchAgent
  `~/Library/LaunchAgents/local.syshud.plist` (managed by `./autostart.sh`
  from `~/monitoring`). It shows in **System Settings → General → Login
  Items & Extensions**.
- Cheat sheet (from `~/monitoring`):

```bash
./syshud set front       # live-switch: overlay above windows (menu bar item disappears)
./syshud set back        # live-switch: overlay behind windows
./syshud set menubar     # live-switch: back to the menu bar numbers
./syshud toggle          # flip front <-> back while in overlay mode
./autostart.sh status    # is auto-start installed? is syshud running?
./autostart.sh install front   # change the at-login mode
./autostart.sh uninstall # permanent off: stop + remove login item
pkill syshud             # stop until next login
```

## The three modes

| Mode | Menu bar | Desktop |
|------|----------|---------|
| `menubar` (default) | live `12 8 61` + dropdown menu | nothing |
| `front` | nothing | stats text above every window, follows all Spaces |
| `back` | nothing | stats text behind windows, above the wallpaper |

The overlay is fully click-through and not selectable in both overlay modes.

## Switching modes (no restart needed)

- **In menu bar mode**: click the numbers → *Show Overlay (Front)* or
  *Show Overlay (Back)*.
- **From the terminal** (the only way back from overlay modes, since the menu
  bar item is gone): `syshud set menubar|front|back`, or `syshud toggle` to
  flip front/back.
- Running `syshud front` (etc.) while an instance is already running does not
  start a second copy — it forwards the mode to the running instance.

## CLI reference

```
syshud                   start in menu bar mode (or forward if running)
syshud menubar|front|back  start in that mode (or forward if running)
syshud set <mode>        live-switch the running instance
syshud toggle            flip front <-> back (overlay modes only)
syshud --sample          print one stats line and exit
```

## Start at login

- **Homebrew installs**: `brew services start syshud` / `brew services stop syshud`.
- **Source checkouts**: `./autostart.sh install [menubar|back|front]`,
  `./autostart.sh uninstall`, `./autostart.sh status`. Installs a per-user
  LaunchAgent — no admin rights.
- Use one mechanism, not both, or two copies will race at login.
- `pkill syshud` stops it until next login; `uninstall` (or
  `brew services stop`) is the permanent off switch.

## Project layout

| Path | What it is |
|------|------------|
| `syshud.swift` | The entire app — one file, ~450 lines |
| `build.sh` | Compiles it: `swiftc -O -o syshud syshud.swift` |
| `autostart.sh` | Installs/removes the login LaunchAgent (source installs) |
| `docs/superpowers/specs/` | Design documents (why things are the way they are) |
| `docs/superpowers/plans/` | Implementation plans with verification steps |
| github.com/kiwixiao/homebrew-tap | **Separate repo**: `Formula/syshud.rb`, what `brew install kiwixiao/tap/syshud` reads |

## How it works inside (one paragraph)

`StatsSampler` reads the kernel counters. An `AppCoordinator` owns a 1-second
timer and the current mode; it feeds each sample to either a
`StatusItemController` (the `NSStatusItem` in the menu bar) or an
`OverlayController` (a borderless, click-through `NSWindow`) — never both.
`syshud set <mode>` works from another process via a macOS distributed
notification named `local.syshud.command`; a freshly launched `syshud` that
detects a running instance forwards its mode the same way instead of starting
a duplicate. Two hard-won gotchas: UI must be created in
`applicationDidFinishLaunching` (a status item made before `app.run()`
silently never appears), and on macOS 26 status-item windows are hosted by
Control Center's process, so you can't find them in the window list by owner
name.

## Making changes and releasing a new version

```bash
# 1. develop
vim syshud.swift && ./build.sh && ./syshud --sample   # quick correctness check
pkill syshud && ./syshud &                            # try it live

# 2. release (from this repo)
git tag v1.0.1 && git push origin main v1.0.1

# 3. update the formula (in the homebrew-tap repo)
curl -sL https://github.com/kiwixiao/syshud/archive/refs/tags/v1.0.1.tar.gz | shasum -a 256
#   edit Formula/syshud.rb: bump the url version and paste the new sha256
git commit -am "syshud 1.0.1" && git push

# 4. any machine updates with
brew update && brew upgrade syshud
```

## How the numbers are computed

- **CPU** — busy ÷ total tick deltas across all cores
  (`host_processor_info`), sampled over the refresh interval.
- **RAM** — Activity Monitor's "Memory Used": app memory + wired +
  compressed (`host_statistics64`), as % of physical RAM.
- **GPU** — `Device Utilization %` from the graphics driver's
  `PerformanceStatistics` in the IORegistry (Apple Silicon `AGXAccelerator`).

A metric that can't be read shows `–`; the app keeps running.

## Troubleshooting

- **I don't see the numbers in the menu bar** — your menu bar may be full
  (notch Macs hide overflow items). Switch to overlay mode:
  `syshud set front`.
- **I don't see the overlay text (back mode)** — a window is covering that
  corner; back mode draws behind windows by design.
- **Menu bar item gone and I forgot the command** — `syshud set menubar`.
- **After a macOS update the build fails** — `xcode-select --install`, then
  `./build.sh`.
