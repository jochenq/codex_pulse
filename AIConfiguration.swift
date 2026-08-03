import AppKit
import CryptoKit
import Foundation

struct AIServiceConfiguration {
    var baseURL: String
    var apiKey: String
    var model: String

    var isConfigured: Bool {
        !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

final class AIConfigurationStore {
    static let shared = AIConfigurationStore()

    private let baseURLKey = "tibo-ai-base-url"
    private let modelKey = "tibo-ai-model"
    private let keyURL: URL
    private let encryptedAPIKeyURL: URL

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codex Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keyURL = directory.appendingPathComponent("ai-config.key")
        encryptedAPIKeyURL = directory.appendingPathComponent("api-key.enc")
    }

    func load() -> AIServiceConfiguration {
        AIServiceConfiguration(
            baseURL: UserDefaults.standard.string(forKey: baseURLKey) ?? "",
            apiKey: readLocalAPIKey(),
            model: UserDefaults.standard.string(forKey: modelKey) ?? ""
        )
    }

    @discardableResult
    func save(_ configuration: AIServiceConfiguration) -> Bool {
        let baseURL = normalizedBaseURL(configuration.baseURL)
        let model = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard writeLocalAPIKey(configuration.apiKey) else { return false }
        UserDefaults.standard.set(baseURL, forKey: baseURLKey)
        UserDefaults.standard.set(model, forKey: modelKey)
        return true
    }

    private func normalizedBaseURL(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        return result
    }

    private func readLocalAPIKey() -> String {
        guard let keyData = try? Data(contentsOf: keyURL), keyData.count == 32,
              let encrypted = try? Data(contentsOf: encryptedAPIKeyURL),
              let box = try? AES.GCM.SealedBox(combined: encrypted),
              let opened = try? AES.GCM.open(box, using: SymmetricKey(data: keyData)) else { return "" }
        return String(data: opened, encoding: .utf8) ?? ""
    }

    private func writeLocalAPIKey(_ rawValue: String) -> Bool {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            try? FileManager.default.removeItem(at: encryptedAPIKeyURL)
            return true
        }
        guard let keyData = encryptionKey(),
              let sealed = try? AES.GCM.seal(Data(value.utf8), using: SymmetricKey(data: keyData)),
              let combined = sealed.combined else { return false }
        do {
            try combined.write(to: encryptedAPIKeyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: encryptedAPIKeyURL.path)
            return true
        } catch {
            return false
        }
    }

    private func encryptionKey() -> Data? {
        if let data = try? Data(contentsOf: keyURL), data.count == 32 { return data }
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        do {
            try data.write(to: keyURL, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            return data
        } catch {
            return nil
        }
    }
}

enum OpenAICompatibleEndpoint {
    static func url(baseURL rawValue: String, operation: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme == "http" || components.scheme == "https",
              components.host != nil else { return nil }
        let operationPath = operation.hasPrefix("/") ? operation : "/" + operation
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        } else if path.hasSuffix("/models") {
            path.removeLast("/models".count)
        }
        if path.isEmpty { path = "/v1" }
        components.path = path + operationPath
        components.query = nil
        components.fragment = nil
        return components.url
    }
}

final class OpenAICompatibleService {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 35
        session = URLSession(configuration: configuration)
    }

    func fetchModels(configuration: AIServiceConfiguration,
                     completion: @escaping (Result<[String], Error>) -> Void) {
        guard let url = OpenAICompatibleEndpoint.url(baseURL: configuration.baseURL, operation: "models") else {
            completion(.failure(AIConfigurationError.invalidBaseURL)); return
        }
        var request = URLRequest(url: url, timeoutInterval: 25)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, let data else {
                completion(.failure(AIConfigurationError.invalidResponse)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(AIConfigurationError.httpError(http.statusCode, apiErrorMessage(data)))); return
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = root["data"] as? [[String: Any]] else {
                completion(.failure(AIConfigurationError.invalidResponse)); return
            }
            let models = Set(items.compactMap { $0["id"] as? String }.filter { !$0.isEmpty }).sorted()
            guard !models.isEmpty else { completion(.failure(AIConfigurationError.noModels)); return }
            completion(.success(models))
        }.resume()
    }
}

final class AIConfigurationWindowController: NSWindowController, NSWindowDelegate {
    var onSave: ((AIServiceConfiguration) -> Void)?

    private let store = AIConfigurationStore.shared
    private let service = OpenAICompatibleService()
    private let baseURLField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let modelCombo = NSComboBox()
    private let statusLabel = NSTextField(labelWithString: "")
    private let fetchButton = ClickableButton(title: "获取模型", target: nil, action: nil)

