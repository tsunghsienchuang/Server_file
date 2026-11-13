import AppKit
import Darwin
import Foundation
import Security

private let filesURL = URL(string: "http://127.0.0.1:8878/")!
private let reportsURL = URL(string: "http://127.0.0.1:8877/")!
private let appName = "Server Files"
private let recentConnectionsKey = "RecentSSHConnections"
private let askpassKey = "CODEX_PREVIEW_ASKPASS_FILE"
private let askpassModeKey = "CODEX_PREVIEW_ASKPASS_MODE"
private let rememberAskpassKey = "CODEX_PREVIEW_REMEMBER_PASSWORD"
private let askpassDirectoryPrefix = "codex-preview-auth-"

private struct SSHConnection: Codable, Equatable {
    let username: String
    let host: String
    let port: Int
    let directory: String

    var target: String { "\(username)@\(host)" }
    var label: String {
        let address = host.contains(":") ? "[\(host)]" : host
        return "\(username)@\(address)" + (port == 22 ? "" : ":\(port)")
    }
    var recentLabel: String { directory.isEmpty ? label : "\(label) — \(directory)" }
    var credentialID: String { "\(username)@\(host)|\(port)" }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.credentialID == rhs.credentialID && lhs.hasDirectory(rhs.directory)
    }

    func hasDirectory(_ value: String) -> Bool {
        // SSH sends UTF-8, and Unix treats canonically equivalent names as distinct byte paths.
        directory.utf8.elementsEqual(value.utf8)
    }

    static func parse(address rawAddress: String, username rawUsername: String, port rawPort: String,
                      directory: String) -> SSHConnection? {
        var address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        var username = rawUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        var port = rawPort.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = address.firstIndex(of: "@") {
            username = String(address[..<at])
            address = String(address[address.index(after: at)...])
        }
        if address.hasPrefix("[") {
            guard let bracket = address.firstIndex(of: "]") else { return nil }
            let remainder = address[address.index(after: bracket)...]
            if !remainder.isEmpty {
                guard remainder.hasPrefix(":") else { return nil }
                port = String(remainder.dropFirst())
            }
            address = String(address[address.index(after: address.startIndex)..<bracket])
        } else if address.filter({ $0 == ":" }).count == 1, let colon = address.firstIndex(of: ":") {
            port = String(address[address.index(after: colon)...])
            address = String(address[..<colon])
        }
        guard username.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$", options: .regularExpression) != nil,
              port.utf8.allSatisfy({ (48...57).contains($0) }),
              let number = Int(port), (1...65535).contains(number),
              let host = normalizedAddress(address) else { return nil }
        return SSHConnection(username: username, host: host, port: number, directory: directory)
    }

    private static func normalizedAddress(_ address: String) -> String? {
        if address.contains(":") {
            let parts = address.split(separator: "%", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            var binaryAddress = in6_addr()
            guard inet_pton(AF_INET6, String(parts[0]), &binaryAddress) == 1 else { return nil }
            if parts.count == 2 {
                guard parts[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
                return parts[0].lowercased() + "%" + parts[1]
            }
            return address.lowercased()
        }
        guard address.utf8.count <= 254 else { return nil }
        let name = address.hasSuffix(".") ? address.dropLast() : address[...]
        guard !name.isEmpty, name.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({
            $0.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,62}$", options: .regularExpression) != nil
        }) else { return nil }
        return address.lowercased()
    }
}

private struct RecentConnection: Codable {
    let connection: SSHConnection
    let remembersPassword: Bool
}

