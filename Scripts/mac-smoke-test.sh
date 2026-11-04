#!/bin/bash
#
# macadt-deploy validation runbook on a Mac.
#
# Chains everything that can be automated, then prints the steps that
# necessarily require a human eye — a dialog that shows up cannot be verified in
# a script.
#
# DEPLOYS NOTHING, INSTALLS NOTHING on the device, except in phase 6 which is
# explicitly optional and flagged.
#
# REQUIRES NEITHER A CERTIFICATE NOR INTUNE.
#
# Usage
#   Scripts/mac-smoke-test.sh              # phases 0 to 3
#   Scripts/mac-smoke-test.sh --with-root  # adds the root phases (4)
#
# Phases 5 and 6 stay manual: they touch /Applications.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR" || exit 1

WITH_ROOT=0
# An unknown argument stops here rather than being ignored: a mistyped
# `--withroot` used to skip the root phases silently, and the runbook would
# return a green report on checks that had not happened.
for arg in "$@"; do
  case "$arg" in
    --with-root) WITH_ROOT=1 ;;
    -h|--help)   printf 'usage: %s [--with-root]\n' "$0"; exit 0 ;;
    *)           printf 'unknown argument: %s\nusage: %s [--with-root]\n' \
                   "$arg" "$0" >&2; exit 2 ;;
  esac
done

# A DIRECTORY, since each deployment has its own state file.
STATE="/tmp/macadt-deploy-test-state"
LOG="/tmp/macadt-deploy-test.log"
AGENT=".build/debug/macadt-deploy"
HELPER=".build/debug/macadt-deploy-ui"
MANIFEST="Examples/test-textedit.json"

