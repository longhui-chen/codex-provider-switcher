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
        .defaultSize(width: 1040, height: 680)
        .windowResizability(.contentMinSize)
        .commands {
            CommandMenu("操作") {
                Button("刷新") {
                    NotificationCenter.default.post(name: .refreshNow, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)

                Button("筛选历史") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)

                Divider()

                Button("打开官方历史选择器") {
                    NotificationCenter.default.post(name: .openPicker, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

private extension Notification.Name {
    static let refreshNow = Notification.Name("CodexProviderSwitcher.refreshNow")
    static let focusSearch = Notification.Name("CodexProviderSwitcher.focusSearch")
    static let openPicker = Notification.Name("CodexProviderSwitcher.openPicker")
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

    private let service: CodexProviderService

    init() {
        // Mirrors the codex CLI convention; also lets demo/sandbox runs point
        // the app at an isolated directory instead of the real ~/.codex.
        if let home = ProcessInfo.processInfo.environment["CODEX_HOME"], !home.isEmpty {
            service = CodexProviderService(codexHome: URL(fileURLWithPath: home))
        } else {
            service = CodexProviderService()
        }
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
            // One pass over config.toml and session_index.jsonl.
            let snapshot = try service.overview()
            status = snapshot.status
            sessions = snapshot.sessions
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

// MARK: - Design tokens

private enum Style {
    static let cardRadius: CGFloat = 12
    static let chipRadius: CGFloat = 8
    static let cardPadding: CGFloat = 14

    static var cardBackground: Color { Color(nsColor: .controlBackgroundColor) }
    static var hairline: Color { Color.primary.opacity(0.08) }

    /// Instructional copy: darker than `.secondary` so it clears 4.5:1 on the
    /// card background. `.tertiary` is reserved for decorative timestamps.
    static var hintForeground: Color { Color.primary.opacity(0.72) }

    /// Warning text that must stay readable in both appearances; system
    /// `.orange` measures ~2.2:1 on white.
    static var warningText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark
                ? NSColor(red: 1.0, green: 0.67, blue: 0.25, alpha: 1)
                : NSColor(red: 0.62, green: 0.35, blue: 0.0, alpha: 1)
        })
    }

    static var avatarPalette: [Color] { [.blue, .purple, .pink, .teal, .indigo, .orange] }

    static func avatarColor(for email: String) -> Color {
        let hash = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return avatarPalette[hash % avatarPalette.count]
    }
}

/// A rounded, elevated container used instead of plain GroupBox.
private struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .fill(Style.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .strokeBorder(Style.hairline)
            )
    }

    private var cardInset: EdgeInsets {
        EdgeInsets(top: Style.cardPadding, leading: Style.cardPadding, bottom: Style.cardPadding, trailing: Style.cardPadding)
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    var badge: String?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .imageScale(.small)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.semibold))
            if let badge {
                Text(badge)
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(.tint)
                    .accessibilityLabel("\(badge) 个条目")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ModeBadge: View {
    let mode: ProviderMode

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(mode.displayName)
                .font(.callout.weight(.semibold))
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.13)))
        // Label-colored text: colored glyphs at this size miss 4.5:1 on tinted
        // backgrounds; the dot carries the hue instead.
        .foregroundStyle(Color.primary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("当前模式：\(mode.displayName)")
    }

    private var color: Color {
        switch mode {
        case .official: .green
        case .proxy: .indigo
        case .custom: .orange
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String
    var valueMonospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(Style.hintForeground)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}

private struct SuccessPill: View {
    let text: String

    var body: some View {
        Label {
            Text(text)
                .foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Style.chipRadius + 2, style: .continuous).fill(Color.green.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: Style.chipRadius + 2, style: .continuous)
                .strokeBorder(Color.green.opacity(0.28))
        )
        .accessibilityElement(children: .combine)
    }
}

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption.weight(.medium))
                .foregroundStyle(Style.hintForeground)
                .accessibilityHidden(true)
            TextField("筛选标题或会话 ID", text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Style.hintForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除筛选")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Style.chipRadius, style: .continuous)
                .fill(Style.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Style.chipRadius, style: .continuous)
                .strokeBorder(Style.hairline)
        )
    }
}

// MARK: - Content

