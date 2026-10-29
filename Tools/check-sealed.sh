#!/bin/zsh
# Sealed-build guard. Fails when network code or a host
# name appears outside the reviewed places, when the host allowlist drifts, or when a built bundle carries
# code or URLs it should not.
#
#   Tools/check-sealed.sh             the source tree (Sources/**/*.swift, comments stripped, literals kept)
#   Tools/check-sealed.sh <App.app>   … and the built bundle: its Mach-O files, linked frameworks and the
#                                     URLs in its strings
#
# The rules:
#  1. Network APIs (URLSession, URLRequest, Network.framework, CFNetwork, sockets, DNS) only in
#     Sources/Net/HTTP.swift (the Google API session), Sources/Accounts/LogoFetcher.swift (the
#     account logo, HTTPS to the account's own domain), Sources/Auth/LoopbackServer.swift (the OAuth
#     redirect listener, loopback only) and Sources/Sync/WakeTriggers.swift (a path monitor, no traffic).
#  2. Web views only in Sources/UI/MailReaderViews.swift and Sources/UI/MailWebContent.swift (the locked reader and its
#     web content, split by rich mail: JavaScript off, a non-persistent
#     data store, a content rule list). No process launches, AppleScript or JavaScriptCore anywhere.
#  3. HTTP.allowedHosts is exactly the Google hosts below; HTTP.swift refuses redirects and checks the host.
#  4. Every URL literal (scheme://host) names a host from HTTP.allowedHosts, a reviewed browser link (the
#     user's browser opens it; the app never fetches it), a loopback address in LoopbackServer.swift, a
#     reserved .example host, or a host on the reviewed per-file list. Interpolated hosts only in
#     LogoFetcher.swift. Other apps' URL schemes only on the reviewed per-file list (Fathom's two links, D-045;
#     Yaya's Murmur's three, D-046, built with URLComponents from Profile.murmurScheme in MurmurModels.swift).
#  5. Bare host names in string literals only where links are recognised (join links), where mail domains
#     are named, in HTTP.swift, in developer-tool files (fixtures, renders), and Google's two API service
#     names in the setup guide (Sources/Accounts/GoogleSetup.swift).
# A new host or network call is a reviewed edit of this file, never a silent addition.
set -uo pipefail
ROOT="${0:A:h:h}"
cd "$ROOT"

fail=0
say_fail() { print -r -- "✗ $1"; fail=1; }

