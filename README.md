# DurableNetworking

The one network stack for Jai's apps (Agent Pager, PRHub) and the kits they embed (PRKit, FeedbackKit,
AgentChatKit). It is built for lifts and bad connections:

- **Nothing sent is lost.** A write is saved to disk before it is sent, and sent again until the server confirms
  it, across kills and, on iOS, after the app has gone (`Outbox`, `BackgroundUploads`). Its client id is the
  idempotency key, so a repeat lands once.
- **What was seen opens offline.** A read opens on its last good answer and refreshes behind it; each value says how
  fresh it is (`Inboxes`, `Inbox`, `ReadState`, `ReadStore`).
- **A push's item is already there.** The notification service or a background fetch loads the item a push names
  into the same store (`Prefetcher`).
- **A returning network retries at once** (`PathWatcher`), and a dropped request that is safe to repeat is repeated
  (`RetryingTransport`).
- **Airplane Wi-Fi is one round trip a read** (`SatmuxTransport`): on a link with a satellite's ~600 ms round trip,
  reads go through a [satmux](https://github.com/Th0rgal/satmux) ground relay over warm connections, and the relay
  does DNS, TLS and the request on the ground.

Hosts give it endpoints, models and keys; it holds nothing app-specific. iOS 26 / macOS 26, Swift 6.

## Install

```swift
.package(url: "https://github.com/jai/durable-networking", from: "0.1.0")
```

## One way out

Code outside this package never makes a `URLSession`, an `NWConnection` or any other network call. A kit takes an
`HTTPTransport` (requests) or `StreamingTransport` (server-sent events, line streams) from its host; the host makes
them here:

```swift
let transport = RetryingTransport(
    inner: URLSessionTransport(isInForeground: { await appIsInForeground() }),
    isInForeground: { await appIsInForeground() }
)
let streams = URLSessionStreamingTransport(quietLimit: 40)
```

SwiftLint enforces it. A host's `.swiftlint.yml` pulls the package's rules (`swiftlint/hosts.yml`:
`no_direct_networking`, `no_network_framework_import`) from a release tag, and its existing lint step in hooks and CI
runs them:

```yaml
parent_config: https://raw.githubusercontent.com/jai/durable-networking/v0.2.0/swiftlint/hosts.yml
```

Comments and strings don't count. An exception is `// swiftlint:disable:next no_direct_networking`, with its reason
on the line above.

## Pieces

- `HTTPTransport`, `URLSessionTransport` (`SessionPolicy`: waits for a network in the foreground, 15 s in the
  background), `RetryingTransport`.
- `StreamingTransport`, `URLSessionStreamingTransport`, `LineStream`.
- `Outbox`, `OutboxItem`, `OutboxVerdict`, `OutboxBackoff`; `BackgroundUploads`.
- `Inboxes`, `Inbox`, `ReadState`, `ReadFailure`, `ReadStore`, `InboxKey`, `KeptAnswer`; `Prefetcher`.
- `PathWatcher`, `NetworkStatus`; `withDeadline`.
- `SatmuxTransport`, `SatmuxRelay`.

## Airplane Wi-Fi: SatmuxTransport

A request made directly over a geostationary satellite link pays about 600 ms for each of DNS, TCP, TLS and the
request itself, then TCP's slow start. `SatmuxTransport` sends a read instead as one encrypted frame over a TCP
connection to a [satmux](https://github.com/Th0rgal/satmux) relay that is already open (it keeps 12, pinged every
12 s); the relay, on fiber near the ground station, makes the request and sends the whole answer back compressed. One
round trip.

```swift
let boost = SatmuxTransport(direct: URLSessionTransport(isInForeground: inForeground))
let transport = RetryingTransport(inner: boost, isInForeground: inForeground)
await boost.engage(try SatmuxRelay(host: host, port: port, keyHex: key)) // the host's setting, on
await boost.disengage()                                                  // and off
await boost.engage(relay, mode: .automatic)                              // or: only while the link is slow
```

- **Automatic:** with `mode: .automatic` the carriers stay open, and reads go through them only while the round trip
  they measure to the relay is above 300 ms, until it falls below 200 ms (`SatmuxMode.whenRoundTrip` sets other
  marks). A host can leave it on: on the plane it carries the reads, on the ground it steps aside. `isRelaying` says
  which it is doing now.

- **What goes through:** http(s) `GET` and `HEAD` (satmux's relay sends no request body). Writes, a request made
  before a carrier is open, and a read the relay can't make (it answers 502 without its marker) go `direct`.
- **The relay** is upstream `satmux.py server`, unchanged; `Tools/satmux/` holds the copy the tests run. The host
  supplies its address and 32-byte key from its own server, never from the binary.
- **Trust:** the relay makes the request, so it sees it, credentials included. Frames are XORed with a BLAKE2b
  keystream from the key; they are not authenticated. Engage only a relay you run.
- **Checked** against frames satmux.py made (`SatmuxWireTests`, `Tools/satmux/vectors.py`) and against the relay
  itself, run locally (`SatmuxRelayTests`).

## Demo and UI checks

`Demo/` is an app that drives the package through simulated network conditions and shows, live, every attempt, the
outbox with its backoff, what reached the server and the kept read: offline and back, slow, timeout, 5xx, 429 with
`Retry-After`, a connection dropped mid-upload, a kill with writes queued, and an offline prefetch. Faults come from
`DurableNetworkingTesting` (`FaultInjectingTransport`), a separate product no app links. These are UI checks against
controlled local services. [The demo walkthrough](docs/demo-walkthrough.md) records a hands-on run and what it found.

## Checks

Prepare the Python test environment separately from test execution:

```sh
mise exec uv@0.13.8 -- uv venv --python 3.14 .venv
mise exec uv@0.13.8 -- uv pip install --python .venv/bin/python -r requirements-test.txt
make test-unit-sdk
make test-integration-sdk
```

Resolver logic runs as Python units with sockets blocked and randomized test order. Tests of the deployment
templates stay in integration. Swift suites and the generated wire-vector comparison run in their existing layers.

## Releases

Releases follow [docs/workflow.md](docs/workflow.md): an external clock creates an SDK candidate; lint, unit, integration and native UI gates must pass before the tested commit receives its SwiftPM version tag.
