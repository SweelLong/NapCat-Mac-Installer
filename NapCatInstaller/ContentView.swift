import AppKit
import Combine
import SwiftUI

struct ContentView: View {
    @AppStorage("GitHubProxyURL") private var proxyAddress = "auto"
    @AppStorage("CustomGitHubProxyURL") private var customProxyAddress = ""
    @State private var qqVersion = QQVersion.loading
    @State private var patchStatus = PatchStatus.loading
    @State private var napcatVersion = NapcatVersion.loading
    @State private var buttonClicked = false
    @State private var showLogs = false
    @State private var showPaths = false
    @State private var accessErrorMessage = ""
    @State private var showAccessError = false
    @StateObject private var installationProgress = InstallationProgress()
    
    private var proxy: GitHubProxy? {
        if proxyAddress == "auto" { return nil }
        if proxyAddress == "custom" { return GitHubProxy(name: "自定义加速", baseURL: customProxyAddress) }
        return GitHubProxy(name: proxyAddress.isEmpty ? "GitHub 原生 / 系统代理" : proxyAddress,
                           baseURL: proxyAddress.isEmpty ? nil : proxyAddress)
    }

    private var showPatch: Bool {
        return napcatVersion.installed || patchStatus.patched
    }

    private var showUsage: Bool {
        return patchStatus.patched
    }

    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            HStack {
                VStack(alignment: .trailing, spacing: 5) {
                    Text("QQ版本")
                    Text("NapCat版本")
                    Text("程序入口")
                }
                VStack(alignment: .leading, spacing: 5) {
                    QQVersionView(version: qqVersion)
                    NapcatVersionView(version: napcatVersion)
                    PatchStatusView(status: patchStatus)
                }
                .foregroundColor(.secondary)
            }
            Divider()
            HStack(spacing: 15) {
                Button {
                    buttonClicked.toggle()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise.circle")
                }
                if case .unauthorized = napcatVersion {
                    Button {
                        requestDataAccess()
                    } label: {
                        Label("授权访问", systemImage: "lock.open")
                    }
                    .help("允许安装器访问 QQ 数据目录，以读取和安装 NapCat")
                }
                NapcatInstallationButton(version: napcatVersion, status: patchStatus, proxy: proxy, showLogs: $showLogs, progress: installationProgress) {
                    buttonClicked.toggle()
                }
                Picker("下载线路", selection: $proxyAddress) {
                    Text("自动检测").tag("auto")
                    ForEach(GitHubProxy.allProxies) { proxyItem in
                        Text(proxyItem.name)
                            .tag(proxyItem.baseURL ?? "")
                    }
                    Text("自定义加速地址").tag("custom")
                }
                .frame(maxWidth: 150)
            }
            if proxyAddress == "custom" {
                TextField("HTTP(S) 加速前缀，例如 https://mirror.example", text: $customProxyAddress)
                    .textFieldStyle(.roundedBorder)
                Text("网络代理和私有 CA 使用 macOS 的系统代理与证书信任设置。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if showLogs {
                NapcatLogView(progress: installationProgress)
            }
            if showPatch {
                NapcatPatchView(status: patchStatus, refreshHandler: updatePatchStatus)
            }
            if showUsage {
                NapcatUsageView()
            }
            HStack(spacing: 20) {
                if patchStatus.patched, let url = try? getWebUILink() {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("打开WebUI", systemImage: "network")
                    }
                }
                Button {
                    showPaths = true
                } label: {
                    Label("文件位置", systemImage: "folder")
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .animation(.default, value: qqVersion)
        .animation(.default, value: patchStatus)
        .animation(.default, value: napcatVersion)
        .task(id: buttonClicked) {
            updateAll()
        }
        .sheet(isPresented: $showPaths) {
            NapcatPathsView()
        }
        .alert("无法授权", isPresented: $showAccessError) {
            Button("好") {}
        } message: {
            Text(accessErrorMessage)
        }
    }
    
    private func updateQQVersion() {
        do {
            guard let version = try getQQVersion() else {
                qqVersion = .missing
                return
            }
            qqVersion = .installed(version)
        } catch {
            qqVersion = .failed(error.localizedDescription)
        }
    }

    private func updateNapcatVersion() async {
        do {
            guard let local = try getLocalNapcat() else {
                napcatVersion = .missing
                return
            }
            do {
                let remote = try await getRemoteNapcat(proxy: proxy)
                if local.compare(remote, options: .numeric) == .orderedAscending {
                    napcatVersion = .outdated(local, remote)
                } else {
                    napcatVersion = .latest(remote)
                }
            } catch {
                napcatVersion = .installed(local)
            }
        } catch {
            if isPermissionDenied(error) {
                napcatVersion = .unauthorized(error.localizedDescription)
            } else {
                napcatVersion = .failed(error.localizedDescription)
            }
        }
    }

    private func requestDataAccess() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = containerURL
        panel.message = "已定位到 QQ 数据目录。点击“授权”即可允许安装器访问 NapCat 所需的文件。\n\(docURL.path)"
        panel.prompt = "授权"
        panel.begin { response in
            guard response == .OK else { return }
            guard let url = panel.url else {
                accessErrorMessage = "没有选中文件夹。请先在面板中选中 Documents 文件夹，再点击“授权”。"
                showAccessError = true
                return
            }
            let selected = url.standardizedFileURL.resolvingSymlinksInPath()
            let expected = docURL.standardizedFileURL.resolvingSymlinksInPath()
            // 允许选择 Documents 本身或其上级目录（例如 QQ 的 Data 目录），上级目录同样覆盖 NapCat 所需路径
            guard selected.path == expected.path || expected.path.hasPrefix(selected.path + "/") else {
                accessErrorMessage = "请选择 \(expected.path)\n当前选择：\(selected.path)"
                showAccessError = true
                return
            }
            updateAll()
        }
    }

