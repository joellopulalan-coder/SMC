#!/bin/sh
# Installs the smcfan daemon as a LaunchDaemon. The app runs this as root.
#   install.sh <path to smcfand> <user name>
set -eu

SRC="$1"
OWNER="$2"
LABEL=local.smcfan
HELPER=/Library/PrivilegedHelperTools/smcfand
CONF_DIR="/Library/Application Support/SMCFan"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

launchctl bootout "system/$LABEL" 2>/dev/null || true

install -d -m 755 -o root -g wheel /Library/PrivilegedHelperTools
install -m 755 -o root -g wheel "$SRC" "$HELPER"

# The app (running as the user) writes the profile; the daemon only reads it.
install -d -m 755 -o "$OWNER" -g staff "$CONF_DIR"
if [ ! -f "$CONF_DIR/config" ]; then
    printf 'profile=balanced\nmode=curve\ntakeover=65\nrelease=60\npoint=65:30\npoint=75:60\npoint=85:100\n' > "$CONF_DIR/config"
    chown "$OWNER":staff "$CONF_DIR/config"
fi

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HELPER</string>
        <string>daemon</string>
        <string>$CONF_DIR/config</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardErrorPath</key><string>/var/log/smcfan.log</string>
</dict>
</plist>
PLIST
chown root:wheel "$PLIST"
chmod 644 "$PLIST"

launchctl bootstrap system "$PLIST"
