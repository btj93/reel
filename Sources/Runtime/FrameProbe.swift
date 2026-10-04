import Core
import Foundation

@MainActor
public final class FrameProbe {
    private var pending: Set<TileID>
    private var frames: [UInt32: CGRect] = [:]
    private var timer: Timer?
    private var completion: (([UInt32: CGRect]) -> Void)?

    public init(ids: Set<TileID>, timeout: Double = 0.5, completion: @escaping ([UInt32: CGRect]) -> Void) {
        pending = ids
        self.completion = completion
        let deadline = Timer(timeInterval: timeout, repeats: false) { [self] _ in
            MainActor.assumeIsolated { finish() }
        }
        timer = deadline
        RunLoop.main.add(deadline, forMode: .common)
        if ids.isEmpty { finish() }
    }

    public func receive(_ id: TileID, frame: CGRect?) {
        guard pending.remove(id) != nil, completion != nil else { return }
        if let frame { frames[id.rawValue] = frame }
        if pending.isEmpty { finish() }
    }

    public func finish() {
        timer?.invalidate()
        timer = nil
        pending.removeAll()
        let callback = completion
        completion = nil
        callback?(frames)
    }
}