    private func updateAll() {
        updateQQVersion()
        updatePatchStatus()
        Task { await updateNapcatVersion() }
    }

    private func updatePatchStatus() {
        do {
            guard let loader = try getAppLoader() else {
                patchStatus = .custom("")
                return
            }
            switch loader {
            case let l where PatchStatus.originalLoaders.contains(l):
                patchStatus = .original
            case let l where l.hasSuffix("/loadNapCat.js"):
                patchStatus = .napcat
            default:
                patchStatus = .custom(loader)
            }
        } catch {
            patchStatus = .failed(error.localizedDescription)
        }
    }
}

private struct QQVersionView: View {
    let version: QQVersion
    var body: some View {
        switch version {
        case .loading:
            Text(Image(systemName: "ellipsis.circle")) + Text(" 正在读取…")
        case .missing:
            Text(Image(systemName: "questionmark.circle")).foregroundColor(.yellow) + Text(" 未安装")
        case .installed(let v):
            Text(Image(systemName: "checkmark.circle")).foregroundColor(.green) + Text(" \(v)")
        case .failed(let d):
            (Text(Image(systemName: "xmark.circle")).foregroundColor(.red) + Text(" 发生错误")).help(d)
        }
    }
}

private struct NapcatVersionView: View {
    let version: NapcatVersion
    var body: some View {
        switch version {
        case .loading:
            Text(Image(systemName: "ellipsis.circle")) + Text(" 正在加载…")
        case .missing:
            Text(Image(systemName: "questionmark.circle")).foregroundColor(.yellow) + Text(" 未安装")
        case .installed(let v):
            Text(Image(systemName: "checkmark.circle")).foregroundColor(.green) + Text(" \(v)，已安装")
        case .outdated(let l, let r):
            Text(Image(systemName: "arrow.up.circle")).foregroundColor(.blue) + Text(" \(l)，可升级\(r)")
        case .latest(let v):
            Text(Image(systemName: "checkmark.circle")).foregroundColor(.green) + Text(" \(v)，已是最新")
        case .unauthorized(let d):
            (Text(Image(systemName: "lock.circle")).foregroundColor(.yellow) + Text(" 需要授权访问 QQ 数据目录")).help(d)
        case .failed(let d):
            (Text(Image(systemName: "xmark.circle")).foregroundColor(.red) + Text(" 发生错误")).help(d)
        }
    }
}

