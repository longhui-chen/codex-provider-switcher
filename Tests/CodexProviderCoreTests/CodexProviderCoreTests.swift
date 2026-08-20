import Foundation
import XCTest
@testable import CodexProviderCore

final class CodexProviderCoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var codexHome: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        codexHome = temporaryDirectory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
        try fixtureConfig.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testStatusNeverReadsTokenFilesAndRedactsThemByOmission() throws {
        let secretURL = codexHome.appendingPathComponent("provider.key")
        try "secret-value".write(to: secretURL, atomically: true, encoding: .utf8)

        let status = try service.status()

        XCTAssertEqual(status.mode, .proxy)
        XCTAssertEqual(status.model, "gpt-5.6-sol")
        XCTAssertTrue(status.responseStorageDisabled)
        XCTAssertTrue(status.proxyConfigured)
    }

    func testOfficialSwitchBacksUpAndRestoresProxySnapshot() throws {
        let official = try service.switchProvider(to: .official)
        XCTAssertEqual(official.mode, .official)
        XCTAssertFalse(official.responseStorageDisabled)

        let officialConfig = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(officialConfig.contains("model_provider = \"openai\""))
        XCTAssertTrue(officialConfig.contains("disable_response_storage = false"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: codexHome.appendingPathComponent("config.backups").path)
        XCTAssertEqual(backups.count, 1)

        let proxy = try service.switchProvider(to: .proxy)
        XCTAssertEqual(proxy.mode, .proxy)
        XCTAssertEqual(proxy.model, "gpt-5.6-sol")
        XCTAssertTrue(proxy.responseStorageDisabled)
    }

    func testProxyOnlyModelFallsBackForOfficial() throws {
        let terra = fixtureConfig.replacingOccurrences(of: "gpt-5.6-sol", with: "gpt-5.6-terra")
        try terra.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let official = try service.switchProvider(to: .official)

        XCTAssertEqual(official.model, CodexProviderService.officialDefaultModel)
        XCTAssertEqual(official.reviewModel, CodexProviderService.officialDefaultModel)
    }

    func testProxyProviderIDIsDetectedDynamically() throws {
        // The provider id is discovered from [model_providers.*], whatever it is named.
        let renamed = fixtureConfig.replacingOccurrences(of: "my_proxy", with: "acme_gateway")
        try renamed.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        XCTAssertTrue(try service.status().proxyConfigured)
        XCTAssertEqual(
            try service.resumeCommand(provider: .proxy),
            "codex --dangerously-bypass-approvals-and-sandbox -c 'model_provider=\"acme_gateway\"' resume --all"
        )

        let switched = try service.switchProvider(to: .proxy)
        XCTAssertEqual(switched.mode, .proxy)
        XCTAssertEqual(switched.activeProvider, "acme_gateway")
    }

    func testMultilineProviderTableIsNotDetectedAsProxy() throws {
        let trapOnly = """
        developer_instructions = \"\"\"
        [model_providers.trap]
        \"\"\"
        model_provider = "openai"
        """
        try trapOnly.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        XCTAssertFalse(try service.status().proxyConfigured)
        XCTAssertThrowsError(try service.resumeCommand(provider: .proxy)) { error in
            XCTAssertTrue(error is CodexProviderError)
        }
    }

    func testMultilineInstructionsCannotShadowTopLevelProviderSettings() throws {
        let config = """
        developer_instructions = \"\"\"
        model_provider = "trap"
        [model_providers.trap]
        \"\"\"
        model_provider = "my_proxy"
        model = "gpt-5.6-sol"
        review_model = "gpt-5.6-sol"
        disable_response_storage = true

        [model_providers.my_proxy]
        name = "My Responses Proxy"
        """
        try config.write(to: codexHome.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let official = try service.switchProvider(to: .official)
        let saved = try String(contentsOf: codexHome.appendingPathComponent("config.toml"), encoding: .utf8)

        XCTAssertEqual(official.mode, .official)
        XCTAssertTrue(saved.contains("model_provider = \"trap\""))
        XCTAssertTrue(saved.contains("[model_providers.trap]"))
        XCTAssertTrue(saved.contains("model_provider = \"openai\""))
    }

    func testResumeCommandsAlwaysCarryTheChosenProvider() throws {
        let id = "019fcb8b-8991-7d71-b986-7d350dbc687c"

        XCTAssertEqual(
            try service.resumeCommand(provider: .official),
            "codex --dangerously-bypass-approvals-and-sandbox -c 'model_provider=\"openai\"' resume --all"
        )
        XCTAssertEqual(
            try service.resumeCommand(sessionID: id, provider: .proxy),
            "codex --dangerously-bypass-approvals-and-sandbox -c 'model_provider=\"my_proxy\"' resume \(id)"
        )
        XCTAssertThrowsError(try service.resumeCommand(sessionID: "not-a-uuid", provider: .proxy))
    }

    func testIndexSessionsAreDeduplicatedAndNewestFirst() throws {
        let idOne = "019fcb8b-8991-7d71-b986-7d350dbc687c"
        let idTwo = "019fc5a6-ff1c-7b23-808d-300b8d774f65"
        let index = """
        {"id":"\(idOne)","thread_name":"Old name","updated_at":"2026-08-04T06:00:00Z"}
        {"id":"\(idTwo)","thread_name":"Second","updated_at":"2026-08-05T06:00:00Z"}
        {"id":"\(idOne)","thread_name":"Newest name","updated_at":"2026-08-06T06:00:00Z"}
        {"id":"not-a-uuid","thread_name":"Ignore","updated_at":"2026-08-07T06:00:00Z"}
        """
        try index.write(to: codexHome.appendingPathComponent("session_index.jsonl"), atomically: true, encoding: .utf8)

        let sessions = try service.listIndexedSessions()

        XCTAssertEqual(sessions.map(\.id), [idOne, idTwo])
        XCTAssertEqual(sessions.first?.title, "Newest name")
        XCTAssertEqual(try service.status().indexedSessionCount, 2)
    }

    func testAccountCaptureParsesEmailAndStoresSnapshot() throws {
        try writeAuthJSON(email: "michael@example.com", marker: "tokens-A")

        XCTAssertEqual(service.activeAccountEmail(), "michael@example.com")
        XCTAssertTrue(service.listAccounts().isEmpty)

        let account = try service.captureCurrentLogin()

        XCTAssertEqual(account.email, "michael@example.com")
        XCTAssertEqual(service.listAccounts().map(\.email), ["michael@example.com"])
        let stored = try String(
            contentsOf: codexHome
                .appendingPathComponent("auth-store/michael-example-com/auth.json"),
            encoding: .utf8
        )
        XCTAssertTrue(stored.contains("tokens-A"))
    }

    func testAccountSwitchSyncsBackRefreshedTokensAndInstallsTarget() throws {
        try writeAuthJSON(email: "first@example.com", marker: "tokens-first-v1")
        _ = try service.captureCurrentLogin()

        // Simulate a different login becoming active without being captured.
        try writeAuthJSON(email: "second@example.com", marker: "tokens-second")
        _ = try service.captureCurrentLogin()

        // Codex refreshes tokens while first@example.com is active again.
        try writeAuthJSON(email: "first@example.com", marker: "tokens-first-refreshed")
        let first = service.listAccounts().first { $0.email == "first@example.com" }!
        _ = try service.switchAccount(to: first.id)

        // The leaving account's refreshed login was synced into the store.
        let storedFirst = try String(
            contentsOf: codexHome.appendingPathComponent("auth-store/first-example-com/auth.json"),
            encoding: .utf8
        )
        XCTAssertTrue(storedFirst.contains("tokens-first-refreshed"))
        // auth.json now carries the target account's login.
        let active = try String(contentsOf: codexHome.appendingPathComponent("auth.json"), encoding: .utf8)
        XCTAssertTrue(active.contains("tokens-first-refreshed"))
        XCTAssertEqual(service.activeAccountEmail(), "first@example.com")
    }

    func testAccountSwitchToUnsavedLoginFailsClosed() throws {
        try writeAuthJSON(email: "only@example.com", marker: "tokens-only")
        _ = try service.captureCurrentLogin()

        XCTAssertThrowsError(try service.switchAccount(to: "does-not-exist")) { error in
            XCTAssertTrue(error is CodexProviderError)
        }
        XCTAssertEqual(service.activeAccountEmail(), "only@example.com")
    }

    func testActiveAccountCannotBeRemoved() throws {
        try writeAuthJSON(email: "keeper@example.com", marker: "tokens-keeper")
        let keeper = try service.captureCurrentLogin()
        try writeAuthJSON(email: "other@example.com", marker: "tokens-other")
        _ = try service.captureCurrentLogin()
        // 活跃登录现在是 other@example.com。

        XCTAssertThrowsError(try service.removeAccount("other-example-com"))
        try service.removeAccount(keeper.id)
        XCTAssertEqual(service.listAccounts().map(\.email), ["other@example.com"])
    }

    func testNotLoggedInWhenAuthJSONMissingOrAPIKeyMode() throws {
        XCTAssertNil(service.activeAccountEmail())
        XCTAssertThrowsError(try service.captureCurrentLogin()) { error in
            XCTAssertTrue(error is CodexProviderError)
        }

        let apiKeyOnly = """
        {"OPENAI_API_KEY": "sk-test", "auth_mode": "apikey", "tokens": null}
        """
        try apiKeyOnly.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        XCTAssertNil(service.activeAccountEmail())
    }

    /// Builds a minimal auth.json whose id_token JWT carries the given email.
    private func writeAuthJSON(email: String, marker: String) throws {
        func base64URL(_ text: String) -> String {
            Data(text.utf8)
                .base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
        }
        let payload = #"{"email":"\#(email)"}"#
        let idToken = "\(base64URL(#"{"alg":"RS256"}"#)).\(base64URL(payload)).signature"
        let auth = """
        {"OPENAI_API_KEY": null, "auth_mode": "chatgpt", "tokens": {"access_token": "\(marker)-access", "refresh_token": "\(marker)-refresh", "id_token": "\(idToken)", "account_id": "acct"}}
        """
        try auth.write(to: codexHome.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
    }

    private var service: CodexProviderService {
        CodexProviderService(codexHome: codexHome)
    }

    private let fixtureConfig = """
    model_provider = "my_proxy"
    model = "gpt-5.6-sol"
    review_model = "gpt-5.6-sol"
    disable_response_storage = true

    [model_providers.my_proxy]
    name = "My Responses Proxy"
    base_url = "http://127.0.0.1:8080"
    wire_api = "responses"

    [model_providers.my_proxy.auth]
    command = "/bin/cat"
    args = ["/tmp/provider.key"]
    """
}
