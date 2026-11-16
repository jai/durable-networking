# End-to-end walk-through

The demo app (`Demo/`) driven through every network condition, on 2026-11-15, on Borg Cube 03: an iPhone 17 Pro
Simulator (iOS 27.2) of this walk's own (`durable-networking-68`, headless, deleted afterwards), against the demo
server (`Demo/server/demo_server.py`) on the same Mac. The same UI test runs in CI on GitHub's macOS runner (`ci.yml`,
job `demo`), on an iPhone Simulator and on the Mac app.

## How it works

- **The package is unchanged in the app.** The demo uses `Outbox`, `Inboxes`/`Inbox`, `Prefetcher` and
  `URLSessionTransport` exactly as an app does.
- **Faults come from `DurableNetworkingTesting`**, a separate library no app links: `FaultInjectingTransport` wraps
  the real transport and applies a condition to each attempt. It also records every attempt: condition, outcome,
  duration, and how long the caller waited since the previous attempt for the same write.
- **The server is the judge.** `Stored` counts distinct writes (by `Idempotency-Key`), `Deliveries` every POST that
  reached it. Its counts are read past the faults.

Run it yourself:

```sh
python3 Demo/server/demo_server.py &          # http://127.0.0.1:8787
cd Demo && xcodegen && open DurableNetworkingDemo.xcodeproj
```

Then the scheme's tests (`DurableNetworkingDemoUITests`), or the buttons by hand.

## Each condition

Lines below are what the app showed at the end of each test (its attempt log, then its results), from the final run:
8 tests, 0 failures, 229 s.

### Offline, then back online

```
#1 POST /writes · offline · offline · 0.00 s
#2 POST /writes · offline · offline · 0.00 s · waited 0.8 s
#3 POST /writes · offline · offline · 0.00 s · waited 0.4 s
#4 POST /writes · offline · offline · 0.00 s · waited 1.5 s
#5 POST /writes · normal · 200 · 0.00 s · waited 1.6 s
1:07:48 PM  w-1-9fe3 saved
1:07:53 PM  back online
1:07:53 PM  w-1-9fe3 accepted after 5 attempts
Stored: 1 · Deliveries: 1 · Outbox: 0
```

The write is saved first and retried with jittered backoff. When the network returns, `Outbox.kick()` sends it in
the same second.

### Slow network (3 s latency)

```
#1 POST /writes · latency 3 s · 200 · 3.03 s
accepted after 1 attempts · Stored: 1
```

A slow answer is still an answer. Nothing is repeated.

### Timeout

```
#1 POST /writes · timeout after 2 s · timed out · 2.13 s
#2 POST /writes · normal · 200 · 0.01 s · waited 0.8 s
accepted after 2 attempts · Stored: 1 · Deliveries: 1
```

### 5xx, then success

```
#1 POST /writes · 503 · 503 · 0.00 s
#2 POST /writes · 503 · 503 · 0.00 s · waited 0.3 s
#3 POST /writes · normal · 200 · 0.02 s · waited 0.5 s
accepted after 3 attempts · Stored: 1 · Deliveries: 1
```

### 429 with Retry-After

```
#1 POST /writes · 429, Retry-After 3 s · 429 · 0.00 s
#2 POST /writes · normal · 200 · 0.00 s · waited 3.0 s
accepted after 2 attempts · Stored: 1
```

The outbox waits at least what the server asked, not its own shorter backoff. The test reads the measured wait.

### Dropped connection mid-upload

```
#1 POST /writes · dropped after send · connection lost · 0.02 s
#2 POST /writes · normal · 200 · 0.01 s · waited 1.0 s
accepted after 2 attempts · Stored: 1 · Deliveries: 2
```

The server got the write twice and keeps one: the idempotency key at work.

### App killed with writes in the outbox, then relaunched

Offline, two writes, five failed attempts so the backoff has grown, then `terminate()`. A new launch with the network
back:

