import XCTest

@testable import Lyrebird

/// Coverage for `SidebarServerStatus.decide` — the pure reducer behind the
/// sidebar's server-footer indicator (audit fix for the hard-coded "Connected"
/// dot + label).
///
/// The footer previously painted a green "live" dot and the literal word
/// "Connected" regardless of reachability, so it kept claiming a healthy link
/// straight through a server outage. The fix routes the dot tint, the
/// status copy, and (implicitly) the album-count line through this reducer,
/// which only reports `.connected` when a session exists *and* the server is
/// actually answering. Exercised through the pure helper so the truth table is
/// verified without realizing a SwiftUI scene.
final class SidebarServerStatusTests: XCTestCase {

    /// The happy path: a live session against a reachable server is the only
    /// combination that reads `.connected` (teal dot + "Connected · N albums").
    func testConnectedRequiresSessionAndReachability() {
        XCTAssertEqual(
            SidebarServerStatus.decide(hasSession: true, isReachable: true),
            .connected,
            "a live session against a reachable server is the only connected state"
        )
    }

    /// A signed-in user whose server has gone dark (5xx / refused / repeated
    /// timeouts flip `ServerReachability.isServerReachable` to `false`) must
    /// read `.disconnected` — this is the exact bug the audit flagged: the
    /// footer used to stay "Connected" during an outage.
    func testUnreachableWithSessionIsDisconnected() {
        XCTAssertEqual(
            SidebarServerStatus.decide(hasSession: true, isReachable: false),
            .disconnected,
            "a live session whose server is unreachable must not read as connected"
        )
    }

    /// No session (cold launch / signed out) is disconnected even though
    /// reachability starts optimistically `true` — there's nothing to be
    /// connected *to* without a session.
    func testNoSessionIsDisconnectedEvenWhenOptimisticallyReachable() {
        XCTAssertEqual(
            SidebarServerStatus.decide(hasSession: false, isReachable: true),
            .disconnected,
            "no session means disconnected regardless of the optimistic reachability default"
        )
    }

    /// Neither a session nor reachability — plainly disconnected.
    func testNoSessionAndUnreachableIsDisconnected() {
        XCTAssertEqual(
            SidebarServerStatus.decide(hasSession: false, isReachable: false),
            .disconnected,
            "no session and unreachable is disconnected"
        )
    }
}
