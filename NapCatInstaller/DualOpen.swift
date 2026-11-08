import AppKit
import CoreGraphics
import Darwin

let qqAppBundleURL = URL(fileURLWithPath: "/Applications/QQ.app")
let qqExecutablePath = qqAppBundleURL.appendingPathComponent("Contents/MacOS/QQ").path
let napcatFlag = "--no-sandbox"

enum QQRole: Equatable {
    case napcat
    case original
}

enum QQWindowState: Equatable {
    case visible
    case hidden
    case none
}

struct QQInstance: Identifiable, Equatable {
    let pid: pid_t
    let role: QQRole
    let startTime: UInt64
    var windowState: QQWindowState = .none
    var id: pid_t { pid }
}

private func allPIDs() -> [pid_t] {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: Int(count) + 64)
    let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
}

private func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
}

private func startTime(of pid: pid_t) -> UInt64? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
}

func processArguments(of pid: pid_t) -> [String]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
    let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
    var index = MemoryLayout<Int32>.size
    while index < size && buffer[index] != 0 { index += 1 }
    while index < size && buffer[index] == 0 { index += 1 }
    var args: [String] = []
    while args.count < argc && index < size {
        let start = index
        while index < size && buffer[index] != 0 { index += 1 }
        args.append(String(decoding: buffer[start..<index], as: UTF8.self))
        index += 1
    }
    return args
}

private func inspect(pid: pid_t) -> QQInstance? {
    guard executablePath(of: pid) == qqExecutablePath,
        let started = startTime(of: pid),
        let args = processArguments(of: pid)
    else { return nil }
    return QQInstance(pid: pid, role: args.dropFirst().contains(napcatFlag) ? .napcat : .original, startTime: started)
}

private func windowStates() -> [pid_t: QQWindowState] {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [:] }
    var states: [pid_t: QQWindowState] = [:]
    for window in list {
        guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
            (window[kCGWindowLayer as String] as? Int) == 0,
            let bounds = window[kCGWindowBounds as String] as? [String: Any],
            let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
            width >= 200, height >= 200
        else { continue }
        if (window[kCGWindowIsOnscreen as String] as? Bool) == true {
            states[pid] = .visible
        } else if states[pid] == nil {
            states[pid] = .hidden
        }
    }
    return states
}

func listQQInstances() -> [QQInstance] {
    let instances = allPIDs().compactMap(inspect(pid:))
    guard !instances.isEmpty else { return [] }
    let windows = windowStates()
    return instances.map { instance in
        var instance = instance
        instance.windowState = windows[instance.pid] ?? .none
        return instance
    }.sorted { $0.startTime < $1.startTime }
}

func isSameProcess(_ instance: QQInstance) -> Bool {
    guard let current = inspect(pid: instance.pid) else { return false }
    return current.startTime == instance.startTime && current.role == instance.role
}

struct OriginalLauncher: Equatable {
    let appDir: URL
    let electronVersion: String
    let hotUpdateVersion: String?
}

enum LauncherCheckError: LocalizedError, Equatable {
    case frameworkUnreadable(String)
    case incomplete(String)
    var errorDescription: String? {
        switch self {
        case .frameworkUnreadable(let path):
            return "无法读取 QQNT.framework 版本：\(path)"
        case .incomplete(let path):
            return "QQ 启动器不完整（缺少 app_launcher/index.js 或 major.node）：\(path)"
        }
    }
}

private func frameworkURL(appDir: URL) -> URL {
    appDir.appendingPathComponent("../../Frameworks/QQNT.framework").standardizedFileURL
}

func frameworkVersion(appDir: URL) -> String? {
    let plistURL = frameworkURL(appDir: appDir).appendingPathComponent("Resources/Info.plist")
    guard let plist = NSDictionary(contentsOf: plistURL) else { return nil }
    return plist["CFBundleVersion"] as? String
}

