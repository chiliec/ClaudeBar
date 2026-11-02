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
}
