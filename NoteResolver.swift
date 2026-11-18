import Foundation

enum NoteResolver {
    static func resolve(_ text: String) async throws -> Note {
        let original = try NetworkPolicy.shareLink(in: text)
        let (html, final) = try await Network.page(original)
        // A long URL's note ID remains authoritative even after an unexpected redirect.
        let identity = noteID(in: original) == nil ? final : original
        return try parse(html: html, url: identity)
    }

    static func noteID(in url: URL) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let last = parts.last, last.count == 24,
              last.range(of: "^[a-fA-F0-9]{24}$", options: .regularExpression) != nil,
              parts.contains("explore") || parts.contains("item") else { return nil }
        return last.lowercased()
    }

    // Parse a JSON-shaped assignment without executing any webpage JavaScript.
    static func stateJSON(in html: String) throws -> Data {
        guard let marker = html.range(of: #"(?:window\.)?__INITIAL_STATE__\s*=\s*"#, options: .regularExpression) else {
            throw LiveError.message("页面没有提供笔记数据，可能需要登录或验证。")
        }
        let input = Array(html[marker.upperBound...])
        var output = "", quoted = false, escaped = false, depth = 0, started = false, i = 0
        while i < input.count {
            let c = input[i]
            if quoted {
                output.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if c == "\"" { quoted = false }
            } else if c == "\"" { quoted = true; output.append(c) }
            else if c == "{" { depth += 1; started = true; output.append(c) }
            else if c == "}" {
                depth -= 1; output.append(c)
                if started && depth == 0 { return Data(output.utf8) }
            } else if c == "u", String(input[i..<min(i + 9, input.count)]) == "undefined" {
                output += "null"; i += 8
            } else { output.append(c) }
            i += 1
        }
        throw LiveError.message("笔记数据不完整，未开始保存。")
    }

    static func parse(html: String, url: URL) throws -> Note {
        guard NetworkPolicy.allows(url), let id = noteID(in: url),
              let state = try JSONSerialization.jsonObject(with: stateJSON(in: html)) as? [String: Any] else {
            throw LiveError.message("无法定位具体笔记。")
        }
        var candidates: [[String: Any]] = []
        if let note = state["note"] as? [String: Any], let map = note["noteDetailMap"] as? [String: Any] {
            candidates += map.values.compactMap { ($0 as? [String: Any])?["note"] as? [String: Any] }
        }
        if let a = state["noteData"] as? [String: Any], let b = a["data"] as? [String: Any], let c = b["noteData"] as? [String: Any] { candidates.append(c) }
        guard let note = candidates.first(where: { (($0["noteId"] ?? $0["id"]) as? String)?.lowercased() == id }) else {
            throw LiveError.message("网页数据与目标笔记不一致，未下载推荐笔记。")
        }
        var items: [MediaItem] = []
        if note["type"] as? String != "video" {
            for (index, item) in (note["imageList"] as? [[String: Any]] ?? []).enumerated() {
                var key = item["fileId"] as? String
                if key == nil, let raw = (item["urlDefault"] ?? item["url"]) as? String,
                   let web = try? NetworkPolicy.secure(raw, media: true), web.host?.hasPrefix("sns-webpic-") == true {
                    let parts = web.path.split(separator: "/")
                    if parts.count >= 3 { key = parts.dropFirst(2).joined(separator: "/").components(separatedBy: "!").first }
                }
                let picture = try key.map { try origin($0, video: false) }
                let motion = try video(in: item)
                items.append(MediaItem(id: index + 1, image: picture, video: motion?.0,
                                       isLive: (item["livePhoto"] as? Bool) == true, webVideo: motion?.1 ?? false))
            }
        }
        if let v = note["video"] as? [String: Any], let movie = try video(in: v) {
            items.append(MediaItem(id: items.count + 1, image: nil, video: movie.0, isLive: false, webVideo: movie.1))
        }
        guard !items.isEmpty else { throw LiveError.message("这篇笔记没有可识别的媒体。") }
        return Note(id: id, title: note["title"] as? String ?? "小红书笔记", items: items)
    }

    static func origin(_ key: String, video: Bool) throws -> URL {
        guard !key.isEmpty, !key.contains(".."), !key.contains("?"), !key.contains("#"), !key.contains("\\") else {
            throw LiveError.message("媒体源标识格式异常。")
        }
        return try NetworkPolicy.secure("https://\(video ? "sns-video-bd" : "sns-img-bd").xhscdn.com/" + key.trimmingCharacters(in: CharacterSet(charactersIn: "/")), media: true)
    }

    private static func video(in item: [String: Any]) throws -> (URL, Bool)? {
        if let consumer = item["consumer"] as? [String: Any], let key = consumer["originVideoKey"] as? String, !key.isEmpty {
            return (try origin(key, video: true), false)
        }
        let media = item["media"] as? [String: Any]
        let streams = (item["stream"] ?? media?["stream"]) as? [String: Any] ?? [:]
        let entries = streams.values.flatMap { $0 as? [[String: Any]] ?? [] }.sorted {
            func n(_ d: [String: Any], _ k: String) -> Double { (d[k] as? NSNumber)?.doubleValue ?? 0 }
            let lhs = n($0, "width") * n($0, "height"), rhs = n($1, "width") * n($1, "height")
            return lhs == rhs ? n($0, "videoBitrate") > n($1, "videoBitrate") : lhs > rhs
        }
        guard let entry = entries.first, let raw = entry["masterUrl"] as? String else { return nil }
        return (try NetworkPolicy.secure(raw, media: true), true)
    }
}