func resolveOriginalLauncher(
    baseAppDir: URL = appURL, versionsDir: URL = versionsURL
) -> Result<OriginalLauncher, LauncherCheckError> {
    var appDir = baseAppDir
    var hotVersion: String?
    if let data = try? Data(contentsOf: versionsDir.appendingPathComponent("config.json")),
        let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let current = config["curVersion"] as? String, !current.isEmpty
    {
        let hotAppDir = versionsDir.appendingPathComponent(current)
            .appendingPathComponent("QQUpdate.app/Contents/Resources/app")
        if FileManager.default.fileExists(atPath: frameworkURL(appDir: hotAppDir).appendingPathComponent("QQNT").path) {
            appDir = hotAppDir
            hotVersion = current
        }
    }
    guard let electron = frameworkVersion(appDir: appDir) else {
        return .failure(.frameworkUnreadable(appDir.path))
    }
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: appDir.appendingPathComponent("app_launcher/index.js").path),
        fileManager.fileExists(atPath: appDir.appendingPathComponent("major.node").path)
    else {
        return .failure(.incomplete(appDir.path))
    }
    return .success(OriginalLauncher(appDir: appDir, electronVersion: electron, hotUpdateVersion: hotVersion))
}

func launchNapcatInTerminal() throws {
    let escapedPath = qqExecutablePath.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
    tell application "Terminal"
        activate
        do script "'\(escapedPath)' \(napcatFlag)"
    end tell
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script]
    try process.run()
}

func launchOriginalQQ() throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-n", qqAppBundleURL.path]
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw NSError(domain: "DualOpen", code: Int(process.terminationStatus),
                      userInfo: [NSLocalizedDescriptionKey: "open -n 返回 \(process.terminationStatus)"])
    }
}

func activate(_ instance: QQInstance) {
    guard isSameProcess(instance), let app = NSRunningApplication(processIdentifier: instance.pid) else { return }
    app.unhide()
    app.activate(options: [.activateAllWindows])
    guard instance.windowState != .visible else { return }
    let target = NSAppleEventDescriptor(processIdentifier: instance.pid)
    let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                       eventID: AEEventID(kAEReopenApplication),
                                       targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                       transactionID: AETransactionID(kAnyTransactionID))
    if let desc = event.aeDesc {
        AESendMessage(desc, nil, AESendMode(kAENoReply), kAEDefaultTimeout)
    }
}

enum StopResult: Equatable {
    case stopped
    case identityChanged
    case stillRunning
}

func stop(_ instance: QQInstance, timeout: TimeInterval = 10) -> StopResult {
    guard isSameProcess(instance) else { return .identityChanged }
    func waitForExit(_ seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !isSameProcess(instance) { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return !isSameProcess(instance)
    }
    if let app = NSRunningApplication(processIdentifier: instance.pid), app.terminate(), waitForExit(timeout) {
        return .stopped
    }
    guard isSameProcess(instance) else { return .stopped }
    kill(instance.pid, SIGTERM)
    return waitForExit(5) ? .stopped : .stillRunning
}

struct QQController {
    var qqInstalled: () -> Bool = { FileManager.default.isExecutableFile(atPath: qqExecutablePath) }
    var instances: () -> [QQInstance] = listQQInstances
    var loaderStatus: () -> LoaderStatus = getLoaderStatus
    var launcher: () -> Result<OriginalLauncher, LauncherCheckError> = { resolveOriginalLauncher() }
    var syncHotUpdates: () throws -> Int = patchHotUpdatePackages
    var updateLoader: () throws -> URL? = { try installLoader() }
    var startNapcat: () throws -> Void = launchNapcatInTerminal
    var startOriginal: () throws -> Void = launchOriginalQQ
    var activateInstance: (QQInstance) -> Void = { activate($0) }
    var stopInstance: (QQInstance) -> StopResult = { stop($0) }
    var copyToPasteboard: (String) -> Void = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
    static let live = QQController()
}
