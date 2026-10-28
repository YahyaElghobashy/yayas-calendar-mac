#!/bin/zsh
# Builds and runs the icon tools with swiftc from the Command Line Tools (no Xcode, no ImageMagick).
#
#   Tools/make-icons.sh                        redraw every icon asset (Tools/MakeIcons.swift) from
#                                              Resources/Brand/AppIcon-Source.png and the BrandMark path
#   Tools/make-icons.sh --strip IN OUT.png …   re-encode images with no metadata (Tools/strip-image-meta.swift)
#
# The tools compile into build/tools/ under the global build lock, then run from the repo root.
# Afterwards: Tools/check-public.sh --images <every image you added or changed>.
set -euo pipefail
YC_ROOT="${0:A:h:h}"; ROOT="$YC_ROOT"
source "$ROOT/Tools/lib/common.zsh"
yc_toolchain
cd "$ROOT"
mkdir -p build/tools

build_tool() {   # <output name> <sources…>
  local out="build/tools/$1"; shift
  yc_lock_acquire
  "$SWIFTC" -O -swift-version 5 -parse-as-library -sdk "$SDK" -suppress-warnings "$@" -o "$out" \
    || { yc_lock_release; yc_fail "could not compile ${out:t}"; }
  yc_lock_release
}

if [[ "${1:-}" == "--strip" ]]; then
  shift
  build_tool strip-image-meta Tools/strip-image-meta.swift Tools/lib/CleanPNG.swift
  build/tools/strip-image-meta "$@"
else
  build_tool make-icons Tools/MakeIcons.swift Tools/lib/CleanPNG.swift Sources/Shared/Widgets/BrandMark.swift
  build/tools/make-icons
fi
