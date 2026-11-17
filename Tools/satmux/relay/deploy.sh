#!/usr/bin/env bash
# The satmux relay in FINN staging (ap-southeast-1), a work experiment. See README.md.
#
#   deploy.sh deploy         key and monitor token (only if missing), then whatever of the relay is missing
#   deploy.sh replace        the same, and rebuild the instance when host/ changed (the Elastic IP stays)
#   deploy.sh status         the relay's address, instance and state
#   deploy.sh push-secrets   SATMUX_HOST, SATMUX_PORT, SATMUX_PSK into the agent-pager Worker
#   deploy.sh rotate-key     new key in SSM and here, restart the relay, push-secrets
#   deploy.sh check          the service, the pinned satmux.py and port 8444, read on the host
#   deploy.sh smoke          upstream client on this machine: timed fetches through the relay
#   deploy.sh destroy        delete everything the relay made, and the key
#
# AWS calls go through Executor's AWS app, account FINN AWS Staging (relay.py runs in its sandbox), so no local
# AWS session or MFA is needed. The key's local copy is ~/.credentials/satmux (SATMUX_PSK=, 0600); it goes to
# its consumers through files and pipes, never to a terminal.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(git -C "$here" rev-parse --show-toplevel)"
account=211125443320                                      # FINN staging; relay.py refuses any other
executor_account=acc_044e34d7-6a34-4865-a80c-e02b9ffa6074 # Executor's aws app, FINN AWS Staging
worker_account=f8966459d8cd6c21a77da30f7e1719ef           # the agent-pager Worker's (worker/wrangler.jsonc)
satmux_commit=2922ebb835d0eb939ddbdfa3b5e7e0f247a0dc0c    # upstream Th0rgal/satmux (MIT), pinned
satmux_sha256=98f5e4f439883b806c211acacca63abf8eb1c1748f4179098ad087e8ff404d04
egress_alarm_gb=5 # the monitor's egress check is degraded above this many GB out in a UTC day
port=8444
credential="$HOME/.credentials/satmux"
monitor_id=satmux-relay
monitor_tokens="$HOME/.credentials/agent-monitor" # MONITOR_TOKENS, the monitor Worker's copy (AGENTS.md)
monitor_worker=finn-agent-monitor-production

die() {
	echo "deploy.sh: $*" >&2
	exit 1
}

# Runs relay.py's main(action, cfg) in Executor's AWS sandbox and prints its RESULT object.
relay() {
	local action="$1" cfg="$2" code js out line result
	code="$(
		echo 'Any = Awaitable = Callable = Call = dict  # stand-ins for the dropped typing imports'
		grep --color=never -v '# local-only' "$here/relay.py"
		printf '\nawait main(call_boto3, %s, json.loads(%s))\n' "$(jq -n --arg a "$action" '$a')" "$(jq -n --arg c "$cfg" '$c')"
	)"
	js="$(jq -n --arg acc "$executor_account" --arg code "$code" \
		'{code: ("const r = await tools.aws.aws___run_script({accountId: " + ($acc | tojson) + ", input: {code: " + ($code | tojson) + "}}); return r.structuredContent ?? r;")}')"
	out="$(mcporter call executor.execute --args "$js")"
	line="$(jq -r '.execution.value.stdout // empty' <<<"$out" | grep --color=never '^RESULT ' | tail -1 || true)"
	[ -n "$line" ] || die "Executor ($action): $(jq -c '.execution.value.error // .execution.error.message // .' <<<"$out" | head -c 800)"
	result="${line#RESULT }"
	jq -e .ok >/dev/null <<<"$result" || die "$action: $(jq -r .error <<<"$result")"
	printf '%s\n' "$result"
}

base_cfg() {
	jq -n --arg account "$account" '{account: $account}'
}

apply_cfg() {
	local host_sha files
	host_sha="$(cat "$here"/host/* | shasum -a 256 | cut -d' ' -f1)"
	files="$(for f in "$here"/host/*; do jq -n --arg n "${f##*/}" --rawfile c "$f" '{($n): $c}'; done | jq -s add)"
	jq -n --arg account "$account" --arg commit "$satmux_commit" --arg sha "$satmux_sha256" --arg host_sha "$host_sha" \
		--argjson egress "$egress_alarm_gb" --argjson files "$files" \
		'{account: $account, satmux_commit: $commit, satmux_sha256: $sha, host_sha256: $host_sha,
      egress_alarm_gb: $egress, files: $files}'
}

