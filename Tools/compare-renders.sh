#!/bin/zsh
# Pixel comparison of two `./build.sh --render <dir>` folders (D-019: visuals must not change).
#
#   Tools/compare-renders.sh <before-dir> <after-dir>
#
# `magick compare -metric AE` per PNG (pixels that differ, no fuzz). Prints every file that differs or
# exists on one side only; last line: "RENDERS compared=<n> identical=<n> differ=<n> missing=<n> extra=<n>".
# Exit 0 only when every file is pixel-identical and both folders hold the same files.
set -uo pipefail
(( $# == 2 )) || { print -u2 "usage: Tools/compare-renders.sh <before-dir> <after-dir>"; exit 2; }
BEFORE="${1:A}"; AFTER="${2:A}"
command -v magick >/dev/null || { print -u2 "✗ ImageMagick (magick) is not installed"; exit 2; }
integer compared=0 identical=0 differ=0 missing=0 extra=0
for a in "$BEFORE"/*.png(N); do
  name="${a:t}"; b="$AFTER/$name"
  if [[ ! -f "$b" ]]; then print -r -- "missing in after: $name"; (( missing += 1 )); continue; fi
  (( compared += 1 ))
  ae="$(magick compare -metric AE "$a" "$b" null: 2>&1 | awk '{print $1}')"
  if [[ "$ae" == "0" ]]; then
    (( identical += 1 ))
  else
    print -r -- "differs: $name (AE $ae)"
    (( differ += 1 ))
  fi
done
for b in "$AFTER"/*.png(N); do
  [[ -f "$BEFORE/${b:t}" ]] || { print -r -- "only in after: ${b:t}"; (( extra += 1 )); }
done
print -r -- "RENDERS compared=$compared identical=$identical differ=$differ missing=$missing extra=$extra"
(( differ == 0 && missing == 0 && extra == 0 ))
