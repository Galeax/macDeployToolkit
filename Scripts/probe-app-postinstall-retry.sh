#!/bin/bash
#
# PROBE #3 FOR THE STANDALONE MODEL — to paste into the POST-INSTALL SCRIPT of a
# test Intune application.
#
# WHAT THIS PROBE MEASURES. The standalone package model puts the whole gate in
# the POST-install: the pkg carries the agent, so it is the post-install that
# returns 60 on a deferral. Nothing guarantees that Intune retries a failed
# post-install the way it would retry an installation — a failed post-install
# may get the application marked "installed but failed" rather than "to retry".
#
# WHAT WE WANT TO KNOW, in order of importance:
#
#   1. After N exits with 60, does Intune still retry? If not, a user who defers
#      will never receive their package and the whole deferral strategy needs
#      rethinking.
#   2. What is the cadence between two attempts? It determines how long a
#      deferral actually delays a deployment.
#   3. When the post-install eventually returns 0, does the application's state
#      go back to "installed" on the Intune side, or stay failed?
#
# NO CERTIFICATE REQUIRED. The pre/post-install scripts are properties of the
# application in Intune, not content of the pkg: they are not signed. The pkg
# itself must be signed with a Developer ID Installer — but not necessarily
# YOURS. Any pkg already signed by its vendor works: OneDrive, Word, Excel or
# FortiClient from the Veille catalog.
#
# Choose an application USELESS on the test device, or already installed: the
# goal is to measure the retry, not to deploy anything.
#
# WATCH OUT FOR A READING TRAP. `installer` will have ALREADY laid down the pkg
# before this script runs. The application will therefore be installed on the
# very first attempt, even when this script returns 60. That is exactly what
# will happen in production, and it is why question 3 is read in the Intune
# console and not on the device: the disk does not distinguish the two cases.
#
# DEPLOYMENT
#
#   Intune > Apps > macOS > Add > macOS app (PKG)
#     - Upload: a pkg signed by its vendor
#     - Pre-install script  : NONE
#     - Post-install script : this file
#     - Included apps       : declare a bundle ID and version that the pkg does
#                             NOT install, otherwise detection will consider the
#                             application laid down and mask the retry
#     - Assignment: Required, on a single test device
#
# READING, after 24 to 48 h
#
#   On the device:
#     cat /var/log/coreupdate-probe/app-postinstall-retry.log
#
#   In Intune, on this device: the application's state across the attempts.
#   That is the only source for question 3.
#
# We expect a sequence like this:
#   POST-INSTALL invocation=1 at=... exit=60 (deferral simulated)
#   POST-INSTALL invocation=2 at=... exit=60 (deferral simulated)
#   POST-INSTALL invocation=3 at=... exit=60 (deferral simulated)
#   POST-INSTALL invocation=4 at=... exit=60 (deferral simulated)
#   POST-INSTALL invocation=5 at=... exit=0  (let through)
#
# If the lines stop before invocation=5, Intune gave up: note at which
# invocation, that is the answer to question 1.

set -u

PROBE_DIR="/var/log/coreupdate-probe"
LOGFILE="${PROBE_DIR}/app-postinstall-retry.log"
COUNTER="${PROBE_DIR}/app-postinstall-retry.count"

# 4 rather than 3: if Intune gives up after 3 attempts, we want to see it rather
# than land exactly on the limit and wrongly conclude all is well.
FAILURES_BEFORE_SUCCESS=4

# 60 = the code macdeploy returns on a user deferral. We reproduce exactly what
# Intune will see in production.
DEFER_EXIT_CODE=60

mkdir -p "$PROBE_DIR"

COUNT=0
[ -f "$COUNTER" ] && COUNT=$(cat "$COUNTER" 2>/dev/null || echo 0)
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER"

STAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if [ "$COUNT" -le "$FAILURES_BEFORE_SUCCESS" ]; then
  echo "POST-INSTALL invocation=${COUNT} at=${STAMP} exit=${DEFER_EXIT_CODE} (deferral simulated)" >> "$LOGFILE"
  logger -s "MDT-PROBE-POST invocation=${COUNT} exit=${DEFER_EXIT_CODE}" 2>/dev/null
  exit "$DEFER_EXIT_CODE"
fi

echo "POST-INSTALL invocation=${COUNT} at=${STAMP} exit=0 (let through)" >> "$LOGFILE"
logger -s "MDT-PROBE-POST invocation=${COUNT} exit=0" 2>/dev/null
exit 0
