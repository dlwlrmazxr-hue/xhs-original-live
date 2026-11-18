import Foundation

enum DownloadService {
    static func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func combine(image: URL, video: URL, in directory: URL) async throws -> String {
        let photo = try OriginalImage.prepare(source: image, output: directory.appendingPathComponent("paired-photo.jpg"))
        return try await savePair(photo, video: video, in: directory)
    }

    private static func savePair(_ photo: PreparedImage, video: URL, in directory: URL) async throws -> String {
        let movie = directory.appendingPathComponent("paired-video.mov")
        try await MoviePairer.pair(source: video, output: movie, identifier: photo.identifier)
        try await PhotoStore.save(image: photo.url, video: movie, live: true)
        return photo.unchanged ? "图片文件完整保留；实况已保存。" : "只补写 JPEG 配对信息，压缩图像数据未改变；实况已保存。"
    }

    static func save(note: Note, kind: DownloadKind, progress: (@Sendable (String) async -> Void)? = nil) async throws -> SaveReport {
        let items = note.items.filter {
            switch kind {
            case .image: return $0.image != nil && !$0.isLive
            case .video: return $0.video != nil
            case .live: return $0.isLive
            }
        }
        guard !items.isEmpty else {
            if kind == .live, note.items.contains(where: { $0.image != nil }) {
                throw LiveError.message("已读到图片，但没有取得与原图对应的实况动态文件；这不表示原帖没有 Live。请等待网页加载后重新读取，或先保存普通图片。")
            }
            throw LiveError.message("这篇帖子未返回所选类型的可下载媒体。")
        }
        var report = SaveReport()
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            await progress?("正在处理 \(index + 1)/\(items.count)…")
            let dir = try folder()
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                switch kind {
                case .image:
                    guard let url = item.image else { throw LiveError.message("没有源图片地址。") }
                    let path = dir.appendingPathComponent("photo.data")
                    try await Network.download(url, to: path, sourcePage: note.sourceURL, userAgent: note.userAgent)
                    if let detail = try await PhotoStore.savePlainImage(path) { report.details.append("第 \(item.id) 项：" + detail) }
                case .video:
                    guard let url = item.video else { throw LiveError.message("没有动态资源地址。") }
                    let path = dir.appendingPathComponent("video.mp4")
                    try await Network.download(url, to: path, sourcePage: note.sourceURL, userAgent: note.userAgent)
                    try await PhotoStore.save(video: path)
                case .live:
                    guard let image = item.image, let video = item.video else { throw LiveError.message("实况图片和动态片段不齐全。") }
                    let motion = dir.appendingPathComponent("original.mp4")
                    var prepared: PreparedImage?
                    var lastError: Error = LiveError.message("未取得可配对的原图。")
                    for (index, candidate) in ([image] + item.alternateImages).enumerated() {
                        try Task.checkCancellation()
                        do {
                            let still = dir.appendingPathComponent("original-\(index).data")
                            try await Network.download(candidate, to: still, sourcePage: note.sourceURL, userAgent: note.userAgent)
                            prepared = try OriginalImage.prepare(source: still, output: dir.appendingPathComponent("paired-\(index).jpg"))
                            break
                        } catch { lastError = error }
                    }
                    guard let prepared else { throw lastError }
                    try await Network.download(video, to: motion, sourcePage: note.sourceURL, userAgent: note.userAgent)
                    let detail = try await savePair(prepared, video: motion, in: dir)
                    report.details.append("第 \(item.id) 项：" + detail)
                }
                report.saved += 1
                if kind != .image && item.webVideo { report.details.append("第 \(item.id) 项动态文件来自平台网页版本，将保存平台提供的最高可用版本，无法保证等同上传原件或完全无水印。") }
            } catch is CancellationError { throw CancellationError() }
            catch { report.failed.append("第 \(item.id) 项：\(error.localizedDescription)") }
        }
        return report
    }
}