scan_output=$(/usr/bin/python3 -I - <<'PY'
import re, pathlib

ALLOWED_HOSTS = {"accounts.google.com", "oauth2.googleapis.com", "gmail.googleapis.com",
                 "www.googleapis.com", "openidconnect.googleapis.com"}
# Opened in the user's browser through NSWorkspace (setup guidance, help, credits); never fetched.
BROWSER_HOSTS = {"github.com", "console.cloud.google.com", "console.developers.google.com",
                 "support.google.com", "myaccount.google.com", "developers.google.com",
                 "calendar.google.com", "mail.google.com"}
# Hosts the code names but can never reach: they are not in HTTP.allowedHosts, which refuses them before
# a request exists. The Microsoft provider stays in the source until it is removed.
UNREACHABLE = {"Sources/Auth/OAuthProvider.swift": {"login.microsoftonline.com", "graph.microsoft.com"}}
PER_FILE_URL_HOSTS = {
    "Sources/Auth/LoopbackServer.swift": {"127.0.0.1", "localhost", "[::1]"},
    # Rich mail's Open: NSWorkspace.urlForApplication(toOpen:) with a reserved https URL names the default browser
    # for HTML attachments. Nothing is fetched.
    "Sources/UI/AttachmentActions.swift": {"example.com"},
}
# Other apps' URL schemes, opened with NSWorkspace and handled by that app on this Mac; nothing is fetched. Join with
# Fathom (D-045): fathom://start-capture?url=<meeting> and fathom://open-app.
PER_FILE_SCHEMES = {
    "Sources/UI/FathomModels.swift": {"fathom": {"start-capture", "open-app"}},
    # Yaya's Murmur (D-046): <scheme>://join?event=<id>[&mode=…], helper?event=<id>, open?event=<id>; the scheme is the
    # profile's (yayamurmur, or yayamurmur-dev for a dev build) and the hosts are Murmur's three commands.
    "Sources/UI/MurmurModels.swift": {"yayamurmur": {"join", "helper", "open"}, "yayamurmur-dev": {"join", "helper", "open"}},
}
# Other apps' URL schemes may not be spelled anywhere else, not even outside a literal URL.
OTHER_APP_SCHEMES = {"yayamurmur": {"Sources/Shared/Profile.swift", "Sources/UI/MurmurModels.swift"}}
# Bare names that are identifiers, not places the app goes: the Google setup guide matches Google's API
# service names in a 403 SERVICE_DISABLED answer and puts them in the user's "Enable" link. Its
# "Check my setup" probes go through HTTP.swift to the allowlisted hosts.
PER_FILE_BARE_HOSTS = {
    "Sources/Accounts/GoogleSetup.swift": {"calendar-json.googleapis.com", "gmail.googleapis.com"},
}
NET_FILES = {
    "Sources/Net/HTTP.swift": None,   # everything
    "Sources/Accounts/LogoFetcher.swift": {"URLSession", "URLRequest", "URLSessionTask", "URLSessionConfiguration",
                                           "URLSessionTaskDelegate", "URLSessionDelegate"},
    "Sources/Auth/LoopbackServer.swift": {"NWListener", "NWConnection", "NWParameters", "NWEndpoint", "NWProtocolTCP"},
    "Sources/Sync/WakeTriggers.swift": {"NWPathMonitor", "NWPath"},
}
WEB_FILES = {"Sources/UI/MailReaderViews.swift", "Sources/UI/MailWebContent.swift"}
# Web view code allowed only between `#if YC_DEV_TOOLS` and `#endif` (the render harness's window-less snapshot of
# the reader's page; release builds leave it out).
DEV_WEB_FILES = {"Sources/UI/RichTextSnapshot.swift"}

def dev_fenced_lines(text):
    """Line numbers inside `#if YC_DEV_TOOLS` … `#endif` (no nesting)."""
    inside, out = False, set()
    for n, raw in enumerate(text.split("\n"), 1):
        t = raw.strip()
        if t.startswith("#if YC_DEV_TOOLS"): inside = True
        elif t.startswith("#endif"): inside = False
        elif inside: out.add(n)
    return out
# Files whose job is to recognise links or name mail domains: bare host literals are data there.
BARE_HOST_FILES = {"Sources/Sync/JoinLinks.swift", "Sources/Notify/JoinGuard.swift",
                   "Sources/App/RouteDecisions.swift", "Sources/Accounts/AccountNaming.swift",
                   "Sources/Notify/DeckExport.swift", "Sources/Sync/MailSyncer.swift",
                   "Sources/Net/HTTP.swift"}
# Developer tools (compiled only with -D YC_DEV_TOOLS) and the sample cast: fixture data, never fetched.
DEV_FILES = re.compile(r"^Sources/(App/(Headless\w*|SelfTest|\w*Renders?)\.swift|Contracts/Fixtures\.swift|Accounts/DevClientFile\.swift)$")
FIXTURE_HOSTS = {"meet.google.com", "zoom.us", "teams.microsoft.com", "calendar.google.com"}

def code_and_strings(text):
    """(line_no, code without comments, [string literals]) per line. Literals keep their quotes."""
    i, n, line = 0, len(text), 1
    buf, lits, rows = [], [], []
    def flush():
        rows.append((line, "".join(buf), list(lits)))
    while i < n:
        c = text[i]
        if text.startswith("//", i):
            while i < n and text[i] != "\n": i += 1
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j): depth += 1; j += 2
                elif text.startswith("*/", j): depth -= 1; j += 2
                else: j += 1
            line += text.count("\n", i, j); i = j; continue
        m = re.match(r'(#*)"""', text[i:i+8])
        if m:
            close = '"""' + m.group(1)
            j = text.find(close, i + len(m.group(0))); j = n if j < 0 else j + len(close)
            lit = text[i:j]; lits.append(lit); buf.append('""'); line += lit.count("\n"); i = j; continue
        m = re.match(r'(#+)"', text[i:i+6])
        if m or c == '"':
            hashes = m.group(1) if m else ""
            close = '"' + hashes
            j = i + len(hashes) + 1
            while j < n and text[j] != "\n":
                if not hashes and text[j] == "\\": j += 2; continue
                if text.startswith(close, j): j += len(close); break
                j += 1
            lit = text[i:j]; lits.append(lit); buf.append('""'); i = j; continue
        if c == "\n":
            flush(); buf.clear(); lits.clear(); line += 1; i += 1; continue
        buf.append(c); i += 1
    flush()
    return rows

