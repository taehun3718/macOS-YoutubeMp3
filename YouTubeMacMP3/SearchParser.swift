import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum SearchFailure: LocalizedError {
    case invalidQuery
    case invalidResponse(Int)
    case unsupportedPage
    case invalidJSON
    case noVideos
    case diagnostic(String)
    var errorDescription: String? {
        switch self {
        case .invalidQuery: return "검색어를 입력하세요."
        case .invalidResponse(let status): return "YouTube 검색 요청에 실패했습니다. HTTP \(status)"
        case .unsupportedPage: return "YouTube 검색 데이터가 없습니다. 로그인/동의 화면이거나 페이지 구조가 달라졌을 수 있습니다."
        case .invalidJSON: return "YouTube 검색 데이터 형식이 달라 JSON을 읽지 못했습니다."
        case .noVideos: return "파싱된 검색 결과가 없습니다. 페이지 구조가 변경되었을 수 있습니다."
        case .diagnostic(let details): return details
        }
    }
}

enum SearchParser {
    // Desktop macOS Safari UA for the public search-page request only.
    // This does not change iOS networking, IP address, TLS fingerprints or cookies.
    static let macSafariUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.2 Safari/605.1.15"

    struct SearchPage {
        let videos: [Video]
        let continuation: String?
        let context: [String: Any]
        let apiKey: String?
    }

