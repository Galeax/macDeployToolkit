#!/bin/bash
#
# Post-install hook — example.
#
# Runs after the installation by Intune, after hardening (quarantine removal,
# signature check, root:wheel) and after the detection check. A failure here
# fails the deployment: what follows must therefore be genuinely required for
# the application to work.
#
# See pre-install.sh for the execution context and the available variables.
#
# PREPARATION
#   chown root:wheel post-install.sh && chmod 755 post-install.sh

set -euo pipefail

echo "post-installation of ${MACADT_APP_NAME} ${MACADT_APP_VERSION}"

# Example: drop a system-wide configuration.
CONFIG_DIR="/Library/Application Support/BusinessTool"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_DIR/managed.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>ServerURL</key>
  <string>https://businesstool.macadt.com</string>
  <key>ManagedByMacADT</key>
  <true/>
</dict>
</plist>
PLIST
chown root:wheel "$CONFIG_DIR/managed.plist"
chmod 644 "$CONFIG_DIR/managed.plist"

# Example: load a LaunchDaemon shipped by the package. `bootout` first, otherwise
# `bootstrap` fails on a service already loaded by a previous version.
LABEL="com.macadt.businesstool.helper"
PLIST_PATH="/Library/LaunchDaemons/${LABEL}.plist"
if [ -f "$PLIST_PATH" ]; then
  launchctl bootout "system/${LABEL}" 2>/dev/null || true
  launchctl bootstrap system "$PLIST_PATH"
  echo "service ${LABEL} loaded"
fi

exit 0
