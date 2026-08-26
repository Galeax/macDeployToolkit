#!/bin/bash
#
# Pre-install hook — example.
#
# EXECUTION CONTEXT
#   - root, daemon context (no GUI session)
#   - current directory = manifest directory
#   - runs AFTER the blocking applications are closed and BEFORE the
#     installation by Intune: it is the only window in which the device is in
#     the state a preparation script expects
#   - killed after 600 s
#
# ENVIRONMENT VARIABLES PROVIDED
#   COREUPDATE_PACKAGE_KEY    stable deployment key
#   COREUPDATE_APP_NAME       display name
#   COREUPDATE_APP_VERSION    target version
#   COREUPDATE_ACTION         install | uninstall | repair
#   COREUPDATE_PHASE          preInstall | postInstall | preUninstall | postUninstall
#   COREUPDATE_MANIFEST_DIR   manifest directory
#   COREUPDATE_BUNDLE_PATH    bundle path (if `detection.bundlePath` is declared)
#   COREUPDATE_LOG            agent log
#
# EXIT CODES
#   0        continue
#   non-zero abort the deployment, UNLESS the code is listed in the manifest's
#            `ignoredExitCodes`
#
# PREPARATION (otherwise the hook is refused by the security checks)
#   chown root:wheel pre-install.sh && chmod 755 pre-install.sh

set -euo pipefail

echo "phase ${COREUPDATE_PHASE} for ${COREUPDATE_APP_NAME} ${COREUPDATE_APP_VERSION}"

# Real example: clean up an old installation in a different path that the
# installer will not replace. This is the 7-Zip case from the Veille catalog,
# where an x86 build and an x64 build coexist in two separate directories.
LEGACY="/Applications/Business Tool (old).app"
if [ -d "$LEGACY" ]; then
  echo "removing the old installation: $LEGACY"
  rm -rf "$LEGACY"
fi

# Example: disable an automatic update that would conflict with the managed
# deployment.
defaults write /Library/Preferences/com.coreupdate.businesstool AutoUpdate -bool false 2>/dev/null || true

exit 0
