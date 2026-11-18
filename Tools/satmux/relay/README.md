# satmux relay

> A ground relay in Singapore for Agent Pager on GEO airplane Wi-Fi: upstream [satmux](https://github.com/Th0rgal/satmux) under systemd on one EC2 instance in FINN staging, a work experiment ([#55](https://github.com/jai/agent-pager/issues/55)).

## What it is

On GEO cabin Wi-Fi (about 600 ms per round trip) every new connection pays DNS, TCP and TLS over the satellite, and the cabin's `:443` proxy drops connections under load. satmux keeps warm TCP connections ("carriers") from the device to a relay on port 8444. Through them, a request either opens a TCP stream to an origin with no extra round trip (`FT_OPEN`, TLS end to end on the device), or is fetched by the relay in one round trip (`FT_FETCH`).

The device side is the "satmux client" thread's DurableNetworking transport ([jai/durable-networking#2](https://github.com/jai/durable-networking/issues/2)); the contract is in [this comment on #55](https://github.com/jai/agent-pager/issues/55#issuecomment-6896408670).

- **Where:** FINN staging `211125443320`, `ap-southeast-1`, in the account's default VPC (`172.31.0.0/16`), apart from `ewa-vpc`.
- **Instance:** `satmux-relay`, one `t4g.nano`, Amazon Linux 2023 arm64, Elastic IP `54.169.78.182`.
- **Program:** upstream `satmux.py` at `2922ebb` (MIT, Thomas Marchand), unmodified, `server --host 0.0.0.0 --port 8444`. The host downloads it at first boot and refuses a file whose sha256 differs.
- **Network:** security group `satmux-relay` lets in TCP 8444 and 443 only. No SSH and no key pair; administration is SSM Run Command and Session Manager.
- **Port 443:** nftables on the host redirects 443 to 8444, and the Worker hands out 443 (`SATMUX_PORT`). TG 409's cabin Wi-Fi (2026-11-17) let nothing through to 8444: the relay saw no packets from the phone all flight (CloudWatch `NetworkPacketsIn` flat). 8444 still works for anything that reaches it.
- **Key:** 32 random bytes as 64 hex characters, in the SSM SecureString `/satmux/psk`, with a copy in `~/.credentials/satmux` on Borg Cube 03 for the Worker secrets and the smoke test.
- **Monitor:** `satmux-relay` on the Agent Pager monitor Worker ([§4.27](../../docs/api/monitors.md), `worker/monitors.registry.json`), like the other EC2 hosts. Every 2 minutes the host checks in `service`, `port` and `egress` (data out in the UTC day, `degraded` above 5 GB, about USD 0.60). No check-in for 10 minutes, or a `down` check, pages at `high` after 5 more. Its bearer is `MONITOR_TOKENS["satmux-relay"]` and the SSM SecureString `/agent-pager/monitor-tokens/satmux-relay`.

### On the host

- `satmux-psk.service` reads `/satmux/psk` into `/run/satmux/psk` (root, `0600`) with the instance role before every start of `satmux.service`.
- `satmux.service` gets the key as a systemd credential and passes it in `SATMUX_PSK`, never on the command line. It runs as a dynamic user, sandboxed, restarts on exit, and is enabled, so it comes back after a reboot.
- Upstream's server connects to any host and port a key holder names, so systemd's `IPAddressDeny` blocks the service from reaching loopback, link-local (the metadata service, and so the instance role) and private ranges (both VPCs). It may reach the VPC's DNS resolver only.
- `satmux-monitor.timer` runs `monitor.sh` (the check-in) every 2 minutes; it reads its bearer from SSM each time.
- BBR and `fq` are on.

## Code

- [`relay.py`](relay.py): every AWS call, as plain boto3 calls that Executor runs in its sandbox. Each step finds its resource by name or tag first, so `deploy` can run again at any time. [`test_relay.py`](test_relay.py) tests the cloud-init it renders.
- [`deploy.sh`](deploy.sh): sends `relay.py` to Executor's `aws` app (account FINN AWS Staging) through `mcporter`, and runs everything else. No local AWS session or MFA is needed.
- [`host/`](host): cloud-init and what it installs: the relay's two units, `run.sh` and `fetch-psk.sh`, and the monitor's timer, unit and `monitor.sh`.

## How to use it

```sh
deploy/satmux/deploy.sh deploy        # key if missing, then whatever of the relay is missing
deploy/satmux/deploy.sh check         # enabled, active, sha256, listening, BBR; port 8444 reachable from here
deploy/satmux/deploy.sh push-secrets  # SATMUX_HOST, SATMUX_PORT, SATMUX_PSK into the agent-pager Worker
deploy/satmux/deploy.sh smoke         # upstream client here: example.com and the Worker's /healthz, direct and relayed
deploy/satmux/deploy.sh rotate-key    # new key in SSM and ~/.credentials, restart the relay, push-secrets
deploy/satmux/deploy.sh replace       # rebuild the instance after a change to host/ (the Elastic IP stays)
deploy/satmux/deploy.sh destroy       # everything above, and the key
```

Executor stops waiting after about a minute. If a step reports that Executor timed out, the AWS calls may still finish: run `status`, then the same command again.

`deploy` adds the monitor's bearer to `MONITOR_TOKENS` the first time: in `~/.credentials/agent-monitor` and in the monitor Worker's secret, which is the whole object. A new monitor in `worker/monitors.registry.json` goes live with `make monitor-deploy` once its commit is green on main.

After `destroy`: remove `satmux-relay` from `worker/monitors.registry.json` and `make monitor-deploy` first, or it pages; then its entry from `MONITOR_TOKENS` the same way `deploy` added it; then the Worker secrets from `worker/`: `npx wrangler secret delete SATMUX_HOST` (and `SATMUX_PORT`, `SATMUX_PSK`).

## Cost

About USD 8.30 a month at Singapore on-demand prices: the instance USD 3.90, the public IPv4 address USD 3.65, the 8 GB gp3 volume USD 0.77. Data out costs USD 0.12 per GB; Agent Pager's traffic is a few MB a day.

## How to verify

1. `deploy.sh check` prints `enabled`, `active`, the pinned sha256, `listening on 8444` and `bbr`, then `reachable`.
2. `deploy.sh smoke` prints `200` on all three paths for both URLs.
3. `GET /monitors` on the monitor Worker ([worker/README.md](../../worker/README.md#the-monitor-worker)) shows `satmux-relay` healthy.
4. After a reboot of `satmux-relay`, `check` passes again with no other step.