private struct PatchStatusView: View {
    let status: PatchStatus
    var body: some View {
        switch status {
        case .loading:
            Text(Image(systemName: "ellipsis.circle")) + Text(" 正在读取…")
        case .original:
            Text(Image(systemName: "ellipsis.circle")).foregroundColor(.blue) + Text(" 原版QQ")
        case .napcat:
            Text(Image(systemName: "checkmark.circle")).foregroundColor(.green) + Text(" NapCat")
        case .custom(let loader):
            Text(Image(systemName: "questionmark.circle")).foregroundColor(.yellow) + Text(" 自定义 \(loader)")
        case .failed(let d):
            (Text(Image(systemName: "xmark.circle")).foregroundColor(.red) + Text(" 发生错误")).help(d)
        }
    }
}

private struct NapcatInstallationButton: View {
    let version: NapcatVersion
    let status: PatchStatus
    let proxy: GitHubProxy?
    @Binding var showLogs: Bool
    @ObservedObject var progress: InstallationProgress
    let refreshHandler: () -> Void
    @State private var loading = false
    @State private var failed = false
    @State private var showSuccessAlert = false
    @State private var installMessage = "操作完成"
    @State private var error: Error?
    var body: some View {
        Group {
            switch version {
            case .loading, .unauthorized, .failed:
                Button {
                    fatalError("Should not be reachable")
                } label: {
                    Label("安装", systemImage: "shippingbox.circle")
                }
                .disabled(true)
            case .missing, .outdated:
                if !loading {
                    Button {
                        Task { @MainActor in
                            loading = true
                            showLogs = true
                            progress.reset()
                            progress.isInstalling = true
                            do {
                                try await installNapcat(proxy: proxy, progress: progress)
                                switch version {
                                case .missing:
                                    installMessage = "NapCat 安装成功"
                                case .outdated:
                                    installMessage = "NapCat 已更新至最新版本"
                                default:
                                    installMessage = "操作完成"
                                }
                                showSuccessAlert = true
                            } catch {
                                failed = true
                                self.error = error
                            }
                            progress.isInstalling = false
                            loading = false
                            showLogs = false
                            progress.reset()
                        }
                    } label: {
                        switch version {
                        case .missing:
                            Label("安装", systemImage: "shippingbox.circle")
                        case .outdated:
                            Label("更新", systemImage: "arrow.up.circle")
                        default:
                            fatalError("Should not be reachable")
                        }
                    }
                }
            case .installed, .latest:
                Button {
                    do {
                        try removeNapcat()
                    } catch {
                        failed = true
                        self.error = error
                    }
                    refreshHandler()
                } label: {
                    Label("卸载", systemImage: "trash.circle")
                }
                .disabled(status.patched)
                .help("请先还原再卸载")
            }
        }
        .alert("发生错误", isPresented: $failed, presenting: error) { _ in
            Button("好") {
                failed = false
                refreshHandler()
            }
        } message: { e in
            Text(e.localizedDescription)
        }
        .alert("安装结果", isPresented: $showSuccessAlert) {
            Button("好") {
                refreshHandler()
            }
        } message: {
            Text(installMessage)
        }
    }
}

