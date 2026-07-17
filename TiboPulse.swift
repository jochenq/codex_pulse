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

    static func empty() -> TiboActivitySnapshot {
        TiboActivitySnapshot(
            fingerprint: "", headline: "正在获取公开动态", summary: "首次分析完成后会显示在这里。",
            latestPostAt: nil, analyzedAt: nil, checkedAt: .distantPast,
            sourceURL: "https://x.com/thsottiaux", status: "loading"
        )
    }
}

private struct TiboPost {
    let id: String
    let text: String
    let publishedAt: Date
    let url: String
}

private struct DeepSeekDigest: Decodable {
    let headline: String
    let summary: String
}

final class TiboMonitor {
    private let profileURL = URL(string: "https://x.com/thsottiaux")!
    private let deepSeekURL = URL(string: "https://api.deepseek.com/chat/completions")!
    private let queue = DispatchQueue(label: "com.codexpulse.tibo-monitor", qos: .utility)
    private let session: URLSession
    private let cacheURL: URL
    private var running = false
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

    func check(completion: @escaping (TiboActivitySnapshot) -> Void) {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.fetchPosts { result in
                self.queue.async {
                    switch result {
                    case .success(let posts): self.handle(posts: posts, completion: completion)
                    case .failure:
                        self.snapshot.checkedAt = Date()
                        self.snapshot.status = self.snapshot.analyzedAt == nil ? "fetch-error" : "stale"
                        self.save()
                        self.finish(completion)
                    }
                }
            }
        }
    }

    private func fetchPosts(completion: @escaping (Result<[TiboPost], Error>) -> Void) {
        var request = URLRequest(url: profileURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let data, let html = String(data: data, encoding: .utf8) else {
                completion(.failure(MonitorError.invalidResponse)); return
            }
            let posts = self.parsePosts(html)
            guard !posts.isEmpty else { completion(.failure(MonitorError.noPosts)); return }
            completion(.success(posts))
        }.resume()
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

    private func handle(posts: [TiboPost], completion: @escaping (TiboActivitySnapshot) -> Void) {
        let canonical = posts.map { "\($0.id)|\(Int($0.publishedAt.timeIntervalSince1970))|\($0.text)" }.joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        if fingerprint == snapshot.fingerprint, snapshot.analyzedAt != nil {
            snapshot.checkedAt = Date()
            snapshot.status = "current"
            save()
            finish(completion)
            return
        }
        guard let key = ProcessInfo.processInfo.environment["DEEPSEEK_API_KEY"], !key.isEmpty else {
            snapshot.checkedAt = Date()
            snapshot.status = "missing-key"
            save()
            finish(completion)
            return
        }
        analyze(posts: posts, apiKey: key) { result in
            self.queue.async {
                switch result {
                case .success(let digest):
                    self.snapshot = TiboActivitySnapshot(
                        fingerprint: fingerprint,
                        headline: digest.headline.trimmingCharacters(in: .whitespacesAndNewlines),
                        summary: digest.summary.trimmingCharacters(in: .whitespacesAndNewlines),
                        latestPostAt: posts.first?.publishedAt,
                        analyzedAt: Date(), checkedAt: Date(),
                        sourceURL: posts.first?.url ?? self.profileURL.absoluteString,
                        status: "current"
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

    private func analyze(posts: [TiboPost], apiKey: String, completion: @escaping (Result<DeepSeekDigest, Error>) -> Void) {
        let formatter = ISO8601DateFormatter()
        let source = posts.enumerated().map { index, post in
            "[\(index + 1)] \(formatter.string(from: post.publishedAt))\n\(post.text)\n\(post.url)"
        }.joined(separator: "\n\n")
        let system = """
        你是一个事实严谨的公开动态摘要助手。只根据给出的帖子总结 Tibo 最近在关注或推进什么，不推测位置、睡眠、私人生活或未公开信息。使用简体中文，信息密度高，不要营销腔。只输出 JSON：{"headline":"不超过18字的标题","summary":"2到3句、总计不超过100字的摘要"}。
        """
        let body: [String: Any] = [
            "model": "deepseek-v4-flash",
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "以下按发布时间从新到旧排列：\n\n\(source)"]
            ],
            "thinking": ["type": "disabled"],
            "response_format": ["type": "json_object"],
            "temperature": 0.2,
            "max_tokens": 260,
            "stream": false
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        var request = URLRequest(url: deepSeekURL, timeoutInterval: 35)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let content = message["content"] as? String,
                  let contentData = content.data(using: .utf8),
                  let digest = try? JSONDecoder().decode(DeepSeekDigest.self, from: contentData),
                  !digest.headline.isEmpty, !digest.summary.isEmpty else {
                completion(.failure(MonitorError.analysisFailed)); return
            }
            completion(.success(digest))
        }.resume()
    }

    private func finish(_ completion: @escaping (TiboActivitySnapshot) -> Void) {
        running = false
        let value = snapshot
        DispatchQueue.main.async { completion(value) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }
}

private enum MonitorError: Error {
    case invalidResponse, noPosts, invalidRequest, analysisFailed
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
