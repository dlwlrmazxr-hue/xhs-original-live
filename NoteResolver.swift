import Foundation

enum NoteResolver {
    static func resolve(_ text: String) async throws -> Note {
        let original = try NetworkPolicy.shareLink(in: text)
        if MediaPlatform.identify(original) != .xhs { return try await SocialResolver.resolve(original) }
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

// Platform parsers only accept media belonging to the requested post identity.
// No global video/image scraping: recommended posts, avatars and previews are excluded.
enum SocialResolver {
    static func id(in url: URL, platform: MediaPlatform) -> String? {
        let parts = url.pathComponents.filter { $0 != "/" }
        switch platform {
        case .douyin:
            if let i = parts.firstIndex(where: { ["video", "note", "slides"].contains($0) }), i + 1 < parts.count { return parts[i+1] }
            return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "modal_id" })?.value
        case .instagram:
            if let i = parts.firstIndex(where: { ["p", "reel", "reels", "tv"].contains($0) }), i + 1 < parts.count { return parts[i+1] }
        case .weibo:
            if parts.count == 2, ["status", "detail"].contains(parts[0]) || parts[0].allSatisfy(\.isNumber) { return parts[1] }
        case .xhs: return NoteResolver.noteID(in: url)
        }
        return nil
    }

    static func resolve(_ original: URL) async throws -> Note {
        guard let platform = MediaPlatform.identify(original), platform != .xhs else { throw LiveError.message("不支持的平台。") }
        let (html, final) = try await Network.page(original)
        guard MediaPlatform.identify(final) == platform else { throw LiveError.message("分享链接跳转到了其他平台，已停止。") }
        let postURL = id(in: original, platform: platform) == nil ? final : original
        guard let target = id(in: postURL, platform: platform), target.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw LiveError.message("请复制具体帖子的链接，暂不支持主页、直播、Story 或微博 TV 单独视频链接。")
        }
        func contextual(_ note: Note) -> Note { var result = note; result.sourceURL = postURL; result.userAgent = Network.mobileAgent; return result }
        if let note = try? parse(html: html, platform: platform, target: target) { return contextual(note) }
        var endpoints: [String] = []
        switch platform {
        case .douyin: endpoints = ["https://www.iesdouyin.com/share/note/\(target)/", "https://www.iesdouyin.com/share/video/\(target)/"]
        case .weibo: endpoints = ["https://weibo.com/ajax/statuses/show?id=\(target)", "https://m.weibo.cn/statuses/show?id=\(target)"]
        case .instagram:
            if let pk = instagramPK(target) { endpoints.append("https://www.instagram.com/api/v1/media/\(pk)/info/") }
            endpoints.append("https://www.instagram.com/p/\(target)/embed/captioned/")
        case .xhs: break
        }
        for endpoint in endpoints {
            try Task.checkCancellation()
            guard let url = URL(string: endpoint) else { continue }
            if let (body, _) = try? await Network.page(url), let note = try? parse(html: body, platform: platform, target: target) { return contextual(note) }
        }
        throw LiveError.message("\(platform.title)没有返回这篇帖子的可下载资源。请点「网页登录／验证」，在官方页面打开目标帖子后重试；若仍失败，请提供错误截图。不能下载私密、已删除或无权限的内容。")
    }

    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            guard m.numberOfRanges > 1, let range = Range(m.range(at: 1), in: text) else { return nil }; return String(text[range])
        }
    }

    static func jsonValues(in html: String) -> [Any] {
        var values: [Any] = []
        func add(_ string: String) {
            if let d = string.data(using: .utf8), let v = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) { values.append(v) }
        }
        add(html)
        for script in captures(#"<script\b[^>]*>(.*?)</script\s*>"#, in: html) {
            add(script)
            if let decoded = script.removingPercentEncoding, decoded != script { add(decoded) }
            // Extract a balanced JSON object from the known state assignments.
            for marker in ["_ROUTER_DATA", "__INITIAL_STATE__", "_sharedData", "__additionalDataLoaded"] {
                guard let r = script.range(of: marker), let start = script[r.upperBound...].firstIndex(of: "{") else { continue }
                var depth = 0, quoted = false, escaped = false
                for i in script[start...].indices {
                    let c = script[i]
                    if quoted { if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false } }
                    else if c == "\"" { quoted = true }
                    else if c == "{" { depth += 1 }
                    else if c == "}" { depth -= 1; if depth == 0 { add(String(script[start...i])); break } }
                }
            }
        }
        return values
    }

    static func find(_ value: Any, matching predicate: ([String: Any]) -> Bool, depth: Int = 0) -> [String: Any]? {
        guard depth < 80 else { return nil }
        if let d = value as? [String: Any] {
            if predicate(d) { return d }
            for key in d.keys.sorted() { if let result = find(d[key]!, matching: predicate, depth: depth + 1) { return result } }
        } else if let a = value as? [Any] {
            for child in a { if let result = find(child, matching: predicate, depth: depth + 1) { return result } }
        }
        return nil
    }
    static func string(_ value: Any?) -> String? {
        if let s = value as? String { return s }; return (value as? NSNumber)?.stringValue
    }
    static func number(_ value: Any?) -> Double { (value as? NSNumber)?.doubleValue ?? 0 }
    static func url(_ value: Any?) -> URL? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return try? NetworkPolicy.secure(s, media: true)
    }
    static func address(_ value: Any?) -> URL? {
        if let direct = url(value) { return direct }
        if let d = value as? [String: Any] {
            for key in ["url_list", "urlList"] { if let a = d[key] as? [String], let first = a.compactMap({ url($0) }).first { return first } }
            return url(d["url"])
        }
        return nil
    }
    static func best(_ entries: [[String: Any]]) -> [String: Any]? {
        entries.sorted { a,b in
            let x = number(a["width"] ?? a["config_width"]) * number(a["height"] ?? a["config_height"]), y = number(b["width"] ?? b["config_width"]) * number(b["height"] ?? b["config_height"])
            return x == y ? number(a["bit_rate"] ?? a["bitrate"]) > number(b["bit_rate"] ?? b["bitrate"]) : x > y
        }.first
    }
    static func instagramPK(_ code: String) -> String? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var value: UInt64 = 0
        for character in code {
            guard let digit = alphabet.firstIndex(of: character) else { return nil }
            let (multiplied, overflow) = value.multipliedReportingOverflow(by: 64)
            let (added, overflow2) = multiplied.addingReportingOverflow(UInt64(digit))
            guard !overflow, !overflow2 else { return nil }; value = added
        }
        return String(value)
    }
    static func parse(html: String, platform: MediaPlatform, target: String, payloads: [String] = []) throws -> Note {
        let values = jsonValues(in: html) + payloads.flatMap { jsonValues(in: $0) }
        let predicate: ([String: Any]) -> Bool = { d in
            switch platform {
            case .douyin: return string(d["aweme_id"] ?? d["awemeId"]) == target
            case .weibo: return ["idstr", "id", "mid", "bid"].contains { string(d[$0]) == target } && (d["pics"] != nil || d["pic_infos"] != nil || d["page_info"] != nil || d["mix_media_info"] != nil)
            case .instagram:
                let identity = string(d["shortcode"] ?? d["code"]) == target || (instagramPK(target) != nil && string(d["pk"] ?? d["id"])?.components(separatedBy: "_").first == instagramPK(target))
                return identity && ["if_not_gated_logged_out", "carousel_media", "edge_sidecar_to_children", "video_versions", "video_url", "image_versions2", "display_url"].contains { d[$0] != nil }
            case .xhs: return false
            }
        }
        guard let post = values.compactMap({ find($0, matching: predicate) }).first else { throw LiveError.message("网页数据与目标帖子不一致，未保存推荐内容。") }
        var items: [MediaItem] = []
        func append(image: URL? = nil, video: URL? = nil, live: Bool = false) {
            guard image != nil || video != nil else { return }
            items.append(MediaItem(id: items.count + 1, image: image, video: video, isLive: live && image != nil && video != nil, webVideo: video != nil))
        }
        switch platform {
        case .douyin:
            let images = post["images"] as? [[String: Any]] ?? post["imagePostInfo"].flatMap { $0 as? [String: Any] }?["images"] as? [[String: Any]] ?? []
            for image in images {
                let picture = address(image["display_image"] ?? image["displayImage"] ?? image)
                let video = image["video"] as? [String: Any] ?? [:]
                let motion = address(video["play_addr"] ?? video["playAddr"])
                append(image: picture, video: motion, live: motion != nil)
                if let picture, motion != nil {
                    let source = (image["display_image"] ?? image["displayImage"]) as? [String: Any] ?? image
                    let urls = (source["url_list"] ?? source["urlList"]) as? [String] ?? []
                    let jpegAlternates = urls.compactMap { url($0) }.filter {
                        $0 != picture && ["jpg", "jpeg"].contains($0.pathExtension.lowercased())
                    }
                    items[items.count - 1].alternateImages = Array(jpegAlternates.prefix(3))
                }
            }
            if images.isEmpty, let video = post["video"] as? [String: Any] {
                let variants = video["bit_rate"] as? [[String: Any]] ?? []
                let ordered = variants.sorted { number($0["bit_rate"]) > number($1["bit_rate"]) }
                let motion = ordered.compactMap { address($0["play_addr"]) }.first ?? address(video["play_addr"] ?? video["playAddr"])
                append(video: motion)
            }
        case .instagram:
            func instagramItem(_ d: [String: Any]) {
                let videos = d["video_versions"] as? [[String: Any]] ?? []
                let motion = best(videos).flatMap { url($0["url"]) } ?? url(d["video_url"])
                let isVideo = (d["is_video"] as? Bool) == true || number(d["media_type"]) == 2 || motion != nil
                if isVideo { append(video: motion); return }
                let versions = d["image_versions2"] as? [String: Any] ?? [:]
                let candidates = versions["candidates"] as? [[String: Any]] ?? d["display_resources"] as? [[String: Any]] ?? []
                let picture = best(candidates).flatMap { url($0["url"] ?? $0["src"]) } ?? url(d["display_url"])
                append(image: picture)
            }
            let product = post["if_not_gated_logged_out"] as? [String: Any] ?? post
            if let carousel = product["carousel_media"] as? [[String: Any]] { carousel.forEach(instagramItem) }
            else if let edge = product["edge_sidecar_to_children"] as? [String: Any], let edges = edge["edges"] as? [[String: Any]] { edges.compactMap { $0["node"] as? [String: Any] }.forEach(instagramItem) }
            else { instagramItem(product) }
        case .weibo:
            func picture(_ d: [String: Any]) {
                let largest = d["largest"] as? [String: Any] ?? d["original"] as? [String: Any] ?? d["large"] as? [String: Any]
                // Never upgrade a thumbnail URL by guessing a different path.
                let still = largest.flatMap { url($0["url"]) }
                // Keep the official player URL intact. Its nested URL is not
                // necessarily authorized as a standalone download.
                let motion = url(d["video"]) ?? url(d["videoSrc"])
                let live = (d["type"] as? String)?.lowercased() == "livephoto"
                append(image: still, video: live ? motion : nil, live: live)
            }
            func movie(_ d: [String: Any]) {
                let media = d["media_info"] as? [String: Any] ?? d
                let streams = (media["playback_list"] as? [[String: Any]] ?? []).compactMap { $0["play_info"] as? [String: Any] }
                if let best = best(streams), let source = url(best["url"]) { append(video: source); return }
                for key in ["mp4_1080p_mp4", "mp4_720p_mp4", "stream_url_hd", "mp4_hd_url", "stream_url", "mp4_sd_url"] {
                    if let source = url(media[key]) { append(video: source); return }
                }
            }
            if let infos = post["pic_infos"] as? [String: Any], let ids = post["pic_ids"] as? [String], !ids.isEmpty {
                ids.compactMap { infos[$0] as? [String: Any] }.forEach(picture)
                if let page = post["page_info"] as? [String: Any] { movie(page) }
            } else if let pics = post["pics"] as? [[String: Any]], !pics.isEmpty {
                for pic in pics { if (pic["type"] as? String)?.lowercased() == "video" { movie(pic) } else { picture(pic) } }
                if let page = post["page_info"] as? [String: Any] { movie(page) }
            } else if let mix = post["mix_media_info"] as? [String: Any], let entries = mix["items"] as? [[String: Any]], !entries.isEmpty {
                for entry in entries { if let d = entry["data"] as? [String: Any] { if entry["type"] as? String == "pic" { picture(d) } else { movie(d) } } }
            } else {
                if let pics = post["pics"] as? [[String: Any]] { pics.forEach(picture) }
                else if let infos = post["pic_infos"] as? [String: Any], let ids = post["pic_ids"] as? [String] { ids.compactMap { infos[$0] as? [String: Any] }.forEach(picture) }
                if let page = post["page_info"] as? [String: Any] { movie(page) }
            }
        case .xhs: break
        }
        guard !items.isEmpty else { throw LiveError.message("这篇帖子未提供可直接下载的图片／视频，可能需要登录或平台暂不提供文件地址。") }
        return Note(id: target, title: (post["desc"] ?? post["title"] ?? post["text_raw"]) as? String ?? "\(platform.title)帖子", items: items)
    }
}
