import SwiftUI

// No Liquid Glass anywhere in this app, on any macOS version. Resolving a glass
// effect inside the panel segfaults the main thread in DesignLibrary, under
// GlassEffectContextResolvedData.updateValue() -> MaterialProviderBox
// .resolveLayers(in:). The panel is a borderless, non-activating NSPanel that is
// transparent over an NSVisualEffectView blending behind the window, so glass has
// no ordinary backdrop to sample. Every `.glass` / `.glassProminent` style is one
// more way to reach that crash, so all of them use the plain AppKit styles.

struct ProminentButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.borderedProminent)
    }
}

struct BorderedButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.buttonStyle(.bordered)
    }
}
