import AppIntents
import UIKit

enum ShortcutMediaKind: String, AppEnum {
    case image, video, live
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "下载类型"
    static var caseDisplayRepresentations: [ShortcutMediaKind: DisplayRepresentation] = [
        .image: "图片", .video: "视频", .live: "原图实况照片"
    ]
}

struct DownloadXHSIntent: AppIntent {
    static var title: LocalizedStringResource = "下载小红书原图、视频或实况"
    static var description = IntentDescription("读取分享文案或剪贴板，并在本地处理后存入照片。")
    static var openAppWhenRun = true

    @Parameter(title: "分享文案（留空读取剪贴板）") var shareText: String?
    @Parameter(title: "下载类型") var kind: ShortcutMediaKind

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let text = shareText ?? UIPasteboard.general.string ?? ""
        let mode = DownloadKind(rawValue: kind.rawValue) ?? .live
        let result = try await AppModel.shared.run(text: text, kind: mode)
        return .result(value: result)
    }
}

struct OriginalLiveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: DownloadXHSIntent(), phrases: ["使用\(.applicationName)下载小红书"],
                    shortTitle: "保存小红书媒体", systemImageName: "livephoto")
    }
}