    init(onSave: ((AIServiceConfiguration) -> Void)? = nil) {
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 350),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Tibo AI 配置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
        reloadFields()
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        reloadFields()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        let title = NSTextField(labelWithString: "AI 服务")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "用于生成 Tibo 动态摘要，兼容 OpenAI Chat Completions 协议。")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        baseURLField.placeholderString = "https://api.openai.com/v1"
        apiKeyField.placeholderString = "可留空（本地无鉴权服务）"
        modelCombo.isEditable = true
        modelCombo.completes = true
        modelCombo.placeholderString = "选择或手动输入模型 ID"

        let baseRow = fieldRow(title: "Base URL", control: baseURLField,
                               help: "填写服务根地址；仅填写域名时会自动补 /v1。")
        let keyRow = fieldRow(title: "API Key", control: apiKeyField,
                              help: "AES 加密保存在本机，不访问 macOS 钥匙串。")
        let modelRow = fieldRow(title: "模型", control: modelCombo,
                                help: "可自动拉取，也可直接输入供应商提供的模型 ID。")

        fetchButton.target = self
        fetchButton.action = #selector(fetchModels)
        fetchButton.bezelStyle = .rounded
        let cancel = ClickableButton(title: "取消", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        let save = ClickableButton(title: "保存配置", target: self, action: #selector(saveConfiguration))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        let actions = NSStackView(views: [fetchButton, statusLabel, NSView(), cancel, save])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let stack = NSStackView(views: [title, subtitle, baseRow, keyRow, modelRow, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            baseRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            keyRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            modelRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 170)
        ])
    }

    private func fieldRow(title: String, control: NSView, help: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let helpLabel = NSTextField(labelWithString: help)
        helpLabel.font = .systemFont(ofSize: 10)
        helpLabel.textColor = .tertiaryLabelColor
        let fields = NSStackView(views: [control, helpLabel])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 3
        control.widthAnchor.constraint(equalTo: fields.widthAnchor).isActive = true
        let row = NSStackView(views: [label, fields])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 10
        fields.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    private func reloadFields() {
        let configuration = store.load()
        baseURLField.stringValue = configuration.baseURL
        apiKeyField.stringValue = configuration.apiKey
        modelCombo.stringValue = configuration.model
        statusLabel.stringValue = configuration.isConfigured ? "已配置" : "尚未配置"
        statusLabel.textColor = configuration.isConfigured ? .systemGreen : .secondaryLabelColor
    }

    private func currentConfiguration() -> AIServiceConfiguration {
        AIServiceConfiguration(baseURL: baseURLField.stringValue,
                               apiKey: apiKeyField.stringValue,
                               model: modelCombo.stringValue)
    }

    @objc private func fetchModels() {
        let configuration = currentConfiguration()
        guard OpenAICompatibleEndpoint.url(baseURL: configuration.baseURL, operation: "models") != nil else {
            showStatus("Base URL 无效", error: true); return
        }
        fetchButton.isEnabled = false
        showStatus("正在获取…", error: false)
        service.fetchModels(configuration: configuration) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetchButton.isEnabled = true
                switch result {
                case .success(let models):
                    let previous = self.modelCombo.stringValue
                    self.modelCombo.removeAllItems()
                    self.modelCombo.addItems(withObjectValues: models)
                    if !previous.isEmpty { self.modelCombo.stringValue = previous }
                    else if let first = models.first { self.modelCombo.stringValue = first }
                    self.showStatus("已获取 \(models.count) 个模型", error: false)
                case .failure(let error):
                    self.showStatus(error.localizedDescription, error: true)
                }
            }
        }
    }

    @objc private func saveConfiguration() {
        let configuration = currentConfiguration()
        guard OpenAICompatibleEndpoint.url(baseURL: configuration.baseURL, operation: "chat/completions") != nil else {
            showStatus("Base URL 无效", error: true); return
        }
        guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showStatus("请填写模型 ID", error: true); return
        }
        guard store.save(configuration) else {
            showStatus("API Key 无法写入本地加密文件", error: true); return
        }
        showStatus("已保存", error: false)
        onSave?(store.load())
        window?.performClose(nil)
    }

    @objc private func cancel() { window?.performClose(nil) }

    private func showStatus(_ text: String, error: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = error ? .systemRed : .secondaryLabelColor
    }
}

private enum AIConfigurationError: LocalizedError {
    case invalidBaseURL
    case invalidResponse
    case noModels
    case httpError(Int, String?)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Base URL 无效"
        case .invalidResponse: return "服务返回了无法识别的响应"
        case .noModels: return "服务没有返回可用模型"
        case .httpError(let status, let message):
            return message.map { "HTTP \(status)：\($0)" } ?? "HTTP \(status)"
        }
    }
}

private func apiErrorMessage(_ data: Data) -> String? {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let error = root["error"] as? [String: Any] else { return nil }
    return error["message"] as? String
}
