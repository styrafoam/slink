# slink

A small macOS menu-bar utility for experimenting with local mouse-button sampling schedules.

slink checks the current state of the left and right mouse buttons. A sample is one check; faster sampling means this utility checks more often. Observed press transitions are counted in memory. The app also checks whether the active application has a focused window, retaining only a yes/no result.

The spring icon in the menu bar is the entire interface. There is no app window, Dock icon, or Command-Tab entry. Observations are not displayed or saved.

## Menu

| Option | What it does |
| --- | --- |
| Refresh | Immediately rechecks permission, focused-window availability, and mouse-button state. |
| Prioritize Heating | Requests checks every 1 ms, interactive scheduling priority, and a latency-critical process activity. This can increase CPU use and power consumption. |
| Prioritize Cooling | Requests checks every 32 ms, utility scheduling priority, and more flexible timer delivery. This reduces the utility's sampling work. |
| Quiet mode | Ends special process activity and restores the default 8 ms sampling schedule. Sampling continues. |
| Quit | Stops sampling, ends process activity, and exits. |

These settings affect slink's own sampling work. They do not change system-wide input delay, device responsiveness, fan speed, or macOS's global timer resolution. Timer intervals are scheduling requests, not exact delivery guarantees. Changes do not produce alerts or mode indicators.

Startup uses the default schedule. Sleep or session lock pauses observation and clears special scheduling activity; waking resumes the default schedule. No login item is installed.

## Privacy and permissions

Enable **Accessibility** for slink in System Settings. On some macOS versions this permission is labeled **Device Control and Data Access**. Add `build/slink.app` manually if needed. slink checks authorization but does not open Settings or request permission through a dialog.

The permission is used to query whether a focused-window reference exists. Without permission, mouse sampling and focused-window queries are skipped; the menu and authorization checks continue. A separate Input Monitoring grant is not requested.

slink reads mouse-button state and retains counters only in memory. It does not read typed text, window titles, document contents, or cursor positions. It does not generate input, intercept events, or alter other applications. There is no network access, analytics, persistent input log, or background helper.

## Build and run

Requires macOS 13 or later, Xcode command-line tools, and Python 3. The build downloads no dependencies and produces a universal Apple Silicon/Intel app with an ad-hoc signature.

```sh
./test.sh
./build.sh
open build/slink.app
```

Alternatively, open `Open slink.command`; it builds the app if needed. Quit a running copy before opening a replacement.

The bundle identifier is `local.slink.sampling`.

## Packaging and verification

Packaging uses fixed byte budgets from `size-targets.json`:

| Artifact | Logical bytes |
| --- | ---: |
| Universal executable | 2,963,648 |
| App bundle | 3,657,580 |
| ZIP archive | 904,793 |

Inert padding is used to reach these budgets. The app does not read or execute that padding. [Packaging details](Tools/PACKAGING.md) explain the design, signature checks, and archive limitations. Build outputs and generated reports are excluded from version control.

```sh
python3 Tools/verify_app.py
python3 Tools/test_packaging.py
```

Verification checks both CPU architectures, signatures, menu-only startup, supported runtime imports, packaged diagnostics, file hashes after extraction, and ZIP recompression. It does not claim a live Dock or app-switcher inspection. `build/slink.app/Contents/MacOS/slink --self-check` prints sampling settings without starting the menu-bar interface.
