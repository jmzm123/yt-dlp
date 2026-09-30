import AppKit
import SwiftUI

// MARK: - Records

struct DownloadRecord: Codable, Identifiable {
    var id = UUID()
    let path: String
    let title: String
    let width: Int
    let height: Int
    let duration: Double
    let size: Int64
    let hasAudio: Bool
    var date = Date()
    var url: URL { URL(fileURLWithPath: path) }
    var details: String {
        let time = String(format: "%02d:%02d", Int(duration) / 60, Int(duration) % 60)
        let bytes = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        return "\(height)p · \(time) · \(bytes)"
    }
}

// MARK: - Queue

enum QueueState: String {
    case waiting, working, needsAction, done, failed
}

struct QueueItem: Identifiable {
    let id = UUID()
    let url: String
    var state: QueueState = .waiting
    var title = ""
    var note = "排队等待中"
    var fraction: Double? = nil
    var speed = ""
    var browserSpace: Int? = nil
    var record: DownloadRecord? = nil
    var host: String { URL(string: url)?.host ?? url }
    var displayTitle: String { title.isEmpty ? url : title }
}

// MARK: - Link parsing (mirrors worker.py extract_urls)

enum LinkParser {
    private static let pattern = #"https?://[A-Za-z0-9\-._~:/?#@!$&'*+,;=%]+"#
    private static let trailing = CharacterSet(charactersIn: ".,;:!?'\"\\")

    static func extract(_ text: String) -> [String] {
        let cleaned = text
            .replacingOccurrences(of: "\\_", with: "_")
            .replacingOccurrences(of: "\\/", with: "/")
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(cleaned.startIndex..., in: cleaned)
        var urls: [String] = []
        for match in regex.matches(in: cleaned, range: range) {
            guard let matchRange = Range(match.range, in: cleaned) else { continue }
            var url = String(cleaned[matchRange])
            while let last = url.unicodeScalars.last, trailing.contains(last) { url.removeLast() }
            guard let parts = URLComponents(string: url),
                  let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil else { continue }
            if !urls.contains(url) { urls.append(url) }
        }
        return urls
    }

    static func hostSummary(_ urls: [String]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for url in urls {
            let host = URL(string: url)?.host ?? url
            if counts[host] == nil { order.append(host) }
            counts[host, default: 0] += 1
        }
        return order.map { counts[$0]! > 1 ? "\($0) × \(counts[$0]!)" : $0 }.joined(separator: " · ")
    }
}

private func isDouyinURL(_ url: String) -> Bool {
    guard let host = URL(string: url)?.host?.lowercased() else { return false }
    return host == "douyin.com" || host.hasSuffix(".douyin.com")
}

private func isBilibiliURL(_ url: String) -> Bool {
    guard let host = URL(string: url)?.host?.lowercased() else { return false }
    return host == "b23.tv" || host == "bilibili.com" || host.hasSuffix(".bilibili.com")
}

// MARK: - Model

@MainActor
final class DownloadModel: ObservableObject {
    @Published var input = ""
    @Published var quality = "best"
    @Published var chromeCookies = false
    @Published var output: String = UserDefaults.standard.string(forKey: "outputDirectory")
        ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path
    @Published var queue: [QueueItem] = []
    @Published var history: [DownloadRecord] = []
    @Published var logs: [String] = []
    @Published var showLogs = false
    @Published var parseHint: String? = nil
    private var process: Process? = nil
    private var currentID: UUID? = nil
    private var generation = UUID()
    /// Agent-owned ego-browser space kept open after a douyin download, reusable by the next douyin item.
    private var douyinSpace: Int? = nil

    var detected: [String] { LinkParser.extract(input) }
    var isBusy: Bool { process != nil }
    var doneCount: Int { queue.filter { $0.state == .done }.count }
    var failedCount: Int { queue.filter { $0.state == .failed }.count }
    var waitingCount: Int { queue.filter { $0.state == .waiting }.count }
    var needsActionItem: QueueItem? { queue.first { $0.state == .needsAction } }

