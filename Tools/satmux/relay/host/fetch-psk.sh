#!/bin/sh
# satmux-psk.service's ExecStart: reads the PSK from SSM into /run/satmux/psk (root, 0600). It runs on every
# start of satmux.service, so `systemctl restart satmux` picks up a rotated key.
set -eu
umask 077
out=/run/satmux/psk
aws ssm get-parameter --region "$AWS_REGION" --name "$SATMUX_PSK_PARAMETER" --with-decryption \
	--query Parameter.Value --output text >"$out.new"
if ! grep -Eqx '[0-9a-f]{64}' "$out.new"; then
	rm -f "$out.new"
	echo "satmux: $SATMUX_PSK_PARAMETER is not 64 lowercase hex characters" >&2
	exit 1
fi
mv "$out.new" "$out"
