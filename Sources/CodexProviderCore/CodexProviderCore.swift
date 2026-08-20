import Darwin
import Foundation

public enum ProviderMode: String, CaseIterable, Codable, Identifiable {
    case official
    case proxy
    case custom

    public var id: String { rawValue }

    public var providerID: String {
        switch self {
        case .official:
            return "openai"
        case .proxy, .custom:
            return ""
        }
    }

    public var displayName: String {
        switch self {
        case .official:
            return "OpenAI / ChatGPT"
        case .proxy:
            return "自定义代理"
        case .custom:
            return "自定义提供方"
        }
    }
}

public struct ProviderStatus: Equatable {
    public let activeProvider: String
    public let mode: ProviderMode
    public let model: String?
    public let reviewModel: String?
    public let responseStorageDisabled: Bool
    public let proxyConfigured: Bool
    public let indexedSessionCount: Int

    public var storageDescription: String {
        responseStorageDisabled ? "已禁用" : "已启用"
    }
}

public struct CodexSession: Identifiable, Hashable {
    public let id: String
    public let title: String
    public let updatedAt: Date?

    public init(id: String, title: String, updatedAt: Date?) {
        self.id = id
        self.title = title
        self.updatedAt = updatedAt
    }
}

public enum CodexProviderError: LocalizedError {
    case missingConfig(URL)
    case invalidSessionID(String)
    case unsupportedProvider
    case proxyNotConfigured
    case failedToLockConfig
    case failedToWrite(String)
    case notLoggedIn
    case unknownAccount(String)
    case accountCurrentlyActive(String)
    case missingStoredAuth(String)

    public var errorDescription: String? {
        switch self {
        case .missingConfig(let url):
            return "未找到 Codex 配置文件：\(url.path)"
        case .invalidSessionID(let id):
            return "所选会话 ID 无效：\(id)"
        case .unsupportedProvider:
            return "只能选择官方 OpenAI 或已配置的代理。"
        case .proxyNotConfigured:
            return "config.toml 中没有找到自定义代理 provider（需要 [model_providers.*] 表）。"
        case .failedToLockConfig:
            return "无法锁定 config.toml，已取消切换以保护配置。"
        case .failedToWrite(let message):
            return message
        case .notLoggedIn:
            return "auth.json 中没有可识别的 ChatGPT 登录（可能未登录或处于 API Key 模式）。"
        case .unknownAccount(let id):
            return "账号库中找不到账号：\(id)"
        case .accountCurrentlyActive(let email):
            return "\(email) 正在使用中，切换到其他账号后才能删除。"
        case .missingStoredAuth(let email):
            return "\(email) 没有保存的登录文件，请先登录该账号并保存。"
        }
    }
}

/// A saved official-account login. Holds only identity metadata;
/// token material stays inside the per-account auth.json snapshots.
public struct CodexAccount: Identifiable, Codable, Hashable {
    public let id: String
    public let email: String
    public var addedAt: Date?
    public var lastUsedAt: Date?

    public init(id: String, email: String, addedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.email = email
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
    }
}

/// A small local-only controller for Codex's top-level provider settings.
/// Account switching manages auth.json snapshots but never surfaces
/// token contents; only the JWT email claim is read for display.
public final class CodexProviderService {
    public static let officialDefaultModel = "gpt-5.5"

    private let fileManager: FileManager
    public let codexHome: URL

