import Darwin

/// Cached high-resolution monotonic clock.
/// Replaces per-call mach_timebase_info() overhead with a process-lifetime cached ratio.
public enum TimeUtil {
    private static let ratio: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// Test hook. nil in production (one nil-check; AX calls dwarf it).
    public static var nowProvider: (() -> Double)?

    /// Current time in seconds (monotonic).
    public static func now() -> Double {
        nowProvider?() ?? Double(mach_absolute_time()) * ratio
    }
}
