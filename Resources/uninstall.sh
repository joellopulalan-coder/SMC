#!/bin/sh
# Removes the smcfan daemon. When it stops, the daemon hands the fans back to macOS.
set -eu

LABEL=local.smcfan
launchctl bootout "system/$LABEL" 2>/dev/null || true
rm -f "/Library/LaunchDaemons/$LABEL.plist" /Library/PrivilegedHelperTools/smcfand