    static func search(_ term: String) async throws -> SearchPage {
        let keyword = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { throw SearchFailure.invalidQuery }

        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: keyword),
            URLQueryItem(name: "hl", value: "ko")
        ]
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        request.setValue(macSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("ko-KR,ko;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchFailure.invalidResponse(0) }
        guard (200...299).contains(http.statusCode) else { throw SearchFailure.invalidResponse(http.statusCode) }
        guard let html = String(data: data, encoding: .utf8) else { throw SearchFailure.unsupportedPage }

        let candidates = extractInitialDataCandidates(from: html)
        let diagnostic = "HTTP \(http.statusCode) · HTML \(data.count) bytes · ytInitialData=\(html.contains("ytInitialData")) · videoRenderer=\(html.contains("videoRenderer")) · lockupViewModel=\(html.contains("lockupViewModel"))"
        print("[YouTubeSearch]", diagnostic)

        // The public web page supplies these values as part of its own bootstrap.
        // This is an undocumented internal endpoint, NOT the official Data API.
        let config = extractYTCFG(from: html)
        let key = config?["INNERTUBE_API_KEY"] as? String
        let context = config?["INNERTUBE_CONTEXT"] as? [String: Any] ?? [
            "client": ["clientName": "WEB", "clientVersion": config?["INNERTUBE_CLIENT_VERSION"] as? String ?? "2.20260101.00.00", "hl": "ko"]
        ]
        for candidate in candidates {
            guard let root = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) else { continue }
            let videos = parseVideos(root)
            if !videos.isEmpty {
                let token = continuationToken(root)
                print("[YouTubeSearch] first page: \(videos.count), hasContinuation=\(token != nil), hasBootstrapKey=\(key != nil)")
                return SearchPage(videos: videos, continuation: token, context: context, apiKey: key)
            }
        }
        throw SearchFailure.diagnostic("검색 JSON에서 동영상 목록을 찾지 못했습니다. \(diagnostic)")
    }

    static func nextPage(token: String, context: [String: Any], apiKey: String?) async throws -> SearchPage {
        guard let apiKey, !apiKey.isEmpty else {
            throw SearchFailure.diagnostic("페이지 추가 로딩에 필요한 YouTube 페이지 설정을 찾지 못했습니다.")
        }
        var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/search")!
        components.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "prettyPrint", value: "false")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 25
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(macSafariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue("ko-KR,ko;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let client = context["client"] as? [String: Any] {
            if let version = client["clientVersion"] as? String {
                request.setValue(version, forHTTPHeaderField: "X-YouTube-Client-Version")
            }
            request.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["context": context, "continuation": token])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SearchFailure.invalidResponse(0) }
        guard (200...299).contains(http.statusCode) else { throw SearchFailure.invalidResponse(http.statusCode) }
        let root = try JSONSerialization.jsonObject(with: data)
        let videos = parseVideos(root)
        let next = continuationToken(root)
        print("[YouTubeSearch] continuation: \(videos.count) videos, next=\(next != nil)")
        return SearchPage(videos: videos, continuation: next, context: context, apiKey: apiKey)
    }

    static func parseVideos(_ root: Any) -> [Video] {
        var output: [Video] = []
        var seen = Set<String>()
        walk(root, output: &output, seen: &seen)
        return output
    }

    // Prefer the continuation in the search-results section, rather than
    // unrelated tokens belonging to filters or recommendations.
    static func continuationToken(_ root: Any) -> String? {
        guard let dictionary = root as? [String: Any] else { return nil }
        if let contents = dictionary["contents"] as? [String: Any],
           let search = contents["twoColumnSearchResultsRenderer"] as? [String: Any],
           let primary = search["primaryContents"] as? [String: Any],
           let section = primary["sectionListRenderer"] as? [String: Any],
           let items = section["contents"] as? [Any],
           let token = tokenInItems(items) { return token }

        for name in ["onResponseReceivedCommands", "onResponseReceivedActions", "onResponseReceivedEndpoints"] {
            if let commands = dictionary[name] as? [[String: Any]] {
                for command in commands {
                    for type in ["appendContinuationItemsAction", "reloadContinuationItemsCommand"] {
                        if let action = command[type] as? [String: Any],
                           let items = action["continuationItems"] as? [Any],
                           let token = tokenInItems(items) { return token }
                    }
                }
            }
        }
        // Legacy continuation layout.
        if let contents = dictionary["continuationContents"] as? [String: Any],
           let section = contents["itemSectionContinuation"] as? [String: Any],
           let continuations = section["continuations"] as? [[String: Any]] {
            for value in continuations {
                if let next = value["nextContinuationData"] as? [String: Any],
                   let token = next["continuation"] as? String { return token }
            }
        }
        return nil
    }

    private static func tokenInItems(_ items: [Any]) -> String? {
        for item in items.reversed() {
            guard let item = item as? [String: Any] else { continue }
            if let renderer = item["continuationItemRenderer"] as? [String: Any],
               let endpoint = renderer["continuationEndpoint"] as? [String: Any],
               let command = endpoint["continuationCommand"] as? [String: Any],
               let token = command["token"] as? String { return token }
            if let section = item["itemSectionRenderer"] as? [String: Any] {
                if let nested = section["contents"] as? [Any], let token = tokenInItems(nested) { return token }
                if let continuations = section["continuations"] as? [[String: Any]] {
                    for entry in continuations {
                        if let next = entry["nextContinuationData"] as? [String: Any],
                           let token = next["continuation"] as? String { return token }
                    }
                }
            }
        }
        return nil
    }

    // ytcfg.set({ ... }) can be embedded among arbitrary script statements.
    // Reuse the balanced brace scanner rather than a greedy regex.
    private static func extractYTCFG(from html: String) -> [String: Any]? {
        let ns = html as NSString
        let needle = "ytcfg.set("
        var start = 0
        while start < ns.length {
            let match = ns.range(of: needle, options: [], range: NSRange(location: start, length: ns.length - start))
            if match.location == NSNotFound { break }
            var i = NSMaxRange(match)
            while i < ns.length && [9, 10, 13, 32].contains(Int(ns.character(at: i))) { i += 1 }
            if i < ns.length && ns.character(at: i) == 123,
               let json = balancedJSONObject(in: ns, from: i),
               let data = json.data(using: .utf8),
               let config = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               config["INNERTUBE_API_KEY"] != nil { return config }
            start = NSMaxRange(match)
        }
        return nil
    }

    // Only match real JavaScript assignments instead of the first occurrence
    // of the word "ytInitialData" (which may occur in unrelated HTML).
    static func extractInitialDataCandidates(from html: String) -> [String] {
        let pattern = #"(?:var\s+ytInitialData|window\s*\[\s*[\"']ytInitialData[\"']\s*\]|ytInitialData)\s*=\s*"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        var results: [String] = []
        for match in matches {
            var offset = NSMaxRange(match.range)
            while offset < ns.length && [9, 10, 13, 32].contains(Int(ns.character(at: offset))) {
                offset += 1
            }
            guard offset < ns.length else { continue }
            // Most pages expose a raw JSON object; never scan forward to an
            // arbitrary '{' if the assignment actually contains another value.
            guard ns.character(at: offset) == 123 else { continue } // '{'
            guard let result = balancedJSONObject(in: ns, from: offset) else { continue }
            results.append(result)
        }
        return results
    }

    private static func balancedJSONObject(in value: NSString, from start: Int) -> String? {
        var depth = 0
        var inString = false
        var escaping = false
        for i in start..<value.length {
            let c = value.character(at: i)
            if inString {
                if escaping { escaping = false }
                else if c == 92 { escaping = true } // backslash
                else if c == 34 { inString = false } // quote
            } else {
                if c == 34 { inString = true }
                else if c == 123 { depth += 1 }
                else if c == 125 {
                    depth -= 1
                    if depth == 0 {
                        return value.substring(with: NSRange(location: start, length: i - start + 1))
                    }
                }
            }
        }
        return nil
    }

    private static func walk(_ value: Any, output: inout [Video], seen: inout Set<String>) {
        if let object = value as? [String: Any] {
            if let renderer = (object["videoRenderer"] ?? object["gridVideoRenderer"] ?? object["compactVideoRenderer"]) as? [String: Any],
               let id = renderer["videoId"] as? String,
               id.count == 11, !seen.contains(id) {
                seen.insert(id)
                let title = text(renderer["title"])
                let channel = text(renderer["ownerText"])
                let duration = text(renderer["lengthText"])
                let thumbnails = (renderer["thumbnail"] as? [String: Any])?["thumbnails"] as? [[String: Any]]
                let thumbnail = (thumbnails?.last?["url"] as? String).flatMap(URL.init(string:))
                output.append(Video(id: id, title: title.isEmpty ? "제목 없음" : title,
                                    channel: channel, duration: duration, thumbnail: thumbnail))
            }
            if let lockup = object["lockupViewModel"] as? [String: Any],
               let id = lockup["contentId"] as? String,
               id.count == 11, !seen.contains(id) {
                let metadata = lockup["metadata"] as? [String: Any] ?? [:]
                let lockupMetadata = metadata["lockupMetadataViewModel"] as? [String: Any] ?? [:]
                let titleInfo = lockupMetadata["title"] as? [String: Any] ?? [:]
                let title = titleInfo["content"] as? String ?? "제목 없음"
                let image = lockup["contentImage"] as? [String: Any] ?? [:]
                let thumbnailView = image["thumbnailViewModel"] as? [String: Any] ?? [:]
                let imageData = thumbnailView["image"] as? [String: Any] ?? [:]
                let sources = imageData["sources"] as? [[String: Any]] ?? []
                let thumbnail = sources.last.flatMap { $0["url"] as? String }.flatMap(URL.init(string:))
                let rows = (lockupMetadata["metadata"] as? [String: Any])?["contentMetadataViewModel"] as? [String: Any] ?? [:]
                let metadataRows = rows["metadataRows"] as? [[String: Any]] ?? []
                var labels: [String] = []
                for row in metadataRows {
                    for part in (row["metadataParts"] as? [[String: Any]] ?? []) {
                        if let txt = (part["text"] as? [String: Any])?["content"] as? String { labels.append(txt) }
                    }
                }
                seen.insert(id)
                output.append(Video(id: id, title: title, channel: labels.first ?? "", duration: "", thumbnail: thumbnail))
            }
            for nested in object.values { walk(nested, output: &output, seen: &seen) }
        } else if let array = value as? [Any] {
            for nested in array { walk(nested, output: &output, seen: &seen) }
        }
    }

    private static func text(_ value: Any?) -> String {
        guard let object = value as? [String: Any] else { return "" }
        if let simple = object["simpleText"] as? String { return simple }
        if let runs = object["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }
}
