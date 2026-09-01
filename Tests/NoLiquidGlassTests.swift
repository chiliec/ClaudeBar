import Testing
import Foundation

/// Liquid Glass segfaults this app. Resolving any glass effect inside the panel
/// crashes the main thread in DesignLibrary, under
/// `GlassEffectContextResolvedData.updateValue()` ->
/// `MaterialProviderBox.resolveLayers(in:)`. The panel is a borderless,
/// non-activating NSPanel, transparent over an NSVisualEffectView that blends
/// behind the window, so glass has no ordinary backdrop to sample.
///
/// v0.0.31 shipped a fix that removed only the one call site found by grepping
/// for `glassEffect`, and still crashed: `.glass` and `.glassProminent` button
/// styles reach the same code. This test looks for every spelling at once, so a
/// reintroduced one fails here rather than in a user's crash log.
@Suite
struct NoLiquidGlassTests {
    static let bannedAPIs = ["glassEffect", ".glass", ".glassProminent", "GlassEffectContainer"]

    @Test func noSourceFileUsesLiquidGlass() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources")

        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        #expect(!files.isEmpty, "found no Swift sources to scan -- the path above is wrong")

        for file in files {
            // Comments explain why glass is banned and necessarily name it, so
            // scan code only.
            let code = try String(contentsOf: file, encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")

            for api in Self.bannedAPIs {
                let message: Comment = """
                    \(file.lastPathComponent) uses \(api). Liquid Glass segfaults \
                    this app's panel -- see the note on this suite.
                    """
                #expect(!code.contains(api), message)
            }
        }
    }
}
