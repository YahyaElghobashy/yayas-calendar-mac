# Shared by build.sh, Tests/run-tests.sh and Tools/gate.sh. Source it; it defines no side effects
# beyond exported toolchain variables.
#
#   yc_toolchain          DEVELOPER_DIR, SDK (YC_SDK overrides), SDK_VER, SWIFTC, TMPDIR (~/Library/Caches/YayasCalendar-build/tmp)
#   yc_lock_acquire / yc_lock_release   global build lock (one compile at a time on this Mac); the holder's
#                                       PID sits in the lock, and a waiter reclaims a lock whose holder is gone
#   yc_lock_traps                       release the lock on HUP, INT, ALRM and TERM (scripts add `trap
#                                       yc_lock_release EXIT` themselves: an EXIT trap set in a function fires
#                                       when that function returns)
#   yc_timeout <secs> <cmd…>            run a command in its own process group, stop the group after <secs> of
#                                       time not spent waiting for the build lock; returns 124 on timeout
#   yc_fail <message>                   print and exit 1
#   yc_profile release|dev              the identifier table of Sources/Shared/Profile.swift → $YC_PROFILE[...]
#   yc_handoff_dir                      that profile's installer handoff folder
#   yc_identity_sha1 <name> [keychain]  SHA-1 of the one certificate labelled exactly <name> (empty: none)
#   yc_keychain_unlock <keychain> <pw>  unlock through `security -i` on stdin (never -p on a command line)
#   yc_symbol_counts <mach-o>           "<local> local / <total> symbols" (nm -a)

yc_fail() { print -u2 -r -- "✗ $*"; exit 1; }

# Toolchain: the active Command Line Tools (xcode-select). Optional override: set DEVELOPER_DIR to another
# toolchain folder (for example a second copy of the Command Line Tools with a newer SDK than the system's).
yc_toolchain() {
  if [[ -n "${YC_SDK:-}" ]]; then
    # One-off builds against another SDK (for example the macOS 26 SDK beside the default 27), e.g.
    # YC_SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk Tests/run-tests.sh
    [[ -d "$YC_SDK" ]] || yc_fail "YC_SDK is not a folder: $YC_SDK"
    SDK="$YC_SDK"
    SDK_VER="$(plutil -extract Version raw -o - "$YC_SDK/SDKSettings.json" 2>/dev/null || xcrun --sdk "$YC_SDK" --show-sdk-version)"
  else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    SDK_VER="$(xcrun --sdk macosx --show-sdk-version)"
  fi
  SWIFTC="$(xcrun -f swiftc)"
  # Compiler temp files go to a private cache folder, never /tmp. Not the repo's .work folder: swiftc
  # traps (SIGTRAP, exit 133, no message) when TMPDIR holds non-ASCII or quote characters, which a
  # checkout path may have.
  export TMPDIR="$HOME/Library/Caches/YayasCalendar-build/tmp/"
  mkdir -p "$TMPDIR"
  # One flag per top-level run: a nested script waiting for the build lock writes its PID here, and every
  # yc_timeout of this run stops counting meanwhile (lock waits are not test or build time).
  export YC_LOCK_WAIT_FILE="${YC_LOCK_WAIT_FILE:-${TMPDIR}lock-wait.$$}"
}

# ── Global build lock ────────────────────────────────────────────────────────────────────────────
# A directory, because mkdir is atomic; the holder writes its PID into it. Nested scripts (build.sh →
# run-tests.sh) take it in turn, never at the same time, so there is no re-entry to handle. A holder that
# died without releasing (SIGKILL, or a signal zsh could not trap in time) leaves the folder behind: a
# waiter that finds the recorded PID gone, or reused by a younger process, reclaims it and logs that in
# YayasCalendar-build.lock.log beside it. A lock without a PID file (an older checkout's) is only waited on.
YC_LOCK="$HOME/Library/Caches/YayasCalendar-build.lock"
typeset -gi YC_LOCK_HELD=0

yc_lock_release() {
  if (( YC_LOCK_HELD )); then
    rm -f "$YC_LOCK/pid" 2>/dev/null; rmdir "$YC_LOCK" 2>/dev/null || true; YC_LOCK_HELD=0
  fi
}

yc_lock_traps() {
  trap 'yc_lock_release; exit 129' HUP
  trap 'yc_lock_release; exit 130' INT
  trap 'yc_lock_release; exit 142' ALRM
  trap 'yc_lock_release; exit 143' TERM
}

