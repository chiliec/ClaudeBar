import Foundation
import Testing
@testable import ClaudeBarUI

@Suite(.serialized)
struct ClaudeCodeSessionTests {
    static let cliJSON = """
    {"claudeAiOauth":{"accessToken":"sk-ant-oat01-x","refreshToken":"sk-ant-ort01-y",\
    "expiresAt":1793620800000,"scopes":["user:inference"],"subscriptionType":"max"}}
    """

    @Test func parsesCLIBlobWithMillisecondExpiry() throws {
        let creds = try #require(ClaudeCodeSession.parse(Self.cliJSON))
        #expect(creds.accessToken == "sk-ant-oat01-x")
        #expect(creds.refreshToken == "sk-ant-ort01-y")
        #expect(creds.expiresAt == Date(timeIntervalSince1970: 1_793_620_800))
    }

    @Test func rejectsGarbage() {
        #expect(ClaudeCodeSession.parse("{}") == nil)
        #expect(ClaudeCodeSession.parse("not json") == nil)
    }

    @Test func loadsFromKeychainUnderUserAccount() throws {
        let kc = KeychainService(serviceName: "com.claudebar.test.claudeCodeSession.cli")
        try kc.save(account: NSUserName(), value: Self.cliJSON)
        defer { try? kc.delete(account: NSUserName()) }
        #expect(ClaudeCodeSession.load(from: kc)?.accessToken == "sk-ant-oat01-x")
    }

    @Test func oldAccountBlobsDecodeWithoutFlag() throws {
        let json = #"{"id":"u1","label":"a@x.com","credentials":{"accessToken":"a","refreshToken":"b","expiresAt":0}}"#
        let acct = try JSONDecoder().decode(Account.self, from: Data(json.utf8))
        #expect(acct.isClaudeCode == nil)
    }

    // MARK: - AppState

    private static let cli = KeychainService(serviceName: "com.claudebar.test.claudeCodeSession.cli")

    @MainActor
    private func makeState() -> AppState {
        let state = AppState(keychain: KeychainService(serviceName: "com.claudebar.test.claudeCodeSession"),
                             claudeCodeKeychain: Self.cli)
        state.wipeAllState()
        try? Self.cli.delete(account: NSUserName())
        return state
    }

    private func creds(_ tag: String, expiresIn: TimeInterval) -> OAuthCredentials {
        OAuthCredentials(accessToken: "at-\(tag)", refreshToken: "rt-\(tag)",
                         expiresAt: Date().addingTimeInterval(expiresIn))
    }

    @MainActor @Test func expiredCLITokenGoesStaleWithoutRefreshing() async throws {
        let state = makeState()
        state.insertClaudeCodeAccount(tokens: creds("old", expiresIn: 3600),
                                      identity: AccountIdentity(uuid: "u1", email: "a@x.com"))
        state.usage = try ClaudeAPIClient.parseUsageResponse(
            data: Data(#"{"seven_day": {"utilization": 10.0, "resets_at": null}}"#.utf8))
        // The CLI's item now holds an expired token.
        try Self.cli.save(account: NSUserName(), value: """
        {"claudeAiOauth":{"accessToken":"at-dead","refreshToken":"rt-dead","expiresAt":\
        \(Int(Date().addingTimeInterval(-60).timeIntervalSince1970 * 1000))}}
        """)

        await state.refreshUsage()

        #expect(state.error == .claudeCodeStale)
        #expect(state.usage != nil)                          // last numbers kept
        #expect(state.activeAccount?.expiredAt == nil)       // not marked dead
        #expect(state.credentials?.refreshToken == "rt-old") // nothing refreshed or rewritten
        state.wipeAllState()
        try? Self.cli.delete(account: NSUserName())
    }

    @MainActor @Test func missingCLIItemGoesStale() async {
        let state = makeState()
        state.insertClaudeCodeAccount(tokens: creds("old", expiresIn: 3600),
                                      identity: AccountIdentity(uuid: "u1", email: "a@x.com"))
        await state.refreshUsage()
        #expect(state.error == .claudeCodeStale)
        #expect(state.isAuthenticated)                       // keeps polling, no sign-in panel
        state.wipeAllState()
    }

    @MainActor @Test func claudeCodeEntryReplacesSameUUIDAccount() {
        let state = makeState()
        state.upsert(Account(id: "u1", label: "a@x.com", credentials: creds("own", expiresIn: 3600)))
        state.upsert(Account(id: "u2", label: "b@x.com", credentials: creds("b", expiresIn: 3600)))

        state.insertClaudeCodeAccount(tokens: creds("cli", expiresIn: 3600),
                                      identity: AccountIdentity(uuid: "u1", email: "a@x.com"))

        #expect(state.accounts.map(\.id) == ["u2", AppState.claudeCodeAccountID])
        #expect(state.activeID == AppState.claudeCodeAccountID)
        #expect(state.activeAccount?.isClaudeCode == true)
        #expect(state.activeAccount?.label == "a@x.com")
        state.wipeAllState()
    }
}
