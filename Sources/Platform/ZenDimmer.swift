import CoreGraphics
import Foundation
import Core
import Config

// MARK: - Private CoreGraphics API

/// CGS connection handle (signed int per CGSInternal headers).
private typealias CGSConnectionID = Int32

@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID

@_silgen_name("CGSSetWindowAlpha")
@discardableResult
private func CGSSetWindowAlpha(_ cid: CGSConnectionID, _ wid: CGWindowID, _ alpha: Float) -> CGError

@_silgen_name("CGSSetWindowLevel")
@discardableResult
private func CGSSetWindowLevel(_ cid: CGSConnectionID, _ wid: CGWindowID, _ level: Int32) -> CGError

// MARK: - ZenDimmer

/// Dims unfocused tiled windows using CGSSetWindowAlpha.
/// Main-thread only — CGSDefaultConnectionForThread() returns a per-thread connection.
public final class ZenDimmer: @unchecked Sendable {

    // MARK: - Config

    public private(set) var enabled: Bool = false
    private var dimAlpha: Double = 0.3
    private var fadeDuration: Double = 0.15

    // MARK: - State

    /// In-flight fade animations, keyed by CGWindowID.
    private var fadeAnimations: [CGWindowID: EasingAnimation] = [:]

    /// Last-known alpha per window. Persists after animation completes to seed retargeting.
    /// Cleared only by restoreWindow/restoreAll.
    private var currentAlphas: [CGWindowID: Double] = [:]

    /// The currently focused window's CGWindowID.
    private var focusedWindowID: CGWindowID?

    /// Per-window rule-based opacity overrides. These take priority over zen dimming.
    private var ruleOpacities: [CGWindowID: Double] = [:]

    /// True when any fade animation is in flight. Used by StripController.isFullySettled.
    public var isAnimating: Bool { !fadeAnimations.isEmpty }

    public init() {}

    /// Set a window's compositing alpha directly. Main-thread only.
    public static func setWindowAlpha(_ wid: CGWindowID, _ alpha: Float) {
        let cid = CGSDefaultConnectionForThread()
        CGSSetWindowAlpha(cid, wid, alpha)
    }

    /// Set a window's compositing level directly. Main-thread only.
    public static func setWindowLevel(_ wid: CGWindowID, _ level: Int32) {
        let cid = CGSDefaultConnectionForThread()
        CGSSetWindowLevel(cid, wid, level)
    }

    /// Register a rule-based opacity for a window. Immediately applies via CGS.
    /// Invariant: callers MUST NOT pass opacity >= 1.0 — use clearRuleOpacity instead.
    public func setRuleOpacity(for wid: CGWindowID, opacity: Double) {
        ruleOpacities[wid] = opacity
        fadeAnimations.removeValue(forKey: wid)
        currentAlphas[wid] = opacity
        let cid = CGSDefaultConnectionForThread()
        CGSSetWindowAlpha(cid, wid, Float(opacity))
    }

    /// Remove a rule opacity override and restore the window to 1.0.
    /// No-op if the window has no rule opacity.
    public func clearRuleOpacity(for wid: CGWindowID) {
        guard ruleOpacities.removeValue(forKey: wid) != nil else { return }
        currentAlphas[wid] = 1.0
        let cid = CGSDefaultConnectionForThread()
        CGSSetWindowAlpha(cid, wid, 1.0)
    }

    // MARK: - Config

    /// Update config. Calls restoreAll() when transitioning enabled→disabled.
    /// The disabled→enabled transition is handled by the caller (StripController).
    public func reloadConfig(_ config: ZenModeConfig) {
        let wasEnabled = enabled
        enabled = config.enabled
        dimAlpha = config.dimAlpha
        fadeDuration = config.fadeDuration

        if wasEnabled && !enabled {
            restoreAll(preserveRuleOpacities: true)
        }
    }

    // MARK: - Focus

