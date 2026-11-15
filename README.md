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

`scripts/no-direct-networking.sh [ROOT]` enforces it: it fails on any Swift file under ROOT that uses `URLSession`,
Network.framework or CFNetwork, except paths listed in `ROOT/.network-allowlist` with a reason. Every repo runs it in
its pre-push hook and CI.

## Pieces

- `HTTPTransport`, `URLSessionTransport` (`SessionPolicy`: waits for a network in the foreground, 15 s in the
  background), `RetryingTransport`.
- `StreamingTransport`, `URLSessionStreamingTransport`, `LineStream`.
- `Outbox`, `OutboxItem`, `OutboxVerdict`, `OutboxBackoff`; `BackgroundUploads`.
- `Inboxes`, `Inbox`, `ReadState`, `ReadFailure`, `ReadStore`, `InboxKey`, `KeptAnswer`; `Prefetcher`.
- `PathWatcher`, `NetworkStatus`; `withDeadline`.

## Releases

An hourly job tags main's newest CI-green commit when it holds `feat` or `fix` commits
(`.github/scripts/release.sh`). Hosts pin the tags.
