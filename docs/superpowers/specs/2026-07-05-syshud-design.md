# syshud — System Usage Overlay for macOS

**Date:** 2026-07-05
**Status:** Approved by user

## Purpose

A lightweight macOS tool that displays live system usage (CPU, GPU, RAM) as a
single line of non-interactive text at the top-right corner of the main screen.
Launched once from the command line, it keeps running in the background with no
Dock icon and no menu bar icon. No paid Apple Developer account required.

## Requirements (user-confirmed)

- Two layering modes, chosen by a launch argument:
  - **`back` (default)** — text sits at desktop level, just above the
    wallpaper and desktop icons, **behind all normal windows** (GeekTool
    style). `./syshud` with no argument uses this.
  - **`front`** — text floats **above all windows**, including full-screen
    apps. Launched as `./syshud front`.
- Overlay is **fully click-through**: not selectable, never intercepts mouse
  events.
- Default position: **top-right corner** of the main screen, just below the
  menu bar.
- Format: one compact line — `CPU 23%   GPU 8%   RAM 61%` — refreshed every
  1 second.
- Stats must closely match Activity Monitor.
- Control is **pure CLI**: start with `./syshud` (back mode) or
  `./syshud front`; stop with `pkill syshud`. No visible presence besides
  the text.
- Build with free Apple Command Line Tools only (`swiftc`); no Xcode project,
  no code-signing certificate.

## Architecture

One Swift source file (`syshud.swift`) compiled by `build.sh` into a single
binary `syshud`. Two logical units inside the file:

### 1. StatsSampler

Reads all three metrics once per second. Every metric fails independently — a
failed read renders as `–` for that field only; the app never exits on a bad
sample.

- **CPU** — `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`. Keep the previous
  tick counters; usage = (busy-tick delta) / (total-tick delta) summed across
  all cores, shown 0–100 %. Same kernel counters Activity Monitor uses.
- **RAM** — `host_statistics64(HOST_VM_INFO64)`. Used = (active + wired +
  compressed pages) × page size; shown as % of `ProcessInfo.physicalMemory`.
  Mirrors Activity Monitor's "Memory Used".
- **GPU** — IOKit registry: match service class `IOAccelerator`
  (`AGXAccelerator` on Apple Silicon), read the `PerformanceStatistics`
  dictionary key `Device Utilization %`. No root, no TCC permissions.

### 2. Overlay window

- Borderless `NSWindow`, `backgroundColor = .clear`, `isOpaque = false`,
  `hasShadow = false`.
- Window level depends on mode:
  - `back` (default): `CGWindowLevelForKey(.desktopIconWindow) + 1` — above
    wallpaper and desktop icons, below every normal window.
  - `front`: `.screenSaver` — floats above normal and full-screen windows.
- `ignoresMouseEvents = true` — clicks pass through; text is unselectable.
- `collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary,
  .ignoresCycle]` — follows every Space, ignored by Mission Control cycling.
- Content: one `NSTextField` label, monospaced-digit system font (~12 pt),
  white text with a dark shadow for readability on light and dark backgrounds.
- Position: top-right of `NSScreen.main.visibleFrame` (visibleFrame already
  excludes the menu bar) with a small margin. Re-position on
  `NSApplication.didChangeScreenParametersNotification` (display changes).

### App lifecycle

- `NSApplication` with activation policy `.prohibited`: no Dock icon, no menu
  bar entry, never takes focus.
- A 1-second `Timer` on the main run loop drives sample → format → update.
- Start: `./syshud &` (or via `nohup`). Stop: `pkill syshud`.

## Files

| File | Purpose |
|------|---------|
| `syshud.swift` | Entire app (~300 lines) |
| `build.sh` | `swiftc -O` build producing `./syshud` |
| `README.md` | Build, run, stop instructions |

## Testing (manual verification)

1. Build with `build.sh`; binary launches with no Dock/menu bar presence.
2. Text appears top-right, below menu bar, updating every second.
3. Load test: run `yes > /dev/null` (and a GPU load if available); compare
   CPU/GPU/RAM values side-by-side with Activity Monitor — should track within
   a few percent.
4. Click-through: click a window's button located under the text — the click
   must reach the window.
5. Layering: in default `back` mode a window dragged over the corner covers
   the text; in `front` mode switch Spaces and enter a full-screen app — the
   text stays visible on top.
6. `pkill syshud` removes the overlay cleanly.

## Out of scope (v1)

Multi-monitor placement options, config file, login auto-start (LaunchAgent),
menu bar controls. All are straightforward follow-ups.
