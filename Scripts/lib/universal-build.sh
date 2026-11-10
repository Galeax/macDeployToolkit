#!/bin/bash
#
# Universal build of the macadt-deploy binaries, shared by build-pkg.sh and
# build-app-pkg.sh.
#
# This file exists for a single reason: both scripts produce pkgs destined for
# the fleet, and a divergence on this precise point would give a
# single-architecture binary that would fail silently on half the devices.
# To source, not to run.

# Minimum target aligned with `platforms: [.macOS(.v13)]` in Package.swift.
# Changing it here without changing it there would produce a binary that refuses
# to launch on the oldest devices in the fleet.
MDT_ARM_TRIPLE="arm64-apple-macosx13.0"
MDT_X86_TRIPLE="x86_64-apple-macosx13.0"
MDT_TOOLS="macadt-deploy macadt-deploy-ui"

# Builds both binaries as universal and drops them into the given directory.
#
# Universal, non-negotiable: the fleet mixes Apple Silicon and Intel.
#
# Two routes lead there, and the first is not always available:
#
#   1. `swift build --arch arm64 --arch x86_64` — the Apple way, a single pass.
#      It delegates to `xcbuild`, shipped with the full Xcode and ABSENT from the
#      Command Line Tools alone, where it fails with "xcbuild executable [...]
#      does not exist".
#   2. Two single-architecture builds via `--triple`, then `lipo -create`. Goes
#      only through llbuild and the Command Line Tools SDK, which contains both
#      architectures. Produces exactly the same universal binary.
#
# The route is chosen by the presence of `xcbuild`, never by a flag: the result
# must be identical, so it is not for the caller to decide.
mdt_build_universal() {
  local dest="$1"
  mkdir -p "$dest" || return 1

  local xcbuild
  xcbuild="$(xcode-select -p 2>/dev/null)/../SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild"

  if [ -x "$xcbuild" ]; then
    echo "== release build (universal, single pass via xcbuild) =="
    swift build -c release --arch arm64 --arch x86_64 || return 1
    local release_dir
    release_dir="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)" || return 1
    for tool in $MDT_TOOLS; do
      cp "$release_dir/$tool" "$dest/" || return 1
    done
  else
    echo "== release build (universal, two passes + lipo) =="
    echo "   xcbuild absent — Command Line Tools without Xcode, fallback route"
    local triple
    for triple in "$MDT_ARM_TRIPLE" "$MDT_X86_TRIPLE"; do
      echo "   -> $triple"
      swift build -c release --triple "$triple" || return 1
    done
    local arm_dir x86_dir
    arm_dir="$(swift build -c release --triple "$MDT_ARM_TRIPLE" --show-bin-path)" || return 1
    x86_dir="$(swift build -c release --triple "$MDT_X86_TRIPLE" --show-bin-path)" || return 1
    for tool in $MDT_TOOLS; do
      lipo -create "$arm_dir/$tool" "$x86_dir/$tool" -output "$dest/$tool" || return 1
    done
  fi

  mdt_verify_universal "$dest" || return 1
  chmod 755 "$dest"/macadt-deploy "$dest"/macadt-deploy-ui || return 1
}

# Verification, not trust: both routes can produce a single-architecture binary
# without anything failing — an ignored `--arch`, a `lipo` that receives the same
# input twice. The defect would then only show on the first Intel device in the
# fleet, long after going to production.
mdt_verify_universal() {
  local dest="$1" tool archs
  echo "== architecture verification =="
  for tool in $MDT_TOOLS; do
    archs="$(lipo -archs "$dest/$tool")" || return 1
    case " $archs " in
      *" arm64 "*) ;;
      *) echo "$tool: arm64 absent (got: $archs)" >&2; return 1 ;;
    esac
    case " $archs " in
      *" x86_64 "*) ;;
      *) echo "$tool: x86_64 absent (got: $archs)" >&2; return 1 ;;
    esac
    echo "   $tool: $archs"
  done
}