PASS=0
FAIL=0
SKIP=0

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '  \033[32mOK\033[0m   %s\n' "$*"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mKO\033[0m   %s\n' "$*"; FAIL=$((FAIL + 1)); }
skip() { printf '  \033[33m--\033[0m   %s\n' "$*"; SKIP=$((SKIP + 1)); }
note() { printf '       %s\n' "$*"; }

# ---------------------------------------------------------------- prerequisites

say "Prerequisites"

if [ "$(uname -s)" != "Darwin" ]; then
  bad "this runbook must run on macOS (detected: $(uname -s))"
  exit 1
fi
ok "macOS $(sw_vers -productVersion) on $(uname -m)"

if command -v swift >/dev/null 2>&1; then
  ok "swift present: $(swift --version 2>&1 | head -1)"
else
  bad "swift absent — install Xcode or the Command Line Tools"
  exit 1
fi

if [ -x /usr/local/bin/dialog ]; then
  ok "swiftDialog present"
  DIALOG_PRESENT=1
else
  skip "swiftDialog absent: phases 3 and 4 will be limited"
  note "install from https://github.com/swiftDialog/swiftDialog/releases"
  DIALOG_PRESENT=0
fi

# ------------------------------------------------------- phase 0: compilation

say "Phase 0 — compilation (THE real gate)"
note "MacADTMac (~2800 lines, 12 files) has never seen a compiler."
note "Errors here are expected, not alarming. Fix then re-run."

if swift build 2>&1 | tee /tmp/macadt-deploy-build.log | tail -30; then
  if grep -q "error:" /tmp/macadt-deploy-build.log; then
    bad "compilation errors — see /tmp/macadt-deploy-build.log"
    note "everything below depends on this phase: stop here."
    exit 1
  fi
  ok "swift build"
else
  bad "swift build failed — see /tmp/macadt-deploy-build.log"
  exit 1
fi

say "Phase 0b — test suite"
note "253 unit tests. They should be green on macOS."
# We judge on the exit code, not on a pattern in the output: on macOS, SwiftPM
# also runs swift-testing (zero tests here) and its summary takes the last
# lines, which used to make a grep "0 failures" return a false failure.
if swift test > /tmp/macadt-deploy-test-suite.log 2>&1; then
  ok "swift test"
  grep -E "Executed [0-9]+ tests" /tmp/macadt-deploy-test-suite.log | tail -1 | sed 's/^/       /'
elif grep -q "no such module 'XCTest'" /tmp/macadt-deploy-test-suite.log; then
  # XCTest ships only with the full Xcode, never with the Command Line Tools
  # alone. It is a missing capability, not a failing test. What running on macOS
  # would add is the detection of divergences between swift-corelibs Foundation
  # and Apple's Foundation (PropertyListSerialization, dates, bundle versions) —
  # worth doing, but nothing else in this runbook depends on it.
  skip "swift test: XCTest absent (Command Line Tools alone, no Xcode)"
  note "active toolchain: $(xcode-select -p)"
  note "to run them: install Xcode, then"
  note "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer"
else
  bad "the test suite failed on macOS"
  note "full detail in /tmp/macadt-deploy-test-suite.log:"
  grep -E "error:|XCTAssert|failed \\(" /tmp/macadt-deploy-test-suite.log | head -10 | sed 's/^/       /'
fi

# ---------------------------------------------------- phase 1: dry-run without root

say "Phase 1 — dry-run (without root, without dialog, without side effects)"
note "Validates manifest loading, the decision engine, dialog construction"
note "and the uninstall plan, on real macOS."

rm -f "$STATE"

if "$AGENT" pre -m "$MANIFEST" --dry-run --state "$STATE" --log "$LOG" 2>/dev/null; then
  ok "pre --dry-run"
  "$AGENT" pre -m "$MANIFEST" --dry-run --state "$STATE" --log "$LOG" 2>/dev/null | sed 's/^/       /'
else
  bad "pre --dry-run failed (code $?)"
fi

if "$AGENT" pre -m "$MANIFEST" --dry-run --json --state "$STATE" --log "$LOG" 2>/dev/null \
  | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
  ok "pre --dry-run --json produces valid JSON"
else
  bad "the --json output is not valid JSON"
fi

if "$AGENT" uninstall -m Examples/slack.json --dry-run --state "$STATE" --log "$LOG" 2>/dev/null \
  | grep -q "plan"; then
  ok "uninstall --dry-run shows a plan"
  note "check by eye that the refusals and warnings make sense"
else
  bad "uninstall --dry-run does not show a plan"
fi

for cmd in version help; do
  if "$AGENT" "$cmd" >/dev/null 2>&1; then ok "macadt-deploy $cmd"; else bad "macadt-deploy $cmd"; fi
done

# ------------------------------------------------- phase 3: real detection

say "Phase 2 — process detection in real conditions"

if pgrep -x TextEdit >/dev/null 2>&1; then
  ok "TextEdit is running"
else
  skip "TextEdit is not running — 'open -a TextEdit' then re-run"
  note "with no application open, the gate returns 'proceed' and tests nothing"
fi

if [ "$WITH_ROOT" -eq 1 ] && pgrep -x TextEdit >/dev/null 2>&1; then
  DETECTED=$(sudo "$AGENT" pre -m "$MANIFEST" --dry-run --state "$STATE" --log "$LOG" 2>/dev/null \
    | grep -c "com.apple.TextEdit")
  if [ "${DETECTED:-0}" -ge 1 ]; then
    ok "the libproc scan as root detects TextEdit"
    note "detection works well in a privileged context"
  else
    bad "TextEdit is running but the scan as root does not see it"
    note "this is a design failure, not a detail: without detection, no close-apps"
  fi
else
  skip "detection as root (re-run with --with-root, TextEdit open)"
fi

# ------------------------------------------------------------------- summary

say "Summary"
printf '  %d OK, %d KO, %d skipped\n' "$PASS" "$FAIL" "$SKIP"

cat <<'MANUAL'

== WHAT STAYS MANUAL ==

A dialog that shows up cannot be verified in a script.

PHASE 3 — the dialog, the deferral, the close   (root, swiftDialog required)

  open -a TextEdit
  rm -rf /tmp/macadt-deploy-test-state
  sudo .build/debug/macadt-deploy pre -m Examples/test-textedit.json \
       --state /tmp/macadt-deploy-test-state --log /tmp/macadt-deploy-test.log -v

  Expected, in order:
   1. a foreground dialog, two buttons, "Defer (2 left)"
   2. if nothing is touched for 20 s: the dialog comes back to the foreground
      (this is persistence, the equivalent of PSADT's -PersistPrompt)
   3. click "Defer"          -> exit code 60
   4. re-run                 -> "Defer (1 left)"
   5. re-run twice           -> no more Defer button, countdown 60 s,
                                blurred screen, dialog not movable
   6. click "Close and install" -> TextEdit is killed (SIGKILL), with no
      authorization prompt and no save dialog
   7. exit code 0

  Check the state between each run:
    .build/debug/macadt-deploy status --state /tmp/macadt-deploy-test-state --json
    plutil -p /tmp/macadt-deploy-test-state/test-textedit.plist
    tail -20 /tmp/macadt-deploy-test.log

PHASE 4 — installation of a real DMG   (root, writes to /Applications)

  This is the most recent and least verified code: mount, ditto, atomic swap,
  hardening, detection.

  Download a DMG (Chrome for example), then:

    KEY=test-chrome
    DIR="/Library/Application Support/MacADT/Deploy/manifests/$KEY"
    sudo mkdir -p "$DIR/payload"
    sudo cp ~/Downloads/googlechrome.dmg "$DIR/payload/chrome.dmg"
    sudo tee "$DIR/manifest.json" >/dev/null <<'JSON'
    {
      "packageKey": "test-chrome",
      "displayName": "Google Chrome",
      "version": "0",
      "mode": "silent",
      "payload": { "file": "payload/chrome.dmg", "installLocation": "/Applications" }
    }
JSON
    sudo chown -R root:wheel "$DIR"
    sudo .build/debug/macadt-deploy install -m "$DIR/manifest.json" -v

  Then check:
    ls -la@ /Applications/Google\ Chrome.app        # no more quarantine attribute
    codesign --verify --deep --strict /Applications/Google\ Chrome.app
    ls -ld /Applications/Google\ Chrome.app         # root:wheel, not writable
    hdiutil info | grep -c /dev/disk                # no image left mounted

  The last point matters: a failed unmount would leave the image attached and
  make the next deployment of the same application fail.

PHASE 5 — the installation package   (optional, writes to /usr/local)

    Scripts/build-pkg.sh --unsigned
    sudo installer -pkg .build/package/macadt-deploy-*.pkg -target /
    /usr/local/macadt/macadt-deploy --version

  The unsigned pkg installs via 'installer' but Intune would refuse it as a
  macOSPkgApp: that is the only thing the certificate unlocks here.

== WHAT STAYS OUT OF REACH WITHOUT A CERTIFICATE ==

  - deployment by Intune as a macOSPkgApp (the pkg must be signed)

  Everything else above can be tested today.
MANUAL
