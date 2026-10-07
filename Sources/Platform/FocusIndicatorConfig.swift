public struct FocusIndicatorConfig: Sendable {
    public enum Style: String, Sendable {
        case none, ring, raise, flash
    }
    public var style: Style = .ring
    public var color: String = "auto"    // "auto" or hex "#RRGGBB" / "#RGB"
    public var width: Double = 3
    public var cornerRadius: Double = 10
    public var raiseHeight: Double = 20  // pixels unfocused windows shrink in raise mode

    public init() {}
}