private struct NapcatLogView: View {
    @ObservedObject var progress: InstallationProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView(value: progress.progress) {
                    Text("进度: \(progress.progress.formatted(.percent))")
                }
                .progressViewStyle(.linear)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(progress.logs) { log in
                            HStack(alignment: .top, spacing: 8) {
                                Text(log.timestamp, style: .time)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 60, alignment: .leading)
                                Text(log.message)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .id(log.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: progress.logs.count) { _ in
                    guard let last = progress.logs.last else { return }
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .font(.system(.callout, design: .monospaced))
            .padding(.horizontal)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.selection)
            .cornerRadius(5)
        }
    }
}

private struct NapcatPatchView: View {
    let status: PatchStatus
    let refreshHandler: () -> Void
    @State private var failed = false
    @State private var error: Error?

    var body: some View {
        switch status {
        case .loading, .failed:
            EmptyView()
        case .original, .custom:
            patchButton(title: "切换程序入口「 NapCat 」", action: setQQPackageBak)
        case .napcat:
            patchButton(title: "切换程序入口「 原版 QQ 」", action: { _ = getQQPackageBak() })
        }
    }

    @ViewBuilder
    private func patchButton(title: LocalizedStringKey, action: @escaping () throws -> Void) -> some View {
        VStack(alignment: .center) {
            Button(title) {
                do {
                    try action()
                } catch {
                    failed = true
                    self.error = error
                }
                refreshHandler()
            }
        }
        .alert("发生错误", isPresented: $failed, presenting: error) { _ in
            Button("好") { failed = false }
        } message: { e in
            Text(e.localizedDescription)
        }
    }
}

struct NapcatUsageView: View {
    var controller = QQController.live
    @State private var instances: [QQInstance] = []
    @State private var loaderStatus = LoaderStatus.current
    @State private var launcher: Result<OriginalLauncher, LauncherCheckError>?
    @State private var message: String? = nil
    @State private var messageIsError = false
    @State private var showNapcatConfirm = false
    @State private var stopCandidate: QQInstance?
    @State private var originalLaunchDeadline: Date?
    @State private var stopping = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var napcatInstances: [QQInstance] { instances.filter { $0.role == .napcat } }
    private var originalInstances: [QQInstance] { instances.filter { $0.role == .original } }
    private var originalLaunching: Bool {
        originalInstances.isEmpty && (originalLaunchDeadline.map { $0 > Date() } ?? false)
    }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            HStack(alignment: .top, spacing: 30) {
                VStack(spacing: 6) {
                    instanceStatus(title: "NapCat", instances: napcatInstances)
                    HStack {
                        Button("🐱 启动 NapCat") {
                            prepareNapcatLaunch()
                        }
                        .disabled(!napcatInstances.isEmpty)
                        stopButtons(for: napcatInstances)
                    }
                }
                VStack(spacing: 6) {
                    instanceStatus(title: "原版 QQ", instances: originalInstances)
                    HStack {
                        Button(originalInstances.isEmpty ? "🐧 启动 原版QQ" : "🐧 显示 原版QQ") {
                            startOriginal()
                        }
                        .disabled(originalLaunching)
                        stopButtons(for: originalInstances)
                    }
                }
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(messageIsError ? .red : .secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: refresh)
        .onReceive(timer) { _ in refresh() }
        .alert("确认启动", isPresented: $showNapcatConfirm) {
            Button("使用终端打开") {
                startNapcat()
            }
            Button("复制") {
                guard syncHotUpdateEntries() else { return }
                copyCommand()
            }
            Button("取消", role: .cancel) {
            }
        } message: {
            Text(napcatCommand)
        }
        .alert("确认停止", isPresented: Binding(get: { stopCandidate != nil }, set: { if !$0 { stopCandidate = nil } }),
               presenting: stopCandidate) { instance in
            Button("停止", role: .destructive) {
                confirmStop(instance)
            }
            Button("取消", role: .cancel) {
            }
        } message: { instance in
            Text(instance.role == .napcat
                 ? "将正常退出 NapCat（PID \(String(instance.pid))），机器人会离线。原版 QQ 不受影响。"
                 : "将正常退出原版 QQ（PID \(String(instance.pid))）。NapCat 不受影响。")
        }
    }

