# Architecture

SMC Fan is a small project on purpose: a C core, a C daemon and a SwiftUI app, built with one shell script and no package manager. This document explains how the pieces fit together and why they're built the way they are.

## Repository layout

```text
App/          SwiftUI menu bar app and dashboard
Core/         C: SMC access (smc.c) and the CPU stress engine (stress.c)
Daemon/       C: smcfan, the command-line tool that is also the root daemon
Resources/    Info.plist, install/uninstall scripts, bridging header, translations (*.lproj)
Scripts/      icon generator, packaging, localization check
docs/         this documentation and the README images
build.sh      builds everything into build/
```

## Components

### Core/smc.c — talking to the SMC

The System Management Controller is reached through the IOKit user client of the `AppleSMC` service, with `IOConnectCallStructMethod` (selector 2) and an 80-byte parameter struct. Four commands are used:

| Command | Value | Purpose |
|---|---|---|
| read key info | 9 | size and type of a key |
| read bytes | 5 | read a key's value |
| write bytes | 6 | write a key's value (root only) |
| key at index | 8 | enumerate all keys |

Key info never changes at runtime, so it is cached in a small open-addressing hash table (1024 slots). That halves the number of kernel calls per reading, which matters because the app reads ~110 temperature sensors per cycle. The cache is not thread-safe: both the app and the daemon use the SMC from a single thread or serial queue.

`smc_to_double` decodes the numeric types found on Apple Silicon: `flt ` (little-endian float — most sensors, fans and power), `ui8 `, `ui16`, `ui32`, `flag`, and the older fixed-point `sp78` and `fpe2`.

### Daemon/smcfan.c — the control loop

One binary, several roles: `status` and `keys` for anyone, and `run`, `daemon` and `auto` for root. The control loop:

1. **Start**: take an exclusive `flock` on `/var/run/smcfan.lock` (a refused second instance exits without touching the fans), then hand all fans back to macOS to start from a known state.
2. **Every 2 seconds**:
   - reload the config file if its modification time changed;
   - read all CPU (`Tp*`) and GPU (`Tg*`) sensors and take the hottest;
   - smooth it with an exponential moving average (factor 0.3);
   - decide: take over at or above `takeover`, keep control until below `release` (hysteresis), always for `max`, never for `off`;
   - when in control, set manual mode and the target speed for every fan — every cycle, because the SMC may fall back to automatic after sleep.
3. **Stop** (SIGTERM from launchd, SIGINT, SIGHUP): hand the fans back to macOS *before* closing the SMC connection.

The fan percentage comes from the curve:

- above the first point: linear interpolation between the points;
- between `release` and the first point: a linear ramp from 0% to the first point's percentage, so the fans settle gradually after a load;
- 0% means the fan's minimum speed (`F*Mn`), 100% its maximum (`F*Mx`).

On M5-generation Macs manual mode is `F*md`; earlier Apple Silicon uses `F*Md` and may require `Ftst = 1` before it accepts manual mode. The daemon detects which keys exist and only sets `Ftst` if a mode write is refused. It resets `Ftst` when releasing the fans.

### Config file

`/Library/Application Support/SMCFan/config` is owned by the user (so the app can write it without a password) and read by the root daemon. One setting per line; unknown lines are ignored:

```text
profile=balanced      for humans and the app; ignored by the daemon
mode=curve            off | curve | max
takeover=65
release=60
point=65:30           temperature (°C) : percentage
point=75:60
point=85:100
```

The app writes it atomically (write to a temporary file, then rename), so the daemon never reads a half-written file.

### The app

| File | Role |
|---|---|
| `SMCFanApp.swift` | App entry, the dashboard `Window` and the `MenuBarExtra`, the menu bar label, formatting helpers |
| `SensorMonitor.swift` | Reads SMC sensors and battery data on a background queue and publishes one snapshot per cycle |
| `SettingsStore.swift` | Profiles, curves, and writing the config file |
| `CoreLoad.swift` | CPU topology (core types and clusters), per-core load and GPU utilization |
| `HelperManager.swift` | Installs/updates/removes the daemon and detects whether it runs (by testing its lock) |
| `StressTest.swift` | CPU and GPU load, scores, results |
| `DashboardView.swift` | The dashboard |
| `MenuBarView.swift` | The menu bar panel |
| `Localization.swift` | `tr()`, the single entry point for translated strings |

**Installing the daemon.** `HelperManager` runs `Resources/install.sh` as root through `NSAppleScript`'s `do shell script … with administrator privileges`, which shows the standard password prompt. The script copies the bundled `smcfand` to `/Library/PrivilegedHelperTools`, creates the config directory owned by the user, writes the LaunchDaemon plist and bootstraps it. `SMAppService` daemons were not used because they require a Developer ID–signed app.