```
#1 POST /writes · normal · 200 · 0.18 s
#2 POST /writes · normal · 200 · 0.04 s
w-1-442a accepted after 6 attempts
w-2-5e66 accepted after 1 attempts
Stored: 2 · Deliveries: 2 · Outbox: 0
both writes stored 2.2 s after relaunch (launch included)
```

### Offline prefetch

```
#1 GET /items/demo-1 · normal · 200 · 0.02 s      (Prefetcher, as a notification service would)
#2 GET /items/demo-1 · offline · offline · 0.00 s (the screen's refresh)
Item demo-1 · stale, saved 1:03:53 PM: offline
```

The item opens at once from what the prefetch kept. It shows its age and why it couldn't refresh.

### Airplane Wi-Fi (600 ms round trip), direct and through a satmux relay

Run on 2026-11-15 on Borg Cube 03 (iPhone 17 Simulator, iOS 27.2, `satmux-client`), `testAirplaneBoostLoadsAScreenFaster`:

```
direct 3.12 s · 6/6 loaded · 0 via relay
boost 0.67 s · 6/6 loaded · 6 via relay
direct … · 6/6 loaded · 0 via relay      (boost off again)
```

Six reads at once, as a screen opening makes them, of about 19 KB each:

- **Direct**, on new connections (as after the cabin link dropped the idle ones), through `geo_link.py`'s SOCKS5
  proxy: each connection waits two round trips (TCP, then the TLS a real https request pays), then the request's own.
- **Boosted** (`SatmuxTransport`), each is one frame over carriers already open through `geo_link.py` to the relay
  (`Tools/satmux/satmux.py server`), which fetches on this machine, past the link: one round trip.
- The link leaves out loss, slow start and bandwidth, all of which cost the direct path more.

Run it yourself (the key is the demo's, `AirplaneModel.Setup`):

```sh
python3 Demo/server/demo_server.py &
SATMUX_PSK=$(printf '5a%.0s' $(seq 32)) python3 Tools/satmux/satmux.py server --host 127.0.0.1 --port 8444 &
python3 Demo/server/geo_link.py --rtt-ms 600 --socks 1081 --forward 8445:127.0.0.1:8444 &
```

The app reaches the demo server as `127.0.0.1.sslip.io` (public DNS for 127.0.0.1): the system sends loopback and
local-network addresses around a proxy, and the relay must fetch the same URL.

## What broke, and what was fixed

1. **A relaunch waited out the old process's backoff** (fixed in the package). `Outbox.start()` kept each item's
   `nextAttemptAt` from the killed process. A write that had backed off offline sat after relaunch for up to
   `OutboxBackoff.cap` (10 s), and longer after a `Retry-After`. Agent Pager's `WriteOutbox` calls `start()` and does
   not `kick()` at launch (`PathWatcher` treats its first answer as no news), so it had this delay. The package's own
   test hid it by calling `kick()` after `start()`. `start()` now makes every waiting item due at once, and
   `aNewProcessFinishesWhatTheLastOneLeft` checks this with no kick.
2. **The 429 check measured the wrong thing** (fixed in the demo). The first walk timed the gap from when the UI test
   saw the 429 row, which counts XCUITest's polling, and failed at 1.7 s. The transport now records `waited` per
   attempt, and the test reads it: 3.0 s.
3. **Demo-only issues, fixed in the demo.** A `List` builds only the rows on screen, so the UI test could not read
   the attempt log; the screen is now a plain stack. A test teardown that read the screen failed Swift 6's isolation
   check; each test now records its end itself.

Not covered here:

- **Background uploads** (`BackgroundUploads`) need a device or a signed app with a background session. Agent Pager's
  `make net-e2e-app` covers them.
- **The Mac app** did not run in this walk. Since 2026-11-16 CI runs the same UI test on the Mac app after the
  iPhone run (`ci.yml`, job `demo`). All nine tests pass on the Mac, Airplane Wi-Fi included: direct 3.04 s, boosted
  0.67 s over the emulated 600 ms link.
