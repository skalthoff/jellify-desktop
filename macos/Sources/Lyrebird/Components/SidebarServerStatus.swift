import SwiftUI

/// Pure decision logic for the `Sidebar` server-footer status indicator.
///
/// The footer previously hard-coded a green dot and the literal word
/// "Connected" regardless of whether the server was actually answering, and
/// showed `model.albums.count` (the number of albums loaded into the paged
/// cache so far) instead of the real library total. That made the footer lie
/// in two ways: it stayed "Connected" through a full server outage, and the
/// album count read low until the user had scrolled the whole library in.
///
/// This type captures the "connected vs disconnected, and which dot tint"
/// contract as a single pure, side-effect-free reducer so it's unit-testable
/// without booting a SwiftUI scene. The view owns the reads of
/// `model.session` / `model.serverReachability.isServerReachable` and the
/// `model.albumsTotal` count; everything visual downstream branches on the
/// returned `State`. Mirrors the `DynamicTypeReflow` / `PlaylistSidebarOrder`
/// pure-helper pattern used elsewhere in the sidebar.
enum SidebarServerStatus {
    /// Resolved footer state.
    enum State: Equatable {
        /// A session exists and the server is answering. The footer shows the
        /// teal "live" dot and the localized "Connected · N albums" copy.
        case connected
        /// Either there is no active session or reachability has flipped to
        /// failing. The footer shows a muted dot and "Disconnected" so the
        /// indicator can't claim a healthy connection during an outage.
        case disconnected
    }

    /// Pure reducer. `hasSession` is `model.session != nil`; `isReachable` is
    /// `model.serverReachability.isServerReachable`. We require *both* — a
    /// signed-in user whose server has gone dark is still "disconnected" for
    /// the purpose of this indicator, and a torn-down session (sign-out) is
    /// disconnected even though reachability starts optimistic.
    static func decide(hasSession: Bool, isReachable: Bool) -> State {
        (hasSession && isReachable) ? .connected : .disconnected
    }
}