    init() {
        if let data = UserDefaults.standard.data(forKey: "downloadHistory"),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            history = saved
        }
        if CommandLine.arguments.contains("--ui-test") {
            input = """
            3.87 :9pm A@g.Ok cnD:/ 08/23 跑分越高的手机，就越好用吗？ # 小米 # OPPO # 骁龙 # 联发科 # 跑分  https://v.douyin.com/4OazCjDdu4o/ 复制此链接，打开Dou音搜索，直接观看视频！
            【自学动画 爆肝俩月】 https://www.bilibili.com/video/BV1E6aq6pEKR 哔哩哔哩
            """
        }
    }

    func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            input = text
            parseHint = nil
        }
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "保存到这里"
        panel.directoryURL = URL(fileURLWithPath: output)
        if panel.runModal() == .OK, let url = panel.url {
            output = url.path
            UserDefaults.standard.set(output, forKey: "outputDirectory")
        }
    }

    func start() {
        let urls = detected
        if CommandLine.arguments.contains("--auto-start") { print("DBG: start detected=\(urls.count)"); fflush(stdout) }
        guard !urls.isEmpty else {
            parseHint = "没有识别到链接，请粘贴视频链接或整段分享文案。"
            return
        }
        parseHint = nil
        for url in urls {
            if let index = queue.firstIndex(where: { $0.url == url }) {
                guard queue[index].state != .working && queue[index].state != .waiting else { continue }
                queue[index].state = .waiting
                queue[index].note = "排队等待中"
                queue[index].fraction = nil
                queue[index].speed = ""
                queue[index].record = nil
                queue[index].browserSpace = nil
            } else {
                queue.append(QueueItem(url: url))
            }
        }
        input = ""
        kick()
    }

    /// Starts the next waiting item when nothing is running. A needsAction item pauses the queue.
    func kick() {
        guard process == nil, needsActionItem == nil else { return }
        guard let index = queue.firstIndex(where: { $0.state == .waiting }) else { return }
        run(index)
    }

    private func workerEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        environment["LANG"] = "en_US.UTF-8"
        return environment
    }

    private func run(_ index: Int) {
        guard let resource = Bundle.main.resourceURL else { return }
        let item = queue[index]
        currentID = item.id
        queue[index].state = .working
        queue[index].note = item.browserSpace != nil ? "正在继续下载…" : "正在连接…"
        queue[index].fraction = nil
        queue[index].speed = ""
        let id = UUID()
        generation = id
        // A kept douyin browser space is handed to the next douyin item so the
        // browser tab is reused instead of opening a fresh one per video.
        var space = item.browserSpace
        if space == nil, isDouyinURL(item.url), let held = douyinSpace {
            space = held
            douyinSpace = nil
            if CommandLine.arguments.contains("--auto-start") { print("DBG: reusing douyin space \(held)"); fflush(stdout) }
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = ["python3", resource.appendingPathComponent("worker.py").path,
                         "--url", item.url, "--output", output, "--quality", quality,
                         "--keep-space"]
        if chromeCookies { arguments.append("--chrome-cookies") }
        if let space { arguments += ["--browser-space", String(space)] }
        task.arguments = arguments
        task.environment = workerEnvironment()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.standardInput = FileHandle.nullDevice
        do {
            try task.run()
            process = task
        } catch {
            queue[index].state = .failed
            queue[index].note = "无法启动下载程序：\(error.localizedDescription)"
            kick()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var buffer = Data()
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(data: buffer[..<newline], encoding: .utf8) ?? ""
                    buffer.removeSubrange(...newline)
                    DispatchQueue.main.async { self?.receive(line, itemID: item.id, gen: id) }
                }
            }
            if !buffer.isEmpty {
                let line = String(data: buffer, encoding: .utf8) ?? ""
                DispatchQueue.main.async { self?.receive(line, itemID: item.id, gen: id) }
            }
            task.waitUntilExit()
            let exitCode = task.terminationStatus
            DispatchQueue.main.async {
                guard let self, self.generation == id else { return }
                self.process = nil
                self.currentID = nil
                if let current = self.queue.firstIndex(where: { $0.id == item.id }),
                   self.queue[current].state == .working {
                    self.queue[current].state = .failed
                    self.queue[current].note = "下载程序提前结束（\(exitCode)）。展开详细记录查看原因。"
                    self.queue[current].fraction = nil
                }
                self.kick()
                // Queue drained: nothing is running and nothing is waiting.
                if self.process == nil, !self.queue.contains(where: { $0.state == .waiting }) {
                    self.closeDouyinSpace()
                }
            }
        }
    }

    private func receive(_ line: String, itemID: UUID, gen: UUID) {
        if CommandLine.arguments.contains("--auto-start") { print("DBG:", line); fflush(stdout) }
        guard generation == gen, let index = queue.firstIndex(where: { $0.id == itemID }) else { return }
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = message["event"] as? String else {
            if !line.isEmpty { addLog(line) }
            return
        }
        switch event {
        case "state":
            queue[index].note = message["text"] as? String ?? queue[index].note
            queue[index].speed = ""
        case "title":
            queue[index].title = message["title"] as? String ?? ""
        case "progress":
            queue[index].fraction = (message["fraction"] as? NSNumber)?.doubleValue
            var speedText = ""
            if let bytes = message["speed"] as? Double, bytes > 0 {
                speedText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + "/s"
            }
            if let seconds = message["eta"] as? Double, seconds > 0 {
                speedText += speedText.isEmpty ? "" : " · 约 \(Int(seconds)) 秒"
            }
            queue[index].speed = speedText
            if queue[index].note.contains("读取") || queue[index].note.contains("连接") {
                queue[index].note = "正在下载视频…"
            }
        case "log":
            addLog(message["text"] as? String ?? "")
        case "browserSpace":
            queue[index].browserSpace = message["id"] as? Int
        case "browserHandoff":
            // The user owns the space now; it must never be reused by the queue.
            douyinSpace = nil
        case "spaceKept":
            douyinSpace = message["id"] as? Int
        case "error":
            let text = message["text"] as? String ?? "下载失败"
            queue[index].state = queue[index].browserSpace != nil ? .needsAction : .failed
            queue[index].note = text
            queue[index].fraction = nil
            queue[index].speed = ""
        case "cancelled":
            queue[index].state = .failed
            queue[index].note = "下载已取消"
            queue[index].fraction = nil
            queue[index].speed = ""
        case "complete":
            guard let path = message["path"] as? String else { return }
            let record = DownloadRecord(path: path,
                title: queue[index].title.isEmpty ? (message["title"] as? String ?? "视频") : queue[index].title,
                width: message["width"] as? Int ?? 0,
                height: message["height"] as? Int ?? 0,
                duration: message["duration"] as? Double ?? 0,
                size: (message["size"] as? NSNumber)?.int64Value ?? 0,
                hasAudio: message["hasAudio"] as? Bool ?? false)
            queue[index].record = record
            queue[index].state = .done
            var note = "下载完成 · \(record.details)"
            if isBilibiliURL(queue[index].url), quality == "best" || quality == "1080",
               record.height > 0, record.height < 1080 {
                note += " · 实际 \(record.height)p · 若该视频有更高清晰度，勾选「使用 Chrome 登录状态」可解锁"
            }
            queue[index].note = note
            if CommandLine.arguments.contains("--auto-start") { print("DBG: note=\(note)"); fflush(stdout) }
            queue[index].fraction = 1
            queue[index].speed = ""
            queue[index].browserSpace = nil
            history.removeAll { $0.path == path }
            history.insert(record, at: 0)
            history = Array(history.prefix(30))
            if let saved = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(saved, forKey: "downloadHistory")
            }
        default:
            break
        }
    }

    private func addLog(_ line: String) {
        logs.append(line)
        if logs.count > 150 { logs.removeFirst(logs.count - 150) }
    }

    func cancel(_ item: QueueItem) {
        if item.state == .waiting {
            queue.removeAll { $0.id == item.id }
        } else if item.state == .working, currentID == item.id {
            process?.terminate()
        }
    }

    func cancelAll() {
        queue.removeAll { $0.state == .waiting }
        process?.terminate()
        closeDouyinSpace()
    }

    /// Closes the kept douyin browser space, if any. Fire and forget.
    func closeDouyinSpace() {
        guard let space = douyinSpace else { return }
        douyinSpace = nil
        if CommandLine.arguments.contains("--auto-start") { print("DBG: closing douyin space \(space)"); fflush(stdout) }
        guard let resource = Bundle.main.resourceURL else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", resource.appendingPathComponent("worker.py").path,
                          "--close-space", String(space)]
        task.environment = workerEnvironment()
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
    }

    func resume(_ item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), item.state == .needsAction else { return }
        queue[index].state = .waiting
        queue[index].note = "排队等待中"
        kick()
    }

    func skip(_ item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }), item.state == .needsAction else { return }
        queue[index].state = .failed
        queue[index].note = "已跳过"
        queue[index].browserSpace = nil
        kick()
    }

    func retry(_ item: QueueItem) {
        guard let index = queue.firstIndex(where: { $0.id == item.id }) else { return }
        queue[index].state = .waiting
        queue[index].note = "排队等待中"
        queue[index].fraction = nil
        queue[index].record = nil
        queue[index].browserSpace = nil
        kick()
    }

    func remove(_ item: QueueItem) {
        guard item.state != .working else { return }
        queue.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        queue.removeAll { $0.state == .done || $0.state == .failed }
    }

    func open(_ item: DownloadRecord) {
        guard FileManager.default.fileExists(atPath: item.path) else { return }
        NSWorkspace.shared.open(item.url)
    }

    func reveal(_ item: DownloadRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([item.url])
    }
}

