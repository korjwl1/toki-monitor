import AppKit
import ObjectiveC.runtime

/// Forces glass effects to render in "active" state even for non-activating panels.
/// Without this, `.glassEffect()` degrades to flat blur in `.nonactivatingPanel` windows
/// because the system checks `_hasActiveAppearance` which returns false for unfocused windows.
///
/// Based on: https://github.com/siracusa/GlassEffectTest/pull/1 (by insidegui)
@objc(GlassFixWorkaround)
final class GlassFixWorkaround: NSObject {

    static func install() {
        let selector = NSSelectorFromString("_hasActiveAppearance")
        guard let original = class_getInstanceMethod(NSWindow.self, selector) else { return }
        guard let replacement = class_getInstanceMethod(
            GlassFixWorkaround.self,
            #selector(swizzledHasActiveAppearance)
        ) else { return }
        method_exchangeImplementations(original, replacement)
    }

    @objc func swizzledHasActiveAppearance() -> Bool {
        true
    }
}
