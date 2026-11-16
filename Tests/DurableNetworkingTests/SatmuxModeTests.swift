@testable import DurableNetworking
import Testing

/// When `.automatic` sends reads through the relay: on above 300 ms, off below 200 ms, unchanged in between and while
/// nothing is measured.
struct SatmuxModeTests {
    private let auto = SatmuxMode.automatic

    @Test func turnsOnAboveTheUpperMarkOnly() {
        #expect(!auto.relays(wasRelaying: false, roundTrip: .milliseconds(40)))
        #expect(!auto.relays(wasRelaying: false, roundTrip: .milliseconds(250)))
        #expect(!auto.relays(wasRelaying: false, roundTrip: .milliseconds(300)))
        #expect(auto.relays(wasRelaying: false, roundTrip: .milliseconds(301)))
        #expect(auto.relays(wasRelaying: false, roundTrip: .milliseconds(600)))
    }

    @Test func turnsOffBelowTheLowerMarkOnly() {
        #expect(auto.relays(wasRelaying: true, roundTrip: .milliseconds(600)))
        #expect(auto.relays(wasRelaying: true, roundTrip: .milliseconds(250)))
        #expect(auto.relays(wasRelaying: true, roundTrip: .milliseconds(200)))
        #expect(!auto.relays(wasRelaying: true, roundTrip: .milliseconds(199)))
    }

    @Test func aRoundTripBetweenTheMarksDoesNotFlap() {
        var relaying = false
        for trip in [250, 320, 250, 280, 210, 260, 190, 250, 290] {
            relaying = auto.relays(wasRelaying: relaying, roundTrip: .milliseconds(trip))
        }
        // On at 320, held through 210, off at 190, held off through 290.
        #expect(!relaying)
    }

    @Test func nothingMeasuredChangesNothing() {
        #expect(auto.relays(wasRelaying: true, roundTrip: nil))
        #expect(!auto.relays(wasRelaying: false, roundTrip: nil))
    }

    @Test func alwaysRelays() {
        #expect(SatmuxMode.always.relays(wasRelaying: false, roundTrip: .milliseconds(1)))
        #expect(SatmuxMode.always.relays(wasRelaying: false, roundTrip: nil))
    }
}