**Detecting updates.** The app compares its bundled `smcfand` byte-for-byte with the installed one and offers **Update** when they differ.

### Staying lightweight

A menu bar utility runs all day, so every idle cycle counts:

- **One published value per cycle.** `SensorMonitor` publishes a single `Snapshot` instead of many properties, so views re-render once per reading.
- **Adaptive polling.** 5 s when only the menu bar is visible, 2 s with the dashboard open or a stress test running. Timers have a tolerance so macOS can coalesce wake-ups.
- **The dashboard draws nothing while hidden.** SwiftUI keeps a closed `Window` alive, and Swift Charts kept redrawing every 2 s in the background (about 3% CPU and 180 MB). `WindowState` tracks the window's visibility (close, occlusion, key status) and swaps the content for `Color.clear` while it isn't visible.
- **The menu bar item only redraws when its text changes.** The label content is `Equatable`; every redraw makes macOS re-render the status item as a bitmap for every display.
- **Battery data is read key by key** with `IORegistryEntryCreateCFProperty` instead of copying the battery's whole property dictionary.
- **Metal is loaded only during a GPU test** and released afterwards.

### Core layout and load

Apple Silicon chips mix core types, and the mix differs per generation: M1–M4 have Performance and Efficiency cores, the M5 has Super and Performance cores, and Ultra chips have more clusters of each. `CPUTopology.read()` works it out at launch without hard-coding chips:

1. **Core types** come from `sysctl`: `hw.nperflevels`, and per level `hw.perflevelN.name` (for example "Super"), `.logicalcpu` and `.cpusperl2`. Level 0 is the fastest.
2. **Which core is which** comes from the device tree (`IODeviceTree:/cpus/cpuN`): every CPU has a `logical-cpu-id`, a `logical-cluster-id` and a `cluster-type` letter — `P` for the fastest cluster type, `M` for the middle one on the M5, `E` for efficiency. Ranked P → M → E, the letters line up with the perflevels; the counts are checked to match.
3. **Fallback**: if the device tree can't be read or doesn't match, cores are assigned by number — macOS numbers the slowest cores first — and split into clusters of `cpusperl2`.

On the 14" M5 Max this yields 6 Super cores (cpu12–17, cluster type `P`) and 12 Performance cores in two clusters (cpu0–11, type `M`).

**Per-core load** comes from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`: one Mach call returns user/system/idle/nice tick counters for every logical CPU, and load is the non-idle share of the ticks since the previous reading. The processor index equals the `logical-cpu-id`. **GPU utilization** is `Device Utilization %` from the `IOAccelerator` service's `PerformanceStatistics`; the core count is its `gpu-core-count` property.

Both are read on the sensor queue in the same cycle as the temperatures, so they add no timers or wake-ups.

### Stress test

- **CPU** (`Core/stress.c`): one pthread per active core at `QOS_CLASS_USER_INITIATED`, each computing 16 independent FMA chains so every floating-point unit stays busy. Each thread counts completed blocks in its own cache line; the app turns blocks per second into GFLOPS.
- **GPU** (`App/StressTest.swift`): a Metal compute kernel with four FMA chains per thread over 4M threads, with two command buffers in flight. Completed dispatches per second become TFLOPS.
- **Throttling** is the drop from the average score in seconds 3–10 to the average over the last 20% of the test.

### Adapter shortfall detection

The battery reports voltage and instantaneous current; their product is the battery power (negative while discharging). A shortfall is reported when the adapter is connected, the battery discharges at 1 W or more, **and** the system draws more than the adapter delivers (`PSTR > PDTR`). That last condition filters out the battery briefly helping out at low load. Because the battery current lags a few seconds behind, the reported shortfall is the larger of the battery power and `PSTR − PDTR`. Two readings in a row are needed to show the warning and two to clear it.

## Localization

Every user-facing string goes through `tr("English text", args...)`. The English text is the key; translations live in `Resources/<lang>.lproj/Localizable.strings`. Placeholders are always `%@` with string arguments; translations may reorder them with `%1$@`, `%2$@`.

`Scripts/check_localization.py` finds every `tr(...)` call and fails when a translation is missing or has a different number of placeholders. CI runs it on every push.

## Why no Xcode project?

The project builds with nothing but the Command Line Tools, which keeps it easy to audit and to build. One consequence: the Command Line Tools don't ship the SwiftUI macro plugins, so the code avoids `@State` (it uses small `ObservableObject`s with `@StateObject` instead) and other macro-based APIs such as `@Observable`.
