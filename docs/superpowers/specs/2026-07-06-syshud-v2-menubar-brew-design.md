# syshud v2 — Menu Bar Mode + Homebrew Distribution

**Date:** 2026-07-06
**Status:** Approved by user (GitHub: kiwixiao)
**Builds on:** 2026-07-05-syshud-design.md (v1 overlay, shipped)

## Purpose

Make syshud a minimal GUI-ish app: it lives in the menu bar by default, can
swap its display to the desktop overlay (freeing menu bar space), and is
installable on any Mac with `brew install kiwixiao/tap/syshud` — still with no
paid Apple Developer account.

## Requirements (user-confirmed)

1. **Three mutually exclusive display modes** — the stats are shown in exactly
   one place at a time:
   - `menubar` (new default): live stats in the menu bar; no desktop overlay.
   - `front`: desktop overlay above all windows; **no menu bar item at all**.
   - `back`: desktop overlay behind windows; **no menu bar item at all**.
   The full hide in overlay modes is deliberate (user chose it over a
   shrunken icon) — it frees menu bar space; switching back is CLI-only.
2. **Menu bar mode content**: compact monospaced `12 8 61` (CPU GPU RAM
   percents, no % signs, `–` for a failed metric). Dropdown menu: three
   labeled live rows (`CPU 12%` / `GPU 8%` / `RAM 61%`, non-clickable),
   separator, `Show Overlay (Front)`, `Show Overlay (Back)`, separator,
   `Quit syshud`.
3. **Live switching between all three modes**, no restart:
   - In menu bar mode: via the dropdown menu.
   - From the terminal (works in any mode): `syshud set menubar|front|back`.
   - `syshud toggle` keeps flipping front↔back (no-op in menubar mode).
4. **No duplicate instances**: launching `syshud [mode]` while one is already
   running forwards the mode to the running instance instead of starting a
   second copy.
5. **Distribution**: public GitHub repo `kiwixiao/syshud` (MIT license) +
   public tap repo `kiwixiao/homebrew-tap` with `Formula/syshud.rb`. The
   formula compiles from source with `swiftc` on the user's machine (no
   signing/notarization) and provides a `service` block so
   `brew services start syshud` handles login auto-start (menubar mode).
6. Everything from v1 still holds: 1 s refresh, accuracy vs Activity Monitor,
   click-through unselectable overlay, `--sample`, no Dock icon.

## Architecture (single file `syshud.swift`, refactored)

- `struct Stats { cpu, gpu, ram: Double? }` + free formatters:
  `statsLine(Stats)` (v1 overlay/`--sample` format, unchanged) and
  `menubarTitle(Stats)` (`"12 8 61"`).
- `StatsSampler` — unchanged internals; gains `sample() -> Stats`.
- `OverlayController` — display-only now (no timer/sampler): `show()`,
  `hide()`, `setLevel(front:)`, `update(Stats)`. Window config as v1.
- `StatusItemController` — new: `NSStatusItem` (variable length,
  monospaced-digit font), dropdown menu per requirement 2, `update(Stats)`,
  `remove()`. Menu actions call back into the coordinator.
- `AppCoordinator` — owns the sampler, the single 1 s timer, and the current
  `DisplayMode`; creates/destroys the two display controllers on mode
  switches; observes `DistributedNotificationCenter` name
  `local.syshud.command` (object = `"menubar"|"front"|"back"|"toggle"`).
- **IPC change**: distributed notifications replace v1's SIGUSR1 (a signal
  can only express a binary toggle; we now have three targets).
- Activation policy `.accessory` (was `.prohibited`) — required for a usable
  status item menu; still no Dock icon.

## CLI surface

```
syshud                  start (menubar mode) — or forward to running instance
syshud menubar|front|back   start in that mode — or forward if running
syshud set <mode>       live-switch the running instance (error if none)
syshud toggle           live flip front <-> back (overlay modes only)
syshud --sample         print one stats line and exit
```

`autostart.sh install [menubar|front|back]` — default becomes `menubar`.

## Distribution details

- `LICENSE`: MIT, copyright 2026 kiwixiao.
- Repo `kiwixiao/syshud` pushed from this project, tagged `v1.0.0`.
- Formula: `url` = GitHub tag tarball, `sha256` computed from the download,
  `system "swiftc", "-O", ...` in `install`, `bin.install "syshud"`,
  `service do run [opt_bin/"syshud", "menubar"]; keep_alive false end`,
  `test` runs `syshud --sample` and matches `/CPU .+GPU .+RAM /`.
- `gh auth login` is required once (interactive; user performs it).

## Testing (evidence-based, as v1)

1. `--sample` format regression after refactor.
2. Window-server checks (`CGWindowListCopyWindowInfo`): menubar mode → one
   syshud window at status-bar layer (25), no overlay window; front → layer
   1000 only; back → desktop-icon+1 layer only.
3. `syshud set` round-trip through all three modes on one PID.
4. Duplicate-launch forwarding: second `syshud front` switches the running
   instance, process count stays 1.
5. Menu interaction (dropdown switch to overlay): user-verified visually.
6. Final: real `brew install kiwixiao/tap/syshud` + `syshud --sample` from
   the brew binary.

## Out of scope

Config file, hotkeys, multi-monitor options, brew bottles (prebuilt
binaries), cask, notarization.