    @ViewBuilder
    private func instanceStatus(title: String, instances: [QQInstance]) -> some View {
        if instances.isEmpty {
            Text(Image(systemName: "circle")).foregroundColor(.secondary) + Text(" \(title)：未运行")
        } else {
            let detail = instances.map { instance -> String in
                guard instance.role == .original else { return "PID \(instance.pid)" }
                switch instance.windowState {
                case .visible: return "PID \(instance.pid)"
                case .hidden: return "PID \(instance.pid)，窗口不在当前桌面"
                case .none: return "PID \(instance.pid)，无窗口"
                }
            }.joined(separator: "；")
            Text(Image(systemName: "checkmark.circle.fill")).foregroundColor(.green) + Text(" \(title)：运行中（\(detail)）")
        }
    }

    @ViewBuilder
    private func stopButtons(for instances: [QQInstance]) -> some View {
        ForEach(instances) { instance in
            // PID 以字符串插入，避免 LocalizedStringKey 按地区格式化成 58,901
            Button(instances.count > 1 ? "停止 \(String(instance.pid))" : "停止") {
                stopCandidate = instance
            }
            .disabled(stopping)
        }
    }

    private var napcatCommand: String {
        "'\(qqExecutablePath)' \(napcatFlag)"
    }

    private func show(_ text: String, error: Bool = false) {
        message = text
        messageIsError = error
    }

    private func refresh() {
        instances = controller.instances()
        // 原版 QQ 已被检测到，说明启动成功，解除启动冷却，避免关闭 QQ 后按钮仍处于禁用状态
        if instances.contains(where: { $0.role == .original }) {
            originalLaunchDeadline = nil
        }
        loaderStatus = controller.loaderStatus()
        launcher = controller.launcher()
    }

    private func checkExecutable() -> Bool {
        guard controller.qqInstalled() else {
            show("未找到 QQ.app 或 QQ 可执行文件不可执行，请确认已安装 QQ", error: true)
            return false
        }
        return true
    }

    private func prepareNapcatLaunch() {
        refresh()
        guard checkExecutable() else { return }
        if let running = napcatInstances.first {
            show("NapCat 已在运行（PID \(running.pid)），不重复启动")
            return
        }
        message = nil
        showNapcatConfirm = true
    }

    private func syncHotUpdateEntries() -> Bool {
        do {
            let patched = try controller.syncHotUpdates()
            if patched > 0 {
                show("已同步 \(patched) 个 QQ 热更新包入口")
            }
            return true
        } catch {
            show("同步 QQ 热更新包入口失败：\(error.localizedDescription)", error: true)
            return false
        }
    }

    private func copyCommand() {
        controller.copyToPasteboard(napcatCommand)
    }

    private func startNapcat() {
        refresh()
        if let running = napcatInstances.first {
            show("NapCat 已在运行（PID \(running.pid)），不重复启动")
            return
        }
        guard ensureLoader(), syncHotUpdateEntries() else { return }
        do {
            try controller.startNapcat()
        } catch {
            show("启动失败: \(error.localizedDescription)", error: true)
        }
    }

    /// 加载器缺失或为旧版时自动生成默认的 loadNapCat.js；自定义内容保持不动。
    private func ensureLoader() -> Bool {
        guard loaderStatus == .missing || loaderStatus == .outdated else { return true }
        do {
            _ = try controller.updateLoader()
            refresh()
            if loaderStatus == .missing || loaderStatus == .outdated {
                show("未写入 loadNapCat.js：需要管理员权限", error: true)
                return false
            }
            return true
        } catch {
            show("无法生成 loadNapCat.js：\(error.localizedDescription)", error: true)
            return false
        }
    }

