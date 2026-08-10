import Config
import Foundation

/// Push config-driven animation values onto a strip.
///
/// Shared by `applyConfig` (existing controllers, on reload) and
/// `applyConfigToStrip` (freshly created controllers) so the two paths cannot
/// drift apart. Wiring only the latter is why `[animation]` settings appeared to
/// do nothing: reload never went through it, so live strips kept the defaults.
///
/// Core never reads `ReelConfig`; these are plain stored properties on `Strip`,
/// injected the same way `gap` / `snapPoints` / `widthPresets` are.
package func applyAnimationConfig(_ config: ReelConfig, to sc: StripController) {
    sc.strip.scrollSpringParams = config.widthSpringParams
    sc.strip.bounceDistance = config.bounceDistance
    sc.strip.bounceDampingRatio = config.bounceDampingRatio
}
