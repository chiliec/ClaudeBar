import Testing
import Foundation

@Suite
struct SigningInvariantTests {
    /// The EdDSA public key published in every shipped build.
    ///
    /// Sparkle accepts a bundle update when EITHER the EdDSA public keys match
    /// OR the Apple code signing identity matches (Sparkle 2.9.2,
    /// `SUUpdateValidator.m`: "we allow failure of one of them, because this
    /// allows key rotation without breaking chain of trust").
    ///
    /// Rotating the EdDSA key and the signing identity in the same release
    /// fails both checks and permanently breaks auto-update for every
    /// installed copy. This test exists so that mistake fails CI instead of
    /// shipping. See docs/RELEASING.md.
    static let publishedEdDSAKey = "vW+hX4dN3wIN/76bu4/m3PbhakqCL1xK1niZ47jHHqc="

    @Test func infoPlistPublicEdKeyIsUnchanged() throws {
        let plistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // package root
            .appendingPathComponent("Sources/ClaudeBar/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization
            .propertyList(from: data, options: [], format: nil) as? [String: Any]
        let key = plist?["SUPublicEDKey"] as? String
        let message: Comment = """
            SUPublicEDKey in Info.plist is \(key ?? "nil") but the published \
            key is \(Self.publishedEdDSAKey). If you are intentionally \
            rotating the EdDSA key, you must NOT also change the code signing \
            identity in the same release. See docs/RELEASING.md.
            """
        #expect(key == Self.publishedEdDSAKey, message)
    }
}
