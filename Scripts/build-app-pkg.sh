#!/bin/bash
#
# Builds the SELF-CONTAINED pkg of an application, for the PSADT model: a single
# Intune package carries the agent, swiftDialog, the manifest, the hooks and the
# vendor's payload. NO dependency to install on the device.
#
#   staging/
#   |- usr/local/macadt/{macadt-deploy,macadt-deploy-ui,Dialog.app}
#   \- Library/Application Support/MacADT/Deploy/manifests/<packageKey>/
#      |- manifest.json
#      |- hooks/            (if the manifest declares any)
#      \- payload/<vendor file>
#
# There is therefore NO pre-install script: it would run before `installer`,
# hence before the agent exists on a fresh device. The whole gate — dialog,
# deferral, close — plays out in the post-install, which this script also renders.
#
# TO RUN ON A MAC. The vendor DMG is never mounted: it travels as an opaque
# file, only the device needs hdiutil.
#
# USAGE
#   Scripts/build-app-pkg.sh -m chrome.json -p ~/Downloads/googlechrome.dmg
#   Scripts/build-app-pkg.sh -m chrome.json -p chrome.dmg --hooks-dir hooks/
#   Scripts/build-app-pkg.sh -m chrome.json -p chrome.dmg --mode Silent
#
#   --unsigned  skips productsign. The pkg is then NOT deployable as a
#               "macOS app (PKG)" type, hence unusable for this model: Intune
#               refuses an unsigned pkg, and it is that type which carries the
#               pre/post-install scripts. Reserve for local validation.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=lib/universal-build.sh
. "$SCRIPT_DIR/lib/universal-build.sh"

TEAM_ID="${MDT_TEAM_ID:-TEAMID_TO_REPLACE}"
PKG_CERT="${MDT_PKG_CERT:-Developer ID Installer: Galeax ($TEAM_ID)}"
AGENT_DIR="/usr/local/macadt"
MANIFEST_ROOT="/Library/Application Support/MacADT/Deploy/manifests"
# swiftDialog installs as a bundle; /usr/local/bin/dialog is just a link to it.
# We therefore embed the whole .app, which keeps its signature/notarization.
DIALOG_APP_SRC="${MDT_DIALOG_APP:-/Library/Application Support/Dialog/Dialog.app}"

MANIFEST=""
PAYLOAD_FILE=""
HOOKS_DIR=""
DEPLOY_MODE="Interactive"
# Default rendered into the post-install. Matches macadt's own baked-in default
# (show the gate even when nothing is running). Editable afterwards in the script.
SHOW_WHEN_NOT_RUNNING="true"
UNSIGNED=0
OUT_DIR=".build/apps"

while [ $# -gt 0 ]; do
  case "$1" in
    -m|--manifest)  MANIFEST="$2"; shift 2 ;;
    -p|--payload)   PAYLOAD_FILE="$2"; shift 2 ;;
    --hooks-dir)    HOOKS_DIR="$2"; shift 2 ;;
    --mode)         DEPLOY_MODE="$2"; shift 2 ;;
    --show-when-not-running) SHOW_WHEN_NOT_RUNNING="$2"; shift 2 ;;
    -o|--out)       OUT_DIR="$2"; shift 2 ;;
    --unsigned)     UNSIGNED=1; shift ;;
    -h|--help)      grep '^#' "$0" | cut -c3-; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

[ -n "$MANIFEST" ]     || { echo "-m/--manifest is required" >&2; exit 2; }
[ -n "$PAYLOAD_FILE" ] || { echo "-p/--payload is required" >&2; exit 2; }
[ -f "$MANIFEST" ]     || { echo "manifest not found: $MANIFEST" >&2; exit 2; }
[ -f "$PAYLOAD_FILE" ] || { echo "payload not found: $PAYLOAD_FILE" >&2; exit 2; }

case "$DEPLOY_MODE" in
  Interactive|NonInteractive|Silent) ;;
  *) echo "--mode must be Interactive, NonInteractive or Silent" >&2; exit 2 ;;
esac

