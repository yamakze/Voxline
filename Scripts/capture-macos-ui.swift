#!/usr/bin/env swift
import AppKit
import ApplicationServices
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

// Actual Voxline windows, driven through Accessibility and captured by ScreenCaptureKit.
// Run from the repository root: swift Scripts/capture-macos-ui.swift --task "Task title"
struct CaptureOptions {
    var app = "dist/macos/Voxline.app"
    var output = "tmp/ui-captures/" + ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    var task: String?
    var mode = "all"
    init() throws {
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--app", "--output", "--task":
                guard let value = args.next() else { throw CaptureFailure("Missing value for \(arg)") }
                if arg == "--app" { app = value }
                else if arg == "--output" { output = value }
                else { task = value }
            case "--current", "--permissions", "--request-permissions", "--dump": mode = String(arg.dropFirst(2))
            case "--help", "-h": mode = "help"
            default: throw CaptureFailure("Unknown option: \(arg)")
            }
        }
    }
}
struct CaptureFailure: Error, CustomStringConvertible {
    let description: String
    let unavailable: Bool
    init(_ description: String, unavailable: Bool = false) { self.description = description; self.unavailable = unavailable }
}
struct PageCapture: Codable {
    let page: String
    let status: String
    let file: String?
    let reason: String?
}

@MainActor final class MacPageCapture {
    let options: CaptureOptions
    let application: NSRunningApplication
    let ax: AXUIElement
    let output: URL
    var records: [PageCapture] = []
    var translations: [String: String] = [:]

