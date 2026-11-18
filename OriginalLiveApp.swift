import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var text = ""
    @Published var kind = DownloadKind.live
    @Published var busy = false
    @Published var status = "支持小红书、抖音、微博和 Instagram。"
    @Published var result = ""
    @Published var error: String?
    @Published var instagramFallback: URL?

    func run(text: String, kind: DownloadKind) async throws -> String {
        guard !busy else { throw LiveError.message("已有任务正在运行，请等它完成。") }
        self.text = text; self.kind = kind
        busy = true; result = ""; error = nil; status = "正在读取笔记…"
        defer { busy = false }
        do {
            let note: Note
            do { note = try await NoteResolver.resolve(text) }
            catch {
                try Task.checkCancellation()
                if kind != .live, let url = try? NetworkPolicy.shareLink(in: text), MediaPlatform.identify(url) == .instagram {
                    instagramFallback = url
                }
                throw error
            }
            status = note.title
            let report = try await DownloadService.save(note: note, kind: kind) { message in
                await MainActor.run { self.status = message }
            }
            result = report.summary
            status = report.failed.isEmpty ? "保存完成" : "处理结束，请查看结果"
            return result
        } catch {
            self.error = error.localizedDescription; status = "未完成"; throw error
        }
    }

    func combineLocal(image: URL, video: URL) async {
        guard !busy else { return }
        busy = true; result = ""; error = nil; status = "正在配对原图和动态片段…"
        defer { busy = false }
        do {
            let dir = try DownloadService.folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            func copy(_ source: URL, name: String) throws -> URL {
                let granted = source.startAccessingSecurityScopedResource()
                defer { if granted { source.stopAccessingSecurityScopedResource() } }
                let target = dir.appendingPathComponent(name)
                try FileManager.default.copyItem(at: source, to: target)
                return target
            }
            let still = try copy(image, name: "original.data"), motion = try copy(video, name: "original.mp4")
            result = try await DownloadService.combine(image: still, video: motion, in: dir)
            status = "保存完成"
        } catch { self.error = error.localizedDescription; status = "未完成" }
    }

    func saveResolved(_ note: Note, kind: DownloadKind) async throws -> String {
        guard !busy else { throw LiveError.message("已有任务正在运行。") }
        busy = true; result = ""; error = nil; defer { busy = false }
        do {
            let report = try await DownloadService.save(note: note, kind: kind) { message in await MainActor.run { self.status = message } }
            result = report.summary; status = report.failed.isEmpty ? "保存完成" : "处理结束，请查看结果"
            return result
        } catch { self.error = error.localizedDescription; status = "未完成"; throw error }
    }
}

@main struct OriginalLiveApp: App {
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(AppModel.shared) }
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var image: URL?
    @State private var video: URL?
    @State private var choosingImage = false
    @State private var choosingVideo = false
    @State private var showBrowser = false
    @State private var browserURL: URL?
    @State private var browserKind = DownloadKind.image

    var body: some View {
        NavigationStack {
            Form {
                Section("分享链接 · 自动识别平台") {
                    TextEditor(text: $model.text).frame(minHeight: 85)
                        .accessibilityLabel("小红书、抖音、微博或 Instagram 分享文案或链接")
                    PasteButton(payloadType: String.self) { values in model.text = values.joined(separator: "\n") }
                    Picker("下载类型", selection: $model.kind) {
                        ForEach(DownloadKind.allCases) { item in Text(item.title).tag(item) }
                    }
                    Text("Instagram 请选图片或视频；微博、抖音实况需要同时取得原图和对应动态片段。")
                        .font(.footnote)
                    Button("开始保存", systemImage: "square.and.arrow.down") {
                        Task { _ = try? await model.run(text: model.text, kind: model.kind) }
                    }.disabled(model.busy || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("网页登录／验证") {
                        do { browserURL = try NetworkPolicy.shareLink(in: model.text); browserKind = model.kind; showBrowser = true }
                        catch { model.error = error.localizedDescription }
                    }
                    Text("直接下载失败时，可在官方网页自行登录或验证，再读取当前帖子。登录状态仅保存在本机；不会发送给解析服务器。网页资源的清晰度及水印以平台实际提供为准。")
                        .font(.footnote)
                }
                Section {
                    if model.busy { ProgressView() }
                    Text(model.status)
                    if !model.result.isEmpty { Text(model.result).textSelection(.enabled) }
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                }
                Section("本地图片＋视频合成") {
                    Button(image == nil ? "选择高清原图" : "图片已选择") { choosingImage = true }
                    Button(video == nil ? "选择动态片段" : "动态片段已选择") { choosingVideo = true }
                    Button("配对并存入照片") {
                        if let image, let video { Task { await model.combineLocal(image: image, video: video) } }
                    }.disabled(image == nil || video == nil || model.busy)
                }
                Section("画质说明") {
                    Text("封面使用下载的高清原图，不从视频截帧。已有苹果配对标识的原图保持文件不变；没有标识的 JPEG 只补写配对信息，不重压缩。首版不转码没有标识的 HEIC/PNG。")
                    Text("视频只重新封装，不重编码。平台未提供的原始画质和音轨无法恢复，已经嵌入文件的水印也不会被消除。")
                    Text("没有会员、广告、每日合成额度或外部解析服务器。")
                }.font(.footnote)
            }
            .navigationTitle("原图实况 · 多平台版")
            .disabled(model.busy)
            .onChange(of: model.instagramFallback) { _, url in
                guard let url else { return }
                browserURL = url
                browserKind = model.kind
                showBrowser = true
                model.instagramFallback = nil
            }
            .sheet(isPresented: $showBrowser) {
                if let url = browserURL { PlatformBrowserSheet(url: url) { note in try await model.saveResolved(note, kind: browserKind) } }
            }
            .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
                do { image = try result.get() } catch { model.error = error.localizedDescription }
            }
            .fileImporter(isPresented: $choosingVideo, allowedContentTypes: [.movie]) { result in
                do { video = try result.get() } catch { model.error = error.localizedDescription }
            }
            .onOpenURL { url in
                guard url.scheme == "originallive", let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
                if let share = parts.queryItems?.first(where: { $0.name == "text" })?.value { model.text = share }
            }
        }
    }
}

