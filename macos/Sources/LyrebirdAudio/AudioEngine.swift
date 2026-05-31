import AVFoundation
import Foundation
import LyrebirdCore

@MainActor
public final class AudioEngine {
    private var player: AVQueuePlayer
    private var core: LyrebirdClient
    private var timeObserverToken: Any?

    public init(player: AVQueuePlayer, core: LyrebirdClient) {
        self.player = player
        self.core = core
    }

    public func startObserving() {
        let interval = CMTime(seconds: 1.0, preferredTimescale: 1)
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            guard let self else { return }
            guard self.player.rate != 0 else { return }
            let positionSeconds = time.seconds
            guard positionSeconds.isFinite, positionSeconds >= 0 else { return }
            let positionTicks = Int64(positionSeconds * 10_000_000)
            try? self.core.markPosition(positionTicks: positionTicks)
        }
    }

    // Additional engine wiring lives in AppModel; this file owns the
    // periodic position bridge to core.markPosition.
    defit comment placeholder removed during edit
    // (no-op)
}
