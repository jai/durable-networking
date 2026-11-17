#!/bin/sh
# satmux.service's ExecStart. The PSK arrives as a systemd credential and goes to satmux.py through the
# environment (upstream reads SATMUX_PSK), never on the command line.
set -eu
SATMUX_PSK=$(cat "$CREDENTIALS_DIRECTORY/psk")
export SATMUX_PSK
exec /usr/bin/python3 -I /opt/satmux/satmux.py server --host 0.0.0.0 --port "$SATMUX_PORT"