private enum PasswordStore {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "org.serverfiles.mac") + ".SSHPassword" }

    static func query(_ connection: SSHConnection) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connection.credentialID,
        ]
    }

    static func read(_ connection: SSHConnection) -> String? {
        var attributes = query(connection)
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(attributes as CFDictionary, &item) == errSecSuccess,
              let bytes = item as? Data else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    static func alreadySaved(_ submitted: String, as savedPassword: String?) -> Bool {
        guard let savedPassword else { return false }
        return submitted.utf8.elementsEqual(savedPassword.utf8)
    }

    static func save(_ password: String, for connection: SSHConnection) -> Bool {
        let identity = query(connection)
        let value = Data(password.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = identity
        item[kSecValueData as String] = value
        item[kSecAttrLabel as String] = appName + " — " + connection.label
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ connection: SSHConnection) -> Bool {
        let status = SecItemDelete(query(connection) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

private struct HealthResponse: Decodable {
    let service: String
    let session: String
    let scope: String
    let target: String
    let port: Int
    let identity: String
    let requestedDirectory: String

    private enum CodingKeys: String, CodingKey {
        case service, session, scope, target, port, identity
        case requestedDirectory = "requested_directory"
    }
}

private struct OneTimePassword {
    let directory: URL
    var file: URL { directory.appendingPathComponent("password", isDirectory: false) }

    init(_ password: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(askpassDirectoryPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        guard !password.isEmpty else { return }
        do {
            let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(password.utf8))
        } catch {
            remove()
            throw error
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }

    func submittedPassword(original: String) -> String? {
        let reply = directory.appendingPathComponent("reply")
        if let value = try? String(contentsOf: reply, encoding: .utf8), !value.isEmpty {
            return value
        }
        return original.isEmpty || FileManager.default.fileExists(atPath: file.path) ? nil : original
    }

    private static func openDirectory(for path: String) -> Int32? {
        let file = URL(fileURLWithPath: path).standardizedFileURL
        let directory = file.deletingLastPathComponent()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL
        let name = directory.lastPathComponent
        guard file.lastPathComponent == "password",
              directory.deletingLastPathComponent().path == temporary.path,
              name.hasPrefix(askpassDirectoryPrefix),
              UUID(uuidString: String(name.dropFirst(askpassDirectoryPrefix.count))) != nil else { return nil }
        let directoryDescriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { return nil }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0,
              directoryInfo.st_uid == geteuid(), (directoryInfo.st_mode & 0o077) == 0 else {
            Darwin.close(directoryDescriptor)
            return nil
        }
        return directoryDescriptor
    }

    static func answerPrompt(from path: String) -> Int32 {
        guard let directoryDescriptor = openDirectory(for: path) else { return 1 }
        defer { Darwin.close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, "password", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return 1 }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == geteuid(), (info.st_mode & 0o077) == 0,
              info.st_size > 0, info.st_size <= 1023,
              unlinkat(directoryDescriptor, "password", 0) == 0 else { return 1 }
        do {
            guard let data = try handle.read(upToCount: 4096), data.count == info.st_size else { return 1 }
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.write(contentsOf: Data([10]))
            return 0
        } catch {
            return 1
        }
    }

    static func recordReply(_ value: String, for path: String) {
        guard let directoryDescriptor = openDirectory(for: path) else { return }
        defer { Darwin.close(directoryDescriptor) }
        let descriptor = openat(directoryDescriptor, "reply", O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        try? handle.write(contentsOf: Data(value.utf8))
    }
}

@MainActor
private func runAskPass(_ environment: [String: String]) -> Int32 {
    guard CommandLine.arguments.count == 2 else { return 1 }
    let prompt = CommandLine.arguments[1]
    let normalized = prompt.lowercased()
    let confirmation = normalized.contains("authenticity of host") && normalized.contains("fingerprint")
        && normalized.contains("(yes/no")
    if !confirmation && environment["SSH_ASKPASS_PROMPT"] == "confirm" { return 1 }
    let asksForPassword = !confirmation
        && ["password", "密碼", "密码"].contains(where: normalized.contains)
        && !["passphrase", "one-time", "one time", "otp", "verification", "new password", "retype",
             "一次性", "動態", "动态", "驗證", "验证", "新密碼", "新密码"].contains(where: normalized.contains)
    if asksForPassword, let path = environment[askpassKey], OneTimePassword.answerPrompt(from: path) == 0 {
        return 0
    }
    let parent = getppid()
    guard parent > 1 else { return 1 }
    let watcher = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: .main)
    watcher.setEventHandler { Darwin.exit(1) }
    watcher.resume()
    defer { watcher.cancel() }
    guard getppid() == parent else { return 1 }

    let application = NSApplication.shared
    application.setActivationPolicy(.accessory)
    application.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = confirmation ? "確認 SSH 主機指紋" : "SSH 驗證"
    let readablePrompt = String(prompt.unicodeScalars.filter {
        !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t"
    }.prefix(1200))
    alert.informativeText = confirmation
        ? "請與伺服器管理員提供的指紋比對，確認後再信任這台主機。\n\n" + readablePrompt
        : readablePrompt
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
    if confirmation {
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "信任並連線")
    } else {
        field.setAccessibilityLabel("SSH 驗證回覆")
        alert.accessoryView = field
        alert.addButton(withTitle: "繼續")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = field
    }
    let response = alert.runModal()
    guard response == (confirmation ? .alertSecondButtonReturn : .alertFirstButtonReturn) else { return 1 }
    let value = confirmation ? "yes" : field.stringValue
    guard value.utf8.count <= 1023, !value.utf8.contains(where: { [0, 10, 13].contains($0) }) else { return 1 }
    do {
        if asksForPassword, !value.isEmpty, environment[rememberAskpassKey] == "1",
           let path = environment[askpassKey] {
            OneTimePassword.recordReply(value, for: path)
        }
        try FileHandle.standardOutput.write(contentsOf: Data((value + "\n").utf8))
        return 0
    } catch {
        return 1
    }
}

@MainActor
final class ServerFiles: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "尚未連線", action: nil, keyEquivalent: "")
    private let stopItem = NSMenuItem(title: "停止這個 App 的連線", action: #selector(stopConnection), keyEquivalent: "")
    private let http = URLSession(configuration: .ephemeral)
    private var attempt: UUID?
    private var connectedTarget: SSHConnection?
    private var connectedIdentity: String?
    private var tunnel: Process?
    private var closingTunnel: Process?
    private var tunnelInput: Pipe?
    private var tunnelOutput: Pipe?
    private var oneTimePassword: OneTimePassword?
    private var failureDetails = ""

    private var loginWindow: NSWindow?
    private let recentMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let forgetButton = NSButton(title: "移除紀錄", target: nil, action: nil)
    private let hostField = NSTextField()
    private let portField = NSTextField()
    private let usernameField = NSTextField()
    private let directoryField = NSTextField()
    private let passwordField = NSSecureTextField()
    private let revealedPasswordField = NSTextField()
    private let passwordVisibilityButton = NSButton()
    private var showsPassword = false
    private let revealedPasswordEditor: NSTextView = {
        let editor = NSTextView()
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.allowsUndo = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticTextCompletionEnabled = false
        return editor
    }()
    private let rememberPassword = NSButton(checkboxWithTitle: "記住密碼", target: nil, action: nil)
    private let connectionProgress = NSProgressIndicator()
    private let loginStatus = NSTextField(wrappingLabelWithString: "")
    private let loginButton = NSButton(title: "連線並開啟", target: nil, action: nil)
    private var currentCredentialID: String?
    private var recentConnections: [RecentConnection] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: appName)
            if button.image == nil { button.title = "預覽" }
            button.toolTip = appName
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        addItem("開啟伺服器檔案", action: #selector(connectOrOpen), to: menu)
        addItem("登入或切換伺服器…", action: #selector(showLogin), to: menu)
        stopItem.target = self
        stopItem.isEnabled = false
        menu.addItem(stopItem)
        menu.addItem(.separator())
        addItem("結束 \(appName)", action: #selector(quit), to: menu)
        statusItem.menu = menu
        showLogin()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLogin()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopConnection()
        if let closingTunnel {
            // Let the worker clean up after EOF. Authentication can still be waiting for input.
            let deadline = DispatchTime.now() + .seconds(1)
            while closingTunnel.isRunning && DispatchTime.now() < deadline {
                Thread.sleep(forTimeInterval: 0.025)
            }
            if closingTunnel.isRunning { closingTunnel.terminate() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === loginWindow else { return }
        clearPasswordFields()
        if attempt != nil { stopConnection() }
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? NSTextField, field === revealedPasswordField else { return nil }
        return revealedPasswordEditor
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        menu.addItem(item)
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: appName)
        appMenu.addItem(withTitle: "結束 \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "編輯")
        let editActions = [("復原", "undo:", "z"), ("重做", "redo:", "Z"),
                           ("剪下", "cut:", "x"), ("複製", "copy:", "c"),
                           ("貼上", "paste:", "v"), ("全選", "selectAll:", "a")]
        for (title, action, key) in editActions {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func createLoginWindow() -> NSWindow {
        let windowWidth: CGFloat = 516
        let horizontalPadding: CGFloat = 26
        let topPadding: CGFloat = 22
        let bottomPadding: CGFloat = 22
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = appName
        window.isReleasedWhenClosed = false
        window.delegate = self

        let logo = NSImageView(image: NSApp.applicationIconImage)
        logo.imageScaling = .scaleProportionallyUpOrDown
        logo.translatesAutoresizingMaskIntoConstraints = false
        logo.widthAnchor.constraint(equalToConstant: 52).isActive = true
        logo.heightAnchor.constraint(equalToConstant: 52).isActive = true
        logo.setAccessibilityElement(false)
        let heading = NSTextField(labelWithString: "連線到伺服器")
        heading.font = .systemFont(ofSize: 24, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "透過 SSH 瀏覽、預覽和編輯遠端檔案")
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        let titleStack = NSStackView(views: [heading, subtitle])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(views: [logo, titleStack])
        header.alignment = .centerY
        header.spacing = 12

        recentMenu.setAccessibilityLabel("最近使用的連線")
        recentMenu.controlSize = .large
        recentMenu.cell?.lineBreakMode = .byTruncatingMiddle
        recentMenu.target = self
        recentMenu.action = #selector(selectRecentConnection)
        forgetButton.target = self
        forgetButton.action = #selector(forgetConnection)
        forgetButton.bezelStyle = .rounded
        forgetButton.controlSize = .large
        forgetButton.setContentHuggingPriority(.required, for: .horizontal)
        forgetButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let recent = labeledControl("最近使用的連線", loginPair(recentMenu, forgetButton))

        hostField.placeholderString = "server.example.com"
        portField.placeholderString = "22"
        portField.alignment = .center
        usernameField.placeholderString = "SSH 帳號"
        directoryField.placeholderString = "留空使用主目錄"
        directoryField.setAccessibilityHelp("可輸入以 / 或 ~/ 開頭的遠端路徑。")
        for field in [hostField, portField, usernameField, directoryField] {
            field.delegate = self
            styleLoginField(field)
        }
        let hostGroup = labeledField("主機", hostField)
        let portGroup = labeledField("連接埠", portField)
        portGroup.widthAnchor.constraint(equalToConstant: 94).isActive = true
        let address = loginPair(hostGroup, portGroup, spacing: 12)
        let usernameGroup = labeledField("帳號", usernameField)
        let directoryGroup = labeledField("遠端目錄（選填）", directoryField)
        let passwordGroup = makePasswordGroup()
        rememberPassword.target = self
        rememberPassword.action = #selector(updatePasswordPlaceholder)
        rememberPassword.toolTip = "SSH 登入成功後，將密碼儲存在 macOS 鑰匙圈。"

        loginStatus.font = .systemFont(ofSize: 12)
        loginStatus.textColor = .secondaryLabelColor
        loginStatus.maximumNumberOfLines = 3
        loginStatus.lineBreakMode = .byTruncatingTail
        loginStatus.preferredMaxLayoutWidth = windowWidth - horizontalPadding * 2 - 24
        loginStatus.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        connectionProgress.style = .spinning
        connectionProgress.controlSize = .small
        connectionProgress.isDisplayedWhenStopped = false
        connectionProgress.setAccessibilityLabel("正在連線")
        connectionProgress.widthAnchor.constraint(equalToConstant: 16).isActive = true
        connectionProgress.heightAnchor.constraint(equalToConstant: 16).isActive = true
        // Keep an inset for the spinner so status messages stay aligned when it stops.
        let statusRow = NSView()
        for view in [connectionProgress, loginStatus] {
            view.translatesAutoresizingMaskIntoConstraints = false
            statusRow.addSubview(view)
        }
        NSLayoutConstraint.activate([
            connectionProgress.topAnchor.constraint(equalTo: statusRow.topAnchor),
            connectionProgress.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor),
            loginStatus.topAnchor.constraint(equalTo: statusRow.topAnchor),
            loginStatus.leadingAnchor.constraint(equalTo: connectionProgress.trailingAnchor, constant: 8),
            loginStatus.trailingAnchor.constraint(equalTo: statusRow.trailingAnchor),
            loginStatus.bottomAnchor.constraint(lessThanOrEqualTo: statusRow.bottomAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 45),
        ])

        loginButton.target = self
        loginButton.action = #selector(beginLogin)
        loginButton.bezelStyle = .rounded
        loginButton.controlSize = .large
        loginButton.keyEquivalent = "\r"
        loginButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelLogin))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .large
        cancel.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [cancel, loginButton])
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        let buttonRow = NSView()
        buttonRow.addSubview(buttons)
        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [header, recent, address, usernameGroup, directoryGroup, passwordGroup,
                                       rememberPassword, separator, statusRow, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 11
        stack.setCustomSpacing(17, after: header)
        stack.setCustomSpacing(15, after: recent)
        stack.setCustomSpacing(13, after: rememberPassword)
        stack.setCustomSpacing(8, after: separator)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        window.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: topPadding),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: horizontalPadding),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -horizontalPadding),
            buttons.topAnchor.constraint(equalTo: buttonRow.topAnchor),
            buttons.trailingAnchor.constraint(equalTo: buttonRow.trailingAnchor),
            buttons.bottomAnchor.constraint(equalTo: buttonRow.bottomAnchor),
        ] + [recent, address, usernameGroup, directoryGroup, passwordGroup, separator, statusRow, buttonRow].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor)
        })
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: windowWidth, height: ceil(stack.fittingSize.height) + topPadding + bottomPadding))
        let tabOrder = [hostField, portField, usernameField, directoryField, passwordField, revealedPasswordField,
                        passwordVisibilityButton, rememberPassword, cancel, loginButton, recentMenu, forgetButton]
        for (current, next) in zip(tabOrder, tabOrder.dropFirst()) { current.nextKeyView = next }
        forgetButton.nextKeyView = hostField
        window.autorecalculatesKeyViewLoop = false
        window.initialFirstResponder = hostField
        window.center()
        return window
    }

    private func styleLoginField(_ field: NSTextField) {
        field.usesSingleLineMode = true
        field.controlSize = .large
        field.font = .systemFont(ofSize: 14)
    }

    private func loginPair(_ primary: NSView, _ trailing: NSView, spacing: CGFloat = 8) -> NSView {
        let row = NSView()
        primary.setContentHuggingPriority(.defaultLow, for: .horizontal)
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for view in [primary, trailing] {
            view.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(view)
        }
        // Explicit edge constraints give the primary control all width left by the trailing control.
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -spacing),
            primary.topAnchor.constraint(equalTo: row.topAnchor),
            primary.bottomAnchor.constraint(equalTo: row.bottomAnchor),
            trailing.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            trailing.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            trailing.topAnchor.constraint(greaterThanOrEqualTo: row.topAnchor),
            trailing.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
        ])
        return row
    }

    private func labeledField(_ title: String, _ field: NSTextField) -> NSStackView {
        field.setAccessibilityLabel(title)
        return labeledControl(title, field)
    }

    private func labeledControl(_ title: String, _ control: NSView) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        let group = NSStackView(views: [label, control])
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 4
        control.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
        return group
    }

    private func makePasswordGroup() -> NSStackView {
        let fields = NSView()
        for field in [passwordField, revealedPasswordField] {
            styleLoginField(field)
            field.setAccessibilityLabel("密碼")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            fields.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: fields.topAnchor),
                field.leadingAnchor.constraint(equalTo: fields.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: fields.trailingAnchor),
                field.bottomAnchor.constraint(equalTo: fields.bottomAnchor),
            ])
        }
        passwordVisibilityButton.target = self
        passwordVisibilityButton.action = #selector(togglePasswordVisibility)
        passwordVisibilityButton.bezelStyle = .rounded
        passwordVisibilityButton.controlSize = .large
        passwordVisibilityButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        setPasswordVisibility(false)
        return labeledControl("密碼", loginPair(fields, passwordVisibilityButton))
    }

    private var activePasswordField: NSTextField {
        showsPassword ? revealedPasswordField : passwordField
    }

    private func setPasswordVisibility(_ visible: Bool) {
        showsPassword = visible
        passwordField.isHidden = visible
        revealedPasswordField.isHidden = !visible
        let action = visible ? "隱藏密碼" : "顯示密碼"
        let image = NSImage(systemSymbolName: visible ? "eye.slash" : "eye", accessibilityDescription: action)
        passwordVisibilityButton.title = image == nil ? action : ""
        passwordVisibilityButton.image = image
        passwordVisibilityButton.imagePosition = image == nil ? .noImage : .imageOnly
        passwordVisibilityButton.toolTip = action
        passwordVisibilityButton.setAccessibilityLabel(action)
    }

    @objc private func togglePasswordVisibility() {
        guard attempt == nil, let window = loginWindow else { return }
        let source = activePasswordField
        let selection = (source.currentEditor() as? NSTextView)?.selectedRange()
        guard window.makeFirstResponder(nil) else { return }
        let value = source.stringValue
        source.stringValue = ""
        revealedPasswordEditor.string = ""
        setPasswordVisibility(!showsPassword)
        let destination = activePasswordField
        destination.stringValue = value
        if window.makeFirstResponder(destination), let selection, let editor = destination.currentEditor() as? NSTextView {
            let length = value.utf16.count
            let start = min(selection.location, length)
            editor.setSelectedRange(NSRange(location: start, length: min(selection.length, length - start)))
        }
    }

    private func clearPasswordFields() {
        if activePasswordField.currentEditor() != nil { loginWindow?.makeFirstResponder(nil) }
        passwordField.stringValue = ""
        revealedPasswordField.stringValue = ""
        revealedPasswordEditor.string = ""
        setPasswordVisibility(false)
    }

    @objc private func showLogin() {
        if loginWindow == nil { loginWindow = createLoginWindow() }
        guard let window = loginWindow else { return }
        if !window.isVisible {
            if let data = UserDefaults.standard.data(forKey: recentConnectionsKey),
               let recent = try? JSONDecoder().decode([RecentConnection].self, from: data) {
                recentConnections = recent
            }
            populateForm(connectedTarget ?? recentConnections.first?.connection)
            setLoginState(connectedIdentity.map { "已連線到 \($0)" } ?? "")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        if attempt == nil { window.makeFirstResponder(hostField) }
    }

    @objc private func cancelLogin() {
        loginWindow?.performClose(nil)
    }

    private var formConnection: SSHConnection? {
        SSHConnection.parse(address: hostField.stringValue, username: usernameField.stringValue,
                            port: portField.stringValue, directory: directoryField.stringValue)
    }

    private var displayedConnections: [SSHConnection] {
        recentConnections.map(\.connection)
    }

    private func hasRememberedPassword(for connection: SSHConnection) -> Bool {
        recentConnections.contains { $0.connection.credentialID == connection.credentialID && $0.remembersPassword }
    }

    private func populateForm(_ connection: SSHConnection?) {
        hostField.stringValue = connection?.host ?? ""
        portField.stringValue = String(connection?.port ?? 22)
        usernameField.stringValue = connection?.username ?? ""
        directoryField.stringValue = connection?.directory ?? ""
        clearPasswordFields()
        currentCredentialID = nil
        rememberPassword.state = .off
        updateCredentialState()
    }

    private func updateCredentialState() {
        let connection = formConnection
        let remembersPassword = connection.map(hasRememberedPassword(for:)) ?? false
        if connection?.credentialID != currentCredentialID {
            clearPasswordFields()
            rememberPassword.state = remembersPassword ? .on : .off
            currentCredentialID = connection?.credentialID
        }
        updatePasswordPlaceholder()
        recentMenu.removeAllItems()
        recentMenu.addItem(withTitle: "選擇最近使用的連線")
        for saved in displayedConnections { recentMenu.addItem(withTitle: saved.recentLabel) }
        let index = connection.flatMap { displayedConnections.firstIndex(of: $0) }
        recentMenu.selectItem(at: index.map { $0 + 1 } ?? 0)
        forgetButton.isEnabled = index != nil && attempt == nil
    }

    @objc private func updatePasswordPlaceholder() {
        let saved = formConnection.map { connection in hasRememberedPassword(for: connection) } ?? false
        let placeholder = saved && rememberPassword.state == .on
            ? "已記住密碼，可直接連線" : "使用 SSH 金鑰時可留空"
        passwordField.placeholderString = placeholder
        revealedPasswordField.placeholderString = placeholder
    }

    func controlTextDidChange(_ notification: Notification) {
        updateCredentialState()
    }

    @objc private func selectRecentConnection() {
        let index = recentMenu.indexOfSelectedItem - 1
        let choices = displayedConnections
        guard choices.indices.contains(index) else { return }
        populateForm(choices[index])
    }

    @objc private func forgetConnection() {
        guard attempt == nil, let connection = formConnection else { return }
        let otherProfile = recentConnections.contains {
            $0.connection != connection && $0.connection.credentialID == connection.credentialID
        }
        if !otherProfile, hasRememberedPassword(for: connection),
           !PasswordStore.remove(connection) {
            setLoginState("無法移除已記住的密碼。", failed: true)
            return
        }
        recentConnections.removeAll { $0.connection == connection }
        saveRecents()
        currentCredentialID = nil
        updateCredentialState()
        setLoginState("已移除連線紀錄。")
    }

    private func saveRecents() {
        if let data = try? JSONEncoder().encode(recentConnections) {
            UserDefaults.standard.set(data, forKey: recentConnectionsKey)
        }
    }

    @objc private func beginLogin() {
        guard attempt == nil else { return }
        loginWindow?.makeFirstResponder(nil)
        guard let connection = formConnection else {
            setLoginState("請檢查主機、帳號，以及 1 至 65535 的連接埠。", failed: true)
            return
        }
        guard connection.directory.utf8.count <= 4096,
              !connection.directory.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            setLoginState("請輸入 4096 位元組以內、沒有控制字元的遠端目錄。", failed: true)
            loginWindow?.makeFirstResponder(directoryField)
            return
        }
        guard connection.directory.isEmpty || connection.directory.hasPrefix("/")
            || connection.directory.hasPrefix("~/") else {
            setLoginState("請輸入以 / 或 ~/ 開頭的遠端目錄。", failed: true)
            loginWindow?.makeFirstResponder(directoryField)
            return
        }
        let password = activePasswordField.stringValue
        let remember = rememberPassword.state == .on
        guard password.utf8.count <= 1023,
              !password.utf8.contains(where: { [0, 10, 13].contains($0) }) else {
            setLoginState("請輸入 1023 位元組以內、沒有換行的 SSH 密碼。", failed: true)
            return
        }
        clearPasswordFields()
        let id = UUID()
        attempt = id
        statusLine.title = "正在檢查 \(connection.label)…"
        setLoginState("正在檢查 \(connection.label)…", busy: true)
        Task { await connect(id, target: connection, password: password, remember: remember) }
    }

    @objc private func connectOrOpen() {
        guard attempt == nil else { showLogin(); return }
        guard let target = connectedTarget, loginWindow?.isVisible != true else {
            showLogin()
            return
        }
        Task {
            let ready = await readyConnection(for: target)
            guard attempt == nil, connectedTarget == target else { return }
            if ready != nil { NSWorkspace.shared.open(filesURL) }
            else {
                connectedTarget = nil
                connectedIdentity = nil
                showLogin()
            }
        }
    }

    private func connect(_ id: UUID, target: SSHConnection, password enteredPassword: String, remember: Bool) async {
        if enteredPassword.isEmpty, let ready = await readyConnection(for: target) {
            if attempt == id {
                openReadyPage(target, identity: ready.identity, password: "", savedPassword: nil, remember: remember)
            }
            return
        }
        guard attempt == id else { return }

        let savedPassword = remember && enteredPassword.isEmpty ? PasswordStore.read(target) : nil
        if remember && enteredPassword.isEmpty && savedPassword == nil && hasRememberedPassword(for: target) {
            failLogin("無法讀取已記住的密碼，請重新輸入。")
            return
        }
        let password = savedPassword ?? enteredPassword

        if let previous = releaseTunnel() {
            connectedTarget = nil
            connectedIdentity = nil
            for _ in 0..<25 {
                guard attempt == id else { return }
                if !previous.isRunning { break }
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }
        async let existingReports = isListening(reportsURL)
        async let existingFiles = isListening(filesURL)
        let occupied = await (existingReports, existingFiles)
        guard attempt == id else { return }
        if occupied.0 || occupied.1 {
            failLogin("8877 或 8878 已被其他預覽使用。請停止舊 App 或 Terminal 的預覽連線後再試。")
            return
        }

        do {
            try startTunnel(target: target, password: password, remember: remember)
        } catch {
            failLogin("無法啟動預覽。\(error.localizedDescription)")
            return
        }

        statusLine.title = "正在連線到 \(target.label)…"
        setLoginState("正在連線到 \(target.label)…", busy: true)
        let deadline = Date().addingTimeInterval(115)
        repeat {
            guard attempt == id else { return }
            if let ready = await readyConnection(for: target) {
                if attempt == id {
                    openReadyPage(target, identity: ready.identity, password: password, savedPassword: savedPassword, remember: remember)
                }
                return
            }
            guard attempt == id else { return }
            if tunnel?.isRunning != true { break }
            try? await Task.sleep(nanoseconds: 240_000_000)
        } while Date() < deadline

        guard attempt == id else { return }
        let details = failureDetails
        _ = releaseTunnel()
        failLogin(connectionFailure(details, passwordEntered: !password.isEmpty))
    }

    private func response(for url: URL, method: String = "GET") async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 0.8)
        request.httpMethod = method
        guard let (data, result) = try? await http.data(for: request),
              let response = result as? HTTPURLResponse,
              response.url?.host == url.host, response.url?.port == url.port else {
            return nil
        }
        return (data, response)
    }

    private func health(_ url: URL, scope: String, target: SSHConnection) async -> HealthResponse? {
        let endpoint = url.appendingPathComponent(".codex-preview").appendingPathComponent("health")
        guard let (data, response) = await response(for: endpoint), response.statusCode == 200,
              data.count <= 65_536, let health = try? JSONDecoder().decode(HealthResponse.self, from: data),
              health.service == "codex-ssh-preview", health.scope == scope,
              health.target == target.target, health.port == target.port,
              target.hasDirectory(health.requestedDirectory), !health.session.isEmpty else { return nil }
        return health
    }

    private func readyConnection(for target: SSHConnection) async -> HealthResponse? {
        async let files = health(filesURL, scope: "files", target: target)
        async let reports = health(reportsURL, scope: "reports", target: target)
        guard let files = await files, let reports = await reports,
              files.session == reports.session, files.identity == reports.identity else { return nil }
        return files
    }

    private func isListening(_ url: URL) async -> Bool {
        await response(for: url, method: "HEAD") != nil
    }

    private func startTunnel(target: SSHConnection, password: String, remember: Bool) throws {
        guard let launcher = Bundle.main.url(forResource: "ServerFilesPreview", withExtension: "command"),
              let askpass = Bundle.main.executableURL,
              FileManager.default.isReadableFile(atPath: launcher.path) else { throw CocoaError(.fileNoSuchFile) }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [launcher.path]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_PREVIEW_HOST"] = target.target
        environment["CODEX_PREVIEW_PORT"] = String(target.port)
        environment["CODEX_PREVIEW_REMOTE_DIR"] = target.directory.isEmpty ? nil : target.directory
        environment["CODEX_PREVIEW_INTERACTIVE"] = "1"
        environment[askpassModeKey] = "1"
        environment["SSH_ASKPASS"] = askpass.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["LC_ALL"] = "C"
        environment.removeValue(forKey: "CODEX_PREVIEW_AUTH")
        environment.removeValue(forKey: "CODEX_PREVIEW_BATCH")
        environment.removeValue(forKey: askpassKey)
        environment.removeValue(forKey: rememberAskpassKey)
        environment.removeValue(forKey: "SSH_ASKPASS_PROMPT")
        if !password.isEmpty || remember {
            let credential = try OneTimePassword(password)
            oneTimePassword = credential
            environment[askpassKey] = credential.file.path
            if remember { environment[rememberAskpassKey] = "1" }
        }
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        failureDetails = ""
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let message = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in self?.appendOutput(message, for: process) }
        }
        process.terminationHandler = { [weak self] child in
            Task { @MainActor [weak self] in
                guard let self, self.tunnel === child, self.attempt == nil else { return }
                self.stopConnection()
                self.statusLine.title = "SSH 已斷線"
            }
        }
        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            oneTimePassword?.remove()
            oneTimePassword = nil
            throw error
        }
        tunnel = process
        tunnelInput = input
        tunnelOutput = output
        stopItem.isEnabled = true
    }

    private func appendOutput(_ message: String, for process: Process) {
        guard tunnel === process else { return }
        failureDetails = String((failureDetails + message).suffix(4096))
    }

    private func setLoginState(_ message: String, busy: Bool = false, failed: Bool = false) {
        loginStatus.stringValue = message
        loginStatus.textColor = failed ? .systemRed : .secondaryLabelColor
        for control in [hostField, usernameField, portField, directoryField, passwordField, revealedPasswordField,
                        passwordVisibilityButton, recentMenu, rememberPassword] {
            control.isEnabled = !busy
        }
        forgetButton.isEnabled = !busy && recentConnections.contains { $0.connection == formConnection }
        if busy { connectionProgress.startAnimation(nil) }
        else { connectionProgress.stopAnimation(nil) }
        loginButton.isEnabled = !busy
    }

    private func failLogin(_ message: String) {
        attempt = nil
        statusLine.title = "連線失敗"
        setLoginState(message, failed: true)
        loginWindow?.makeFirstResponder(activePasswordField)
    }

    private func openReadyPage(_ target: SSHConnection, identity: String, password: String,
                               savedPassword: String?, remember: Bool) {
        let submitted = remember ? oneTimePassword?.submittedPassword(original: password) : nil
        attempt = nil
        connectedTarget = target
        connectedIdentity = identity
        oneTimePassword?.remove()
        oneTimePassword = nil
        let previouslySaved = savedPassword != nil || hasRememberedPassword(for: target)
        var saved = previouslySaved
        var keychainError: String?
        if let submitted {
            if PasswordStore.alreadySaved(submitted, as: savedPassword) || PasswordStore.save(submitted, for: target) {
                saved = true
            } else {
                keychainError = "已連線，但無法記住這次的密碼。"
            }
        } else if remember && !password.isEmpty && !previouslySaved {
            keychainError = "這次連線未使用可儲存的 SSH 密碼。"
        } else if !remember && previouslySaved {
            if PasswordStore.remove(target) { saved = false }
            else { keychainError = "已連線，但無法移除已記住的密碼。" }
        }
        recentConnections.removeAll { $0.connection == target }
        recentConnections = recentConnections.map { recent in
            guard recent.connection.credentialID == target.credentialID else { return recent }
            return RecentConnection(connection: recent.connection, remembersPassword: saved)
        }
        recentConnections.insert(RecentConnection(connection: target, remembersPassword: saved), at: 0)
        saveRecents()
        statusLine.title = "已連線到 \(identity)"
        setLoginState(statusLine.title)
        if let keychainError { showMessage("記住密碼", keychainError) }
        loginWindow?.orderOut(nil)
        NSWorkspace.shared.open(filesURL)
    }

    private func releaseTunnel() -> Process? {
        oneTimePassword?.remove()
        oneTimePassword = nil
        if let writer = tunnelInput?.fileHandleForWriting { try? writer.close() }
        let previous = tunnel
        if let previous, previous.isRunning {
            closingTunnel = previous
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                if previous.isRunning { previous.terminate() }
                if self?.closingTunnel === previous { self?.closingTunnel = nil }
            }
        }
        tunnelOutput?.fileHandleForReading.readabilityHandler = nil
        tunnel = nil
        tunnelInput = nil
        tunnelOutput = nil
        stopItem.isEnabled = false
        return previous
    }

    @objc private func stopConnection() {
        attempt = nil
        connectedTarget = nil
        connectedIdentity = nil
        _ = releaseTunnel()
        statusLine.title = "尚未連線"
        setLoginState("")
    }

    private func connectionFailure(_ details: String, passwordEntered: Bool) -> String {
        let output = details.lowercased()
        if output.contains("remote host identification has changed") {
            return "主機的 SSH 金鑰已變更。請向管理員確認主機指紋後再連線。"
        }
        if output.contains("host key verification failed") || output.contains("no host key is known") {
            return "SSH 主機尚未通過驗證。請與管理員比對指紋，再重試連線。"
        }
        if output.contains("permission denied") || output.contains("authentication failed") {
            return passwordEntered
                ? "SSH 驗證失敗。請確認密碼是否正確，以及主機是否允許密碼登入。"
                : "SSH 金鑰驗證失敗。請輸入 SSH 密碼，或確認這台 Mac 的金鑰已加入該主機。"
        }
        if output.contains("address already in use") {
            return "預覽連接埠已被使用。請停止舊 App 或 Terminal 的預覽連線後再試。"
        }
        if output.contains("administratively prohibited") || output.contains("streamlocal forwarding") {
            return "主機未允許此 App 使用的 SSH 通訊端轉送，請檢查伺服器設定。"
        }
        if output.contains("python3") && output.contains("not found") {
            return "SSH 已登入。請在遠端主機安裝 Python 3 後重試。"
        }
        if let cause = details.split(separator: "\n").last, !cause.isEmpty {
            return "無法連線。請檢查主機、連接埠和網路。若主機需要 VPN，請先連線。\n\(cause.prefix(180))"
        }
        return "無法連線。請檢查主機、連接埠和網路。若主機需要 VPN，請先連線。"
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func showMessage(_ title: String, _ description: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = description
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}

@main
struct ApplicationMain {
    @MainActor
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        if environment[askpassModeKey] == "1" {
            Darwin.exit(runAskPass(environment))
        }
        let app = NSApplication.shared
        // The same executable starts as a UI agent when OpenSSH runs it as askpass.
        app.setActivationPolicy(.regular)
        let delegate = ServerFiles()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
