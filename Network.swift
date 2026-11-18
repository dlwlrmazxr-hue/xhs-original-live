import Foundation

enum NetworkPolicy {
    static func allows(_ url: URL, media: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let roots = ["xiaohongshu.com", "xhslink.com", "xhslink.cn"] + (media ? ["xhscdn.com"] : [])
        return roots.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func secure(_ value: String, media: Bool) throws -> URL {
        var string = value
        if string.hasPrefix("//") { string = "https:" + string }
        if string.hasPrefix("http://") { string = "https://" + String(string.dropFirst(7)) }
        guard let url = URL(string: string), allows(url, media: media) else {
            throw LiveError.message("链接不是受支持的小红书地址。")
        }
        return url
    }

    static func shareLink(in text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            if let url = match.url, allows(url) { return url }
        }
        throw LiveError.message("未找到小红书分享链接，请重新复制帖子的完整分享文案。")
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    let media: Bool
    init(media: Bool) { self.media = media }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map { NetworkPolicy.allows($0, media: media) } == true ? request : nil)
    }
}

enum Network {
    static let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1"

    private static func session(media: Bool) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config, delegate: RedirectPolicy(media: media), delegateQueue: nil)
    }

    private static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(mobileAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.xiaohongshu.com/", forHTTPHeaderField: "Referer")
        return request
    }

    static func page(_ url: URL) async throws -> (String, URL) {
        guard NetworkPolicy.allows(url) else { throw LiveError.message("不支持的笔记域名。") }
        let client = session(media: false)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, NetworkPolicy.allows(finalURL), data.count < 16 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8) else {
            throw LiveError.message("无法读取笔记网页；可能需要登录、验证或重新复制完整链接。")
        }
        return (html, finalURL)
    }

    static func download(_ url: URL, to target: URL) async throws {
        guard NetworkPolicy.allows(url, media: true) else { throw LiveError.message("不支持的媒体域名。") }
        let client = session(media: true)
        defer { client.invalidateAndCancel() }
        let (file, response) = try await client.download(for: request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = response.url, NetworkPolicy.allows(final, media: true) else {
            throw LiveError.message("媒体下载失败（源地址过期或平台拒绝访问）。")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw LiveError.message("媒体为空或超过本版本的 512 MB 文件上限。") }
        try FileManager.default.moveItem(at: file, to: target)
    }
}