NET = re.compile(r'\b(URLSession\w*|NSURLSession|URLRequest|NSURLConnection|NW(Connection|Listener|Browser|PathMonitor|Path|Parameters|Endpoint|Protocol\w*)|nw_[a-z_]+|CFStream\w*|CFSocket\w*|CFHost\w*|CFHTTPMessage\w*|WebSocket\w*|dataTask|uploadTask|downloadTask|SCNetworkReachability\w*|getaddrinfo|DNSService\w*|NSStream|sendto|recvfrom)\b|(?<![.\w])(?<!func )(socket|connect)\s*\((?!\s*\w+\s*:)')
WEB = re.compile(r'\b(WK\w*WebView|WebView|WKWebsiteDataStore|JSContext|JSValue)\b')
NEVER = re.compile(r'\b(?:Process\s*\(|(?:NSTask|launchPath|posix_spawn\w*|NSUserUnixTask|NSAppleScript|OSAScript|NSUbiquitousKeyValueStore|CKContainer|CKDatabase)\b)|(?<![.\w])(?<!func )system\s*\((?!\s*\))(?!\s*\w+\s*:)')
REMOTE_LOAD = re.compile(r'(contentsOf|contentsOfURL)\s*:\s*URL\s*\(\s*string')
URL_RE = re.compile(r'([A-Za-z][A-Za-z0-9+.-]*)://(\[[0-9a-fA-F:]+\]|[A-Za-z0-9.-]*|\\\()')
TLDS = "com|net|org|io|co|us|app|dev|live|me|ai|aws|si|gov|edu|uk|de|fr|eu|info|biz|cloud|tech|ly|gl|gg|so|to|tv|xyz"
BARE = re.compile(r'^"(?:[a-z0-9-]+\.)+(' + TLDS + r')"$')
OWN_SCHEMES = {"yayacal", "yayacal-dev", "file", "mailto"}

