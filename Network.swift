import Foundation
import WebKit

enum MediaPlatform: String {
    case xhs, douyin, weibo, instagram
    var title: String {
        switch self { case .xhs: return "小红书"; case .douyin: return "抖音"; case .weibo: return "微博"; case .instagram: return "Instagram" }
    }
    var roots: [String] {
        switch self {
        case .xhs: return ["xiaohongshu.com", "xhslink.com", "xhslink.cn"]
        case .douyin: return ["douyin.com", "iesdouyin.com", "amemv.com"]
        case .weibo: return ["weibo.com", "weibo.cn", "t.cn"]
        case .instagram: return ["instagram.com"]
        }
    }
    var home: String {
        switch self { case .xhs: return "https://www.xiaohongshu.com/"; case .douyin: return "https://www.douyin.com/"; case .weibo: return "https://weibo.com/"; case .instagram: return "https://www.instagram.com/" }
    }
    static func identify(_ url: URL) -> MediaPlatform? {
        guard let host = url.host?.lowercased() else { return nil }
        return [Self.xhs, .douyin, .weibo, .instagram].first { platform in platform.roots.contains { host == $0 || host.hasSuffix("." + $0) } }
    }
}

enum NetworkPolicy {
    static func allows(_ url: URL, media: Bool = false) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        let roots = [MediaPlatform.xhs, .douyin, .weibo, .instagram].flatMap(\.roots) + (media ? ["xhscdn.com", "douyinvod.com", "douyinpic.com", "byteimg.com", "ibytedtos.com", "pstatp.com", "snssdk.com", "bytecdn.cn", "weibocdn.com", "sinaimg.cn", "sina.com.cn", "cdninstagram.com", "fbcdn.net"] : [])
        return roots.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static func secure(_ value: String, media: Bool) throws -> URL {
        var string = value
        if string.hasPrefix("//") { string = "https:" + string }
        if string.hasPrefix("http://") { string = "https://" + String(string.dropFirst(7)) }
        guard let url = URL(string: string), allows(url, media: media) else {
            throw LiveError.message("链接不是受支持的平台或媒体地址。")
        }
        return url
    }

    static func shareLink(in text: String) throws -> URL {
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for match in detector.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text)) {
            if let url = match.url, allows(url) { return url }
        }
        throw LiveError.message("未找到支持的分享链接。支持小红书、抖音、微博、Instagram 的帖子链接。")
    }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    let media: Bool
    init(media: Bool) { self.media = media }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url.map({ NetworkPolicy.allows($0, media: media) }) == true else { completionHandler(nil); return }
        var next = request
        // A platform login must never be forwarded to a different redirect host.
        if request.url?.host != response.url?.host {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
            next.setValue(nil, forHTTPHeaderField: "Authorization")
        }
        completionHandler(next)
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

    private static func request(_ url: URL, sourcePage: URL? = nil, userAgent: String? = nil) async -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent ?? mobileAgent, forHTTPHeaderField: "User-Agent")
        let platform = MediaPlatform.identify(url)
        let host = url.host?.lowercased() ?? ""
        let referer = platform?.home ?? (host.contains("sina") || host.contains("weibocdn") ? MediaPlatform.weibo.home : host.contains("instagram") || host.hasSuffix("fbcdn.net") ? MediaPlatform.instagram.home : host.contains("xhs") ? MediaPlatform.xhs.home : MediaPlatform.douyin.home)
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let sourcePage, NetworkPolicy.allows(sourcePage) { request.setValue(sourcePage.absoluteString, forHTTPHeaderField: "Referer") }
        if platform == .instagram { request.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID") }
        // Login cookies stay in the platform's on-device WebKit store. Media CDN
        // requests receive none, and redirects strip cookies on a host change.
        if platform != nil {
            let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
            let matching = cookies.filter { cookie in
                let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                return (host == domain || host.hasSuffix("." + domain)) && url.path.hasPrefix(cookie.path) && (cookie.expiresDate == nil || cookie.expiresDate! > Date())
            }
            for (key,value) in HTTPCookie.requestHeaderFields(with: matching) { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }

    static func page(_ url: URL) async throws -> (String, URL) {
        guard NetworkPolicy.allows(url) else { throw LiveError.message("不支持的笔记域名。") }
        let client = session(media: false)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: await request(url))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let finalURL = response.url, NetworkPolicy.allows(finalURL), data.count < 16 * 1024 * 1024,
              let html = String(data: data, encoding: .utf8) else {
            throw LiveError.message("无法读取笔记网页；可能需要登录、验证或重新复制完整链接。")
        }
        return (html, finalURL)
    }

    static func download(_ url: URL, to target: URL, sourcePage: URL? = nil, userAgent: String? = nil) async throws {
        guard NetworkPolicy.allows(url, media: true) else { throw LiveError.message("不支持的媒体域名。") }
        let client = session(media: true)
        defer { client.invalidateAndCancel() }
        let (file, response) = try await client.download(for: await request(url, sourcePage: sourcePage, userAgent: userAgent))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let final = response.url, NetworkPolicy.allows(final, media: true) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LiveError.message("媒体下载失败：HTTP \(status)，资源主机 \(url.host ?? "未知")。未将错误网页当作媒体保存。")
        }
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0, size <= 512 * 1024 * 1024 else { throw LiveError.message("媒体为空或超过本版本的 512 MB 文件上限。") }
        try FileManager.default.moveItem(at: file, to: target)
    }
}
