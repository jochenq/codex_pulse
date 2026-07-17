import Foundation
import CryptoKit

struct TiboActivitySnapshot: Codable {
    var fingerprint: String
    var headline: String
    var summary: String
    var latestPostAt: Date?
    var analyzedAt: Date?
    var checkedAt: Date
    var sourceURL: String
    var status: String
    var activityState: String?

    static func empty() -> TiboActivitySnapshot {
        TiboActivitySnapshot(
            fingerprint: "", headline: "正在获取公开动态", summary: "首次分析完成后会显示在这里。",
            latestPostAt: nil, analyzedAt: nil, checkedAt: .distantPast,
            sourceURL: "https://x.com/thsottiaux", status: "loading", activityState: nil
        )
    }
}

private struct TiboPost {
    let id: String
    let text: String
    let publishedAt: Date
    let url: String
}

private struct AIActivityDigest: Decodable {
    let state: String
    let headline: String
    let summary: String
}

final class TiboMonitor {
    private let profileURL = URL(string: "https://x.com/thsottiaux")!
    private let liveMirrorURL = URL(string: "https://r.jina.ai/http://twstalker.com/thsottiaux")!
    private let syndicationURL = URL(string: "https://syndication.twitter.com/srv/timeline-profile/screen-name/thsottiaux")!
    private let queue = DispatchQueue(label: "com.codexpulse.tibo-monitor", qos: .utility)
    private let session: URLSession
    private let cacheURL: URL
    private var running = false
    private var pendingForcedCompletion: ((TiboActivitySnapshot) -> Void)?
    private(set) var snapshot: TiboActivitySnapshot

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 35
        config.httpMaximumConnectionsPerHost = 1
        session = URLSession(configuration: config)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Codex Pulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cacheURL = support.appendingPathComponent("tibo-activity.json")
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode(TiboActivitySnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = .empty()
        }
    }

    func check(forceAnalysis: Bool = false, completion: @escaping (TiboActivitySnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.running {
                if forceAnalysis { self.pendingForcedCompletion = completion }
                return
            }
            self.running = true
            self.fetchPosts { result in
                self.queue.async {
                    switch result {
                    case .success(let posts): self.handle(posts: posts, forceAnalysis: forceAnalysis, completion: completion)
                    case .failure:
                        self.snapshot.checkedAt = Date()
                        if self.snapshot.latestPostAt.map({ Date().timeIntervalSince($0) > 14 * 24 * 60 * 60 }) ?? false {
                            self.snapshot.headline = "公开时间线已过期"
                            self.snapshot.summary = "X 返回的公开时间线不是最新内容，已暂停 AI 摘要，等待新数据源恢复。"
                            self.snapshot.activityState = "等更新"
                            self.snapshot.status = "source-stale"
                        } else {
                            self.snapshot.status = self.snapshot.analyzedAt == nil ? "fetch-error" : "stale"
                        }
                        self.save()
                        self.finish(completion)
                    }
                }
            }
        }
    }

    private func fetchPosts(completion: @escaping (Result<[TiboPost], Error>) -> Void) {
        fetchPage(liveMirrorURL) { mirror in
            if case .success(let html) = mirror {
                let posts = self.parseLiveMirrorPosts(html)
                if self.isFresh(posts) { completion(.success(posts)); return }
            }
            self.fetchPage(self.syndicationURL) { result in
                if case .success(let html) = result {
                    let posts = self.parseSyndicatedPosts(html)
                    if self.isFresh(posts) { completion(.success(posts)); return }
                }
                self.fetchPage(self.profileURL) { fallback in
                    guard case .success(let html) = fallback else {
                        completion(.failure(MonitorError.invalidResponse)); return
                    }
                    let posts = self.parsePosts(html)
                    guard self.isFresh(posts) else {
                        completion(.failure(MonitorError.staleTimeline)); return
                    }
                    completion(.success(posts))
                }
            }
        }
    }

    private func fetchPage(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if url.host == "r.jina.ai" { request.setValue("html", forHTTPHeaderField: "X-Return-Format") }
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(MonitorError.invalidResponse)); return
            }
            completion(.success(html))
        }.resume()
    }

    private func parseLiveMirrorPosts(_ html: String) -> [TiboPost] {
        guard let regex = try? NSRegularExpression(
            pattern: #"href=\"/thsottiaux/status/(\d+)\">[^<]*</a>.*?<div class=\"activity-descp\">\s*<p>(.*?)</p>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var seen = Set<String>()
        var posts: [TiboPost] = []
        for match in matches {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted, let date = dateFromSnowflake(id) else { continue }
            let body = nsHTML.substring(with: match.range(at: 2))
            let text = stripHTML(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            posts.append(TiboPost(id: id, text: text, publishedAt: date, url: "https://x.com/thsottiaux/status/\(id)"))
        }
        let sorted = posts.sorted { $0.publishedAt > $1.publishedAt }
        let substantive = sorted.filter { !$0.text.hasPrefix("@") }
        let replies = sorted.filter { $0.text.hasPrefix("@") }.prefix(4)
        return Array((substantive + replies).prefix(12)).sorted { $0.publishedAt > $1.publishedAt }
    }

    private func parseSyndicatedPosts(_ html: String) -> [TiboPost] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<script[^>]*id=\"__NEXT_DATA__\"[^>]*>(.*?)</script>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)),
              let data = nsHTML.substring(with: match.range(at: 1)).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let timeline = pageProps["timeline"] as? [String: Any],
              let entries = timeline["entries"] as? [[String: Any]] else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        var seen = Set<String>()
        var posts: [TiboPost] = []
        for entry in entries {
            guard entry["type"] as? String == "tweet",
                  let content = entry["content"] as? [String: Any],
                  let tweet = content["tweet"] as? [String: Any],
                  let id = tweet["id_str"] as? String, seen.insert(id).inserted,
                  let rawText = (tweet["full_text"] ?? tweet["text"]) as? String,
                  let created = tweet["created_at"] as? String,
                  let date = formatter.date(from: created) else { continue }
            let text = decodeHTMLEntities(rawText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            posts.append(TiboPost(id: id, text: text, publishedAt: date, url: "https://x.com/thsottiaux/status/\(id)"))
        }
        return posts.sorted { $0.publishedAt > $1.publishedAt }.prefix(12).map { $0 }
    }

    private func isFresh(_ posts: [TiboPost]) -> Bool {
        guard let newest = posts.map(\.publishedAt).max() else { return false }
        return Date().timeIntervalSince(newest) < 14 * 24 * 60 * 60
    }

    private func parsePosts(_ html: String) -> [TiboPost] {
        guard let articleRegex = try? NSRegularExpression(
            pattern: #"<article[^>]*data-tweet-id=\"([^\"]+)\"[^>]*>(.*?)</article>"#,
            options: [.dotMatchesLineSeparators]
        ), let metaRegex = try? NSRegularExpression(
            pattern: #"<meta content=\"([^\"]*)\" itemProp=\"([^\"]+)\"\s*/?>"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let nsHTML = html as NSString
        let matches = articleRegex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var seen = Set<String>()
        var posts: [TiboPost] = []
        for match in matches {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted else { continue }
            let body = nsHTML.substring(with: match.range(at: 2))
            let nsBody = body as NSString
            var metadata: [String: String] = [:]
            for meta in metaRegex.matches(in: body, range: NSRange(location: 0, length: nsBody.length)) {
                metadata[nsBody.substring(with: meta.range(at: 2))] = decodeHTMLEntities(nsBody.substring(with: meta.range(at: 1)))
            }
            guard let text = metadata["articleBody"]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let dateText = metadata["datePublished"], let date = iso.date(from: dateText) else { continue }
            let canonicalURL = "https://x.com/thsottiaux/status/\(id)"
            posts.append(TiboPost(id: id, text: text, publishedAt: date, url: canonicalURL))
        }
        return posts.sorted { $0.publishedAt > $1.publishedAt }.prefix(8).map { $0 }
    }

    private func handle(posts: [TiboPost], forceAnalysis: Bool,
                        completion: @escaping (TiboActivitySnapshot) -> Void) {
        let canonical = "tibo-reset-radar-v4\n" + posts.map { "\($0.id)|\(Int($0.publishedAt.timeIntervalSince1970))|\($0.text)" }.joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let configuration = AIConfigurationStore.shared.load()
        guard configuration.isConfigured else {
            snapshot.checkedAt = Date()
            snapshot.status = "missing-configuration"
            save()
            finish(completion)
            return
        }
        if !forceAnalysis, fingerprint == snapshot.fingerprint, snapshot.analyzedAt != nil {
            snapshot.checkedAt = Date()
            snapshot.status = "current"
            save()
            finish(completion)
            return
        }
        analyze(posts: posts, configuration: configuration) { result in
            self.queue.async {
                switch result {
                case .success(let digest):
                    self.snapshot = TiboActivitySnapshot(
                        fingerprint: fingerprint,
                        headline: limitedText(digest.headline, maximum: 14),
                        summary: limitedText(digest.summary, maximum: 66),
                        latestPostAt: posts.first?.publishedAt,
                        analyzedAt: Date(), checkedAt: Date(),
                        sourceURL: posts.first?.url ?? self.profileURL.absoluteString,
                        status: "current",
                        activityState: limitedText(digest.state, maximum: 5)
                    )
                case .failure:
                    self.snapshot.checkedAt = Date()
                    self.snapshot.status = self.snapshot.analyzedAt == nil ? "analysis-error" : "stale"
                }
                self.save()
                self.finish(completion)
            }
        }
    }

    private func analyze(posts: [TiboPost], configuration: AIServiceConfiguration,
                         completion: @escaping (Result<AIActivityDigest, Error>) -> Void) {
        let formatter = ISO8601DateFormatter()
        let source = posts.enumerated().map { index, post in
            "[\(index + 1)] \(formatter.string(from: post.publishedAt))\n\(post.text)\n\(post.url)"
        }.joined(separator: "\n\n")
        let system = """
        你是“Codex 重置之神 Tibo”的公开动态观察员。只根据给出的帖子工作，并遵循以下优先级：
        1. 首要寻找 Codex 用量额度、rate limit、reset、重置窗口、reset card、reset credit、订阅用量恢复等信息。只要存在，就必须放在标题和摘要首句，并写清帖子日期；不得把旧消息说成刚发生。
        2. 如果没有发现这类信息，标题直接说明“暂无新的 Reset 消息”，不要自行猜测。
        3. 其他 Codex 产品、模型或团队动态最多用一句话简要概括。
        根据最近几条帖子推断一个不超过5个汉字的即时状态，例如“要重置”“在修Bug”“忙发布”“看反馈”；这是对公开工作动态的轻量判断，不得推断位置、作息或私人生活。
        不使用营销腔；不得在结果中出现“帖子1”“帖子7”之类的内部编号。只输出 JSON，不要 Markdown：{"state":"不超过5个汉字","headline":"不超过14个汉字","summary":"1到2句，不超过66个汉字"}。输出前自行检查长度，超出必须压缩。
        """
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "以下按发布时间从新到旧排列：\n\n\(source)"]
            ],
            "temperature": 0.2,
            "max_tokens": 180,
            "stream": false
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        guard let endpoint = OpenAICompatibleEndpoint.url(baseURL: configuration.baseURL,
                                                          operation: "chat/completions") else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let contentData = extractedJSONObject(from: content)?.data(using: .utf8),
                  let digest = try? JSONDecoder().decode(AIActivityDigest.self, from: contentData),
                  !digest.state.isEmpty, !digest.headline.isEmpty, !digest.summary.isEmpty else {
                completion(.failure(MonitorError.analysisFailed)); return
            }
            completion(.success(digest))
        }.resume()
    }

    private func finish(_ completion: @escaping (TiboActivitySnapshot) -> Void) {
        running = false
        let value = snapshot
        let pending = pendingForcedCompletion
        pendingForcedCompletion = nil
        DispatchQueue.main.async { completion(value) }
        if let pending { check(forceAnalysis: true, completion: pending) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private enum MonitorError: Error {
    case invalidResponse, noPosts, staleTimeline, invalidRequest, analysisFailed
}

private func decodeHTMLEntities(_ text: String) -> String {
    var decoded = text
        .replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&quot;", with: "\"")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&#x27;", with: "'")
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&nbsp;", with: " ")
    guard let numeric = try? NSRegularExpression(pattern: #"&#(x?[0-9A-Fa-f]+);"#) else { return decoded }
    let matches = numeric.matches(in: decoded, range: NSRange(decoded.startIndex..., in: decoded)).reversed()
    for match in matches {
        guard let whole = Range(match.range(at: 0), in: decoded), let valueRange = Range(match.range(at: 1), in: decoded) else { continue }
        let raw = String(decoded[valueRange])
        let number = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw, radix: 10)
        if let number, let scalar = UnicodeScalar(number) { decoded.replaceSubrange(whole, with: String(scalar)) }
    }
    return decoded
}

private func stripHTML(_ html: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: #"<[^>]+>"#) else { return decodeHTMLEntities(html) }
    let range = NSRange(html.startIndex..., in: html)
    return decodeHTMLEntities(regex.stringByReplacingMatches(in: html, range: range, withTemplate: ""))
}

private func dateFromSnowflake(_ id: String) -> Date? {
    guard let snowflake = Int64(id) else { return nil }
    let milliseconds = (snowflake >> 22) + 1_288_834_974_657
    return Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
}

private func limitedText(_ text: String, maximum: Int) -> String {
    let normalized = text
        .replacingOccurrences(of: "\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard normalized.count > maximum else { return normalized }
    return String(normalized.prefix(maximum - 1)) + "…"
}

private func extractedJSONObject(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return trimmed }
    guard let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start < end else { return nil }
    return String(trimmed[start...end])
}