problems = []
for f in sorted(pathlib.Path("Sources").rglob("*.swift")):
    path = str(f)
    dev = bool(DEV_FILES.match(path))
    source = f.read_text(errors="replace")
    fenced = dev_fenced_lines(source) if path in DEV_WEB_FILES else set()
    for ln, code, lits in code_and_strings(source):
        where = f"{path}:{ln}"
        for m in NET.finditer(code):
            api = m.group(0).strip().rstrip("(").strip()
            allowed = NET_FILES.get(path, set())
            if allowed is not None and api not in allowed:
                problems.append(f"network API {api} outside its reviewed place: {where}")
        if WEB.search(code) and path not in WEB_FILES and ln not in fenced:
            problems.append(f"web view outside the locked reader: {where}: {code.strip()[:100]}")
        if NEVER.search(code):
            problems.append(f"process launch / scripting / iCloud surface: {where}: {code.strip()[:100]}")
        if REMOTE_LOAD.search(code) or any(REMOTE_LOAD.search(l) for l in lits):
            problems.append(f"loader built from a URL string: {where}")
        for lit in lits:
            for scheme, host in URL_RE.findall(lit):
                scheme = scheme.lower(); host = host.lower()
                if scheme in OWN_SCHEMES or host == "":
                    continue
                if scheme in PER_FILE_SCHEMES.get(path, {}):
                    if host not in PER_FILE_SCHEMES[path][scheme]:
                        problems.append(f"URL {scheme}://{host} not reviewed for this file: {where}")
                    continue
                if host == "\\(":
                    if path != "Sources/Accounts/LogoFetcher.swift":
                        problems.append(f"URL with an interpolated host outside LogoFetcher.swift: {where}")
                    continue
                if scheme not in ("https", "http"):
                    problems.append(f"URL scheme {scheme}:// not reviewed: {where}")
                    continue
                ok = (host in ALLOWED_HOSTS or host in BROWSER_HOSTS or host.endswith(".example")
                      or host in PER_FILE_URL_HOSTS.get(path, set()) or host in UNREACHABLE.get(path, set())
                      or (dev and host in FIXTURE_HOSTS))
                if scheme == "http" and host not in PER_FILE_URL_HOSTS.get(path, set()):
                    ok = ok and False
                if not ok:
                    problems.append(f"URL {scheme}://{host} not reviewed for this file: {where}")
            for name, homes in OTHER_APP_SCHEMES.items():
                if name in lit.lower() and path not in homes and not dev:
                    problems.append(f"{name} named outside its reviewed files: {where}")
            if BARE.match(lit) and not re.match(r'^"(com|org|net|io)\.', lit):   # reverse-DNS ids are names, not hosts
                host = lit.strip('"')
                if not (path in BARE_HOST_FILES or dev or host in ALLOWED_HOSTS or host in BROWSER_HOSTS
                        or host in PER_FILE_BARE_HOSTS.get(path, set())):
                    problems.append(f"host name {host} outside the link and domain files: {where}")

# Pins on the reviewed places.
http = pathlib.Path("Sources/Net/HTTP.swift").read_text()
m = re.search(r'static let allowedHosts: Set<String> = \[(.*?)\]', http, re.S)
hosts = set(re.findall(r'"([^"]+)"', m.group(1))) if m else set()
if hosts != ALLOWED_HOSTS:
    problems.append(f"HTTP.allowedHosts drifted: {sorted(hosts)} (reviewed: {sorted(ALLOWED_HOSTS)})")
for need in ["willPerformHTTPRedirection", "allowedHosts.contains(host)", ".ephemeral", "tlsMinimumSupportedProtocolVersion"]:
    if need not in http:
        problems.append(f"HTTP.swift lost its {need}")
for f, names in UNREACHABLE.items():
    for h in names & hosts:
        problems.append(f"{h} is listed as unreachable for {f} but HTTP.allowedHosts allows it")
logo = pathlib.Path("Sources/Accounts/LogoFetcher.swift").read_text()
if "willPerformHTTPRedirection" not in logo:
    problems.append("LogoFetcher.swift lost its redirect guard")
if re.search(r'"http://', logo):
    problems.append("LogoFetcher.swift fetches over plain http")
loop = pathlib.Path("Sources/Auth/LoopbackServer.swift").read_text()
if "acceptLocalOnly = true" not in loop or ".loopback" not in loop:
    problems.append("LoopbackServer.swift must listen on loopback only (acceptLocalOnly, .loopback)")
reader = pathlib.Path("Sources/UI/MailReaderViews.swift").read_text()
if "WKContentRuleList" not in reader:
    problems.append("MailReaderViews.swift lost WKContentRuleList")
content = pathlib.Path("Sources/UI/MailWebContent.swift").read_text()
for need in ["allowsContentJavaScript = false", ".nonPersistent()"]:
    if need not in content:
        problems.append(f"MailWebContent.swift lost {need}")