# alive | dead | unknown (no PID recorded yet, or an older checkout's lock)
yc_lock_holder() {
  zmodload -F zsh/stat b:zstat 2>/dev/null; zmodload zsh/datetime 2>/dev/null
  local pid etime d=0 h=0 m=0 s=0 e
  pid="$(cat "$YC_LOCK/pid" 2>/dev/null || true)"
  [[ "$pid" == <-> ]] || { print -r -- unknown; return }
  etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  [[ -n "$etime" ]] || { print -r -- dead; return }
  e="$etime"
  if [[ "$e" == *-* ]]; then d=$(( 10#${e%%-*} )); e="${e#*-}"; fi
  local -a p=( ${(s.:.)e} )
  if (( ${#p} == 3 )); then h=$(( 10#${p[1]} )); m=$(( 10#${p[2]} )); s=$(( 10#${p[3]} ))
  else m=$(( 10#${p[1]} )); s=$(( 10#${p[2]:-0} )); fi
  local -i running=$(( d * 86400 + h * 3600 + m * 60 + s ))
  local -a mt; zstat -A mt +mtime "$YC_LOCK/pid" 2>/dev/null || { print -r -- alive; return }
  # The PID was reused: a process younger than the lock cannot be the one that took it.
  (( running + 5 < EPOCHSECONDS - mt[1] )) && { print -r -- dead; return }
  print -r -- alive
}

# Moves a dead holder's lock aside atomically (one waiter wins the rename) and removes it.
yc_lock_reclaim() {
  local seen="$1" stale="$YC_LOCK.stale.$$" now
  mv "$YC_LOCK" "$stale" 2>/dev/null || return 0
  if [[ "$(cat "$stale/pid" 2>/dev/null || true)" == "$seen" ]]; then
    rm -rf "$stale"
    now="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    print -r -- "▸ build lock: holder PID $seen is gone; reclaimed $YC_LOCK"
    print -r -- "$now reclaimed from dead PID $seen by PID $$ (${ZSH_ARGZERO:t})" >> "$YC_LOCK.log" 2>/dev/null || true
  else
    mv "$stale" "$YC_LOCK" 2>/dev/null || rm -rf "$stale"   # a live holder took it meanwhile: give it back
  fi
}

yc_lock_acquire() {
  mkdir -p "${YC_LOCK:h}"
  local -i waited=0
  local state holder
  # While this file names a live PID, yc_timeout callers up the chain do not count the time (run-tests.sh).
  local flag="${YC_LOCK_WAIT_FILE:-}"
  until mkdir "$YC_LOCK" 2>/dev/null; do
    state="$(yc_lock_holder)"
    if [[ "$state" == dead ]]; then
      yc_lock_reclaim "$(cat "$YC_LOCK/pid" 2>/dev/null || true)"
      continue
    fi
    [[ -n "$flag" && ! -f "$flag" ]] && print -r -- $$ > "$flag"
    if (( waited % 60 == 0 )); then
      holder="$(cat "$YC_LOCK/pid" 2>/dev/null || true)"
      print -r -- "▸ waiting for the build lock ($YC_LOCK${holder:+, held by PID $holder $(ps -o comm= -p "$holder" 2>/dev/null | sed 's|.*/||')})…"
    fi
    sleep 2; (( waited += 2 ))
    if (( waited >= 3600 )); then
      [[ -n "$flag" ]] && rm -f "$flag"
      yc_fail "build lock still held after an hour: $YC_LOCK (holder: ${state})"
    fi
  done
  print -r -- $$ > "$YC_LOCK/pid"
  YC_LOCK_HELD=1
  [[ -n "$flag" ]] && rm -f "$flag"
  return 0
}

# ── Timeout (macOS has no coreutils `timeout`) ───────────────────────────────────────────────────
# perl forks the command into its own process group and waits. After <secs> of active time it sends TERM
# to the whole group (the script and whatever it is running, so a script's TERM trap can release the build
# lock once its child is gone), then KILL 10 s later. Time spent while $YC_LOCK_WAIT_FILE names a live
# process (a nested script waiting for the build lock) does not count. INT, TERM and HUP sent to perl are
# passed on to the group. External commands only (not shell functions); `exec { $ARGV[0] } @ARGV` never goes
# through /bin/sh (a one-word exec would, and a checkout path may hold spaces or quotes).
yc_timeout() {
  local -i secs=$1; shift
  /usr/bin/perl -e '
    use strict; use warnings; use POSIX qw(:sys_wait_h); use Time::HiRes qw(time sleep);
    my $secs = shift @ARGV; my $flag = $ENV{YC_LOCK_WAIT_FILE} // "";
    my $pid = fork; die "fork failed: $!\n" unless defined $pid;
    if ($pid == 0) { setpgrp(0, 0); exec { $ARGV[0] } @ARGV or die "exec failed: $!\n"; }
    for my $sig (qw(INT TERM HUP)) { $SIG{$sig} = sub { kill $sig, -$pid; kill $sig, $pid; }; }
    my ($used, $last, $status) = (0, time, undef);
    sub waiting { return 0 unless length $flag && -f $flag; open my $fh, "<", $flag or return 0;
                  my $p = <$fh> // ""; chomp $p; return ($p =~ /^\d+$/ && kill(0, $p)) ? 1 : 0; }
    while (1) {
      my $w = waitpid($pid, WNOHANG);
      if ($w == $pid) { $status = $?; last; }
      sleep 0.2; my $now = time; $used += $now - $last unless waiting(); $last = $now;
      if ($used >= $secs) {
        kill "TERM", -$pid; kill "TERM", $pid;
        for (1 .. 50) { if (waitpid($pid, WNOHANG) == $pid) { $status = $?; last; } sleep 0.2; }
        unless (defined $status) { kill "KILL", -$pid; kill "KILL", $pid; waitpid($pid, 0); }
        exit 124;
      }
    }
    exit(($status & 127) ? 128 + ($status & 127) : ($status >> 8));
  ' "$secs" "$@"
}

# ── Build profile: Sources/Shared/Profile.swift is the one identifier table ───────────────────────
# Reads the `static let <key> = "<value>"` lines of one branch (`#if YC_PROFILE_DEV` = dev, `#else` =
# release) into the associative array YC_PROFILE. Tests/Profile proves this reading matches the Swift one.
typeset -gA YC_PROFILE
yc_profile() {
  local want="$1" file="${YC_ROOT:?}/Sources/Shared/Profile.swift" branch="" line k
  [[ "$want" == release || "$want" == dev ]] || yc_fail "yc_profile: release or dev, not '$want'"
  [[ -f "$file" ]] || yc_fail "missing $file"
  YC_PROFILE=()
  while IFS= read -r line; do
    case "$line" in
      *'#if YC_PROFILE_DEV'*) branch=dev; continue ;;
      *'#else'*) [[ "$branch" == dev ]] && branch=release; continue ;;
      *'#endif'*) branch=""; continue ;;
    esac
    [[ "$branch" == "$want" ]] || continue
    if [[ "$line" =~ '^[[:space:]]*static let ([A-Za-z]+) = "([^"\\]*)"[[:space:]]*$' ]]; then
      YC_PROFILE[$match[1]]="$match[2]"
    fi
  done < "$file"
  for k in name bundleId widgetBundleId displayName urlScheme dataRoot \
           keychainOAuth keychainClient keychainLinkKey widgetEntitlements; do
    [[ -n "${YC_PROFILE[$k]:-}" ]] || yc_fail "Profile.swift ($want) has no '$k'"
  done
  [[ -n "$(yc_handoff_dir)" ]] || yc_fail "Profile.swift ($want) has no installer handoff folder"
  [[ "${YC_PROFILE[name]}" == "$want" ]] || yc_fail "Profile.swift: the $want branch is named '${YC_PROFILE[name]}'"
}

# The installer handoff folder of the profile last read: the table's `handoffDir`, or `suiteHandoffDir`
# while the table uses that name. YC_PROFILE itself stays exactly the table (Tests/Profile compares them).
yc_handoff_dir() { print -r -- "${YC_PROFILE[handoffDir]:-${YC_PROFILE[suiteHandoffDir]:-}}" }

# ── Signing helpers (names and hashes only; never a password on a command line) ──────────────────
# SHA-1 of the one certificate whose label is exactly <name>; prints nothing when there is none, and
# fails when there are several (codesign would pick one at random).
yc_identity_sha1() {
  local name="$1" kc="${2:-}" sha="" line
  local -a found
  local out; out="$(security find-certificate -a -c "$name" -Z ${kc:+"$kc"} 2>/dev/null)" || true
  for line in "${(@f)out}"; do
    if [[ "$line" == "SHA-1 hash: "* ]]; then sha="${line#SHA-1 hash: }"
    elif [[ "$line" == *'"labl"<blob>="'"$name"'"' && -n "$sha" ]]; then found+=( "$sha" ); sha=""
    fi
  done
  found=( ${(u)found} )
  (( ${#found} <= 1 )) || yc_fail "${#found} certificates are labelled \"$name\"${kc:+ in ${kc:t}}; keep one"
  (( ${#found} == 0 )) || print -r -- "${found[1]}"
}

# `security -i` reads the command from stdin, so the password never appears in any process's argv.
yc_keychain_unlock() {
  local kc="$1" pw="$2"
  [[ "$pw" != *[\"\\$'\n']* ]] || yc_fail "the keychain password has a quote, backslash or newline; unlock ${kc:t} yourself (security unlock-keychain) and build again"
  print -r -- "unlock-keychain -p \"$pw\" \"$kc\"" | security -i >/dev/null 2>&1
}

# Local symbols counted the way check-public --bundle counts them (nm -a, lowercase type letter or stab).
yc_symbol_counts() {
  local out; out="$(nm -a "$1" 2>/dev/null)" || true
  local -i total=0 local_n=0
  local line
  for line in "${(@f)out}"; do
    [[ -n "$line" ]] || continue
    (( total += 1 ))
    [[ "$line" =~ '^[[:space:]]*[0-9A-Fa-f]*[[:space:]]+[a-z-][[:space:]]' ]] && (( local_n += 1 ))
  done
  print -r -- "$local_n local / $total symbols"
}