    /// Update which window is focused. Starts fade easings for newly-dimmed/undimmed windows.
    /// Returns true if any new easings were created (caller should resume FrameLoop).
    /// No-ops if disabled, or if focus hasn't changed and force is false.
    @discardableResult
    public func setFocusedWindow(_ focusedID: TileID, allTileIDs: [TileID], at time: Double, force: Bool = false) -> Bool {
        guard enabled else { return false }

        let newFocusedWID = focusedID.rawValue

        if !force && newFocusedWID == focusedWindowID {
            return false
        }

        focusedWindowID = newFocusedWID
        var createdEasings = false

        for tileID in allTileIDs {
            let wid = tileID.rawValue
            if ruleOpacities[wid] != nil { continue }
            let targetAlpha = (wid == newFocusedWID) ? 1.0 : dimAlpha
            let currentAlpha = currentAlphaFor(wid, at: time)

            // Skip if already at target
            if abs(currentAlpha - targetAlpha) < 0.001 {
                fadeAnimations.removeValue(forKey: wid)
                continue
            }

            fadeAnimations[wid] = EasingAnimation(
                from: currentAlpha,
                to: targetAlpha,
                startTime: time,
                duration: fadeDuration,
                curve: .easeOutCubic
            )
            createdEasings = true
        }

        return createdEasings
    }

    // MARK: - Tick

    /// Evaluate all in-flight fade animations. Call from handleFrameTick.
    public func tick(time: Double) {
        let cid = CGSDefaultConnectionForThread()
        var completed: [CGWindowID] = []

        for (wid, easing) in fadeAnimations {
            let alpha = easing.evaluate(at: time)
            currentAlphas[wid] = alpha
            CGSSetWindowAlpha(cid, wid, Float(alpha))

            if easing.isDone(at: time) {
                completed.append(wid)
            }
        }

        for wid in completed {
            fadeAnimations.removeValue(forKey: wid)
        }
    }

    // MARK: - Restore

    /// Restore all tracked windows. Clears all state.
    /// When preserveRuleOpacities is true (zen-disable), rule-opacity windows keep their rule value.
    /// When false (shutdown/rebuild), everything goes to 1.0.
    public func restoreAll(preserveRuleOpacities: Bool = false) {
        let cid = CGSDefaultConnectionForThread()
        // Pass 1: restore windows in currentAlphas
        for wid in currentAlphas.keys {
            let restoreAlpha: Float
            if preserveRuleOpacities, let ruleAlpha = ruleOpacities[wid] {
                restoreAlpha = Float(ruleAlpha)
            } else {
                restoreAlpha = 1.0
            }
            CGSSetWindowAlpha(cid, wid, restoreAlpha)
        }
        // Pass 2: ensure rule-opacity windows get their value applied even if not in currentAlphas
        if preserveRuleOpacities {
            for (wid, ruleAlpha) in ruleOpacities where currentAlphas[wid] == nil {
                CGSSetWindowAlpha(cid, wid, Float(ruleAlpha))
            }
        }
        fadeAnimations.removeAll()
        if preserveRuleOpacities {
            currentAlphas = ruleOpacities
        } else {
            currentAlphas.removeAll()
            ruleOpacities.removeAll()
        }
        focusedWindowID = nil
    }

    /// Restore a single window to full alpha and remove from tracking.
    /// Primary purpose: state cleanup to prevent stale entries on CGWindowID recycling.
    public func restoreWindow(_ tileID: TileID) {
        let wid = tileID.rawValue
        fadeAnimations.removeValue(forKey: wid)
        currentAlphas.removeValue(forKey: wid)

        if focusedWindowID == wid {
            focusedWindowID = nil
        }

        // Best-effort — compositing layer may already be torn down
        let cid = CGSDefaultConnectionForThread()
        CGSSetWindowAlpha(cid, wid, 1.0)
        ruleOpacities.removeValue(forKey: wid)
    }

    // MARK: - Private

    /// Get the current alpha for a window: from in-flight easing, from stored alpha, or 1.0.
    private func currentAlphaFor(_ wid: CGWindowID, at time: Double) -> Double {
        if let easing = fadeAnimations[wid] {
            return easing.evaluate(at: time)
        }
        return currentAlphas[wid] ?? 1.0
    }
}
