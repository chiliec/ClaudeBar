import Testing
@testable import ClaudeBarUI

@Suite(.serialized)
struct KeychainServiceTests {
    let service = KeychainService(serviceName: "com.claudebar.test")

    /// A release build must land on the production service and nothing else:
    /// getting this wrong points every installed copy at an empty keychain item
    /// and silently signs the user out.
    @Test func releaseBuildsUseTheProductionService() {
        #expect(KeychainService.resolveServiceName(isDebug: false, override: nil)
                == "com.claudebar")
    }

    @Test func devBuildsGetTheirOwnService() {
        // run.sh: debug binary, no Info.plist to read an override from.
        #expect(KeychainService.resolveServiceName(isDebug: true, override: nil)
                == "com.claudebar.dev")
        // bundle.sh: release configuration, so the override is the only signal.
        #expect(KeychainService.resolveServiceName(isDebug: false, override: "com.claudebar.dev")
                == "com.claudebar.dev")
    }

    private func cleanup() {
        try? service.delete(account: "sessionKey")
        try? service.delete(account: "orgId")
    }

    @Test func saveAndRetrieve() throws {
        cleanup()
        try service.save(account: "sessionKey", value: "sk-ant-sid01-test123")
        let retrieved = try service.retrieve(account: "sessionKey")
        #expect(retrieved == "sk-ant-sid01-test123")
        cleanup()
    }

    @Test func retrieveNonExistent() {
        cleanup()
        let result = try? service.retrieve(account: "nonexistent")
        #expect(result == nil)
    }

    @Test func overwriteExisting() throws {
        cleanup()
        try service.save(account: "sessionKey", value: "old-value")
        try service.save(account: "sessionKey", value: "new-value")
        let retrieved = try service.retrieve(account: "sessionKey")
        #expect(retrieved == "new-value")
        cleanup()
    }

    @Test func delete() throws {
        cleanup()
        try service.save(account: "orgId", value: "abc-123")
        try service.delete(account: "orgId")
        let result = try? service.retrieve(account: "orgId")
        #expect(result == nil)
    }
}