# Writes one SSM SecureString through relay.py; the value comes from a file, never from argv or a terminal.
put_secret() { # parameter-name value-file
	relay put-secret "$(jq -n --arg account "$account" --arg name "$1" --rawfile value "$2" \
		'{account: $account, name: $name, value: ($value | rtrimstr("\n"))}')" >/dev/null
}

read_psk() { # file
	awk -F= '$1=="SATMUX_PSK"{print $2; exit}' "$1"
}

# A fresh 32-byte key as 64 hex characters, written to SSM from the file it was generated into.
new_psk() { # file
	(umask 077 && printf 'SATMUX_PSK=%s\n' "$(openssl rand -hex 32)" >"$1")
	put_secret /satmux/psk <(read_psk "$1")
}

# The relay's check-in bearer: added to MONITOR_TOKENS (the local copy, then the monitor Worker's secret, which
# is the whole object) and to SSM for the host. Run once; the token stays until destroy.
new_monitor_token() {
	local updated
	updated="$(umask 077 && mktemp "$monitor_tokens.new.XXXXXX")"
	jq --arg id "$monitor_id" --arg t "$(openssl rand -hex 32)" '.MONITOR_TOKENS[$id] = $t' "$monitor_tokens" >"$updated"
	cp -p "$monitor_tokens" "$monitor_tokens.bak-$(date +%Y%m%d)"
	mv "$updated" "$monitor_tokens"
	jq -c .MONITOR_TOKENS "$monitor_tokens" | put_monitor_worker_secret MONITOR_TOKENS
	put_secret /agent-pager/monitor-tokens/$monitor_id <(jq -r --arg id "$monitor_id" '.MONITOR_TOKENS[$id]' "$monitor_tokens")
}

monitor_credential() { # name
	awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,""); print; exit}' "$HOME/.credentials/cloudflare-finn-agent-monitor"
}

put_monitor_worker_secret() { # name; value on stdin
	mkdir -p "$repo/tmp"
	(cd "$repo/tmp" && CLOUDFLARE_API_TOKEN="$(monitor_credential CLOUDFLARE_API_TOKEN)" \
	CLOUDFLARE_ACCOUNT_ID="$(monitor_credential CLOUDFLARE_ACCOUNT_ID)" \
		npx --yes wrangler@4 secret put "$1" --name "$monitor_worker" >/dev/null)
}

on_host() { # script
	local result
	result="$(relay run "$(jq -n --arg account "$account" --arg s "$1" '{account: $account, script: $s}')")"
	jq -r '.stdout, .stderr' <<<"$result"
	[ "$(jq -r .status <<<"$result")" = Success ] || die "on the host: $(jq -r .status <<<"$result")"
}

relay_host() {
	relay status "$(base_cfg)" | jq -r .host
}

cloudflare_token() {
	awk -F= '$1=="CLOUDFLARE_API_TOKEN"{sub(/^[^=]*=/,""); print; exit}' "$HOME/.credentials/cloudflare"
}

# Runs outside worker/ by name: worker/wrangler.jsonc only parses after `deploy/prhub.sh fetch`.
put_worker_secret() { # name; value on stdin
	mkdir -p "$repo/tmp"
	(cd "$repo/tmp" && CLOUDFLARE_API_TOKEN="$(cloudflare_token)" CLOUDFLARE_ACCOUNT_ID="$worker_account" \
		npx --yes wrangler@4 secret put "$1" --name agent-pager >/dev/null)
}

push_secrets() {
	[ -f "$credential" ] || die "$credential is missing: run rotate-key"
	relay_host | tr -d '\n' | put_worker_secret SATMUX_HOST
	printf '%s' "$port" | put_worker_secret SATMUX_PORT
	read_psk "$credential" | tr -d '\n' | put_worker_secret SATMUX_PSK
	echo "Worker secrets SATMUX_HOST, SATMUX_PORT, SATMUX_PSK set"
}