    private func startOriginal() {
        refresh()
        guard checkExecutable() else { return }
        // 已有原版实例时激活它，而不是继续创建新实例
        if let existing = originalInstances.first(where: { $0.windowState == .visible })
            ?? originalInstances.first(where: { $0.windowState == .hidden })
            ?? originalInstances.first
        {
            controller.activateInstance(existing)
            guard existing.windowState == .none else {
                show("已激活原版 QQ（PID \(existing.pid)）")
                return
            }
            show("正在唤起原版 QQ（PID \(existing.pid)）的窗口…")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                refresh()
                if let current = originalInstances.first(where: { $0.pid == existing.pid }),
                    current.windowState == .none
                {
                    show("原版 QQ（PID \(existing.pid)）没有任何窗口，可能未正常启动。可点击「停止」结束该实例后重新启动。",
                         error: true)
                }
            }
            return
        }
        guard ensureLoader() else { return }
        if case .failure(let error) = launcher {
            show("无法启动原版 QQ：\(error.localizedDescription)。请重新打开一次原版 QQ 让其完成更新，或重新安装 QQ。", error: true)
            return
        }
        do {
            try controller.startOriginal()
            originalLaunchDeadline = Date().addingTimeInterval(20)
            show("已启动新的原版 QQ 实例，请使用与 NapCat 不同的 QQ 账号登录")
        } catch {
            show("启动失败: \(error.localizedDescription)", error: true)
        }
    }

    private func confirmStop(_ instance: QQInstance) {
        stopping = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = controller.stopInstance(instance)
            DispatchQueue.main.async {
                stopping = false
                refresh()
                switch result {
                case .stopped:
                    show("已停止 PID \(instance.pid)")
                case .identityChanged:
                    show("PID \(instance.pid) 已不是原来的进程，未执行任何操作", error: true)
                case .stillRunning:
                    show("PID \(instance.pid) 未响应退出请求，仍在运行。为避免数据损坏未强制结束，请在该程序中手动退出。", error: true)
                }
            }
        }
    }
}

private struct NapcatPathsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("文件位置")
                    .font(.headline)
                Spacer()
                Button("完成") {
                    dismiss()
                }
            }
            PathRow(title: "QQ 入口配置", path: "/Applications/QQ.app/Contents/Resources/app/package.json", isDirectory: false)
            PathRow(title: "QQ 热更新包", path: "\(NSHomeDirectory())/Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ/versions", isDirectory: true)
            PathRow(title: "NapCat 加载器", path: "/Applications/QQ.app/Contents/Resources/app/loadNapCat.js", isDirectory: false)
            PathRow(title: "NapCat 安装位置", path: "\(NSHomeDirectory())/Library/Containers/com.tencent.qq/Data/Documents/napcat", isDirectory: true)
            PathRow(title: "NapCat 数据存储", path: "\(NSHomeDirectory())/Library/Containers/com.tencent.qq/Data/Library/Application Support/QQ/NapCat", isDirectory: true)
            PathRow(title: "NapCat 配置目录", path: "\(NSHomeDirectory())/Library/Containers/com.tencent.qq/Data/.config/QQ/NapCat", isDirectory: true)
        }
        .padding()
        .frame(width: 560)
    }
}

private struct PathRow: View {
    let title: String
    let path: String
    let isDirectory: Bool

    @State private var missing = false

    var body: some View {
        HStack(spacing: 8) {
            Button {
                guard FileManager.default.fileExists(atPath: path) else {
                    missing = true
                    return
                }
                let url = URL(fileURLWithPath: path)
                if isDirectory {
                    NSWorkspace.shared.open(url)
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } label: {
                Label("打开 \(title)", systemImage: "folder")
                    .font(.caption)
            }
            Text(path)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .alert("提示", isPresented: $missing) {
            Button("好") { missing = false }
        } message: {
            Text("未找到该路径：\n\(path)")
        }
    }
}

#Preview {
    ContentView()
}
