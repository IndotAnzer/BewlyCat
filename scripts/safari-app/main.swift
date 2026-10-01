import AppKit
import SafariServices

final class BewlyCatApp: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    let status = NSTextField(wrappingLabelWithString: "")
    var button: NSButton!
    var automatic: NSButton!
    var updater: Process?
    var timer: Timer?
    let defaults = UserDefaults.standard
    let diagnostics = CommandLine.arguments.contains("--diagnose-updates")

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["automaticStableUpdates": true])
        let menu = NSMenu()
        let appMenu = NSMenu()
        let root = NSMenuItem()
        root.submenu = appMenu
        menu.addItem(root)
        appMenu.addItem(withTitle: "检查更新…", action: #selector(checkManually), keyEquivalent: "u").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BewlyCat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 510, height: 270),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "BewlyCat"
        window.center()
        let title = NSTextField(labelWithString: "BewlyCat Safari")
        title.font = .boldSystemFont(ofSize: 24)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
        let detail = NSTextField(labelWithString: "正式版 \(version) · App 内置自动更新")
        detail.textColor = .secondaryLabelColor
        status.stringValue = "扩展请在 Safari 设置中启用。更新时不会退出 Safari。"
        button = NSButton(title: "检查更新", target: self, action: #selector(checkManually))
        button.bezelStyle = .rounded
        let safari = NSButton(title: "打开 Safari 扩展设置", target: self, action: #selector(showSafari))
        safari.bezelStyle = .rounded
        automatic = NSButton(checkboxWithTitle: "App 运行时自动检查正式版本", target: self, action: #selector(toggleAutomatic))
        automatic.state = defaults.bool(forKey: "automaticStableUpdates") ? .on : .off
        let buttons = NSStackView(views: [button, safari])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, detail, status, automatic, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 26),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -26),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 26)
        ])
        if !diagnostics {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 4 * 3600, repeats: true) { [weak self] _ in
            self?.checkAutomatically()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if self.diagnostics { self.checkManually() } else { self.checkAutomatically() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if updater != nil {
            status.stringValue = "更新正在进行，请完成后再退出。"
            window.makeKeyAndOrderFront(nil)
            return .terminateCancel
        }
        return .terminateNow
    }
    @objc func toggleAutomatic() { defaults.set(automatic.state == .on, forKey: "automaticStableUpdates") }
    @objc func showSafari() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: "com.keleus.BewlyCat.Extension") { error in
            if let error = error { DispatchQueue.main.async { self.status.stringValue = error.localizedDescription } }
        }
    }
    func checkAutomatically() {
        guard defaults.bool(forKey: "automaticStableUpdates") else { return }
        let last = defaults.double(forKey: "lastStableCheck")
        guard Date().timeIntervalSince1970 - last >= 4 * 3600 else { return }
        check(manual: false)
    }
    @objc func checkManually() { check(manual: true) }

    // Same official stable-release endpoint used by BewlyCat's About.vue.
    func check(manual: Bool) {
        guard updater == nil, button.isEnabled else { return }
        button.isEnabled = false
        status.stringValue = "正在检查正式版本…"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/keleus/BewlyCat/releases/latest")!)
        request.setValue("BewlyCat-Safari-Updater", forHTTPHeaderField: "User-Agent")
        URLSession(configuration: configuration).dataTask(with: request) { data, response, error in
            do {
                if let error = error { throw error }
                guard (response as? HTTPURLResponse)?.statusCode == 200, let data = data,
                      let release = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      release["prerelease"] as? Bool == false, release["draft"] as? Bool == false,
                      let tag = release["tag_name"] as? String,
                      tag.range(of: "^v[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil else {
                    throw NSError(domain: "BewlyCat", code: 1, userInfo: [NSLocalizedDescriptionKey: "正式版本信息不可用"])
                }
                DispatchQueue.main.async {
                    self.defaults.set(Date().timeIntervalSince1970, forKey: "lastStableCheck")
                    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                    let latest = String(tag.dropFirst())
                    if self.diagnostics {
                        print("Official stable release: \(latest); installed app: \(current); updater resource: \(Bundle.main.url(forResource: "update-stable", withExtension: "sh") != nil)")
                        NSApp.terminate(nil)
                        return
                    }
                    if latest.compare(current, options: .numeric) == .orderedDescending {
                        self.install(latest)
                    } else {
                        self.status.stringValue = "已是最新正式版 \(current) · \(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)) 检查"
                        self.button.isEnabled = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.status.stringValue = "检查失败：\(error.localizedDescription)。稍后会重试。"
                    self.button.isEnabled = true
                    if self.diagnostics { fputs("Update check failed: \(error.localizedDescription)\n", stderr); exit(1) }
                }
            }
        }.resume()
    }

    func install(_ version: String) {
        guard let script = Bundle.main.url(forResource: "update-stable", withExtension: "sh") else {
            status.stringValue = "更新组件缺失。"
            button.isEnabled = true
            return
        }
        status.stringValue = "发现正式版 \(version)，正在下载、校验并安装…"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["BEWLYCAT_APP_PATH"] = Bundle.main.bundlePath
        environment["BEWLYCAT_ENTITLEMENTS"] = Bundle.main.url(forResource: "extension", withExtension: "entitlements")?.path
        process.environment = environment
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BewlyCat")
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let log = logDirectory.appendingPathComponent("update.log")
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: log)
            handle.seekToEndOfFile()
            process.standardOutput = handle
            process.standardError = handle
            process.terminationHandler = { [weak self] completed in
                try? handle.close()
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.updater = nil
                    self.button.isEnabled = true
                    let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
                    let installed = info?["CFBundleShortVersionString"] as? String
                    if completed.terminationStatus == 0 && installed == version {
                        NSApp.terminate(nil) // The installer has launched the updated app.
                    } else {
                        self.status.stringValue = "更新尚未完成（云端可能仍在构建），请稍后重试。旧版本已保留。"
                        self.defaults.removeObject(forKey: "lastStableCheck")
                    }
                }
            }
            updater = process
            try process.run()
        } catch {
            updater = nil
            button.isEnabled = true
            status.stringValue = "更新失败：\(error.localizedDescription)"
        }
    }
}

let app = NSApplication.shared
let delegate = BewlyCatApp()
app.setActivationPolicy(.regular)
app.delegate = delegate
app.run()
