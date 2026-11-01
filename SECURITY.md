# Security

## What runs with elevated rights

SMC Fan installs one root process: `/Library/PrivilegedHelperTools/smcfand`, started by launchd from `/Library/LaunchDaemons/local.smcfan.plist`. Both files are owned by root and not writable by other users.

The daemon:

- only **writes** fan keys to the SMC (`F*md`/`F*Md` mode, `F*Tg` target speed, and `Ftst` on older Macs);
- **reads** one config file, `/Library/Application Support/SMCFan/config`, which the logged-in user may write. Only `mode`, `takeover`, `release` and up to eight `point` lines are recognized; lines are read with a fixed-size buffer and parsed with bounded `sscanf` formats. Anything else is ignored;
- opens no network connections and accepts no other input.

The worst a malicious edit of the config file can do is choose fan speeds — something the user can already do through the app. Apple's thermal protection keeps working regardless.

The app runs as the user. It asks for administrator rights only when you click **Install**, **Update**, **Restart** or **Remove**, using the standard macOS password prompt, and only to run the bundled `install.sh` or `uninstall.sh`.

## Downloads

Release builds are ad-hoc signed, not notarized. Every release lists a SHA-256 checksum. If you'd rather not trust a binary, build from source with `./build.sh` — it's one script and a few hundred lines of C and Swift.

## Reporting a vulnerability

Please report security issues privately through [GitHub's private vulnerability reporting](https://github.com/joellopulalan-coder/SMC/security/advisories/new) rather than in a public issue. You can expect a first response within a week.
