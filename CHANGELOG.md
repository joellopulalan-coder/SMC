# Changelog

All notable changes to SMC Fan are listed here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [semantic versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-01

The first public release.

### Added

- Fan control for Apple Silicon MacBooks through a root LaunchDaemon (`smcfand`) with five profiles: macOS, Balanced, Performance, Maximum and Custom.
- Custom fan curve editor with takeover threshold, three curve points and a live preview.
- Hysteresis, temperature smoothing and a smooth ramp-down to minimum speed after a load.
- Dashboard with CPU/GPU temperatures, fan speeds, power and 5 minutes of history.
- Power monitoring: system power, adapter input and rating, battery percentage and charge/discharge rate.
- Adapter shortfall warning when the Mac draws more than the adapter delivers.
- Configurable menu bar item: temperature, fan speed, profile icon, power draw, charging/discharging, battery percentage.
- Stress test and benchmark for CPU, GPU or both, with GFLOPS/TFLOPS scores, thermal-throttling percentage and a results history.
- `smcfan` command-line tool: `status`, `keys`, `run`, `daemon`, `auto`, `version`.
- English and Dutch localization.
- Experimental support for the `F*Md` fan mode key and `Ftst` unlock used by M1–M4 Macs.

### Performance

- About 1% CPU and 50 MB with only the menu bar visible; the background service uses about 0.2% CPU and under 2 MB.

[Unreleased]: https://github.com/joellopulalan-coder/SMC/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/joellopulalan-coder/SMC/releases/tag/v1.0.0
