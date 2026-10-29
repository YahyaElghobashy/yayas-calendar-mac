#!/bin/zsh
# Proves a built dev app reaches none of the release app's identifiers: every Mach-O's strings, the
# Info.plists, the entitlements and the code-signing identifiers. The release identifiers come from the one
# table (Sources/Shared/Profile.swift, read with yc_profile), never from a list kept here:
#   - the release bundle id anywhere it is not the start of the dev id (keychain services, notification
#     names and queue labels are all built on it),
#   - the release URL scheme as a word ("yayacal", "yayacal://"),
#   - the release data folder (not followed by the dev suffix) and the installer handoff folder,
#   - Yaya's Murmur's release names (D-046): its bundle id outside `….dev`, its URL scheme as a word and its data
#     folder (not followed by "Dev"), so a dev calendar can only ever find and read a dev Murmur.
#
#   Tools/check-profile.sh "build/Yaya's Calendar Dev.app"
#
# Prints each offending string with the file it came from; exit 1 on any. Short Swift string literals
# (15 bytes or fewer) live inside instructions, not as strings: Tests/Profile covers those through the table.
set -euo pipefail
YC_ROOT="${0:A:h:h}"
source "$YC_ROOT/Tools/lib/common.zsh"

APP="${1:?usage: Tools/check-profile.sh <dev .app>}"
[[ -d "$APP" ]] || yc_fail "no such app: $APP"

yc_profile release; typeset -A REL; REL=( "${(@kv)YC_PROFILE}" ); rel_handoff="$(yc_handoff_dir)"
yc_profile dev;     typeset -A DEV; DEV=( "${(@kv)YC_PROFILE}" )
[[ "${DEV[bundleId]}" == "${REL[bundleId]}"* ]] || yc_fail "the dev bundle id must extend the release one"
[[ "${DEV[dataRoot]}" == "${REL[dataRoot]}"* ]] || yc_fail "the dev data root must extend the release one"
id_suffix="${DEV[bundleId]#${REL[bundleId]}}"      # ".dev"
root_suffix="${DEV[dataRoot]#${REL[dataRoot]}}"    # "Dev"

# Perl patterns, built from the table (\Q…\E quotes the values).
export YCP_ID="${REL[bundleId]}" YCP_ID_SUFFIX="$id_suffix" YCP_SCHEME="${REL[urlScheme]}"
export YCP_ROOT="${REL[dataRoot]#Library/}" YCP_ROOT_SUFFIX="$root_suffix"
export YCP_HANDOFF_PARENT="${${rel_handoff#Library/}%/*}"
[[ "${DEV[murmurBundleId]}" == "${REL[murmurBundleId]}.dev" ]] || yc_fail "the dev Murmur bundle id must be the release one + .dev"
[[ "${DEV[murmurDataRoot]}" == "${REL[murmurDataRoot]}Dev" ]] || yc_fail "the dev Murmur data root must be the release one + Dev"
export YCP_MURMUR_ID="${REL[murmurBundleId]}" YCP_MURMUR_SCHEME="${REL[murmurScheme]}" YCP_MURMUR_ROOT="${REL[murmurDataRoot]#Library/}"

# What the app carries: strings of every Mach-O, every plist and entitlements file, the signing identifiers.
SCRATCH="$YC_ROOT/.work/check-profile"; rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
typeset -i n=0
while IFS= read -r -d '' f; do
  rel="${f#$APP/}"
  if [[ "$(file -b "$f")" == *Mach-O* ]]; then
    strings -a -n 4 "$f" | sed "s|^|$rel: |" >> "$SCRATCH/strings.txt"
  elif [[ "$f" == *.plist || "$f" == *.entitlements || "$f" == *.strings ]]; then
    plutil -convert xml1 -o - "$f" 2>/dev/null | sed "s|^|$rel: |" >> "$SCRATCH/strings.txt" || true
  else
    strings -a -n 4 "$f" | sed "s|^|$rel: |" >> "$SCRATCH/strings.txt" || true
  fi
  (( n += 1 ))
done < <(find "$APP" -type f -print0)
for bundle in "$APP" "$APP"/Contents/PlugIns/*.appex(N); do
  codesign -dvv "$bundle" 2>&1 | sed -n "s|^Identifier=|${bundle#$APP/}: signing identifier |p" >> "$SCRATCH/strings.txt" || true
  codesign -d --entitlements - --xml "$bundle" 2>/dev/null | tr '>' '\n' | sed "s|^|${bundle#$APP/}: entitlements |" >> "$SCRATCH/strings.txt" || true
done

hits="$(/usr/bin/perl -ne '
  BEGIN {
    $id = qr/\Q$ENV{YCP_ID}\E(?!\Q$ENV{YCP_ID_SUFFIX}\E(?![A-Za-z0-9]))/;
    $scheme = qr/(?<![A-Za-z0-9.-])\Q$ENV{YCP_SCHEME}\E(?![A-Za-z0-9.-])/;
    $root = qr/\Q$ENV{YCP_ROOT}\E(?!\Q$ENV{YCP_ROOT_SUFFIX}\E)/;
    $handoff = qr/\Q$ENV{YCP_HANDOFF_PARENT}\E/;
    $mid = qr/\Q$ENV{YCP_MURMUR_ID}\E(?!\.dev(?![A-Za-z0-9]))/;
    $mscheme = qr/(?<![A-Za-z0-9.-])\Q$ENV{YCP_MURMUR_SCHEME}\E(?![A-Za-z0-9.-])/;
    $mroot = qr/\Q$ENV{YCP_MURMUR_ROOT}\E(?!Dev)/;
  }
  my ($where, $text) = /\A(.*?): (.*)\z/s or next;
  for my $p (["bundle id", $id], ["URL scheme", $scheme], ["data folder", $root], ["handoff folder", $handoff],
             ["Murmur bundle id", $mid], ["Murmur scheme", $mscheme], ["Murmur data folder", $mroot]) {
    if ($text =~ $p->[1]) { chomp $text; print "$p->[0]\t$where\t$text\n"; last }
  }' "$SCRATCH/strings.txt" | sort -u)"

print -r -- "$hits" > "$SCRATCH/hits.tsv"   # kind <TAB> file <TAB> string (Tools/gate.sh p5 reads it)
if [[ -n "$hits" ]]; then
  print -u2 -r -- "✗ check-profile: release identifiers reachable in ${APP:t} ($(print -r -- "$hits" | wc -l | tr -d ' ')):"
  print -r -- "$hits" | awk -F'\t' '{ printf "    %-13s %s: %s\n", $1, $2, $3 }' >&2
  exit 1
fi
print -r -- "✓ check-profile: ${APP:t} ($n files) reaches no release identifier (bundle id, scheme, data folder, handoff folder; Murmur's bundle id, scheme, data folder)"
