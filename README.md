# syshud

A tiny macOS overlay that shows live system usage as background text at the
top-right of your screen:

    CPU 23%   GPU 8%   RAM 61%

- Fully click-through and not selectable in both modes.
- Updates every second, using the same kernel counters Activity Monitor reads.
- No Dock icon, no menu bar icon. No Xcode or Apple Developer account needed.

## Build

    ./build.sh

Requires only the free Apple Command Line Tools (`xcode-select --install`).

## Run

    ./syshud &          # default: back mode — behind windows, above wallpaper
    ./syshud front &    # front mode — always on top, even over full-screen apps

## Stop

    pkill syshud

## Check stats from the terminal

    ./syshud --sample

Prints one stats line and exits.

## How the numbers are computed

- **CPU** — busy ÷ total tick deltas across all cores
  (`host_processor_info`), sampled over the refresh interval.
- **RAM** — Activity Monitor's "Memory Used": app memory + wired +
  compressed (`host_statistics64`), as % of physical RAM.
- **GPU** — `Device Utilization %` from the graphics driver's
  `PerformanceStatistics` in the IORegistry.