check() {
	on_host "set -e
systemctl is-enabled satmux.service
systemctl is-active satmux.service
echo \"satmux.py sha256 \$(sha256sum /opt/satmux/satmux.py | cut -d' ' -f1)\"
ss -ltnH 'sport = :$port' | grep -q . && echo 'listening on $port'
sysctl -n net.ipv4.tcp_congestion_control"
	local address
	address="$(relay_host)"
	nc -z -G 5 "$address" "$port" && echo "reachable from $(hostname -s): $address:$port"
}

# Runs upstream's client here on spare ports and times the same fetches direct and through the relay.
smoke() {
	local address work worker_url
	address="$(relay_host)"
	worker_url="$(awk -F= '$1=="WORKER_URL"{sub(/^[^=]*=/,""); print; exit}' "$HOME/.credentials/agent-pager")"
	work="$repo/tmp/satmux-smoke"
	mkdir -p "$work"
	curl -fsSL -o "$work/satmux.py" "https://raw.githubusercontent.com/Th0rgal/satmux/$satmux_commit/satmux.py"
	echo "$satmux_sha256  $work/satmux.py" | shasum -a 256 -c - >/dev/null
	SATMUX_PSK="$(read_psk "$credential")" python3 -I "$work/satmux.py" client --host "$address" --port "$port" \
		--carriers 4 --socks-port 21080 --http-port 28080 --fast-port 28081 --gh-sock "$repo/tmp/smux.sock" \
		>"$work/client.log" 2>&1 &
	smoke_client=$!
	trap 'kill "$smoke_client" 2>/dev/null || true' EXIT
	for _ in $(seq 50); do
		grep -qs READY "$work/client.log" && break
		sleep 0.2
	done
	grep -qs READY "$work/client.log" || die "no carrier came up: $(tail -5 "$work/client.log")"
	sleep 1
	for url in https://example.com "$worker_url/healthz"; do
		echo "$url (5 tries each: HTTP status, median and max seconds)"
		echo "  direct:               $(timed "$url")"
		echo "  relay, 1-RTT fetch:   $(timed "http://127.0.0.1:28081/$url")"
		echo "  relay, SOCKS5 stream: $(timed "$url" --socks5-hostname 127.0.0.1:21080)"
	done
}

# Five fetches of one URL: the statuses seen, then the median and the slowest total time.
timed() {
	local url="$1"
	shift
	for _ in 1 2 3 4 5; do curl -sS -o /dev/null -w '%{http_code} %{time_total}\n' "$@" "$url"; done |
		sort -k2 -n | awk '{codes[$1]=1; t[NR]=$2} END {for (c in codes) s=s c " "; printf "%smedian %.3f max %.3f", s, t[3], t[5]}'
}

cmd="${1:-}"
case "$cmd" in
deploy | replace)
	if [ ! -f "$credential" ]; then
		new_psk "$credential"
		echo "wrote a new key to SSM and $credential"
	fi
	if ! jq -e --arg id "$monitor_id" '.MONITOR_TOKENS[$id]' "$monitor_tokens" >/dev/null; then
		new_monitor_token
		echo "added the $monitor_id check-in token to MONITOR_TOKENS and SSM"
	fi
	action=apply
	[ "$cmd" = replace ] && action=replace
	for _ in 1 2 3 4 5 6; do
		result="$(relay "$action" "$(apply_cfg)")"
		jq . <<<"$result"
		jq -e .pending >/dev/null <<<"$result" || break
		action=apply
		sleep 5
	done
	jq -e '.pending | not' >/dev/null <<<"$result" || die "the instance is still pending: run deploy again"
	;;
status) relay status "$(base_cfg)" | jq . ;;
push-secrets) push_secrets ;;
rotate-key)
	new_psk "$credential.new"
	mv "$credential.new" "$credential"
	on_host "systemctl restart satmux.service && systemctl is-active satmux.service"
	push_secrets
	;;
check) check ;;
smoke) smoke ;;
destroy)
	relay destroy "$(base_cfg)" | jq .
	rm -f "$credential"
	echo "removed $credential; the Worker secrets SATMUX_* are still set (README: Tear down)"
	;;
*)
	sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
	exit 2
	;;
esac