import WebKit

// The webpage stays on the phone. Only post JSON responses are held temporarily,
// and every result is checked against the original post ID before saving.
@MainActor final class PlatformBrowserModel: NSObject, ObservableObject, WKNavigationDelegate {
    let initial: URL
    let web: WKWebView
    @Published var message = "等待页面加载。需要登录时，请在平台官方页面自行登录。"
    @Published var reading = false
    private var boundURL: URL?
    var save: ((Note) async throws -> String)?
    init(url: URL) {
        initial = url
        if let p = MediaPlatform.identify(url), SocialResolver.id(in: url, platform: p) != nil { boundURL = url }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let capture = #"""
        (() => {
          const payloads = []; window.__originalLivePayloads = payloads;
          const wanted = u => /\/aweme\/.*(?:detail|slides|iteminfo)|\/ajax\/statuses\/show|\/statuses\/show|\/api\/v1\/media\/|\/api\/graphql|\/graphql\/query/.test(String(u));
          const keep = (u,t) => {
            if (!wanted(u) || typeof t !== 'string' || t.length > 4000000) return;
            if (!/"(?:aweme_id|image_versions2|video_versions|shortcode_media|xig_polaris_media|pic_infos|pics|page_info)"/.test(t)) return;
            if (payloads.length >= 16) payloads.shift(); payloads.push(t);
          };
          const originalFetch = window.fetch;
          window.fetch = function(...args) {
            return originalFetch.apply(this,args).then(r => { if(wanted(r.url)) r.clone().text().then(t=>keep(r.url,t)).catch(()=>{}); return r; });
          };
          const open = XMLHttpRequest.prototype.open, send = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(method,url,...args) { this.__originalLiveURL=url; return open.call(this,method,url,...args); };
          XMLHttpRequest.prototype.send = function(...args) {
            if(wanted(this.__originalLiveURL)) this.addEventListener('load',()=>{try {
              keep(this.responseURL || this.__originalLiveURL, this.responseType==='json' ? JSON.stringify(this.response) : this.responseText);
            } catch(e){} });
            return send.apply(this,args);
          };
        })();
        """#
        config.userContentController.addUserScript(WKUserScript(source: capture, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if MediaPlatform.identify(url) == .instagram {
            let dismissPromotion = #"""
            (() => {
              if (!/^\/(?:p|reels?|tv)\//.test(location.pathname)) return;
              const dismiss = () => {
                for (const dialog of document.querySelectorAll('[role="dialog"],[aria-modal="true"]')) {
                  const title = dialog.innerText || '';
                  if (!/在应用中查看这篇帖子|See this post in the app|View this post in the app/i.test(title)) continue;
                  const labels = dialog.querySelectorAll('[aria-label="Close"],[aria-label="关闭"]');
                  for (const label of labels) {
                    const button = label.closest('button,[role="button"]');
                    if (button) { button.click(); observer.disconnect(); return; }
                  }
                }
              };
              const observer = new MutationObserver(dismiss);
              observer.observe(document.documentElement, {childList:true,subtree:true});
              setTimeout(() => observer.disconnect(), 15000);
              dismiss();
            })();
            """#
            config.userContentController.addUserScript(WKUserScript(source: dismissPromotion, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }
        web = WKWebView(frame: .zero, configuration: config)
        super.init()
        web.navigationDelegate = self
        web.customUserAgent = Network.mobileAgent
        web.load(URLRequest(url: initial))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, NetworkPolicy.allows(url), MediaPlatform.identify(url) == MediaPlatform.identify(initial) else { decisionHandler(.cancel); return }
        // Keep new-window links inside the platform view; never open an app scheme.
        if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if boundURL == nil, let url = webView.url, let p = MediaPlatform.identify(url), SocialResolver.id(in: url, platform: p) != nil { boundURL = url }
        message = "页面加载完成。确认是目标帖子后，点「读取并保存」。"
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { message = error.localizedDescription }
    func read() async {
        guard !reading else { return }; reading = true; defer { reading = false }
        do {
            guard let current = web.url, let platform = MediaPlatform.identify(initial), let bound = boundURL,
                  let target = SocialResolver.id(in: bound, platform: platform), SocialResolver.id(in: current, platform: platform) == target else {
                throw LiveError.message("请先返回原分享链接对应的帖子，不能从登录页或其他推荐帖子保存。")
            }
            let raw = try await web.evaluateJavaScript("JSON.stringify({html:document.documentElement.outerHTML,payloads:window.__originalLivePayloads||[]})")
            guard let raw = raw as? String, raw.utf8.count < 20 * 1024 * 1024,
                  let data = raw.data(using: .utf8), let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LiveError.message("页面数据过大或不可读取。") }
            let html = snapshot["html"] as? String ?? ""
            let note: Note
            if platform == .xhs { note = try NoteResolver.parse(html: html, url: bound) }
            else if let parsed = try? SocialResolver.parse(html: html, platform: platform, target: target, payloads: snapshot["payloads"] as? [String] ?? []) { note = parsed }
            else {
                message = "正在使用本机登录状态重新读取目标帖子…"
                note = try await SocialResolver.resolve(bound)
            }
            message = "正在保存…"
            var contextual = note
            contextual.sourceURL = current; contextual.userAgent = web.customUserAgent
            message = try await save?(contextual) ?? "没有保存任务。"
        } catch { message = error.localizedDescription }
    }
    func standardPage() {
        guard let bound = boundURL, let p = MediaPlatform.identify(bound), let id = SocialResolver.id(in: bound, platform: p) else { return }
        let path: String
        switch p {
        case .douyin: path = "https://www.douyin.com/note/\(id)"
        case .instagram: path = "https://www.instagram.com/p/\(id)/"
        case .weibo: path = "https://m.weibo.cn/detail/\(id)"
        case .xhs: path = bound.absoluteString
        }
        web.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Version/17.0 Safari/605.1.15"
        if let url = URL(string: path) { web.load(URLRequest(url: url)) }
    }
}

struct PlatformWebView: UIViewRepresentable {
    let model: PlatformBrowserModel
    func makeUIView(context: Context) -> WKWebView { model.web }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
struct PlatformBrowserSheet: View {
    @StateObject var browser: PlatformBrowserModel
    @Environment(\.dismiss) private var dismiss
    init(url: URL, save: @escaping (Note) async throws -> String) {
        let model = PlatformBrowserModel(url: url); model.save = save
        _browser = StateObject(wrappedValue: model)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(browser.web.url?.host ?? browser.initial.host ?? "官方网页").font(.caption)
                Text(browser.message).font(.footnote).textSelection(.enabled).padding(.horizontal)
                HStack {
                    Button("返回目标帖子") { browser.web.load(URLRequest(url: browser.initial)) }.disabled(browser.reading)
                    Button("标准网页") { browser.standardPage() }.disabled(browser.reading)
                    Button("读取并保存") { Task { await browser.read() } }.disabled(browser.reading)
                }
                PlatformWebView(model: browser)
            }
            .navigationTitle("官方网页登录／验证").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { dismiss() }.disabled(browser.reading) } }
        }.interactiveDismissDisabled(browser.reading)
    }
}
