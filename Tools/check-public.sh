#!/bin/bash
# Tools/check-public.sh: leak check for everything that leaves this Mac in public.
#
# Modes (one per run):
#   --tree DIR|REF       The archive view: the file list of `git archive` (git ls-files minus the paths
#                        with export-ignore) of a checkout DIR, or of REF in the current repository.
#                        A folder that is not a checkout, or is ignored inside one, is scanned as plain
#                        files. Any hit in an archive file fails, so a file with a deny-list hit that
#                        lost its export-ignore fails; hits inside export-ignored files are counted as
#                        information only. Non-text files also get the --images parse.
#   --staged             The index of the current repository (pre-commit hook), same rules as --tree.
#   --bundle APP         A built .app or .appex, repeatable. Every Mach-O goes through strings -a -n 4,
#                        a raw byte scan (printable runs, so UTF-8 text counts), the same bytes with
#                        each length-prefixed Swift identifier set apart, nm -a | swift-demangle and
#                        the bytes of the __swift5_reflstr and __swift5_typeref sections; plists,
#                        other resources and images too. Rules of the classes the deny list marks sub
#                        match as substrings here, because Swift mangling puts word characters on both
#                        sides of a name.
#                        Prints each Mach-O's local symbol count and the caveat on short Swift
#                        string literals.
#   --history GITDIR     Commit messages and added lines of `git log -p` on every ref (or the range),
#     [--range A..B]     annotated tags and binary blobs. Author, committer and tagger must equal a line
#     [--refs]           of the identity allow file whenever it exists (required with --strict); the
#                        generic email rule never sees them. --refs also fails on any ref outside
#                        refs/heads/*, refs/tags/* and remote-tracking refs.
#   --images [PATH...]   Lists every non-text file for the eye check and parses it: PNG chunk whitelist
#                        (IHDR PLTE tRNS IDAT IEND sRGB iCCP pHYs gAMA cHRM), generic colour profiles
#                        only, no JPEG APP1/APP11/APP13/COM, the same PNG check inside .icns, no PDF XMP
#                        and no PDF Author/Creator/Producer naming a person or a machine.
#                        Without PATH: the non-text files of the current checkout.
#   --text FILE...       Prose that leaves the Mac outside the repo (release notes, repo description,
#                        posts, video copy). Every hit fails; with --promo, hits of the classes the deny
#                        list marks promo pass.
#   --self-test          Plants every kind of hit at run time under .work/check-public-selftest/ and
#                        asserts that each fires and that clean controls pass. Works without the
#                        private deny list (its cases are then skipped and reported as skipped).
# Options:
#   --strict             The private deny list and the private allow file are required: a missing one is
#                        exit 2. Release and publish steps use it. Without --strict a missing list is a
#                        warning and only the generic rules run, which is what strangers and CI get.
#   --promo              With --text only, for promo copy (see --text).
#
# Files:
#   Tools/public-rules.txt    generic rules, committed, no personal data (see its header)
#   Tools/public-allow.txt    reviewed author credit, committed (see its header)
#   $YC_DENYLIST              private deny list. Default: <main checkout>/.work/private/deny.txt, where
#                             the main checkout is "$(git rev-parse --path-format=absolute --git-common-dir)/..",
#                             so every worktree finds the same list.
#   $YC_PRIVATE_ALLOW         private allow file, the format of Tools/public-allow.txt: reviewed exceptions
#                             that would describe a private class. Default: the deny list's USE allow line.
#   $YC_ALLOW_IDENTITY        the private identity allow. Default: the deny list's USE identity line.
#   $YC_DENYLIST_PROBES       optional private probe file for --self-test. Default: the deny list's USE
#                             probes line.
#   $YC_PUBLIC_RULES, $YC_PUBLIC_ALLOW replace the two committed files (the self-test uses them).
#
# Deny-list format (the contents are never printed, logged or committed):
#   UTF-8, mode 0600. Lines starting with # are comments, blank lines are ignored. Every other line has
#   four fields separated by one TAB:
#     RULE_ID<TAB>CLASS<TAB>FLAGS<TAB>PERL_REGEX      a rule
#     CLASS<TAB>Pnn<TAB>PROPS<TAB>-                   the properties of a class
#     USE<TAB>identity|allow|probes<TAB>FILE<TAB>-    a companion file, relative to the list's folder
#     FOLD<TAB>U+XXXX<TAB>U+YYYY|-<TAB>-              a letter variant: the decoded forms read the first
#                                                     character as the second, or drop it ('-')
#   CLASS is an opaque id, P01 to P99; what each class covers is written only in the list's own header.
#   RULE_ID is CLASS-NN.
#   FLAGS is a comma list, or "-" for none:
#     i      case-insensitive
#     w      wrap in word boundaries (text, tree and history modes)
#     s      substring, also in text modes
#     short  a short tag; its hits end in REVIEW-BY-EYE
#     ctx    the pattern already encodes the context it needs
#   PROPS is a comma list, or "-" for none:
#     sub    in --bundle mode the class's rules always match as substrings (w is ignored, boundary-only
#            lookarounds are dropped; short-tag rules keep their context)
#     promo  --text --promo lets the class's hits pass
#     name, term   self-test hints: the identifier shapes it builds from the class's probes (see
#            Tools/check-public/selftest.pl)
#   The identity allow (0600): "name<TAB>email" lines, the author and committer identities allowed by
#   --history, nothing else.
#
# Disguised forms (private rules only): besides every line as written, the private rules run over a
#   decoded, normalized copy: JSON, Swift and \x escapes (also escaped twice, as JSON inside JSON
#   writes them), HTML entities, %XX, quoted-printable and RFC 2047 encoded words decoded; a written
#   control escape (\n, \t, \r, \f, \b, \v, \0 in JSON, ICS and Swift strings) read as a space; every
#   Unicode space, tabs and doubled spaces made one space; Unicode dashes made '-'; curly quotes made
#   straight; invisible format characters (zero-width characters, soft hyphens, bidi marks) and
#   combining marks removed; the decimal digits of every script made 0-9; compatibility forms folded
#   (NFKC: fullwidth letters, ligatures, presentation forms); the list's FOLD lines applied;
#   concatenated string literals joined; leading comment and quote markers dropped. The same steps
#   run for every script.
#   That copy is read with every line joined to the next by a space (hard wraps; a blank line stays a
#   break), again with '+' before a letter as a space, again with '/' between words as a space
#   (skipped for a pattern that contains '/', so a rule can exclude paths), and with each pair of lines
#   joined with nothing (folds inside a word), and also without the '-' of a word hyphenated at the
#   break (both skipped for short-tag rules). A hit is reported at the first line it touches; allow
#   digests still apply to a hit inside one line. In --bundle mode only names, plists and text
#   resources get these forms. YC_NO_VIEWS=1 turns them off, for timing comparisons only.
# Decoded generic rules: the path, mail, zone and meeting rules also run over the decoded copy, line by
#   line (JSONEncoder's \/, %2F, %40, &#64;), with or without the private deny list.
#
# Output: one line per hit, "RULE-ID path:line" (line 0 is the file name itself), or in --bundle mode
#   "RULE-ID bundle:<file>:<section>". Short-tag hits end in " REVIEW-BY-EYE". The matched text is never
#   printed: a match of any rule inside a printed path is shown as ***, and a path component that
#   matches only in its decoded, normalized form is shown as *** whole. Warnings never name the home
#   folder. INFO, EYE and CAVEAT lines carry counts and file kinds only. The last line is
#   "SUMMARY mode=... hits=N <CLASS>=<count>... exit=N".
# Exit: 0 clean, 1 any hit, 2 usage or configuration error.
#
# Needs only stock macOS and the Command Line Tools: bash 3.2, perl, git, strings, nm, swift-demangle,
# plutil. Paths may contain spaces, apostrophes and emoji.

