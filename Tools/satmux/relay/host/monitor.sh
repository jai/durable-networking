#!/bin/sh
# satmux-monitor.service: checks the relay in with the Agent Pager monitor Worker every 2 minutes
# (docs/api/monitors.md §4.27, monitor satmux-relay). Checks: the service, the port, and today's data out
# (UTC), which is the relay's only cost that grows with use.
set -eu
umask 077

check() { # id label status value
	printf '{"id":"%s","label":"%s","status":"%s","value":"%s"}' "$1" "$2" "$3" "$4"
}

if systemctl is-active --quiet satmux.service; then
	service=$(check service "satmux service" ok "active")
else
	service=$(check service "satmux service" down "$(systemctl is-active satmux.service || true)")
fi

if ss -ltnH "sport = :$SATMUX_PORT" | grep -q .; then
	port=$(check port "Port $SATMUX_PORT" ok "listening")
else
	port=$(check port "Port $SATMUX_PORT" down "not listening")
fi

# Bytes sent since the start of the UTC day: the interface counter minus its value at the day's first run (or
# at boot, when the counter restarted).
iface=$(ip route show default | awk '{print $5; exit}')
tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes")
today=$(date -u +%F)
state="$STATE_DIRECTORY/egress"
day=""
base=0
[ -f "$state" ] && read -r day base <"$state"
if [ "$day" != "$today" ] || [ "$tx" -lt "$base" ]; then
	[ "$day" = "$today" ] && base=0 || base=$tx
fi
printf '%s %s\n' "$today" "$base" >"$state"
gb=$(awk -v b=$((tx - base)) 'BEGIN {printf "%.2f", b / 1e9}')
if awk -v g="$gb" -v l="$SATMUX_EGRESS_ALARM_GB" 'BEGIN {exit !(g > l)}'; then
	egress=$(check egress "Data out today" degraded "$gb GB (UTC day), over $SATMUX_EGRESS_ALARM_GB GB")
else
	egress=$(check egress "Data out today" ok "$gb GB (UTC day)")
fi

token=$(aws ssm get-parameter --region "$AWS_REGION" --name "$SATMUX_MONITOR_TOKEN_PARAMETER" --with-decryption \
	--query Parameter.Value --output text)
printf 'Authorization: Bearer %s\n' "$token" >"$RUNTIME_DIRECTORY/header"
printf '{"instance_id":"%s","checks":[%s,%s,%s]}' "$(cat /proc/sys/kernel/random/boot_id)" "$service" "$port" "$egress" |
	curl -fsS --max-time 20 -o /dev/null -H @"$RUNTIME_DIRECTORY/header" -H 'Content-Type: application/json' \
		--data-binary @- "$SATMUX_MONITOR_URL"