for wf in sorted(WEB_FILES | DEV_WEB_FILES):
    if re.search(r"allowsContentJavaScript\s*=\s*true", pathlib.Path(wf).read_text()):
        problems.append(f"{wf} turns content JavaScript on")
print("\n".join(problems))
PY
)
[[ -n "$scan_output" ]] && say_fail "source scan:"$'\n'"$scan_output"

# Optional: the built bundle.
if (( $# >= 1 )); then
  app="$1"
  [[ -d "$app" ]] || { say_fail "no such bundle: $app"; app=""; }
  if [[ -n "$app" ]]; then
    exe="$app/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app/Contents/Info.plist")"
    appex_dir=( "$app"/Contents/PlugIns/*.appex(N) )
    widget_exe=""
    (( ${#appex_dir} == 1 )) && widget_exe="${appex_dir[1]}/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "${appex_dir[1]}/Contents/Info.plist")"
    machos=( ${(f)"$(find "$app" -type f -exec sh -c 'file -b "$1" | grep -q Mach-O && echo "$1"' _ {} \;)"} )
    expected=( "$exe" ${widget_exe:+"$widget_exe"} )
    [[ "${(j:|:)${(o)machos}}" == "${(j:|:)${(o)expected}}" ]] || say_fail "unexpected executable code in the bundle: ${machos[*]#$app/}"
    # URLs in the binaries: Google API hosts, the reviewed browser links, loopback, Apple/W3C schema ids,
    # reserved .example hosts (dev builds' fixtures) and the unreachable Microsoft endpoints; example.com is
    # rich mail's default-browser probe (AttachmentActions.swift, never fetched).
    ok_hosts='(accounts\.google\.com|oauth2\.googleapis\.com|gmail\.googleapis\.com|www\.googleapis\.com|openidconnect\.googleapis\.com|github\.com|console\.cloud\.google\.com|console\.developers\.google\.com|support\.google\.com|myaccount\.google\.com|developers\.google\.com|calendar\.google\.com|mail\.google\.com|127\.0\.0\.1|localhost|www\.apple\.com|www\.w3\.org|[a-z0-9.-]+\.example|example\.com|login\.microsoftonline\.com|graph\.microsoft\.com|meet\.google\.com|zoom\.us|teams\.microsoft\.com)'
    for bin in "${expected[@]}"; do
      bad="$(strings -a "$bin" | grep -oE '[A-Za-z][A-Za-z0-9+.-]*://[A-Za-z0-9.-]+' | sort -u \
             | grep -vxE "https?://$ok_hosts|file://|yayacal://|yayacal-dev://|fathom://(start-capture|open-app)|yayamurmur(-dev)?://(join|helper|open)" || true)"
      [[ -z "$bad" ]] || say_fail "unexpected URL in ${bin:t}: ${(f)bad}"
      print -r -- "  ${bin:t} URLs: $(strings -a "$bin" | grep -oE 'https?://[A-Za-z0-9.-]+' | sort -u | tr '\n' ' ')"
    done
    if [[ -n "$widget_exe" ]]; then
      widget_libs="$(otool -L "$widget_exe" | grep -E '/(WebKit|Network|CFNetwork|CloudKit|JavaScriptCore)\.framework/' || true)"
      [[ -z "$widget_libs" ]] || say_fail "the widget links network or web frameworks: ${(f)widget_libs}"
    fi
    app_libs="$(otool -L "$exe" | grep -E '/(CloudKit|JavaScriptCore)\.framework/' || true)"
    [[ -z "$app_libs" ]] || say_fail "the app links frameworks it should not: ${(f)app_libs}"
  fi
fi

if (( fail )); then
  print -r -- "✗ sealed check FAILED"
  exit 1
fi
print -r -- "✓ sealed check passed (network only via Sources/Net/HTTP.swift → ${#${(s: :)${:-accounts oauth2 gmail www openidconnect}}} Google hosts; logos, loopback and the path monitor in their reviewed files)"
