import Foundation
import Testing
@testable import ClaudeBarUI

@Suite(.serialized)
struct AccountStoreTests {
    private let keychain = KeychainService(serviceName: "com.claudebar.test")

    private func wipe() {
        try? keychain.delete(account: AccountStore.keychainAccount)
        try? keychain.delete(account: OAuthService.keychainAccount)
    }

    private func creds(_ tag: String) -> OAuthCredentials {
        OAuthCredentials(accessToken: "at-\(tag)", refreshToken: "rt-\(tag)",
                         expiresAt: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test func emptyWhenNothingStored() throws {
        wipe()
        let set = try AccountStore.load(from: keychain)
        #expect(set.accounts.isEmpty)
        #expect(set.activeID == nil)
    }

    @Test func saveThenLoadRoundTrips() throws {
        wipe()
        let a = Account(id: "u1", label: "a@x.com", credentials: creds("1"))
        let b = Account(id: "u2", label: "b@x.com", credentials: creds("2"))
        try AccountStore.save(AccountSet(accounts: [a, b], activeID: "u2"), to: keychain)
        let set = try AccountStore.load(from: keychain)
        #expect(set.accounts == [a, b])
        #expect(set.activeID == "u2")
        wipe()
    }

    @Test func migratesLegacyCredentialBlob() throws {
        wipe()
        // Seed a legacy single-credential blob the way OAuthService writes it.
        try OAuthService.save(creds("legacy"), to: keychain)
        let set = try AccountStore.load(from: keychain)
        #expect(set.accounts.count == 1)
        #expect(set.activeID == AccountStore.legacyDefaultID)
        #expect(set.accounts.first?.id == AccountStore.legacyDefaultID)
        #expect(set.accounts.first?.credentials == creds("legacy"))
        // Legacy key is deleted; a second load reads the migrated blob, not the legacy path.
        #expect((try? keychain.retrieve(account: OAuthService.keychainAccount)) == nil)
        let again = try AccountStore.load(from: keychain)
        #expect(again.accounts.count == 1)
        wipe()
    }
}