case "$SHOW_WHEN_NOT_RUNNING" in
  true|false) ;;
  *) echo "--show-when-not-running must be true or false" >&2; exit 2 ;;
esac

# ------------------------------------------------------- reading the manifest

# `plutil` and not python3: it reads JSON, it is in the Command Line Tools, and
# is therefore present everywhere this script can run.
field() {
  plutil -extract "$1" raw -o - "$MANIFEST" 2>/dev/null
}

PACKAGE_KEY="$(field packageKey)" \
  || { echo "packageKey missing from the manifest" >&2; exit 2; }
[ -n "$PACKAGE_KEY" ] || { echo "empty packageKey" >&2; exit 2; }

VERSION="$(field version)" || VERSION=""
[ -n "$VERSION" ] || VERSION="0"

PAYLOAD_REL="$(field payload.file)" \
  || { echo "the manifest declares no payload.file" >&2; exit 2; }
[ -n "$PAYLOAD_REL" ] || { echo "empty payload.file" >&2; exit 2; }

# The same confinement the agent applies at runtime: refuse here rather than
# build a pkg that macadt-deploy will reject on the device.
case "$PAYLOAD_REL" in
  /*|*..*) echo "payload.file must be relative and without '..': $PAYLOAD_REL" >&2; exit 2 ;;
esac

echo "== $PACKAGE_KEY $VERSION =="
echo "   manifest   : $MANIFEST"
echo "   payload    : $PAYLOAD_FILE -> $PAYLOAD_REL"
echo "   mode       : $DEPLOY_MODE (in the post-install, not in the pkg)"

# ------------------------------------------------------------------ staging

cd "$ROOT_DIR"
STAGING="$OUT_DIR/$PACKAGE_KEY/staging"
rm -rf "$OUT_DIR/$PACKAGE_KEY"
MANIFEST_STAGE="$STAGING$MANIFEST_ROOT/$PACKAGE_KEY"
mkdir -p "$MANIFEST_STAGE"

mdt_build_universal "$STAGING$AGENT_DIR"

# swiftDialog embedded: the device needs no pre-installed binary. Copy from the
# build host; the .app keeps its own Developer ID signature and notarization, so
# it runs even if our pkg is not notarized.
if [ ! -d "$DIALOG_APP_SRC" ]; then
  echo "swiftDialog not found: $DIALOG_APP_SRC" >&2
  echo "  Install swiftDialog on this build host, or pass" >&2
  echo "  MDT_DIALOG_APP=<path to Dialog.app>." >&2
  exit 2
fi
cp -R "$DIALOG_APP_SRC" "$STAGING$AGENT_DIR/Dialog.app"
echo "   swiftDialog   : $DIALOG_APP_SRC -> $AGENT_DIR/Dialog.app"

cp "$MANIFEST" "$MANIFEST_STAGE/manifest.json"
mkdir -p "$MANIFEST_STAGE/$(dirname "$PAYLOAD_REL")"
cp "$PAYLOAD_FILE" "$MANIFEST_STAGE/$PAYLOAD_REL"

if [ -n "$HOOKS_DIR" ]; then
  [ -d "$HOOKS_DIR" ] || { echo "--hooks-dir not found: $HOOKS_DIR" >&2; exit 2; }
  mkdir -p "$MANIFEST_STAGE/hooks"
  cp "$HOOKS_DIR"/*.sh "$MANIFEST_STAGE/hooks/"
  chmod 755 "$MANIFEST_STAGE/hooks"/*.sh
  echo "   hooks         : $(ls "$MANIFEST_STAGE/hooks" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- the package

echo "== building the pkg =="
COMPONENT="$OUT_DIR/$PACKAGE_KEY/$PACKAGE_KEY-component.pkg"
UNSIGNED_PKG="$OUT_DIR/$PACKAGE_KEY/$PACKAGE_KEY-unsigned.pkg"
FINAL_PKG="$OUT_DIR/$PACKAGE_KEY/$PACKAGE_KEY.pkg"

# `--ownership recommended`: the files are owned by root:wheel on the device,
# whatever the identity of the build host. The agent checks this ownership
# before running a hook, and would refuse a writable file.
# One identifier per application, otherwise two wrappers would each take the
# other for an update of itself.
# swiftDialog ships as a relocatable .app bundle. Left to its default, pkgbuild
# marks it `BundleIsRelocatable`, and on any device that already has swiftDialog
# somewhere — the build host always does, it is a build dependency — installer
# diverts the bundle to that existing copy via Spotlight instead of laying it down
# at /usr/local/macadt, leaving the agent without its embedded Dialog.app
# ("swiftDialog not found"). Pin every bundle to its root-relative path.
COMPONENT_PLIST="$OUT_DIR/$PACKAGE_KEY/$PACKAGE_KEY-components.plist"
pkgbuild --analyze --root "$STAGING" "$COMPONENT_PLIST" >/dev/null
i=0
while plutil -replace "$i.BundleIsRelocatable" -bool false "$COMPONENT_PLIST" >/dev/null 2>&1; do
  i=$((i + 1))
done
echo "   bundles pinned: $i (BundleIsRelocatable=false)"

pkgbuild --root "$STAGING" \
         --component-plist "$COMPONENT_PLIST" \
         --identifier "com.macadt.deploy.app.$PACKAGE_KEY" \
         --version "$VERSION" \
         --install-location / \
         --ownership recommended \
         "$COMPONENT"

productbuild --package "$COMPONENT" "$UNSIGNED_PKG"

if [ "$UNSIGNED" -eq 1 ]; then
  mv "$UNSIGNED_PKG" "$FINAL_PKG"
  echo "== signing SKIPPED (--unsigned) =="
  echo "   Intune REFUSES an unsigned pkg as a \"macOS app (PKG)\" type, and it is"
  echo "   that type which carries the pre/post-install scripts. This package is"
  echo "   therefore only good for local validation with 'installer -pkg'."
else
  productsign --sign "$PKG_CERT" "$UNSIGNED_PKG" "$FINAL_PKG"
  rm -f "$UNSIGNED_PKG"
  echo "   signed with: $PKG_CERT"
fi
rm -f "$COMPONENT"

# ------------------------------------------------- the post-install script

echo "== rendering the post-install script =="
TEMPLATE="$SCRIPT_DIR/templates/macos-postinstall-standalone.sh.template"
POSTINSTALL="$OUT_DIR/$PACKAGE_KEY/$PACKAGE_KEY-postinstall.sh"

# The substitution applies to the whole file, comments included — the templates
# therefore never mention their own tokens literally.
sed -e "s|{##PACKAGE_KEY##}|$PACKAGE_KEY|g" \
    -e "s|{##DEPLOY_MODE##}|$DEPLOY_MODE|g" \
    -e "s|{##SHOW_WHEN_NOT_RUNNING##}|$SHOW_WHEN_NOT_RUNNING|g" \
    "$TEMPLATE" > "$POSTINSTALL"

if grep -q '{##' "$POSTINSTALL"; then
  echo "some tokens were not substituted in $POSTINSTALL:" >&2
  grep -n '{##' "$POSTINSTALL" >&2
  exit 1
fi
sh -n "$POSTINSTALL" || { echo "the rendered script is syntactically invalid" >&2; exit 1; }

# -------------------------------------------------------------- summary

cat <<RECAP

== done ==
  pkg            : $FINAL_PKG
  post-install   : $POSTINSTALL

TO ENTER IN INTUNE ("macOS app (PKG)" type)
  1. Upload $FINAL_PKG
  2. postInstallScript  <- the contents of $POSTINSTALL
     preInstallScript   <- NONE, on purpose (see the script header)
  3. "Included apps": the bundle ID and version of the TARGET application, not
     those of the pkg. That is what Intune's detection is based on, and nothing
     in the pkg provides them — pkgbuild has no bundle to infer here.
  4. Do NOT also deploy the agent pkg or swiftDialog: this package contains them
     both, and the post-install removes them after a successful installation.
     Only the state.plist and the logs stay on the device.
     NO dependency to pre-install on the fleet.

To change mode, regenerate only the post-install (--mode) and update the
application property. The pkg does not move.
RECAP
