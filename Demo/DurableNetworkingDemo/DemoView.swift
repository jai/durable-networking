import DurableNetworking
import DurableNetworkingTesting
import SwiftUI

/// One screen: the network's conditions on top, then what DurableNetworking did, live — every attempt, the outbox with
/// its backoff, each write's end, what reached the server, and the prefetched item.
struct DemoView: View {
    let model: DemoModel
    let airplane: AirplaneModel

    var body: some View {
        NavigationStack {
            // Not a List: a List makes only the rows on screen, and the UI test reads every one.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    conditions
                    actions
                    outbox
                    server
                    results
                    reads
                    airplaneWiFi
                    attempts
                }
                .padding()
            }
            .navigationTitle("DurableNetworking")
        }
    }

    private var conditions: some View {
        Block("Network conditions", footer: "Once-only conditions apply to the next attempts, then the standing one returns.") {
            Text("Network: \(model.condition)").accessibilityIdentifier("condition")
            grid([
                ("Normal", "condition.normal", { model.set(.normal) }),
                ("Offline", "condition.offline", { model.set(.offline) }),
                ("Slow (3 s)", "condition.slow", { model.set(.latency(.seconds(3))) }),
                ("Timeout once", "condition.timeout", { model.next(.timeout(after: .seconds(2))) }),
                ("503 twice", "condition.503", { model.next(.status(503), .status(503)) }),
                ("429, Retry-After 3", "condition.429", { model.next(.status(429, retryAfter: 3)) }),
                ("Drop mid-upload", "condition.drop", { model.next(.droppedAfterSend) }),
            ])
        }
    }

    private var actions: some View {
        Block("Actions") {
            grid([
                ("Send a write", "send", { Task { await model.sendWrite() } }),
                ("Back online", "backOnline", { Task { await model.backOnline() } }),
                ("Prefetch item", "prefetch", { Task { await model.prefetch() } }),
                ("Open item", "openItem", { Task { await model.openItem() } }),
            ])
        }
    }

    private var outbox: some View {
        Block("Outbox (saved before sending)") {
            Text("Outbox: \(model.outboxItems.count)").accessibilityIdentifier("outbox.count")
            ForEach(model.outboxItems) { item in
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.id).font(.body.monospaced())
                        Text(Self.status(of: item, underWay: model.underWay.contains(item.id), now: context.date))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("outbox.item")
            }
        }
    }

    private var server: some View {
        Block("Server") {
            Text("Stored: \(model.truth.stored)").accessibilityIdentifier("server.stored")
            Text("Deliveries: \(model.truth.deliveries)").accessibilityIdentifier("server.deliveries")
            if let error = model.truthError {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("server.error")
            }
        }
    }

    private var results: some View {
        Block("Results") {
            ForEach(Array(model.results.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).accessibilityIdentifier("result")
            }
        }
    }

    private var reads: some View {
        Block("Kept read") {
            if let prefetch = model.prefetchResult {
                Text(prefetch).accessibilityIdentifier("prefetch.result")
            }
            if let item = model.item {
                Text(Self.describe(item.state)).accessibilityIdentifier("item.state")
                if let value = item.state.value {
                    Text(value.title).accessibilityIdentifier("item.title")
                }
            }
        }
    }

    private var airplaneWiFi: some View {
        Block(
            "Airplane Wi-Fi (600 ms round trip)",
            footer: "Six reads at once. Direct pays TCP and TLS on new connections, then the request; boosted, each is "
                + "one round trip over carriers already open to a satmux relay. Auto boosts only while the round trip "
                + "is high."
        ) {
            Text(airplane.isOnGround ? "Link: ground" : "Link: satellite (600 ms)")
                .accessibilityIdentifier("airplane.linkStatus")
            Text(airplane.status).accessibilityIdentifier("airplane.status")
            grid([
                (airplane.boost == .on ? "Boost off" : "Boost on", "airplane.boost", {
                    Task { await airplane.toggleBoost() }
                }),
                (airplane.boost == .auto ? "Auto off" : "Auto", "airplane.auto", {
                    Task { await airplane.toggleAuto() }
                }),
                (airplane.isOnGround ? "To satellite" : "To ground", "airplane.link", {
                    Task { await airplane.toggleLink() }
                }),
                ("Load a screen", "airplane.load", { Task { await airplane.loadScreen() } }),
            ])
            if airplane.isLoading {
                ProgressView().accessibilityIdentifier("airplane.loading")
            }
            ForEach(Array(airplane.loads.enumerated().reversed()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).accessibilityIdentifier("airplane.result")
            }
        }
    }

    private var attempts: some View {
        Block("Attempts (newest first)") {
            Text("Attempts: \(model.attempts.count)").accessibilityIdentifier("attempts.count")
            ForEach(model.attempts.reversed()) { record in
                Text(record.summary).font(.caption.monospaced()).accessibilityIdentifier("attempt")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func grid(_ buttons: [(String, String, () -> Void)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 8) {
            ForEach(buttons, id: \.1) { title, identifier, action in
                Button(title, action: action)
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier(identifier)
            }
        }
        .padding(.vertical, 4)
    }

    static func status(of item: OutboxItem, underWay: Bool, now: Date) -> String {
        if let rejection = item.rejection {
            return "refused: \(rejection)"
        }
        if underWay {
            return "sending · attempt \(item.attempts + 1)"
        }
        let wait = item.nextAttemptAt.timeIntervalSince(now)
        let after = item.lastError.map { " after \($0)" } ?? ""
        guard wait > 0 else {
            return "\(item.attempts) attempts\(after) · due now"
        }
        return "\(item.attempts) attempts\(after) · next in \(String(format: "%.1f", wait)) s"
    }

    static func describe(_ state: ReadState<DemoItem>) -> String {
        let time = { (date: Date) in date.formatted(date: .omitted, time: .standard) }
        return switch state {
        case .empty: "empty"
        case .unreachable(let failure): "unreachable: \(failure)"
        case .cached(_, let savedAt): "cached, saved \(time(savedAt))"
        case .fresh(_, let readAt): "fresh, read \(time(readAt))"
        case .stale(_, let savedAt, let failure): "stale, saved \(time(savedAt)): \(failure)"
        }
    }
}

/// A titled group, as a List's section looks, in a plain stack.
private struct Block<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder let content: Content

    init(_ title: String, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            content
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
