import Core
import Foundation

/// A census must not wait behind a hung app's AX queue. Missing focus is explicit and never replaced by cached focus.
@MainActor
package final class FrontmostRead {
    private var completion: ((TileID?) -> Void)?
    private var timer: Timer?

    package init(timeout: Double = 0.15, completion: @escaping (TileID?) -> Void) {
        self.completion = completion
        timer = Timer(timeInterval: timeout, repeats: false) { [self] _ in
            MainActor.assumeIsolated { finish(nil) }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    package func finish(_ tile: TileID?) {
        timer?.invalidate()
        timer = nil
        let callback = completion
        completion = nil
        callback?(tile)
    }
}