// MARK: - Palette

private let bg = Color(red: 0.047, green: 0.055, blue: 0.078)
private let sidebarBg = Color(red: 0.035, green: 0.042, blue: 0.062)
private let card = Color.white.opacity(0.05)
private let cardBorder = Color.white.opacity(0.09)
private let ink = Color.white.opacity(0.93)
private let quiet = Color.white.opacity(0.48)
private let teal = Color(red: 0.18, green: 0.83, blue: 0.75)
private let sky = Color(red: 0.24, green: 0.72, blue: 0.98)
private let mint = Color(red: 0.33, green: 0.86, blue: 0.56)
private let warn = Color(red: 0.98, green: 0.66, blue: 0.27)
private let danger = Color(red: 0.97, green: 0.44, blue: 0.44)
private let accent = LinearGradient(colors: [teal, sky], startPoint: .leading, endPoint: .trailing)
private let accentTile = LinearGradient(colors: [teal, sky], startPoint: .topLeading, endPoint: .bottomTrailing)

// MARK: - Window

struct DownloadWindow: View {
    @ObservedObject var model: DownloadModel
    @FocusState private var linkFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack {
                bg
                Circle().fill(teal.opacity(0.10)).frame(width: 420).blur(radius: 90)
                    .offset(x: 260, y: -280)
                Circle().fill(sky.opacity(0.08)).frame(width: 380).blur(radius: 90)
                    .offset(x: -180, y: 300)
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        inputCard
                        settings
                        actionArea
                        if !model.queue.isEmpty { queueSection }
                        if !model.logs.isEmpty { logs }
                        HStack(spacing: 5) {
                            Image(systemName: "lock.shield.fill")
                            Text("在这台 Mac 上本地下载，文件保存在你选择的文件夹。")
                        }
                        .font(.system(size: 11)).foregroundColor(quiet)
                        .padding(.top, 2)
                    }
                    .padding(32)
                    .frame(maxWidth: 800, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .foregroundColor(ink)
        .frame(minWidth: 960, minHeight: 700)
        .preferredColorScheme(.dark)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            // Headless smoke test: --auto-start (with --ui-test input) drives the real queue.
            if CommandLine.arguments.contains("--auto-start") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { model.start() }
            }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "arrow.down.to.line.compact")
                    .font(.system(size: 18, weight: .bold)).foregroundColor(bg)
                    .frame(width: 38, height: 38)
                    .background(accentTile, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .shadow(color: teal.opacity(0.35), radius: 10, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text("林序下载器").font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("VIDEO LIBRARY").font(.system(size: 8, weight: .semibold)).tracking(1.2).foregroundColor(quiet)
                }
            }.padding(.bottom, 30)
            Label("视频下载", systemImage: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold)).foregroundColor(teal)
                .padding(.horizontal, 13).padding(.vertical, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(teal.opacity(0.25), lineWidth: 1))
            HStack {
                Text("最近下载").font(.system(size: 11, weight: .medium)).foregroundColor(quiet)
                Spacer()
                Text("\(model.history.count)").font(.system(size: 10, design: .monospaced)).foregroundColor(quiet)
            }.padding(.top, 28).padding(.bottom, 12)
            if model.history.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("还没有下载记录").font(.system(size: 12))
                    Text("完成的视频会出现在这里").font(.system(size: 10)).foregroundColor(quiet)
                }.padding(.horizontal, 5).padding(.top, 4)
            } else {
                ScrollView {
                    VStack(spacing: 7) {
                        ForEach(model.history) { item in
                            Button { model.reveal(item) } label: {
                                HStack(alignment: .top, spacing: 9) {
                                    Image(systemName: "film.fill").foregroundColor(teal).padding(.top, 2)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(2).multilineTextAlignment(.leading)
                                        Text(item.details).font(.system(size: 9, design: .monospaced)).foregroundColor(quiet).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            }.buttonStyle(.plain).help("在 Finder 中显示")
                        }
                    }
                }
            }
            Spacer(minLength: 20)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Circle().fill(mint).frame(width: 5, height: 5)
                    Text("本地运行").font(.system(size: 10, weight: .medium))
                }
                Text("Powered by yt-dlp · v0.2.0")
                    .font(.system(size: 9)).foregroundColor(quiet)
            }
        }
        .padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 22)
        .frame(width: 228)
        .background(sidebarBg)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把喜欢的视频，留在身边。")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text("粘贴链接或整段分享文案，批量下载交给它。")
                    .font(.system(size: 13)).foregroundColor(quiet)
            }
            Spacer()
            if !model.queue.isEmpty {
                HStack(spacing: 8) {
                    statChip("\(model.doneCount)", "完成", mint)
                    if model.failedCount > 0 { statChip("\(model.failedCount)", "失败", danger) }
                    if model.waitingCount > 0 { statChip("\(model.waitingCount)", "排队", sky) }
                }.padding(.bottom, 4)
            }
        }.padding(.top, 4)
    }

    private func statChip(_ value: String, _ label: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value).font(.system(size: 12, weight: .bold, design: .monospaced))
            Text(label).font(.system(size: 11)).foregroundColor(quiet)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(card, in: Capsule())
        .overlay(Capsule().stroke(cardBorder, lineWidth: 1))
    }

    // MARK: Input

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("视频链接", systemImage: "link").font(.system(size: 13, weight: .semibold))
                Spacer()
                if !model.input.isEmpty {
                    Button { model.input = "" } label: {
                        Label("清空", systemImage: "xmark.circle").font(.system(size: 11, weight: .medium))
                    }.buttonStyle(.plain).foregroundColor(quiet)
                }
                Button { model.paste() } label: {
                    Label("粘贴", systemImage: "doc.on.clipboard").font(.system(size: 11, weight: .medium))
                }.buttonStyle(.plain).foregroundColor(teal)
            }
            ZStack(alignment: .topLeading) {
                if model.input.isEmpty {
                    Text("粘贴视频链接，或整段分享文案，可一次粘贴多条…")
                        .font(.system(size: 14)).foregroundColor(quiet.opacity(0.7))
                        .padding(.horizontal, 5).padding(.vertical, 8).allowsHitTesting(false)
                }
                TextEditor(text: $model.input)
                    .font(.system(size: 14)).scrollContentBackground(.hidden)
                    .frame(height: 92).focused($linkFocused)
                    .accessibilityLabel("视频链接输入框")
                    .onChange(of: model.input) { _ in model.parseHint = nil }
            }
            .padding(10)
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(linkFocused ? teal.opacity(0.55) : cardBorder, lineWidth: 1))
            if let hint = model.parseHint {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundColor(warn)
                    Text(hint)
                }.font(.system(size: 11)).foregroundColor(quiet)
            } else if !model.input.isEmpty {
                HStack(spacing: 8) {
                    if model.detected.isEmpty {
                        Image(systemName: "questionmark.circle.fill").foregroundColor(warn)
                        Text("未识别到链接，换一段包含 http 链接的文案试试。")
                            .font(.system(size: 11)).foregroundColor(quiet)
                    } else {
                        Text("已识别 \(model.detected.count) 个链接")
                            .font(.system(size: 11, weight: .bold)).foregroundColor(bg)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(accent, in: Capsule())
                        Text(LinkParser.hostSummary(model.detected))
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(quiet).lineLimit(1)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundColor(teal)
                    Text("抖音、B站及 yt-dlp 支持的网站，自动从分享文案中提取链接。")
                }.font(.system(size: 11)).foregroundColor(quiet)
            }
        }
        .padding(20)
        .background(card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(cardBorder, lineWidth: 1))
    }

    // MARK: Settings

    private var settings: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 20) {
                Label("清晰度", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .medium)).frame(width: 83, alignment: .leading)
                Picker("清晰度", selection: $model.quality) {
                    Text("自动最佳").tag("best")
                    Text("1080p 以内").tag("1080")
                    Text("720p 以内").tag("720")
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 400)
                Spacer(minLength: 0)
            }
            HStack(spacing: 20) {
                Label("保存位置", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium)).frame(width: 83, alignment: .leading)
                Text(model.output.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(size: 12, design: .monospaced)).foregroundColor(quiet).lineLimit(1).truncationMode(.middle).help(model.output)
                Spacer(minLength: 0)
                Button("更改…") { model.chooseOutput() }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(teal)
            }
            Toggle("使用 Chrome 登录状态", isOn: $model.chromeCookies)
                .toggleStyle(.checkbox).font(.system(size: 11)).foregroundColor(quiet)
                .help("当网站要求登录时，允许 yt-dlp 读取 Chrome Cookie。")
        }.padding(.horizontal, 3)
    }

    // MARK: Actions

    private var startLabel: String {
        let count = model.detected.count
        if model.isBusy { return count > 0 ? "加入队列 (\(count))" : "正在下载…" }
        return count > 1 ? "开始下载 \(count) 个视频" : "开始下载"
    }

    private var actionArea: some View {
        HStack(spacing: 14) {
            Button { linkFocused = false; model.start() } label: {
                HStack(spacing: 9) {
                    Image(systemName: model.isBusy ? "text.append" : "arrow.down.to.line")
                    Text(startLabel)
                }
                .font(.system(size: 14, weight: .semibold)).foregroundColor(bg)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(model.detected.isEmpty && !model.isBusy ? AnyShapeStyle(Color.white.opacity(0.12)) : AnyShapeStyle(accent),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: model.detected.isEmpty ? .clear : teal.opacity(0.3), radius: 12, y: 4)
            }
            .buttonStyle(.plain).keyboardShortcut(.return, modifiers: .command)
            .disabled(model.detected.isEmpty)
            if model.isBusy || model.waitingCount > 0 {
                Button("全部取消") { model.cancelAll() }.buttonStyle(.plain)
                    .font(.system(size: 12)).foregroundColor(quiet)
            }
        }
    }

    // MARK: Queue

    private var queueSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("下载队列").font(.system(size: 15, weight: .bold, design: .rounded))
                Text("\(model.queue.count)").font(.system(size: 11, design: .monospaced)).foregroundColor(quiet)
                Spacer()
                if model.doneCount + model.failedCount > 0 {
                    Button("清空已完成") { model.clearFinished() }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundColor(quiet)
                }
            }
            VStack(spacing: 9) {
                ForEach(model.queue) { item in
                    QueueCard(item: item, model: model)
                }
            }
        }
    }

    private var logs: some View {
        DisclosureGroup("详细记录", isExpanded: $model.showLogs) {
            ScrollView {
                Text(model.logs.joined(separator: "\n"))
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(quiet)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(9)
            }.frame(height: 130).background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 8)
        }.font(.system(size: 11)).foregroundColor(quiet)
    }
}

