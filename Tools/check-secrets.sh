#!/bin/zsh
# Fails if a secret shape is in the sources or in a built bundle.
#
#   Tools/check-secrets.sh            the sources: tracked files plus untracked files that are not ignored,
#                                     when this folder is the top of its own checkout; otherwise (a "Download
#                                     ZIP" copy, a `git archive` export, or a copy sitting inside another
#                                     repository's ignored folder) every file under the source folder except
#                                     the paths .gitignore lists
#   Tools/check-secrets.sh <path>…    every file under each path (e.g. the built .app), binaries included
#
# The shapes are the GEN-SECRET rules of Tools/public-rules.txt (Google client secret, client id, access
# and refresh tokens, API key; PEM private keys; GitHub and Slack tokens), matched by
# Tools/check-public/engine.pl. Prints only the names of offending files, never the match itself.
set -euo pipefail
ROOT="${0:A:h:h}"
ENGINE="$ROOT/Tools/check-public/engine.pl"
RULES="$ROOT/Tools/public-rules.txt"

typeset -a files hits
if (( $# == 0 )); then
  # Only this folder's own checkout counts: inside another repository's ignored folder, `git ls-files`
  # would list nothing and the scan would pass without reading a single file.
  top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$top" && "${top:A}" == "${ROOT:A}" ]]; then
    label="repository"
    files=( ${(0)"$(git -C "$ROOT" ls-files -z --cached --others --exclude-standard)"} )
    files=( ${files/#/$ROOT/} )
  else
    label="source folder (not a git checkout)"
    # Mirror of .gitignore: build output, scratch space, local config and keys are not sources.
    for f in "$ROOT"/**/*(.DN); do
      rel="${f#$ROOT/}"
      case "$rel" in
        build/*|dist/*|.work/*|Tests/.out/*|.git/*) continue ;;
        .build/*|*/.build/*|renders/*|*/renders/*) continue ;;
        brand/BRAND.md|brand/icon/*) ;;
        brand/*) continue ;;
        *.p12|*.keychain-db|*.mobileprovision|.DS_Store|*/.DS_Store) continue ;;
        Config/*.example.*) ;;
        Config/*.local.*|client_secret*.json|*/client_secret*.json) continue ;;
      esac
      files+=( "$f" )
    done
  fi
else
  label="${(j:, :)${@:t}}"
  for target in "$@"; do
    [[ -e "$target" ]] || { print -u2 -r -- "✗ check-secrets: no such path: $target"; exit 1; }
    files+=( "$target"/**/*(.DN) )
    [[ -f "$target" ]] && files+=( "$target" )
  done
fi

if (( ${#files} )); then
  out=$(print -rN -- "${files[@]}" | /usr/bin/perl "$ENGINE" --mode secrets --rules "$RULES") || {
    print -u2 -r -- "✗ check-secrets: the matcher failed"; exit 1; }
  hits=( ${(f)out} )
fi

if (( ${#hits} )); then
  print -u2 -r -- "✗ check-secrets: secret-shaped strings in ${#hits} file(s) of the $label:"
  for h in "${hits[@]}"; do print -u2 -r -- "    ${h#$ROOT/}"; done
  exit 1
fi
print -r -- "✓ check-secrets: ${#files} files in the $label, no secret shapes"
