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
    var inferredLocation: String?
    var timeZoneIdentifier: String?
    var locationIsInferred: Bool?
    var avatarURL: String?
    var latestReplyText: String?
    var latestReplyAt: Date?
    var latestReplyURL: String?

    static func empty() -> TiboActivitySnapshot {
        TiboActivitySnapshot(
            fingerprint: "", headline: "正在获取公开动态", summary: "首次分析完成后会显示在这里。",
            latestPostAt: nil, analyzedAt: nil, checkedAt: .distantPast,
            sourceURL: "https://x.com/thsottiaux", status: "loading", activityState: nil,
            inferredLocation: nil, timeZoneIdentifier: nil, locationIsInferred: nil, avatarURL: nil,
            latestReplyText: nil, latestReplyAt: nil, latestReplyURL: nil
        )
    }
}

private struct TiboPost {
    let id: String
    let text: String
    let publishedAt: Date
    let url: String
    let avatarURL: String?
    let isReply: Bool
}

private struct AIActivityDigest: Decodable {
    let headline: String
    let summary: String
    let activityState: String?
    let location: String?
    let timeZone: String?
    let locationMode: String?
}

final class TiboMonitor {
    private let profileURL = URL(string: "https://x.com/thsottiaux")!
    private let liveMirrorURL = URL(string: "https://r.jina.ai/http://twstalker.com/thsottiaux")!
    private let repliesMirrorURL = URL(string: "https://r.jina.ai/https://xcancel.com/thsottiaux/with_replies")!
    // Jina's anonymous mirror can be unavailable or rate-limited. Keep direct
    // xcancel endpoints as a parser-compatible fallback instead of treating a
    // temporary proxy failure as an empty timeline.
    private let directTimelineURL = URL(string: "https://xcancel.com/thsottiaux")!
    private let directRepliesURL = URL(string: "https://xcancel.com/thsottiaux/with_replies")!
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
        config.timeoutIntervalForResource = 75
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
        let group = DispatchGroup()
        var primaryResult: Result<[TiboPost], Error>?
        var replies: [TiboPost] = []
        group.enter()
        fetchPrimaryPosts { result in
            self.queue.async { primaryResult = result; group.leave() }
        }
        group.enter()
        fetchReplies { result in
            self.queue.async { replies = result; group.leave() }
        }
        group.notify(queue: queue) {
            let primary: [TiboPost]
            if case .success(let posts)? = primaryResult { primary = posts } else { primary = [] }
            let merged = self.mergedPosts(primary + replies)
            if self.isFresh(merged) { completion(.success(merged)) }
            else { completion(.failure(MonitorError.staleTimeline)) }
        }
    }

    private func fetchPrimaryPosts(completion: @escaping (Result<[TiboPost], Error>) -> Void) {
        let group = DispatchGroup()
        var collected: [TiboPost] = []
        func fetch(_ url: URL, parser: @escaping (String) -> [TiboPost]) {
            group.enter()
            fetchPage(url) { result in
                self.queue.async {
                    if case .success(let body) = result {
                        collected.append(contentsOf: parser(body))
                    }
                    group.leave()
                }
            }
        }
        // Query every usable public representation. Parsers only emit records
        // with a stable status ID and a verifiable timestamp; merge by ID later.
        fetch(liveMirrorURL, parser: parseLiveMirrorPosts)
        fetch(directTimelineURL, parser: parseXCancelPosts)
        fetch(syndicationURL, parser: parseSyndicatedPosts)
        fetch(profileURL, parser: parsePosts)
        group.notify(queue: queue) {
            let posts = self.mergedPosts(collected)
            if self.isFresh(posts) { completion(.success(posts)) }
            else { completion(.failure(MonitorError.staleTimeline)) }
        }
    }

    private func fetchReplies(completion: @escaping ([TiboPost]) -> Void) {
        fetchPage(repliesMirrorURL) { result in
            if case .success(let markdown) = result {
                let posts = self.parseReplyPosts(markdown)
                if !posts.isEmpty { completion(posts); return }
            }
            self.fetchPage(self.directRepliesURL) { direct in
                guard case .success(let html) = direct else { completion([]); return }
                completion(self.parseXCancelPosts(html))
            }
        }
    }

    private func fetchPage(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        if url == liveMirrorURL { request.setValue("html", forHTTPHeaderField: "X-Return-Format") }
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
        let avatarURL = firstTiboAvatarURL(in: html)
        for match in matches {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted, let date = dateFromSnowflake(id) else { continue }
            let body = nsHTML.substring(with: match.range(at: 2))
            let text = stripHTML(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            posts.append(TiboPost(id: id, text: text, publishedAt: date,
                                  url: "https://x.com/thsottiaux/status/\(id)", avatarURL: avatarURL, isReply: false))
        }
        let sorted = posts.sorted { $0.publishedAt > $1.publishedAt }
        let substantive = sorted.filter { !$0.text.hasPrefix("@") }
        let replies = sorted.filter { $0.text.hasPrefix("@") }
        return (substantive + replies).sorted { $0.publishedAt > $1.publishedAt }
    }

    private func parseReplyPosts(_ markdown: String) -> [TiboPost] {
        let statusPrefix = "[](https://xcancel.com/thsottiaux/status/"
        var currentID: String?
        var waitingForBody = false
        var posts: [TiboPost] = []
        var seen = Set<String>()
        for rawLine in markdown.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix(statusPrefix), let end = line.range(of: "#m)") {
                let start = line.index(line.startIndex, offsetBy: statusPrefix.count)
                let id = String(line[start..<end.lowerBound])
                currentID = id.allSatisfy(\.isNumber) ? id : nil
                waitingForBody = false
                continue
            }
            if line.hasPrefix("Replying to ") {
                waitingForBody = currentID != nil
                continue
            }
            guard waitingForBody, !line.isEmpty, let id = currentID,
                  seen.insert(id).inserted, let date = dateFromSnowflake(id) else { continue }
            posts.append(TiboPost(
                id: id, text: "回复：\(line)", publishedAt: date,
                url: "https://x.com/thsottiaux/status/\(id)",
                avatarURL: "https://pbs.twimg.com/profile_images/2075819673263001600/pj1vyX6I.jpg",
                isReply: true
            ))
            waitingForBody = false
        }
        return posts.sorted { $0.publishedAt > $1.publishedAt }
    }

    /// Parse the current xcancel HTML layout. Unlike the old Jina markdown
    /// representation, direct xcancel pages expose each post as a timeline
    /// item with a stable status link and tweet-content node.
    private func parseXCancelPosts(_ html: String) -> [TiboPost] {
        guard let regex = try? NSRegularExpression(
            pattern: #"<a class=\"tweet-link\" href=\"/thsottiaux/status/(\d+)#m\"></a>(.*?<div class=\"tweet-content media-body\"[^>]*>(.*?)</div>)"#,
            options: [.dotMatchesLineSeparators]
        ) else { return [] }
        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        let avatarURL = firstTiboAvatarURL(in: html)
        var seen = Set<String>()
        var posts: [TiboPost] = []
        for match in matches {
            let id = nsHTML.substring(with: match.range(at: 1))
            guard seen.insert(id).inserted, let date = dateFromSnowflake(id) else { continue }
            let context = nsHTML.substring(with: match.range(at: 2))
            let body = nsHTML.substring(with: match.range(at: 3))
            let text = stripHTML(body).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            posts.append(TiboPost(
                id: id,
                text: text,
                publishedAt: date,
                url: "https://x.com/thsottiaux/status/\(id)",
                avatarURL: avatarURL,
                isReply: context.contains("class=\"replying-to\"")
            ))
        }
        let sorted = posts.sorted { $0.publishedAt > $1.publishedAt }
        let substantive = sorted.filter { !$0.isReply }
        let replies = sorted.filter(\.isReply)
        return (substantive + replies).sorted { $0.publishedAt > $1.publishedAt }
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
            let user = tweet["user"] as? [String: Any]
            let avatarURL = user?["profile_image_url_https"] as? String ?? firstTiboAvatarURL(in: html)
            posts.append(TiboPost(id: id, text: text, publishedAt: date,
                                  url: "https://x.com/thsottiaux/status/\(id)", avatarURL: avatarURL, isReply: false))
        }
        return posts.sorted { $0.publishedAt > $1.publishedAt }
    }

    private func isFresh(_ posts: [TiboPost]) -> Bool {
        guard let newest = posts.map(\.publishedAt).max() else { return false }
        let age = Date().timeIntervalSince(newest)
        return age >= -5 * 60 && age < 14 * 24 * 60 * 60
    }

    private func mergedPosts(_ posts: [TiboPost]) -> [TiboPost] {
        var byID: [String: TiboPost] = [:]
        for candidate in posts {
            guard let current = byID[candidate.id] else {
                byID[candidate.id] = candidate
                continue
            }
            if candidate.isReply != current.isReply {
                if candidate.isReply { byID[candidate.id] = candidate }
            } else if candidate.text.count > current.text.count
                        || (candidate.text.count == current.text.count && candidate.text < current.text) {
                byID[candidate.id] = candidate
            }
        }
        return byID.values.sorted {
            if $0.publishedAt != $1.publishedAt { return $0.publishedAt > $1.publishedAt }
            return $0.id > $1.id
        }
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
            guard let text = (metadata["articleBody"] ?? metadata["text"])?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
                  let dateText = metadata["datePublished"], let date = parseISO8601Date(dateText, formatter: iso) else { continue }
            let canonicalURL = "https://x.com/thsottiaux/status/\(id)"
            posts.append(TiboPost(id: id, text: text, publishedAt: date,
                                  url: canonicalURL, avatarURL: firstTiboAvatarURL(in: html), isReply: false))
        }
        return posts.sorted { $0.publishedAt > $1.publishedAt }
    }

    private func handle(posts: [TiboPost], forceAnalysis: Bool,
                        completion: @escaping (TiboActivitySnapshot) -> Void) {
        let canonical = "tibo-evidence-v7\n" + posts.map {
            "\($0.id)|\($0.isReply)|\($0.publishedAt.timeIntervalSince1970)|\($0.text)"
        }.joined(separator: "\n")
        let fingerprint = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let latestReply = posts.first(where: \.isReply)
        let configuration = AIConfigurationStore.shared.load()
        guard configuration.isConfigured else {
            snapshot.checkedAt = Date()
            snapshot.status = "missing-configuration"
            save()
            finish(completion)
            return
        }
        if !forceAnalysis, fingerprint == snapshot.fingerprint, snapshot.analyzedAt != nil,
           latestReply?.url == snapshot.latestReplyURL {
            snapshot.checkedAt = Date()
            if ["stale", "fetch-error", "source-stale"].contains(snapshot.status) {
                snapshot.status = "current"
            }
            save()
            finish(completion)
            return
        }
        analyze(posts: posts, configuration: configuration) { result in
            self.queue.async {
                let digest: AIActivityDigest
                let status: String
                switch result {
                case .success(let value):
                    digest = value
                    status = "current"
                case .failure:
                    // Keep fresh source data visible if a provider is
                    // temporarily unavailable or truncates its response.
                    digest = self.fallbackDigest(posts: posts)
                    status = "current-fallback"
                }
                self.apply(digest: digest, status: status, posts: posts,
                           fingerprint: fingerprint, latestReply: latestReply)
                self.save()
                self.finish(completion)
            }
        }
    }

    private func apply(digest: AIActivityDigest, status: String, posts: [TiboPost],
                       fingerprint: String, latestReply: TiboPost?) {
        let proposedTimeZone = digest.timeZone.flatMap(TimeZone.init(identifier:))
        let hasLocationEvidence = digest.locationMode == "inferred"
            && proposedTimeZone != nil
            && digest.location?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        snapshot = TiboActivitySnapshot(
            fingerprint: fingerprint,
            headline: normalizedTiboHeadline(digest.headline),
            summary: limitedText(digest.summary, maximum: 66),
            latestPostAt: posts.first?.publishedAt,
            analyzedAt: Date(), checkedAt: Date(),
            sourceURL: posts.first?.url ?? profileURL.absoluteString,
            status: status,
            activityState: normalizedActivityState(digest.activityState),
            inferredLocation: hasLocationEvidence ? limitedText(digest.location!, maximum: 12) : nil,
            timeZoneIdentifier: hasLocationEvidence ? proposedTimeZone!.identifier : nil,
            locationIsInferred: hasLocationEvidence ? true : nil,
            avatarURL: posts.compactMap(\.avatarURL).first ?? snapshot.avatarURL
                ?? "https://pbs.twimg.com/profile_images/2075819673263001600/pj1vyX6I.jpg",
            latestReplyText: latestReply.map { replyDisplayText($0.text) },
            latestReplyAt: latestReply?.publishedAt,
            latestReplyURL: latestReply?.url
        )
    }

    private func fallbackDigest(posts: [TiboPost]) -> AIActivityDigest {
        let post = posts.first(where: { !$0.isReply }) ?? posts[0]
        let firstLine = post.text.components(separatedBy: .newlines).first ?? post.text
        return AIActivityDigest(
            headline: limitedText("新帖：\(firstLine)", maximum: 14),
            summary: limitedText(post.text, maximum: 66),
            activityState: nil,
            location: nil,
            timeZone: nil,
            locationMode: "unknown"
        )
    }

    private func analyze(posts: [TiboPost], configuration: AIServiceConfiguration,
                         completion: @escaping (Result<AIActivityDigest, Error>) -> Void) {
        let formatter = ISO8601DateFormatter()
        let evidence: [[String: Any]] = posts.map { post in
            [
                "post_id": post.id,
                "kind": post.isReply ? "reply" : "post",
                "published_at_utc": formatter.string(from: post.publishedAt),
                "text": post.text,
                "url": post.url
            ]
        }
        guard let evidenceData = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]),
              let source = String(data: evidenceData, encoding: .utf8) else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        let system = """
        你是“Tibo 公开动态分析员”。输入是客户端取得并校验过的全部可用事实：帖子 ID、类型、UTC 发布时间、完整正文和原帖链接。你只能根据这些事实判断，不得补充背景知识，不得把推测写成事实。

        分析规则：
        1. 先按真实发布时间判断新旧。优先概括最新且信息量最高的动态；回复与主帖具有同等证据地位。
        2. 重点识别 Codex 用量额度、rate limit、reset、重置窗口、reset card、reset credit 或订阅用量恢复。只有正文明确涉及这些内容才能判定存在 Reset 消息，并必须在摘要中写清其真实日期。旧 Reset 消息不能描述为刚刚发生，也不能压过明显更新且更重要的动态。
        3. activityState 是对“Tibo 最近在干什么”的五个汉字以内结论。只能根据帖子正文、帖子类型、发布时间和当前 UTC 时间谨慎判断；证据不足必须输出“状态未知”，禁止仅按当地钟点猜测“工作、睡觉、休息”。
        4. 只有帖子正文明确提供所在地、行程或当地活动证据时，才能输出粗粒度 location 和合法 IANA timeZone，并令 locationMode="inferred"；否则三个字段分别输出 null、null、"unknown"。禁止默认旧金山湾区，禁止推断精确地址。
        5. 不使用营销腔，不出现内部序号。headline 不超过14个汉字；summary 为1到2句、不超过66个汉字。

        只输出 JSON，不要 Markdown：{"headline":"...","summary":"...","activityState":"五字以内或状态未知","location":null,"timeZone":null,"locationMode":"unknown或inferred"}。输出前检查事实、日期和长度。
        """
        let body: [String: Any] = [
            "model": configuration.model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": "当前 UTC 时间：\(formatter.string(from: Date()))\n以下 JSON 数组按发布时间从新到旧排列：\n\n\(source)"]
            ],
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            // Compatible reasoning models count hidden reasoning toward this
            // limit. Leave enough room for reasoning plus the short JSON result;
            // content fingerprints prevent unchanged posts from spending it.
            "max_tokens": 4096,
            "stream": false
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: body) else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        guard let endpoint = OpenAICompatibleEndpoint.url(baseURL: configuration.baseURL,
                                                          operation: "chat/completions") else {
            completion(.failure(MonitorError.invalidRequest)); return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = json
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !configuration.apiKey.isEmpty {
            request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        }
        session.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data else {
                completion(.failure(MonitorError.analysisFailed)); return
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any] else {
                completion(.failure(MonitorError.analysisFailed)); return
            }
            // Reasoning-capable compatible models may put the final answer in
            // `reasoning_content` while leaving `content` empty. Accept both
            // shapes so a provider-specific response format cannot freeze the
            // dynamic card on its previous summary.
            let content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let reasoning = (message["reasoning_content"] as? String)
                ?? (message["reasoning"] as? String)
                ?? ""
            let output = content.isEmpty ? reasoning : content
            let extracted = extractedJSONObject(from: output)
            guard let contentData = extracted?.data(using: .utf8),
                  let digest = try? JSONDecoder().decode(AIActivityDigest.self, from: contentData),
                  !digest.headline.isEmpty, !digest.summary.isEmpty else {
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

private func firstTiboAvatarURL(in text: String) -> String? {
    guard let regex = try? NSRegularExpression(
        pattern: #"https://pbs\.twimg\.com/profile_images/[A-Za-z0-9_./-]+"#
    ), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
       let range = Range(match.range, in: text) else { return nil }
    return String(text[range]).replacingOccurrences(of: "_normal.", with: ".")
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

private func parseISO8601Date(_ value: String, formatter: ISO8601DateFormatter) -> Date? {
    if let date = formatter.date(from: value) { return date }
    let fallback = ISO8601DateFormatter()
    fallback.formatOptions = [.withInternetDateTime]
    return fallback.date(from: value)
}

private func limitedText(_ text: String, maximum: Int) -> String {
    let normalized = text
        .replacingOccurrences(of: "\n", with: " ")
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
    guard normalized.count > maximum else { return normalized }
    return String(normalized.prefix(maximum - 1)) + "…"
}

private func replyDisplayText(_ text: String) -> String {
    let prefix = "回复："
    let value = text.hasPrefix(prefix) ? String(text.dropFirst(prefix.count)) : text
    return limitedText(value, maximum: 48)
}

private func normalizedTiboHeadline(_ value: String) -> String {
    let text = limitedText(value, maximum: 14)
    let lowered = text.lowercased()
    if lowered.contains("reset") && (text.contains("暂无") || text.contains("没有") || text.contains("无新")) {
        return "近期公开动态"
    }
    return text
}

private func normalizedActivityState(_ value: String?) -> String {
    guard let value else { return "状态未知" }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return "状态未知" }
    return limitedText(normalized, maximum: 5)
}

private func extractedJSONObject(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") { return trimmed }
    // Reasoning models can mention an intermediate JSON example before their
    // final answer. Select the object nearest the end of the response so that
    // an earlier example cannot make an otherwise valid response fail decode.
    guard let end = trimmed.lastIndex(of: "}"),
          let start = trimmed[..<end].lastIndex(of: "{"), start < end else { return nil }
    return String(trimmed[start...end])
}