set -o pipefail

SELF="${BASH_SOURCE[0]}"
case "$SELF" in /*) ;; *) SELF="$PWD/$SELF" ;; esac
TOOLS=$(cd "$(dirname "$SELF")" && pwd -P) || exit 2
ENGINE="$TOOLS/check-public/engine.pl"
PERL=/usr/bin/perl
[ -x "$PERL" ] || PERL=perl

usage() {
  sed -n '2,/^$/p' "$SELF" | sed -e 's/^# \{0,1\}//' >&2
  exit 2
}
die2() {
  echo "ERROR: $1" >&2
  exit 2
}

mode=""
strict=0
promo=0
refs=0
range=""
targets=()
set_mode() {
  [ -z "$mode" ] || [ "$mode" = "$1" ] || die2 "one mode per run (see --help)"
  mode="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tree)
      set_mode tree
      [ $# -ge 2 ] || die2 "--tree needs a folder or a git ref"
      [ ${#targets[@]} -eq 0 ] || die2 "--tree takes one folder or ref"
      targets+=("$2"); shift 2 ;;
    --staged) set_mode staged; shift ;;
    --bundle)
      set_mode bundle
      [ $# -ge 2 ] || die2 "--bundle needs an .app or .appex folder"
      targets+=("$2"); shift 2 ;;
    --history)
      set_mode history
      [ $# -ge 2 ] || die2 "--history needs a git directory or checkout"
      targets+=("$2"); shift 2 ;;
    --range)
      [ $# -ge 2 ] || die2 "--range needs A..B"
      range="$2"; shift 2 ;;
    --refs) refs=1; shift ;;
    --images)
      set_mode images; shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do targets+=("$1"); shift; done ;;
    --text)
      set_mode text; shift
      while [ $# -gt 0 ] && [ "${1#--}" = "$1" ]; do targets+=("$1"); shift; done
      [ ${#targets[@]} -gt 0 ] || die2 "--text needs at least one file" ;;
    --strict) strict=1; shift ;;
    --promo) promo=1; shift ;;
    --self-test) set_mode selftest; shift ;;
    -h|--help) usage ;;
    *) die2 "unknown argument (see --help)" ;;
  esac
done

[ -n "$mode" ] || usage
if [ -n "$range" ] || [ $refs = 1 ]; then
  [ "$mode" = history ] || die2 "--range and --refs go with --history"
fi
if [ $promo = 1 ] && [ "$mode" != text ]; then
  die2 "--promo goes with --text"
fi

# The main checkout, from any worktree: "<git common dir>/..".
MAIN=""
common=$(git -C "$TOOLS" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
  || common=$(git -C "$TOOLS" rev-parse --git-common-dir 2>/dev/null) || common=""
if [ -n "$common" ]; then
  case "$common" in /*) ;; *) common="$TOOLS/$common" ;; esac
  MAIN=$(cd "$common/.." 2>/dev/null && pwd -P) || MAIN=""
fi

DENY="${YC_DENYLIST:-}"
if [ -z "$DENY" ] && [ -n "$MAIN" ]; then DENY="$MAIN/.work/private/deny.txt"; fi
# The companion files default to the deny list's USE lines (the engine and the self-test read them).
IDENT="${YC_ALLOW_IDENTITY:-}"
PRIV_ALLOW="${YC_PRIVATE_ALLOW:-}"
RULES="${YC_PUBLIC_RULES:-$TOOLS/public-rules.txt}"
ALLOW="${YC_PUBLIC_ALLOW:-$TOOLS/public-allow.txt}"

if [ "$mode" = selftest ]; then
  top=$(git -C "$TOOLS" rev-parse --show-toplevel 2>/dev/null) || top=$(cd "$TOOLS/.." && pwd -P)
  PROBES="${YC_DENYLIST_PROBES:-}"
  CP_SCRIPT="$TOOLS/check-public.sh" CP_TOOLS="$TOOLS" CP_SELFTEST_DIR="$top/.work/check-public-selftest" \
    CP_DENY="$DENY" CP_PROBES="$PROBES" exec "$PERL" "$TOOLS/check-public/selftest.pl"
fi

args=(--mode "$mode" --rules "$RULES" --allow "$ALLOW" --repo "$PWD")
[ -n "$DENY" ] && args+=(--deny "$DENY")
[ -n "$IDENT" ] && args+=(--identity "$IDENT")
[ -n "$PRIV_ALLOW" ] && args+=(--private-allow "$PRIV_ALLOW")
[ $strict = 1 ] && args+=(--strict)
[ $promo = 1 ] && args+=(--promo)
[ $refs = 1 ] && args+=(--refs)
[ -n "$range" ] && args+=(--range "$range")
for t in ${targets[@]+"${targets[@]}"}; do args+=(--target "$t"); done

exec "$PERL" "$ENGINE" "${args[@]}"