// MARK: - Queue card

struct QueueCard: View {
    let item: QueueItem
    @ObservedObject var model: DownloadModel

    private var statusColor: Color {
        switch item.state {
        case .waiting: return quiet
        case .working: return sky
        case .needsAction: return warn
        case .done: return mint
        case .failed: return danger
        }
    }

    private var statusIcon: String {
        switch item.state {
        case .waiting: return "clock"
        case .working: return "arrow.down.circle.fill"
        case .needsAction: return "person.crop.circle.badge.exclamationmark.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: statusIcon)
                .font(.system(size: 15)).foregroundColor(statusColor)
                .frame(width: 34, height: 34)
                .background(statusColor.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.system(size: 12.5, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(item.host).font(.system(size: 10, design: .monospaced)).foregroundColor(teal.opacity(0.85))
                    Text("·").foregroundColor(quiet)
                    Text(item.state == .working && !item.speed.isEmpty ? item.speed : item.note)
                        .font(.system(size: 11)).foregroundColor(item.state == .failed || item.state == .needsAction ? statusColor.opacity(0.95) : quiet)
                        .lineLimit(2)
                }
                if item.state == .working {
                    ProgressBar(fraction: item.fraction)
                }
                if item.state == .needsAction {
                    HStack(spacing: 12) {
                        Button { model.resume(item) } label: {
                            Label("继续下载", systemImage: "play.fill")
                                .font(.system(size: 11, weight: .bold)).foregroundColor(bg)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(accent, in: Capsule())
                        }.buttonStyle(.plain)
                        Button("跳过") { model.skip(item) }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundColor(quiet)
                    }.padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(14)
        .background(card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .stroke(item.state == .working ? sky.opacity(0.35) : cardBorder, lineWidth: 1))
    }

    @ViewBuilder
    private var trailing: some View {
        switch item.state {
        case .waiting:
            iconButton("xmark", "移除") { model.cancel(item) }
        case .working:
            if let fraction = item.fraction {
                Text("\(Int(fraction * 100))%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundColor(sky)
            }
            iconButton("stop.fill", "取消") { model.cancel(item) }
        case .needsAction:
            EmptyView()
        case .done:
            if let record = item.record {
                HStack(spacing: 6) {
                    iconButton("play.fill", "播放") { model.open(record) }
                    iconButton("folder", "在 Finder 中显示") { model.reveal(record) }
                }
            }
        case .failed:
            HStack(spacing: 6) {
                iconButton("arrow.clockwise", "重试") { model.retry(item) }
                iconButton("xmark", "移除") { model.remove(item) }
            }
        }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .foregroundColor(quiet).frame(width: 28, height: 28)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(.plain).help(help)
    }
}

// MARK: - Progress bar

struct ProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.09))
                if let fraction {
                    Capsule().fill(accent)
                        .frame(width: max(6, geo.size.width * CGFloat(fraction)))
                        .animation(.easeOut(duration: 0.25), value: fraction)
                } else {
                    IndeterminateFill(width: geo.size.width)
                }
            }
        }
        .frame(height: 5)
    }
}

private struct IndeterminateFill: View {
    let width: CGFloat
    @State private var phase = false

    var body: some View {
        Capsule().fill(accent)
            .frame(width: max(30, width * 0.28))
            .offset(x: phase ? width * 0.72 : 0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: DownloadModel?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.isBusy else {
            model?.closeDouyinSpace()
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "视频正在下载"
        alert.informativeText = "退出会取消当前下载。"
        alert.addButton(withTitle: "继续下载")
        alert.addButton(withTitle: "取消下载并退出")
        if alert.runModal() == .alertSecondButtonReturn {
            model.cancelAll()
            // Let the worker terminate its downloader and close its own browser task.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { NSApp.reply(toApplicationShouldTerminate: true) }
            return .terminateLater
        }
        return .terminateCancel
    }
}

@main
struct LinxuDownloader: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = DownloadModel()
    var body: some Scene {
        Window("林序下载器", id: "main") {
            DownloadWindow(model: model).onAppear { delegate.model = model }
        }
        .defaultSize(width: 1000, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .pasteboard) {
                Button("粘贴视频链接") { model.paste() }.keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }
    }
}
