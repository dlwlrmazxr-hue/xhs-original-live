import Foundation

enum LiveError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

enum DownloadKind: String, CaseIterable, Identifiable {
    case image, video, live
    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频（含实况片段）"
        case .live: return "原图实况照片"
        }
    }
}

struct MediaItem: Identifiable {
    let id: Int
    let image: URL?
    let video: URL?
    let isLive: Bool
    let webVideo: Bool
    var alternateImages: [URL] = []
    var alternateVideos: [URL] = []
}

struct Note {
    let id: String
    let title: String
    let items: [MediaItem]
    var sourceURL: URL? = nil
    var userAgent: String? = nil
}

struct SaveReport {
    var saved = 0
    var failed: [String] = []
    var details: [String] = []
    var summary: String {
        let first = "已保存 \(saved) 项；失败 \(failed.count) 项。"
        return ([first] + failed + details).joined(separator: "\n")
    }
}
