#!/usr/bin/env bash
# Fails when Swift code outside DurableNetworking reaches the network itself. Every request goes through
# DurableNetworking's HTTPTransport or StreamingTransport, so nothing Jai sends skips the outbox and nothing he has seen
# skips the cache.
#
#   no-direct-networking.sh [ROOT]     (ROOT defaults to the current directory)
#
# Scans tracked Swift files under ROOT. Refused: URLSession and its types (DurableNetworking's own URLSessionTransport and
# URLSessionStreamingTransport are how a host makes a transport, so they are allowed), Network.framework (NWConnection,
# NWPathMonitor, `import Network`, ...), CFNetwork's streams and messages, NSURLConnection, and a remote fetch through
# `contentsOf:` on an http(s) URL literal. A URLRequest is allowed: it is a value, and nothing outside this package can
# send it. Comments are ignored.
#
# Exceptions are paths, one glob per line, in ROOT/.network-allowlist (# comments allowed). Each must say why on the
# line above it. DurableNetworking's own sources are its only entry.
set -euo pipefail

root=${1:-.}
cd "$root"

allow=()
if [[ -f .network-allowlist ]]; then
  while IFS= read -r line; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | xargs)
    [[ -n "$line" ]] && allow+=("$line")
  done < .network-allowlist
fi

allowed() {
  local file=$1 glob
  for glob in "${allow[@]+"${allow[@]}"}"; do
    # shellcheck disable=SC2053 # the glob is meant to match
    [[ "$file" == $glob ]] && return 0
  done
  return 1
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  files=$(git ls-files --cached --others --exclude-standard -- '*.swift')
else
  files=$(find . -name '*.swift' -not -path '*/.build/*' | sed 's#^\./##')
fi

failed=0
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  allowed "$file" && continue
  hits=$(perl -ne '
    s{//.*$}{};                                  # line comments
    next unless /\S/;
    if (/\bURLSession(?!(Streaming)?Transport\b)\w*\b/ || /\bNSURLConnection\b/ || /\bNW(Connection|PathMonitor|Listener|Browser|Endpoint|Parameters|Protocol\w*)\b/
        || /^\s*(\@\w+\s+)*import\s+(Network|CFNetwork)\b/ || /\bCF(Read|Write)Stream\w*\b/ || /\bCFHTTPMessage\w*\b/
        || /\bCFStreamCreatePairWith\w*\b/ || /contentsOf:\s*URL\(string:\s*"https?:/) {
      print "$.: $_";
    }
  ' "$file")
  if [[ -n "$hits" ]]; then
    failed=1
    while IFS= read -r hit; do
      printf '%s:%s\n' "$file" "$hit"
    done <<<"$hits"
  fi
done <<<"$files"

if (( failed )); then
  cat >&2 <<'EOF'

Networking outside DurableNetworking. Send requests through an HTTPTransport (or StreamingTransport) the host passes
in: https://github.com/jai/durable-networking#one-way-out. An exception goes in .network-allowlist with its reason.
EOF
  exit 1
fi
echo "no-direct-networking: clean"