    private var configURL: URL { codexHome.appendingPathComponent("config.toml") }
    private var indexURL: URL { codexHome.appendingPathComponent("session_index.jsonl") }
    private var stateURL: URL { codexHome.appendingPathComponent(".codex-provider-switcher-app.json") }
    private var backupDirectoryURL: URL { codexHome.appendingPathComponent("config.backups") }
    private var lockURL: URL { codexHome.appendingPathComponent(".config.toml.provider-switcher-app.lock") }
    private var authURL: URL { codexHome.appendingPathComponent("auth.json") }
    private var accountStoreURL: URL { codexHome.appendingPathComponent("auth-store") }
    private var accountIndexURL: URL { accountStoreURL.appendingPathComponent("accounts.json") }

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), fileManager: FileManager = .default) {
        self.codexHome = codexHome.standardizedFileURL
        self.fileManager = fileManager
    }

    public func listIndexedSessions() throws -> [CodexSession] {
        guard fileManager.fileExists(atPath: indexURL.path) else { return [] }
        let content = try String(contentsOf: indexURL, encoding: .utf8)
        var records: [String: CodexSession] = [:]

        for line in content.split(whereSeparator: \.isNewline) {
            guard
                let data = line.data(using: .utf8),
                let item = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let id = item["id"] as? String,
                UUID(uuidString: id) != nil
            else {
                continue
            }

            let rawTitle = (item["thread_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle?.isEmpty == false ? rawTitle! : "未命名会话"
            let updatedAt = Self.parseDate(item["updated_at"] as? String)
            let candidate = CodexSession(id: id, title: title, updatedAt: updatedAt)

            if let current = records[id] {
                if (candidate.updatedAt ?? .distantPast) > (current.updatedAt ?? .distantPast) {
                    records[id] = candidate
                }
            } else {
                records[id] = candidate
            }
        }

        return records.values.sorted {
            ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast)
        }
    }

    public func resumeCommand(sessionID: String? = nil, provider: ProviderMode) throws -> String {
        guard provider == .official || provider == .proxy else {
            throw CodexProviderError.unsupportedProvider
        }
        let providerID = provider == .official ? provider.providerID : try requireConfiguredProxyID()
        let prefix = "codex --dangerously-bypass-approvals-and-sandbox -c 'model_provider=\"\(providerID)\"' resume"
        guard let sessionID else { return "\(prefix) --all" }
        guard UUID(uuidString: sessionID) != nil else {
            throw CodexProviderError.invalidSessionID(sessionID)
        }
        return "\(prefix) \(sessionID)"
    }

    /// Makes the target provider the default for future Codex processes.
    /// Resume commands remain provider-explicit and do not require this switch.
    @discardableResult
    public func switchProvider(to target: ProviderMode) throws -> ProviderStatus {
        guard target == .official || target == .proxy else {
            throw CodexProviderError.unsupportedProvider
        }

        return try withExclusiveConfigLock {
            let original = try readConfig()
            let current = try status(from: original)
            if target == .proxy {
                _ = try requireConfiguredProxyID(in: original)
            }
            var state = readState()
            let currentSnapshot = ConfigSnapshot(
                modelProvider: current.activeProvider,
                model: current.model,
                reviewModel: current.reviewModel,
                responseStorageDisabled: current.responseStorageDisabled
            )

            var targetModel = current.model
            var targetReviewModel = current.reviewModel
            if target == .official {
                if current.mode == .proxy {
                    state.proxySnapshot = currentSnapshot
                }
                if isProxyOnlyModel(targetModel) {
                    targetModel = Self.officialDefaultModel
                }
                if isProxyOnlyModel(targetReviewModel) {
                    targetReviewModel = Self.officialDefaultModel
                }
            } else if let snapshot = state.proxySnapshot {
                targetModel = snapshot.model
                targetReviewModel = snapshot.reviewModel
            } else if state.proxySnapshot == nil {
                state.proxySnapshot = currentSnapshot
            }

            var updated = setTopLevelAssignment(
                in: original,
                key: "model_provider",
                value: tomlString(target == .official ? target.providerID : try requireConfiguredProxyID(in: original))
            )
            updated = setTopLevelAssignment(
                in: updated,
                key: "disable_response_storage",
                value: target == .proxy ? "true" : "false"
            )
            updated = setOrRemoveTopLevelAssignment(
                in: updated,
                key: "model",
                value: targetModel.map(tomlString)
            )
            updated = setOrRemoveTopLevelAssignment(
                in: updated,
                key: "review_model",
                value: targetReviewModel.map(tomlString)
            )

            guard updated != original else { return current }
            // Retain the known-good proxy values before changing the active
            // config, so an interrupted switch still leaves a safe restore path.
            try writeState(state)
            try createBackup(of: original)
            try atomicWrite(updated.data(using: .utf8) ?? Data(), to: configURL)
            return try status(from: updated)
        }
    }

    // MARK: - Official account switching

    /// All logins saved in the account store, sorted by email.
    public func listAccounts() -> [CodexAccount] {
        readAccountIndex().accounts.sorted { $0.email < $1.email }
    }

    /// Email inside the active auth.json's id_token claim, or nil when
    /// logged out / API-key mode / unparseable. Token bodies are never returned.
    public func activeAccountEmail() -> String? {
        guard let email = try? parseActiveAuthEmail() else { return nil }
        return email
    }

    /// Saves the login currently inside auth.json into the account store
    /// (create or overwrite), returning the stored account.
    @discardableResult
    public func captureCurrentLogin() throws -> CodexAccount {
        try withExclusiveConfigLock {
            let authData = try readAuthData()
            let email = try parseActiveAuthEmail(authData: authData)
            let account = CodexAccount(id: Self.accountSlug(for: email), email: email, addedAt: Date())
            try upsertStoredAuth(authData, for: account)
            return account
        }
    }

    /// Makes the target account's saved login the active auth.json.
    /// The login currently in auth.json is synced back into its own store
    /// entry first, so token refreshes performed while it was active are kept.
    public func switchAccount(to accountID: String) throws -> CodexAccount {
        try withExclusiveConfigLock {
            var index = readAccountIndex()
            guard let target = index.accounts.first(where: { $0.id == accountID }) else {
                throw CodexProviderError.unknownAccount(accountID)
            }
            let targetAuthURL = accountStoreURL
                .appendingPathComponent(target.id)
                .appendingPathComponent("auth.json")
            guard fileManager.fileExists(atPath: targetAuthURL.path) else {
                throw CodexProviderError.missingStoredAuth(target.email)
            }

            if let authData = try? readAuthData(), let currentEmail = try? parseActiveAuthEmail(authData: authData) {
                // Persist any refreshed tokens for the account being left —
                // or the same account, so reinstalling below cannot roll the
                // login back to a stale snapshot.
                let leaving = CodexAccount(id: Self.accountSlug(for: currentEmail), email: currentEmail)
                try upsertStoredAuth(authData, for: leaving, index: &index)
            }

            let installed = try Data(contentsOf: targetAuthURL)
            try atomicWrite(installed, to: authURL)

            if let position = index.accounts.firstIndex(where: { $0.id == target.id }) {
                index.accounts[position].lastUsedAt = Date()
            }
            try writeAccountIndex(index)
            return index.accounts.first { $0.id == target.id } ?? target
        }
    }

    /// Removes a saved login from the store. The currently active account
    /// cannot be removed while its login is installed in auth.json.
    public func removeAccount(_ accountID: String) throws {
        try withExclusiveConfigLock {
            var index = readAccountIndex()
            guard let account = index.accounts.first(where: { $0.id == accountID }) else {
                throw CodexProviderError.unknownAccount(accountID)
            }
            if let active = try? parseActiveAuthEmail(), active == account.email {
                throw CodexProviderError.accountCurrentlyActive(account.email)
            }
            index.accounts.removeAll { $0.id == accountID }
            try writeAccountIndex(index)
            try? fileManager.removeItem(at: accountStoreURL.appendingPathComponent(accountID))
        }
    }

    private func readAuthData() throws -> Data {
        guard fileManager.fileExists(atPath: authURL.path) else {
            throw CodexProviderError.notLoggedIn
        }
        return try Data(contentsOf: authURL)
    }

    /// Decodes only the id_token email claim. The decoded payload stays in
    /// local scope; no other claim or token is exposed to callers.
    private func parseActiveAuthEmail(authData: Data? = nil) throws -> String {
        let data: Data
        if let authData {
            data = authData
        } else {
            data = try readAuthData()
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String
        else {
            throw CodexProviderError.notLoggedIn
        }
        let segments = idToken.split(separator: ".")
        guard segments.count == 3 else {
            throw CodexProviderError.notLoggedIn
        }
        var payload = segments[1].replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload += "="
        }
        guard let payloadData = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        else {
            throw CodexProviderError.notLoggedIn
        }
        if let email = claims["email"] as? String,
           !email.trimmingCharacters(in: .whitespaces).isEmpty {
            return email.trimmingCharacters(in: .whitespaces)
        }
        if let auth = claims["https://api.openai.com/auth"] as? [String: Any],
           let email = auth["user_email"] as? String,
           !email.isEmpty {
            return email
        }
        throw CodexProviderError.notLoggedIn
    }

    private func upsertStoredAuth(_ authData: Data, for account: CodexAccount, index: inout AccountIndex) throws {
        let directory = accountStoreURL.appendingPathComponent(account.id)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try atomicWrite(authData, to: directory.appendingPathComponent("auth.json"))

        if let position = index.accounts.firstIndex(where: { $0.id == account.id }) {
            index.accounts[position].addedAt = index.accounts[position].addedAt ?? account.addedAt
        } else {
            index.accounts.append(account)
        }
        try writeAccountIndex(index)
    }

    private func upsertStoredAuth(_ authData: Data, for account: CodexAccount) throws {
        var index = readAccountIndex()
        try upsertStoredAuth(authData, for: account, index: &index)
    }

    private func readAccountIndex() -> AccountIndex {
        guard let data = try? Data(contentsOf: accountIndexURL),
              let index = try? JSONDecoder().decode(AccountIndex.self, from: data) else {
            return AccountIndex()
        }
        return index
    }

    private func writeAccountIndex(_ index: AccountIndex) throws {
        let data = try JSONEncoder().encode(index)
        try atomicWrite(data, to: accountIndexURL)
    }

    private static func accountSlug(for email: String) -> String {
        let lowered = email.lowercased()
        var slug = ""
        var previousDash = false
        for scalar in lowered.unicodeScalars {
            switch scalar {
            case "a"..."z", "0"..."9":
                slug.unicodeScalars.append(scalar)
                previousDash = false
            default:
                if !previousDash && !slug.isEmpty {
                    slug.append("-")
                    previousDash = true
                }
            }
        }
        while slug.hasSuffix("-") {
            slug.removeLast()
        }
        return slug.isEmpty ? "account-\(UUID().uuidString.prefix(8))" : slug
    }

    private func readConfig() throws -> String {
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw CodexProviderError.missingConfig(configURL)
        }
        return try String(contentsOf: configURL, encoding: .utf8)
    }

    /// Reads config and the session index in a single pass for UI refresh,
    /// so callers that need both do not parse the index file twice.
    public func overview() throws -> (status: ProviderStatus, sessions: [CodexSession]) {
        let sessions = try listIndexedSessions()
        let status = try status(from: readConfig(), indexedSessionCount: sessions.count)
        return (status, sessions)
    }

    public func status() throws -> ProviderStatus {
        try status(from: readConfig(), indexedSessionCount: (try? listIndexedSessions().count) ?? 0)
    }

    private func status(from source: String, indexedSessionCount: Int = 0) throws -> ProviderStatus {
        let activeProvider = topLevelValue(in: source, key: "model_provider") ?? "openai"
        let proxyID = configuredProxyID(in: source)
        let mode: ProviderMode
        if activeProvider == ProviderMode.official.providerID {
            mode = .official
        } else if let proxyID, activeProvider == proxyID {
            mode = .proxy
        } else {
            mode = .custom
        }
        return ProviderStatus(
            activeProvider: activeProvider,
            mode: mode,
            model: topLevelValue(in: source, key: "model"),
            reviewModel: topLevelValue(in: source, key: "review_model"),
            responseStorageDisabled: topLevelBoolean(in: source, key: "disable_response_storage") ?? false,
            proxyConfigured: proxyID != nil,
            indexedSessionCount: indexedSessionCount
        )
    }

    /// Resolves the id of the first custom (non-openai) proxy provider
    /// configured in config.toml, throwing when none exists.
    private func requireConfiguredProxyID(in source: String? = nil) throws -> String {
        if let source {
            guard let id = configuredProxyID(in: source) else {
                throw CodexProviderError.proxyNotConfigured
            }
            return id
        }
        return try requireConfiguredProxyID(in: try readConfig())
    }

    /// Scans real `[model_providers.<id>]` table headers and returns the
    /// first id other than "openai". Headers that only appear inside TOML
    /// multiline strings are ignored, matching the top-level parser rules.
    private func configuredProxyID(in source: String) -> String? {
        let remainder = splitTopLevel(source).remainder
        let headerPattern = "^\\[model_providers\\.([A-Za-z0-9_.-]+)\\]"
        var multilineDelimiter: String?
        var lineStart = remainder.startIndex

        while lineStart < remainder.endIndex {
            let lineEnd = remainder[lineStart...].firstIndex(of: "\n") ?? remainder.endIndex
            let line = String(remainder[lineStart..<lineEnd])

            if let delimiter = multilineDelimiter {
                if hasOddOccurrences(of: delimiter, in: line) {
                    multilineDelimiter = nil
                }
            } else {
                if let match = line.range(of: headerPattern, options: .regularExpression) {
                    let id = String(line[match].dropFirst("[model_providers.".count).dropLast())
                    if id != ProviderMode.official.providerID {
                        return id
                    }
                }
                multilineDelimiter = openedMultilineDelimiter(in: line)
            }

            lineStart = lineEnd < remainder.endIndex ? remainder.index(after: lineEnd) : remainder.endIndex
        }
        return nil
    }

    private func topLevelValue(in source: String, key: String) -> String? {
        let prefix = splitTopLevel(source).prefix
        guard let range = topLevelAssignmentRange(in: prefix, key: key) else { return nil }
        let line = prefix[range].trimmingCharacters(in: .whitespaces)
        guard let separator = line.firstIndex(of: "=") else { return nil }
        return parseTomlScalar(String(line[line.index(after: separator)...]))
    }

    private func topLevelBoolean(in source: String, key: String) -> Bool? {
        guard let value = topLevelValue(in: source, key: key) else { return nil }
        switch value.lowercased() {
        case "true":
            return true
        case "false":
            return false
        default:
            return nil
        }
    }

    private func parseTomlScalar(_ rawValue: String) -> String {
        let withoutComment = rawValue.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .trimmingCharacters(in: .whitespaces)
        guard withoutComment.count >= 2, withoutComment.first == "\"", withoutComment.last == "\"" else {
            return withoutComment
        }
        if let data = withoutComment.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return decoded
        }
        return String(withoutComment.dropFirst().dropLast())
    }

    private func splitTopLevel(_ source: String) -> (prefix: String, remainder: String) {
        guard let tableStart = firstTopLevelTableStart(in: source) else {
            return (source, "")
        }
        return (String(source[..<tableStart]), String(source[tableStart...]))
    }

    private func setTopLevelAssignment(in source: String, key: String, value: String) -> String {
        let pieces = splitTopLevel(source)
        if let range = topLevelAssignmentRange(in: pieces.prefix, key: key) {
            let replacement = "\(key) = \(value)"
            return pieces.prefix.replacingCharacters(in: range, with: replacement) + pieces.remainder
        }
        var prefix = pieces.prefix
        if !prefix.isEmpty && !prefix.hasSuffix("\n") {
            prefix.append("\n")
        }
        prefix += "\(key) = \(value)\n"
        return prefix + pieces.remainder
    }

    private func setOrRemoveTopLevelAssignment(in source: String, key: String, value: String?) -> String {
        guard let value else { return removeTopLevelAssignment(in: source, key: key) }
        return setTopLevelAssignment(in: source, key: key, value: value)
    }

    private func removeTopLevelAssignment(in source: String, key: String) -> String {
        let pieces = splitTopLevel(source)
        guard let assignment = topLevelAssignmentRange(in: pieces.prefix, key: key) else {
            return source
        }
        var removal = assignment
        if removal.upperBound < pieces.prefix.endIndex, pieces.prefix[removal.upperBound] == "\n" {
            removal = removal.lowerBound..<pieces.prefix.index(after: removal.upperBound)
        }
        return pieces.prefix.replacingCharacters(in: removal, with: "") + pieces.remainder
    }

    /// Finds actual top-level assignments while skipping TOML multiline
    /// strings. This prevents a line inside developer_instructions from being
    /// mistaken for a provider setting.
    private func topLevelAssignmentRange(in source: String, key: String) -> Range<String.Index>? {
        var lineStart = source.startIndex
        var multilineDelimiter: String?
        let keyPattern = "^[[:space:]]*\(NSRegularExpression.escapedPattern(for: key))[[:space:]]*="

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let lineRange = lineStart..<lineEnd
            let line = String(source[lineRange])

            if let delimiter = multilineDelimiter {
                if hasOddOccurrences(of: delimiter, in: line) {
                    multilineDelimiter = nil
                }
            } else {
                if line.range(of: keyPattern, options: .regularExpression) != nil {
                    return lineRange
                }
                multilineDelimiter = openedMultilineDelimiter(in: line)
            }

            lineStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
        }
        return nil
    }

    private func firstTopLevelTableStart(in source: String) -> String.Index? {
        var lineStart = source.startIndex
        var multilineDelimiter: String?

        while lineStart < source.endIndex {
            let lineEnd = source[lineStart...].firstIndex(of: "\n") ?? source.endIndex
            let line = String(source[lineStart..<lineEnd])
            if let delimiter = multilineDelimiter {
                if hasOddOccurrences(of: delimiter, in: line) {
                    multilineDelimiter = nil
                }
            } else {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    return lineStart
                }
                multilineDelimiter = openedMultilineDelimiter(in: line)
            }
            lineStart = lineEnd < source.endIndex ? source.index(after: lineEnd) : source.endIndex
        }
        return nil
    }

    private func openedMultilineDelimiter(in line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#") else { return nil }
        for delimiter in ["\"\"\"", "'''"] where hasOddOccurrences(of: delimiter, in: line) {
            return delimiter
        }
        return nil
    }

    private func hasOddOccurrences(of delimiter: String, in line: String) -> Bool {
        let count = line.components(separatedBy: delimiter).count - 1
        return count.isMultiple(of: 2) == false
    }

    private func tomlString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func isProxyOnlyModel(_ model: String?) -> Bool {
        guard let model = model?.lowercased() else { return false }
        return model.hasSuffix("-terra") || model.hasSuffix("_terra")
    }

    private func withExclusiveConfigLock<T>(_ operation: () throws -> T) throws -> T {
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CodexProviderError.failedToLockConfig }
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CodexProviderError.failedToLockConfig }
        return try operation()
    }

    private func createBackup(of source: String) throws {
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true)
        let timestamp = Self.backupTimestamp()
        let backupURL = backupDirectoryURL.appendingPathComponent("config-\(timestamp)-\(UUID().uuidString.prefix(8)).toml")
        try atomicWrite(source.data(using: .utf8) ?? Data(), to: backupURL)
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: [])
            let descriptor = Darwin.open(temporary.path, O_RDONLY)
            guard descriptor >= 0 else {
                throw CodexProviderError.failedToWrite("无法同步写入 \(destination.lastPathComponent)。")
            }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.fsync(descriptor) == 0 else {
                throw CodexProviderError.failedToWrite("无法同步写入 \(destination.lastPathComponent)。")
            }
            guard chmod(temporary.path, S_IRUSR | S_IWUSR) == 0 else {
                throw CodexProviderError.failedToWrite("无法为 \(destination.lastPathComponent) 设置受限权限。")
            }
            guard rename(temporary.path, destination.path) == 0 else {
                throw CodexProviderError.failedToWrite("无法原子替换 \(destination.lastPathComponent)。")
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private func readState() -> AppState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(AppState.self, from: data) else {
            return AppState()
        }
        return state
    }

    private func writeState(_ state: AppState) throws {
        let data = try JSONEncoder().encode(state)
        try atomicWrite(data, to: stateURL)
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: Date())
    }
}

private struct ConfigSnapshot: Codable {
    let modelProvider: String
    let model: String?
    let reviewModel: String?
    let responseStorageDisabled: Bool
}

private struct AppState: Codable {
    var proxySnapshot: ConfigSnapshot?
}

private struct AccountIndex: Codable {
    var accounts: [CodexAccount] = []
}
