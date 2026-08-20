import AppKit
import CodexProviderCore
import Darwin
import SwiftUI

@main
struct CodexProviderSwitcherApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
    }
}

@MainActor
private final class ProviderViewModel: ObservableObject {
    @Published private(set) var status: ProviderStatus?
    @Published private(set) var sessions: [CodexSession] = []
    @Published private(set) var accounts: [CodexAccount] = []
    @Published private(set) var activeEmail: String?
    @Published var selectedSessionID: String?
    @Published var searchText = ""
    @Published var message: String?
    @Published var errorMessage: String?

    private let service = CodexProviderService()

    init() {
        refresh()
    }

    var selectedSession: CodexSession? {
        sessions.first { $0.id == selectedSessionID }
    }

    /// True when the login currently in auth.json already has a store entry.
    var activeAccountIsStored: Bool {
        guard let activeEmail else { return false }
        return accounts.contains { $0.email.lowercased() == activeEmail.lowercased() }
    }

    var filteredSessions: [CodexSession] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        return sessions.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    func refresh() {
        do {
            status = try service.status()
            sessions = try service.listIndexedSessions()
            accounts = service.listAccounts()
            activeEmail = service.activeAccountEmail()
            if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }
            message = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchAccount(_ account: CodexAccount) {
        do {
            let switched = try service.switchAccount(to: account.id)
            activeEmail = service.activeAccountEmail()
            accounts = service.listAccounts()
            message = "已切换到 \(switched.email)。之后启动的 Codex 使用该账号；正在运行的会话仍持有旧登录。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// One-step entry: makes this account active, then puts the official
    /// command on the clipboard so a paste in the terminal just works.
    /// When the account is already active, auth.json is left untouched.
    func copyOfficialCommandAs(account: CodexAccount) {
        do {
            let isActive = activeEmail?.lowercased() == account.email.lowercased()
            if !isActive {
                _ = try service.switchAccount(to: account.id)
                activeEmail = service.activeAccountEmail()
                accounts = service.listAccounts()
            }
            let command = try service.resumeCommand(provider: .official)
            copyToClipboard(command)
            message = isActive
                ? "官方命令已复制（当前登录就是 \(account.email)），粘贴到终端即可。"
                : "已切换到 \(account.email)，官方命令已复制，粘贴到终端即可。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func captureAccount() {
        do {
            let account = try service.captureCurrentLogin()
            accounts = service.listAccounts()
            message = "已把当前登录（\(account.email)）保存进账号库。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeAccount(_ account: CodexAccount) {
        do {
            try service.removeAccount(account.id)
            accounts = service.listAccounts()
            message = "已从账号库移除 \(account.email)。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func switchProvider(to target: ProviderMode) {
        do {
            status = try service.switchProvider(to: target)
            sessions = try service.listIndexedSessions()
            message = "默认提供方已切换为 \(target.displayName)。新启动的 Codex 才会使用它。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchPicker() {
        do {
            try launchInTerminal(service.resumeCommand(provider: .official))
            message = "已在 Terminal 中打开官方历史选择器。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copyPickerCommand() {
        do {
            let command = try service.resumeCommand(provider: .official)
            copyToClipboard(command)
            message = "官方历史命令已复制。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func launchSelected(provider: ProviderMode) {
        guard let session = selectedSession else { return }
        do {
            try launchInTerminal(service.resumeCommand(sessionID: session.id, provider: provider))
            message = "已在 Terminal 中使用 \(provider.displayName) 打开所选会话。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func copySelectedCommand(provider: ProviderMode) {
        guard let session = selectedSession else { return }
        do {
            let command = try service.resumeCommand(sessionID: session.id, provider: provider)
            copyToClipboard(command)
            message = provider == .proxy ? "代理恢复命令已复制。" : "官方恢复命令已复制。"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearError() {
        errorMessage = nil
    }

    private func copyToClipboard(_ command: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(command, forType: .string)
    }

    private func launchInTerminal(_ command: String) throws {
        let scriptURL = try makeTerminalCommandFile(command)
        let launcher = Process()
        launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        launcher.arguments = ["-a", "Terminal", scriptURL.path]
        launcher.standardOutput = FileHandle.nullDevice
        launcher.standardError = FileHandle.nullDevice
        do {
            try launcher.run()
        } catch {
            throw NSError(
                domain: "CodexProviderSwitcher",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法启动 Terminal。请使用“复制命令”后在终端手动执行。"]
            )
        }
    }

    private func makeTerminalCommandFile(_ command: String) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("codex-provider-switcher", isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let file = directory.appendingPathComponent("resume-\(UUID().uuidString).command")
        let script = "#!/bin/zsh\nexec /bin/zsh -lic \(shellQuote(command))\n"
        try script.write(to: file, atomically: true, encoding: .utf8)
        guard chmod(file.path, 0o700) == 0 else {
            throw NSError(
                domain: "CodexProviderSwitcher",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "无法准备 Terminal 启动文件。请使用“复制命令”。"]
            )
        }
        return file
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private struct ContentView: View {
    @StateObject private var model = ProviderViewModel()
    @State private var pendingProvider: ProviderMode?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                providerPane
                    .frame(minWidth: 250, idealWidth: 280)
                historyPane
                    .frame(minWidth: 360, idealWidth: 430)
                detailPane
                    .frame(minWidth: 270, idealWidth: 300)
            }
            .padding(12)
        }
        .confirmationDialog(
            "切换默认提供方？",
            isPresented: Binding(
                get: { pendingProvider != nil },
                set: { if !$0 { pendingProvider = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingProvider
        ) { target in
            Button("设为 \(target.displayName)") {
                model.switchProvider(to: target)
            }
            Button("取消", role: .cancel) {}
        } message: { target in
            Text("这会修改新建 Codex 会话的 config.toml 默认值；所选历史的恢复提供方仍由各按钮明确指定。")
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.clearError() } }
            )
        ) {
            Button("好", role: .cancel) { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(.tint)
            Text("Codex 提供方切换")
                .font(.headline)
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var providerPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            GroupBox("新建 Codex 会话默认设置") {
                if let status = model.status {
                    VStack(alignment: .leading, spacing: 8) {
                        statusRow("提供方", status.mode.displayName)
                        statusRow("模型", status.model ?? "Codex 默认")
                        statusRow("响应存储", status.storageDescription)
                        statusRow("代理", status.proxyConfigured ? "已配置" : "未配置")
                        Divider()
                        HStack {
                            Button("设为官方") {
                                pendingProvider = .official
                            }
                            .disabled(status.mode == .official)
                            Button("设为代理") {
                                pendingProvider = .proxy
                            }
                            .disabled(!status.proxyConfigured || status.mode == .proxy)
                        }
                    }
                    .padding(.vertical, 2)
                } else {
                    ProgressView()
                }
            }

            GroupBox("官方账号") {
                VStack(alignment: .leading, spacing: 8) {
                    statusRow("当前登录", model.activeEmail ?? "未登录 / API Key 模式")
                    statusRow("已保存账号", "\(model.accounts.count) 个")
                    if !model.accounts.isEmpty {
                        Divider()
                        ForEach(model.accounts) { account in
                            accountRow(account)
                        }
                    }
                    Button {
                        model.captureAccount()
                    } label: {
                        Label(
                            model.activeAccountIsStored ? "当前登录已保存" : "保存当前登录到账号库",
                            systemImage: model.activeAccountIsStored ? "checkmark.circle.fill" : "person.badge.plus"
                        )
                    }
                    .disabled(model.activeEmail == nil || model.activeAccountIsStored)
                    Text("新账号：直接在终端执行 codex login 登录另一个邮箱，回到这里点“保存当前登录”。切勿先 codex logout——那会在服务端吊销当前账号的令牌，导致它保存的快照失效。切换只影响之后启动的 Codex；建议切换前关闭正在运行的会话。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }

            if let message = model.message {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("官方历史") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("无论当前默认提供方是什么，选择器都会以 OpenAI 打开。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("命令默认带有危险模式：跳过确认并关闭沙箱。")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                        Button {
                            model.launchPicker()
                        } label: {
                            Label("打开官方历史选择器", systemImage: "terminal")
                        }
                        .buttonStyle(.borderedProminent)

                        Button {
                            model.copyPickerCommand()
                        } label: {
                            Label("复制官方历史命令", systemImage: "doc.on.doc")
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)
            Text("不启动后台服务。账号切换会替换 auth.json，但界面永不显示令牌内容。")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("本地历史")
                    .font(.headline)
                Spacer()
                Text("\(model.sessions.count)")
                    .foregroundStyle(.secondary)
            }
            TextField("筛选标题或会话 ID", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
            List(model.filteredSessions, selection: $model.selectedSessionID) { session in
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .lineLimit(2)
                    Text(session.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "日期不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .tag(session.id)
            }
            .overlay {
                if model.filteredSessions.isEmpty {
                    ContentUnavailableView("没有匹配的历史", systemImage: "clock")
                }
            }
        }
    }

    @ViewBuilder
    private var detailPane: some View {
        if let session = model.selectedSession {
            VStack(alignment: .leading, spacing: 12) {
                Text("已选历史")
                    .font(.headline)
                Text(session.title)
                    .font(.title3)
                    .lineLimit(4)
                Text(session.id)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                if let updatedAt = session.updatedAt {
                    Text(updatedAt.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button("用代理继续") {
                    model.launchSelected(provider: .proxy)
                }
                .buttonStyle(.borderedProminent)
                Button("用官方继续") {
                    model.launchSelected(provider: .official)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        model.copySelectedCommand(provider: .proxy)
                    } label: {
                        Label("复制代理恢复命令", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.copySelectedCommand(provider: .official)
                    } label: {
                        Label("复制官方恢复命令", systemImage: "doc.on.doc")
                    }
                }
                Spacer(minLength: 0)
                Text("这些按钮只指定本次恢复会话所用的提供方，不会修改默认提供方。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("启动和复制的命令均会跳过确认并关闭沙箱。")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        } else {
            ContentUnavailableView(
                "选择一条历史",
                systemImage: "clock.arrow.circlepath",
                description: Text("选择本地 Codex 会话后，可以用官方提供方或代理继续。")
            )
        }
    }

    private func accountRow(_ account: CodexAccount) -> some View {
        let isActive = model.activeEmail?.lowercased() == account.email.lowercased()
        return HStack(spacing: 8) {
            Image(systemName: isActive ? "checkmark.circle.fill" : "person.crop.circle")
                .foregroundStyle(isActive ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email)
                    .font(.caption)
                    .lineLimit(1)
                if let lastUsed = account.lastUsedAt {
                    Text("上次使用 \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.copyOfficialCommandAs(account: account)
            } label: {
                Label(isActive ? "复制官方命令" : "切换并复制官方命令", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .help(isActive ? "该账号已是当前登录，直接复制官方命令" : "切到该账号，并把官方命令复制到剪贴板")
            Button("切换") {
                model.switchAccount(account)
            }
            .disabled(isActive)
            Button {
                model.removeAccount(account)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(isActive ? "使用中的账号不能删除" : "从账号库移除该登录")
        }
    }

    private func statusRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption)
    }
}