private struct ContentView: View {
    @StateObject private var model = ProviderViewModel()
    @State private var pendingProvider: ProviderMode?
    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// State changes crossfade in ~200ms; nil under Reduce Motion.
    private var contentAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.2)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            // Plain HStack, not HSplitView: NSSplitView ignores SwiftUI
            // min/ideal/max pane frames when the window resizes, which let
            // the side panes explode and corrupted content layout. HStack
            // keeps side panes clamped and gives extra width to the list.
            HStack(spacing: 0) {
                providerPane
                    .frame(minWidth: 272, idealWidth: 312, maxWidth: 360)
                Divider()
                historyPane
                    .frame(minWidth: 340, idealWidth: 430)
                Divider()
                detailPane
                    .frame(minWidth: 284, idealWidth: 330, maxWidth: 440)
            }
            .padding(.top, 10)
            .padding(.bottom, 12)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onReceive(NotificationCenter.default.publisher(for: .refreshNow)) { _ in
            model.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPicker)) { _ in
            model.launchPicker()
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
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 28, height: 28)
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.body.weight(.bold))
                    .imageScale(.small)
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("Codex 提供方切换")
                    .font(.headline)
                Text("本地提供方与官方账号管理")
                    .font(.caption2)
                    .foregroundStyle(Style.hintForeground)
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("重新读取 config.toml 与会话索引（⌘R）")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Left pane

    private var providerPane: some View {
        ScrollView {
            VStack(spacing: 12) {
                defaultProviderCard
                accountsCard
                if let message = model.message {
                    SuccessPill(text: message)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }
                historyPickerCard
                Text("不启动后台服务。账号切换会替换 auth.json，但界面永不显示令牌内容。")
                    .font(.caption2)
                    .foregroundStyle(Style.hintForeground)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 12)
        }
        // Keep animation modifiers OUTSIDE the ScrollView; applying them to
        // its content is fragile when the pane resizes.
        .animation(contentAnimation, value: model.message)
    }

    private var defaultProviderCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "新建会话默认", systemImage: "sparkles.rectangle.stack")

                if let status = model.status {
                    ModeBadge(mode: status.mode)

                    VStack(spacing: 7) {
                        InfoRow(label: "提供方", value: status.activeProvider)
                        InfoRow(label: "模型", value: status.model ?? "Codex 默认")
                        InfoRow(label: "响应存储", value: status.storageDescription)
                        InfoRow(label: "代理", value: status.proxyConfigured ? "已配置" : "未配置")
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Button {
                            pendingProvider = .official
                        } label: {
                            Label("设为官方", systemImage: "checkmark.seal")
                                .frame(maxWidth: .infinity)
                        }
                        .tint(.green)
                        .buttonStyle(.bordered)
                        .disabled(status.mode == .official)

                        Button {
                            pendingProvider = .proxy
                        } label: {
                            Label("设为代理", systemImage: "arrow.triangle.branch")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!status.proxyConfigured || status.mode == .proxy)
                    }
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        }
    }

    private var accountsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(
                    title: "官方账号",
                    systemImage: "person.2",
                    badge: model.accounts.isEmpty ? nil : "\(model.accounts.count)"
                )

                InfoRow(label: "当前登录", value: model.activeEmail ?? "未登录 / API Key 模式")

                if !model.accounts.isEmpty {
                    Divider()
                    VStack(spacing: 6) {
                        ForEach(model.accounts) { account in
                            accountRow(account)
                        }
                    }
                }

                Button {
                    model.captureAccount()
                } label: {
                    Label(
                        model.activeAccountIsStored ? "当前登录已保存" : "保存当前登录到账号库",
                        systemImage: model.activeAccountIsStored ? "checkmark.circle.fill" : "person.badge.plus"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.activeEmail == nil || model.activeAccountIsStored)

                Text("新账号：直接在终端执行 codex login 登录另一个邮箱，回到这里点“保存当前登录”。切勿先 codex logout——那会在服务端吊销当前账号的令牌，导致它保存的快照失效。切换只影响之后启动的 Codex；建议切换前关闭正在运行的会话。")
                    .font(.caption2)
                    .foregroundStyle(Style.hintForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var historyPickerCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "官方历史", systemImage: "clock.arrow.circlepath")

                Button {
                    model.launchPicker()
                } label: {
                    Label("打开官方历史选择器", systemImage: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.copyPickerCommand()
                } label: {
                    Label("复制官方历史命令", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Text("无论当前默认提供方是什么，选择器都会以 OpenAI 打开。")
                    .font(.caption2)
                    .foregroundStyle(Style.hintForeground)
                Label("命令默认带有危险模式：跳过确认并关闭沙箱。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(Style.warningText)
            }
        }
    }

    private func accountRow(_ account: CodexAccount) -> some View {
        let isActive = model.activeEmail?.lowercased() == account.email.lowercased()
        let tint = Style.avatarColor(for: account.email)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(0.16))
                    Text(String(account.email.prefix(1)).uppercased())
                        .font(.callout.weight(.bold))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)
                .overlay(
                    Circle()
                        .stroke(isActive ? Color.green : .clear, lineWidth: 2)
                        .padding(-3)
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(account.email)
                            .font(.callout.weight(isActive ? .semibold : .regular))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if isActive {
                            Text("当前")
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.15)))
                                .foregroundStyle(Color.primary)
                        }
                    }
                    if let lastUsed = account.lastUsedAt {
                        Text("上次使用 \(lastUsed.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityElement(children: .combine)

                Spacer(minLength: 4)

                if !isActive {
                    Button {
                        model.removeAccount(account)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.red)
                    .accessibilityLabel("从账号库移除 \(account.email)")
                    .help("从账号库移除该登录")
                }
            }

            HStack(spacing: 8) {
                Button {
                    model.copyOfficialCommandAs(account: account)
                } label: {
                    Label(isActive ? "复制官方命令" : "切换并复制官方命令", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help(isActive ? "该账号已是当前登录，直接复制官方命令" : "切到该账号，并把官方命令复制到剪贴板")

                if !isActive {
                    Button("只切换") {
                        model.switchAccount(account)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("切换登录，但不复制任何命令")
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: Style.chipRadius, style: .continuous)
                .fill(isActive ? Color.green.opacity(0.06) : Color.primary.opacity(0.03))
        )
    }

    // MARK: Middle pane

    private var historyPane: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: "clock")
                    .font(.subheadline.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("本地历史")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.sessions.count)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(Style.hintForeground)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
                    .accessibilityLabel("共 \(model.sessions.count) 条历史")
            }

            SearchField(text: $model.searchText)
                .focused($searchFocused)

            List(model.filteredSessions, selection: $model.selectedSessionID) { session in
                sessionRow(session)
                    .tag(session.id)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .overlay {
                if model.filteredSessions.isEmpty {
                    ContentUnavailableView("没有匹配的历史", systemImage: "clock")
                }
            }
        }
    }

    private func sessionRow(_ session: CodexSession) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
            Text(session.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "日期不可用")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    // MARK: Right pane

    private var detailPane: some View {
        Group {
            if let session = model.selectedSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "已选历史", systemImage: "clock.arrow.circlepath")

                        Text(session.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Style.hintForeground)
                                .accessibilityHidden(true)
                            Text(session.id)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: Style.chipRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.04))
                        )

                        if let updatedAt = session.updatedAt {
                            Label(
                                updatedAt.formatted(date: .long, time: .shortened),
                                systemImage: "calendar"
                            )
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                        }

                        Divider()

                        VStack(spacing: 8) {
                            Button {
                                model.launchSelected(provider: .proxy)
                            } label: {
                                Label("用代理继续", systemImage: "arrow.triangle.branch")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)

                            Button {
                                model.launchSelected(provider: .official)
                            } label: {
                                Label("用官方继续", systemImage: "checkmark.seal")
                                    .frame(maxWidth: .infinity)
                            }
                            .tint(.green)
                            .buttonStyle(.bordered)

                            Button {
                                model.copySelectedCommand(provider: .proxy)
                            } label: {
                                Label("复制代理恢复命令", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button {
                                model.copySelectedCommand(provider: .official)
                            } label: {
                                Label("复制官方恢复命令", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }

                        Text("这些按钮只指定本次恢复会话所用的提供方，不会修改默认提供方。启动和复制的命令均会跳过确认并关闭沙箱。")
                            .font(.caption2)
                            .foregroundStyle(Style.hintForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(4)
                }
                .transition(.opacity)
            } else {
                ContentUnavailableView(
                    "选择一条历史",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("选择本地 Codex 会话后，可以用官方提供方或代理继续。")
                )
                .transition(.opacity)
            }
        }
        .animation(contentAnimation, value: model.selectedSessionID)
    }
}
