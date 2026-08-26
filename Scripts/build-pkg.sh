#!/bin/bash
#
# Builds, signs and notarizes the macdeploy installation package.
# TO RUN ON A MAC.
#
# PREREQUISITES — this is the project's critical administrative path, not technical:
#
#   1. Apple Developer Program account in the company's name ($99/year).
#      Organization enrollment: requires a D-U-N-S number and a person with the
#      legal authority to bind the company. Allow 1 to 3 weeks if the D-U-N-S
#      already exists, 4 to 6 otherwise.
#
#   2. TWO distinct certificates, and this is where many get caught out:
#        - "Developer ID Application"  -> signs the binaries
#        - "Developer ID Installer"    -> signs the .pkg
#      Intune REFUSES an unsigned pkg as a "macOS app (PKG)" type.
#
#   3. Only the Account Holder can create a Developer ID certificate. Not an
#      Admin. If the account is in the executive's name, plan ahead.
#
#   4. An App Store Connect API key for notarytool (Issuer ID, Key ID, .p8), or
#      failing that an app-specific password.
#
# WHILE WAITING FOR THE CERTIFICATES: this script works without them with
# --unsigned. The pkg produced is not deployable as a "macOS app (PKG)" type,
# but it installs perfectly via `installer -pkg` from an Intune shell script —
# Gatekeeper only checks quarantined files, and a pkg laid down by a script
# never is.
#
# XCODE IS NOT REQUIRED. The single-pass universal build goes through
# `xcbuild`, shipped with the full Xcode and absent from the Command Line Tools
# alone; the script then falls back to two `--triple` builds followed by a
# `lipo`, which produce the same universal binary. The package is deployable in
# both cases, and the architectures are verified before packaging.
#
# USAGE
#   Scripts/build-pkg.sh              # sign + notarize
#   Scripts/build-pkg.sh --unsigned   # without a certificate

set -euo pipefail

# ---------------------------------------------------------------- configuration

TEAM_ID="${MDT_TEAM_ID:-TEAMID_TO_REPLACE}"
APP_CERT="${MDT_APP_CERT:-Developer ID Application: Galeax ($TEAM_ID)}"
PKG_CERT="${MDT_PKG_CERT:-Developer ID Installer: Galeax ($TEAM_ID)}"
KEYCHAIN_PROFILE="${MDT_NOTARY_PROFILE:-coreupdate-notary}"

IDENTIFIER="com.coreupdate.deploy.pkg"
INSTALL_DIR="/usr/local/coreupdate"
# swiftDialog embedded: the device has no dependency to pre-install. We copy the
# whole bundle (/usr/local/bin/dialog is just a link to it).
DIALOG_APP_SRC="${MDT_DIALOG_APP:-/Library/Application Support/Dialog/Dialog.app}"
VERSION="$(grep -o 'version = "[^"]*"' Sources/MDTKit/DryRunReport.swift | head -1 | cut -d'"' -f2)"

BUILD_DIR=".build/package"
PAYLOAD="$BUILD_DIR/payload"
UNSIGNED=0
NOTARIZE=1

for arg in "$@"; do
  case "$arg" in
    --unsigned)     UNSIGNED=1; NOTARIZE=0 ;;
    --no-notarize)  NOTARIZE=0 ;;
    -h|--help)
      grep '^#' "$0" | cut -c3-
      exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 2 ;;
  esac
done

echo "== macdeploy $VERSION =="

# ---------------------------------------------------------------------- compile

# The universal build and its verification live in Scripts/lib, because
# build-app-pkg.sh needs them identically: a divergence would give a
# single-architecture pkg, a defect invisible until the first Intel device.
# shellcheck source=lib/universal-build.sh
. "$(dirname "$0")/lib/universal-build.sh"

rm -rf "$BUILD_DIR"
mkdir -p "$PAYLOAD$INSTALL_DIR"

mdt_build_universal "$PAYLOAD$INSTALL_DIR"

# swiftDialog embedded in the agent pkg — keeping its signature/notarization.
if [ ! -d "$DIALOG_APP_SRC" ]; then
  echo "swiftDialog not found: $DIALOG_APP_SRC" >&2
  echo "  Install swiftDialog on this host, or pass MDT_DIALOG_APP=<Dialog.app>." >&2
  exit 2
fi
cp -R "$DIALOG_APP_SRC" "$PAYLOAD$INSTALL_DIR/Dialog.app"
echo "== swiftDialog embedded from $DIALOG_APP_SRC =="

mkdir -p "$PAYLOAD/Library/Application Support/CoreUpdate/Deploy/manifests"

# ----------------------------------------------------------------- signing

if [ "$UNSIGNED" -eq 1 ]; then
  echo "== signing SKIPPED (--unsigned) =="
  echo "   The pkg produced will NOT be deployable as a \"macOS app (PKG)\" type."
  echo "   It remains installable via an Intune shell script (installer -pkg)."
else
  echo "== signing the binaries =="
  # `--options runtime` (hardened runtime) is required by notarization.
  codesign --force --timestamp --options runtime \
    --sign "$APP_CERT" \
    --identifier "com.coreupdate.deploy" \
    "$PAYLOAD$INSTALL_DIR/macdeploy"

  codesign --force --timestamp --options runtime \
    --sign "$APP_CERT" \
    --identifier "com.coreupdate.deploy.ui" \
    "$PAYLOAD$INSTALL_DIR/macdeploy-ui"
fi

# ---------------------------------------------------------------------- package

echo "== building the pkg =="
COMPONENT="$BUILD_DIR/macdeploy-component.pkg"
DISTRIBUTION="$BUILD_DIR/macdeploy-$VERSION.pkg"

pkgbuild \
  --root "$PAYLOAD" \
  --identifier "$IDENTIFIER" \
  --version "$VERSION" \
  --install-location / \
  --ownership recommended \
  "$COMPONENT"

if [ "$UNSIGNED" -eq 1 ]; then
  productbuild --package "$COMPONENT" "$DISTRIBUTION"
else
  productbuild --package "$COMPONENT" --sign "$PKG_CERT" "$DISTRIBUTION"
fi

# ----------------------------------------------------------------- notarization

if [ "$NOTARIZE" -eq 1 ]; then
  echo "== notarization =="
  # Profile to create once:
  #   xcrun notarytool store-credentials coreupdate-notary \
  #     --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER-UUID
  xcrun notarytool submit "$DISTRIBUTION" \
    --keychain-profile "$KEYCHAIN_PROFILE" --wait
  xcrun stapler staple "$DISTRIBUTION"
fi

echo
echo "== done =="
echo "package: $DISTRIBUTION"
echo
echo "NEXT STEPS"
echo "  1. Deploy swiftDialog (dependency) on the fleet."
echo "  2. Deploy this pkg."
echo "  3. Verify: /usr/local/coreupdate/macdeploy --version"
echo "  4. Dry-run: macdeploy pre -m <manifest> --dry-run"