    init(_ options: CaptureOptions) throws {
        self.options = options
        let appURL = URL(fileURLWithPath: options.app).standardizedFileURL
        guard let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier,
              let application = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0.bundleURL?.resolvingSymlinksInPath() == appURL.resolvingSymlinksInPath() }) else {
            throw CaptureFailure("Launch \(appURL.path) first (make run).")
        }
        self.application = application
        self.ax = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        output = URL(fileURLWithPath: options.output).standardizedFileURL
        let strings = appURL.appendingPathComponent("Contents/Resources/Voxline_VoxlineApp.bundle/en.lproj/Localizable.strings")
        let data = try Data(contentsOf: strings)
        translations = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] ?? [:]
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
    func text(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
    func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    func nodes(_ root: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var pending = [(root, 0)]
        while let (element, depth) = pending.popLast() {
            result.append(element)
            if depth < 20 { pending.append(contentsOf: children(element).reversed().map { ($0, depth + 1) }) }
        }
        return result
    }
    func focusedWindow() throws -> AXUIElement {
        guard let value = attribute(ax, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw CaptureFailure("No focused Voxline window. Unlock the Mac and keep Voxline visible.")
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    func normalized(_ value: String) -> String { value.replacingOccurrences(of: "…", with: "...") }
    func matches(_ element: AXUIElement, _ key: String) -> Bool {
        let names = [key, translations[key] ?? key].map(normalized)
        let values = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, kAXValueAttribute, kAXPlaceholderValueAttribute]
            .map { normalized(text(element, $0)) }
        return values.contains { value in names.contains { value == $0 || value.hasPrefix($0 + "、") } }
    }
    func find(_ key: String, role: String? = nil, in root: AXUIElement? = nil) -> AXUIElement? {
        guard let scope = root ?? (try? focusedWindow()) else { return nil }
        return nodes(scope).first { element in
            guard role == nil || text(element, kAXRoleAttribute) == role else { return false }
            if matches(element, key) { return true }
            return role == kAXRowRole && nodes(element).dropFirst().contains { matches($0, key) }
        }
    }
    func wait(_ key: String, role: String? = nil, seconds: Double = 5) async throws -> AXUIElement {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if let element = find(key, role: role) { return element }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        throw CaptureFailure("Control unavailable: \(key)", unavailable: true)
    }
    func bounds(_ element: AXUIElement) throws -> CGRect {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else {
            throw CaptureFailure("Cannot read window/control bounds")
        }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &dimensions) else {
            throw CaptureFailure("Invalid Accessibility geometry")
        }
        return CGRect(origin: point, size: dimensions)
    }
    func press(_ element: AXUIElement) throws {
        if let enabled = attribute(element, kAXEnabledAttribute) as? Bool, !enabled { throw CaptureFailure("Control disabled", unavailable: true) }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result == .success { return }
        // SwiftUI sidebar rows can expose selection without AXPress. Click their native bounds.
        guard result == .actionUnsupported || result == .notImplemented else {
            throw CaptureFailure("AXPress failed: \(result.rawValue)")
        }
        let rect = try bounds(element)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: CGPoint(x: rect.midX, y: rect.midY), mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: CGPoint(x: rect.midX, y: rect.midY), mouseButton: .left) else {
            throw CaptureFailure("Cannot create native mouse event")
        }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    func click(_ key: String, role: String? = nil) async throws { try press(await wait(key, role: role)) }
    func key(_ code: CGKeyCode, command: Bool = false) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw CaptureFailure("Cannot create native keyboard event")
        }
        if command { down.flags = .maskCommand; up.flags = .maskCommand }
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
    }
    func dismiss(done: Bool = false) async throws {
        let window = try focusedWindow()
        let sheet = nodes(window).first { text($0, kAXRoleAttribute) == kAXSheetRole } ?? window
        for name in done ? ["完成"] : ["取消", "取消导入"] {
            if let button = find(name, role: kAXButtonRole, in: sheet) {
                try press(button)
                try await Task.sleep(for: .milliseconds(300))
                return
            }
        }
        throw CaptureFailure("Cannot dismiss current sheet safely; close it manually.")
    }
    func menu(_ key: String) async throws {
        try await click(key, role: kAXMenuItemRole)
        try await Task.sleep(for: .milliseconds(300))
    }
    func capture(_ page: String) async throws {
        try await Task.sleep(for: .milliseconds(600))
        // Sheet animations temporarily clear AX focus. Wait for the actual foreground window.
        let deadline = Date().addingTimeInterval(8)
        var target: (AXUIElement, CGWindowID)?
        repeat {
            if let focused = try? focusedWindow(), let frame = try? bounds(focused),
               let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                for info in windows where (info[kCGWindowOwnerPID as String] as? Int32) == application.processIdentifier {
                    guard let values = info[kCGWindowBounds as String] as? [String: Any],
                          let rect = CGRect(dictionaryRepresentation: values as CFDictionary),
                          abs(rect.minX - frame.minX) < 2, abs(rect.minY - frame.minY) < 2,
                          abs(rect.width - frame.width) < 2, abs(rect.height - frame.height) < 2,
                          let id = info[kCGWindowNumber as String] as? CGWindowID else { continue }
                    target = (focused, id)
                    break
                }
            }
            if target == nil { try await Task.sleep(for: .milliseconds(150)) }
        } while target == nil && Date() < deadline
        guard let (focused, _) = target else { throw CaptureFailure("Focused Voxline window did not become capturable within 8 seconds") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw CaptureFailure("Voxline lost foreground focus; stop capture to avoid including another application")
        }
        guard #available(macOS 15.2, *) else { throw CaptureFailure("Native window-region capture requires macOS 15.2 or later") }
        // A sheet's desktopIndependentWindow filter can capture its parent on macOS 15.
        // Capture its actual visible screen rectangle instead, including native window corners.
        let image = try await SCScreenshotManager.captureImage(in: bounds(focused))
        let file = page + ".png"
        let url = output.appendingPathComponent(file)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CaptureFailure("Cannot create PNG: \(url.path)")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CaptureFailure("Cannot write PNG: \(url.path)") }
        records.append(.init(page: page, status: "captured", file: file, reason: nil))
        print("captured \(page)")
    }
    func sheet(_ page: String, done: Bool = false, opening: () async throws -> Void) async throws {
        try await opening()
        do { try await capture(page) }
        catch { try await dismiss(done: done); throw error }
        try await dismiss(done: done)
    }
    func optional(_ page: String, action: () async throws -> Void) async throws {
        do { try await action() }
        catch let error as CaptureFailure where error.unavailable {
            if let window = try? focusedWindow(), let menu = nodes(window).first(where: { text($0, kAXRoleAttribute) == kAXMenuRole }) {
                let result = AXUIElementPerformAction(menu, kAXCancelAction as CFString)
                guard result == .success else { throw CaptureFailure("Cannot close menu: \(result.rawValue)") }
            }
            records.append(.init(page: page, status: "unavailable", file: nil, reason: error.description))
            print("unavailable \(page): \(error)")
        } catch {
            records.append(.init(page: page, status: "failed", file: nil, reason: String(describing: error)))
            throw error
        }
    }
    func index() throws {
        records.sort { $0.page < $1.page }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(records).write(to: output.appendingPathComponent("manifest.json"), options: .atomic)
        let rows = records.map { record in
            if let file = record.file { return "<section><h2>\(record.page)</h2><a href=\"\(file)\"><img loading=\"lazy\" src=\"\(file)\"></a></section>" }
            let reason = (record.reason ?? "").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            return "<section><h2>\(record.page)</h2><p>Unavailable: \(reason)</p></section>"
        }.joined(separator: "\n")
        let html = "<!doctype html><meta charset=utf-8><title>Voxline Mac UI</title><style>body{font:16px system-ui;background:#eee;margin:32px}section{margin-bottom:32px}img{max-width:100%;height:auto;box-shadow:0 2px 16px #888}h2{font-size:18px}</style><h1>Voxline Mac UI</h1>" + rows
        try html.write(to: output.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
    }
    func run() async throws {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        application.activate()
        try await Task.sleep(for: .milliseconds(350))
        if options.mode == "dump" {
            for element in nodes(try focusedWindow()) {
                let role = text(element, kAXRoleAttribute)
                if text(element, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { continue }
                print(role, text(element, kAXTitleAttribute), text(element, kAXDescriptionAttribute), text(element, kAXHelpAttribute))
            }
            return
        }
        if options.mode == "current" {
            try await capture("current-window")
            try index()
            return
        }
        // Work in a fresh native tab, leaving an existing editing session untouched.
        try key(45, command: true) // Cmd+N
        _ = try await wait("全部任务", role: kAXRowRole)
        let captureWindowID = text(try focusedWindow(), kAXIdentifierAttribute)
        try await capture("01-task-library")
        if find("编辑", role: kAXButtonRole) != nil {
            try await click("编辑", role: kAXButtonRole)
            try await capture("02-task-library-edit")
            try await click("完成", role: kAXButtonRole)
        }
        try key(17, command: true) // Cmd+T
        _ = try await wait("任务名称")
        try await capture("03-new-task")
        try await optional("04-model-management-sheet") {
            try await sheet("04-model-management-sheet", done: true) { try await click("管理模型", role: kAXButtonRole) }
        }
        try await dismiss()
        try await optional("task-pages") { try await taskPages() }
        try await click("翻译服务", role: kAXRowRole)
        try await capture("20-translation-services")
        try await optional("21-add-translation-service") {
            try await sheet("21-add-translation-service") {
                let name = find("添加服务", role: kAXButtonRole) != nil ? "添加服务" : "添加翻译服务"
                try await click(name, role: kAXButtonRole)
            }
        }
        try await click("云端转写", role: kAXRowRole)
        try await capture("22-transcription-services")
        try await optional("23-add-transcription-service") {
            try await sheet("23-add-transcription-service") {
                let name = find("添加服务", role: kAXButtonRole) != nil ? "添加服务" : "添加转写服务"
                try await click(name, role: kAXButtonRole)
            }
        }
        try key(43, command: true) // Cmd+,
        _ = try await wait("模型管理", role: kAXRadioButtonRole)
        for (name, page) in [("模型管理", "24-settings-models"), ("iCloud 同步", "25-settings-sync"), ("更新", "26-settings-updates")] {
            try await click(name, role: kAXRadioButtonRole)
            try await capture(page)
        }
        try key(13, command: true) // Cmd+W: settings window only
        try await click("全部任务", role: kAXRowRole)
        guard text(try focusedWindow(), kAXIdentifierAttribute) == captureWindowID else {
            throw CaptureFailure("Capture tab changed; leave it open for manual inspection")
        }
        try key(13, command: true)
        try index()
        print("Captured \(records.filter { $0.status == "captured" }.count) pages; unavailable \(records.filter { $0.status == "unavailable" }.count)")
        print("Gallery: \(output.appendingPathComponent("index.html").path)")
    }
    func taskPages() async throws {
        let title: String
        if let requested = options.task { title = requested }
        else {
            let exclusions = ["新建任务", "打开文件…", "编辑", "完成", "下载", "全部任务", "翻译服务", "云端转写"]
            guard let entry = nodes(try focusedWindow()).first(where: { element in
                text(element, kAXRoleAttribute) == kAXButtonRole && !(text(element, kAXTitleAttribute) + text(element, kAXDescriptionAttribute)).isEmpty &&
                !exclusions.contains(where: { matches(element, $0) })
            }) else { throw CaptureFailure("No task found. Supply --task with an existing video task title.", unavailable: true) }
            title = text(entry, kAXTitleAttribute).isEmpty ? text(entry, kAXDescriptionAttribute) : text(entry, kAXTitleAttribute)
        }
        try await click(title)
        _ = try await wait("校对", seconds: 4)
        try await capture("05-task-detail")
        try await optional("06-task-parameters") {
            try await sheet("06-task-parameters") { try await click("调整参数", role: kAXButtonRole) }
        }
        try await click("校对", role: kAXButtonRole)
        _ = try await wait("在字幕中搜索…")
        try await capture("07-proofreading")
        try await optional("08-insert-subtitle") {
            try await sheet("08-insert-subtitle") { try await click("添加字幕…", role: kAXButtonRole) }
        }
        for (item, page) in [("导出字幕文件…", "09-export-subtitles"), ("内封软字幕…", "10-embed-subtitles"), ("烧录硬字幕…", "11-burn-subtitles")] {
            try await optional(page) {
                try await sheet(page) {
                    try await click("导出字幕或包含字幕的媒体文件")
                    try await menu(item)
                }
            }
        }
        for (item, page) in [("整体时间偏移…", "12-time-offset"), ("重新关联媒体…", "13-relink-media"), ("替换原文字幕…", "14-import-source"), ("导入译文字幕…", "15-import-translation")] {
            try await optional(page) {
                try await sheet(page) {
                    try await click("校对与媒体工具")
                    try await menu(item)
                }
            }
        }
        for (item, page) in [("调整时间…", "17-adjust-subtitle-time"), ("拆分字幕…", "18-split-subtitle"), ("与下一句合并…", "19-merge-subtitles")] {
            try await optional(page) {
                try await sheet(page) {
                    try await click("更多操作", role: kAXPopUpButtonRole)
                    try await menu(item)
                }
            }
        }
        try await optional("16-edit-subtitle") {
            try await click("更多操作", role: kAXPopUpButtonRole)
            try await menu("编辑")
            _ = try await wait("原文内容")
            try await capture("16-edit-subtitle")
            try await click("取消", role: kAXButtonRole)
        }
        // Open editors without changing a field; never save, export, process, download or confirm deletion.
    }
}

Task { @MainActor in
    do {
        let options = try CaptureOptions()
        if options.mode == "help" {
            print("""
            Usage: swift Scripts/capture-macos-ui.swift [options]
              --app PATH        Running Voxline app (default dist/macos/Voxline.app)
              --output PATH     PNG gallery and manifest (default tmp/ui-captures/<time>)
              --task TITLE      Existing task with a playable video and subtitles
              --current         Capture only the focused Voxline window
              --dump            Print visible Accessibility control names (no secure fields)
              --permissions     Check Screen Recording and Accessibility access
              --request-permissions  Ask macOS for required access, then rerun
            Default: traverse Mac pages in a new tab; cancel sheets and close the capture tab when finished.
            """)
            exit(0)
        }
        if options.mode == "request-permissions" {
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(prompt)
            _ = CGRequestScreenCaptureAccess()
        }
        let accessibility = AXIsProcessTrusted(), recording = CGPreflightScreenCaptureAccess()
        if options.mode == "permissions" || options.mode == "request-permissions" {
            print("Accessibility: \(accessibility ? "granted" : "required")\nScreen Recording: \(recording ? "granted" : "required")")
            exit(accessibility && recording ? 0 : 2)
        }
        guard accessibility && recording else {
            throw CaptureFailure("Enable Accessibility and Screen Recording for the terminal/runner in System Settings → Privacy & Security. Run --request-permissions, then rerun this command.")
        }
        let capture = try MacPageCapture(options)
        do { try await capture.run() }
        catch {
            try capture.index()
            throw error
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("capture-macos-ui: \(error)\n".utf8))
        exit(1)
    }
}
RunLoop.main.run()
