import SwiftUI
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    static let shared = AppModel()
    @Published var text = ""
    @Published var kind = DownloadKind.live
    @Published var busy = false
    @Published var status = "复制小红书分享链接，选择类型后保存。"
    @Published var result = ""
    @Published var error: String?

    func run(text: String, kind: DownloadKind) async throws -> String {
        guard !busy else { throw LiveError.message("已有任务正在运行，请等它完成。") }
        busy = true; result = ""; error = nil; status = "正在读取笔记…"
        defer { busy = false }
        do {
            let note = try await NoteResolver.resolve(text)
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

    var body: some View {
        NavigationStack {
            Form {
                Section("小红书链接") {
                    TextEditor(text: $model.text).frame(minHeight: 85)
                        .accessibilityLabel("小红书分享文案或链接")
                    PasteButton(payloadType: String.self) { values in model.text = values.joined(separator: "\n") }
                    Picker("下载类型", selection: $model.kind) {
                        ForEach(DownloadKind.allCases) { item in Text(item.title).tag(item) }
                    }
                    Button("开始保存", systemImage: "square.and.arrow.down") {
                        Task { _ = try? await model.run(text: model.text, kind: model.kind) }
                    }.disabled(model.busy || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            .navigationTitle("原图实况 · 试用版")
            .disabled(model.busy)
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
