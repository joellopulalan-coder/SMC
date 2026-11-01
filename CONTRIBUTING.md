# Contributing to SMC Fan

Thanks for helping out! Hardware reports, translations, bug reports and code are all welcome.

## Hardware reports

SMC Fan was developed on one Mac (14" M5 Max). Reports from other Macs are the most useful contribution right now. Open a [hardware report](https://github.com/joellopulalan-coder/SMC/issues/new?template=hardware_report.yml) and include:

- the output of `sysctl -n hw.model machdep.cpu.brand_string` and `sw_vers`;
- `smcfan keys F` (fan keys) and `smcfan status`;
- whether profiles work: does the dashboard show "SMC Fan" on the fan cards under load, and what does `/var/log/smcfan.log` say?

See [docs/SMC.md](docs/SMC.md) for what the keys mean.

## Development setup

```bash
xcode-select --install
```
```bash
git clone https://github.com/joellopulalan-coder/SMC.git && cd SMC && ./build.sh
```

`./build.sh install` also copies the app to `/Applications`. After changing anything in `Daemon/` or `Core/smc.c`, the dashboard shows **Update** for the background service; click it to install your new daemon.

You can run the control loop in the foreground while developing:

```bash
sudo launchctl bootout system/local.smcfan
```
```bash
sudo build/smcfan run
```

Press Ctrl-C to stop; the fans go back to macOS. Re-install the service from the app afterwards.

## Code style

- Match the surrounding code: naming, comment density and idioms.
- Comments and identifiers are in English.
- Keep it light. SMC Fan runs all day; every timer, redraw and allocation in the idle path counts. Measure with `top -pid $(pgrep -x SMCFan)` before and after.
- No external dependencies, and the project must keep building with only the Command Line Tools. That rules out SwiftUI macros such as `@State` and `@Observable` (see [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#why-no-xcode-project)).
- C code compiles warning-free with `-Wall -Wextra`.

## Localization

All user-facing strings go through `tr("English text", args...)`:

```swift
Text(tr("Fan %@", "\(fan.id + 1)"))
```

- The English text is the key. Use `%@` placeholders with `String` arguments only.
- Add the translation to every `Resources/<lang>.lproj/Localizable.strings`. Translations may reorder placeholders with `%1$@`, `%2$@`.
- Run the check, which CI also runs:
  ```bash
  python3 Scripts/check_localization.py
  ```

### Adding a language

1. Copy `Resources/nl.lproj` to `Resources/<code>.lproj` (for example `de.lproj`) and translate both files in it.
2. Add the code to `CFBundleLocalizations` in `Resources/Info.plist`.
3. Run the check, build, and test with:
   ```bash
   open -n "build/SMC Fan.app" --args -AppleLanguages "(de)"
   ```

`python3 Scripts/check_localization.py --list` prints every key in the source.

## Pull requests

- One topic per PR, with a short description of what and why.
- Run `./build.sh` and `python3 Scripts/check_localization.py`.
- If you touched the fan control: describe how you tested it (which Mac, which profile, what the fans did).
- If you changed the UI: add a screenshot.
- Add a line to the *Unreleased* section of [CHANGELOG.md](CHANGELOG.md).

## Releasing (maintainers)

1. Update `VERSION` and move the *Unreleased* changelog entries under the new version.
2. Commit, then tag and push: `git tag v1.2.3 && git push origin v1.2.3`.
3. The release workflow builds the app, zips it and publishes a GitHub release with the changelog section and checksum.

## Code of conduct

Be kind and constructive. Harassment or personal attacks aren't tolerated; maintainers may remove comments, issues or contributors that don't follow this.
