import Core
import CoreGraphics
import Engine
import Platform

@MainActor
package protocol CensusObserver {
    var known: [CGWindowID: WindowFacts] { get }
    func prepareCensus(_ onScreen: [CGWindowInfo], completion: @escaping () -> Void)
    func census(_ onScreen: [CGWindowInfo], space: SpaceKey?) -> [ObservedWindow]
}

@MainActor
package struct LoopReads {
    let space: (UInt32, Bool) -> SpaceSnapshot?
    let screen: () -> [CGWindowInfo]
    let memberships: (UInt32) -> Set<UInt64>?

    package init(space: @escaping (UInt32, Bool) -> SpaceSnapshot? = SpaceObserver.space,
                 screen: @escaping () -> [CGWindowInfo] = getAllWindowInfo,
                 memberships: @escaping (UInt32) -> Set<UInt64>? = SpaceIdentity.spaces) {
        self.space = space
        self.screen = screen
        self.memberships = memberships
    }
}
