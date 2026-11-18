import Foundation
import Photos
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

enum PhotoStore {
    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; if finished { return false }; finished = true; return true }
    }

    static func validateLive(image: URL, video: URL) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = Once()
            let requestID = PHLivePhoto.request(withResourceFileURLs: [image, video], placeholderImage: nil,
                                    targetSize: .zero, contentMode: .aspectFit) { result, info in
                if (info[PHLivePhotoInfoIsDegradedKey] as? Bool) == true { return }
                guard once.take() else { return }
                if let result, result.size.width > 0 { continuation.resume() }
                else { continuation.resume(throwing: info[PHLivePhotoInfoErrorKey] as? Error ?? LiveError.message("系统未能识别这组实况文件；没有存入相册。")) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                guard once.take() else { return }
                PHLivePhoto.cancelRequest(withRequestID: requestID)
                continuation.resume(throwing: LiveError.message("系统实况识别超时；没有存入相册。"))
            }
        }
    }

    static func permission() async throws {
        let result = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard result == .authorized || result == .limited else {
            throw LiveError.message("没有照片添加权限。请到设置 → 隐私与安全性 → 照片 → 原图实况，允许添加照片。")
        }
    }

    static func save(image: URL? = nil, video: URL? = nil, live: Bool = false) async throws {
        let image = try image.map { try typedImage($0) }
        if let image {
            guard CGImageSourceCreateWithURL(image as CFURL, nil) != nil else { throw LiveError.message("图片文件无法识别。") }
        }
        if let video {
            let tracks = try await AVURLAsset(url: video).loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { throw LiveError.message("下载结果不是有效视频。") }
        }
        if live, let image, let video { try await validateLive(image: image, video: video) }
        try await permission()
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            if let image {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = image.lastPathComponent
                if let source = CGImageSourceCreateWithURL(image as CFURL, nil), let type = CGImageSourceGetType(source) {
                    options.uniformTypeIdentifier = type as String
                }
                request.addResource(with: .photo, fileURL: image, options: options)
            }
            if let video { request.addResource(with: live ? .pairedVideo : .video, fileURL: video, options: nil) }
        }
    }

    static func typedImage(_ source: URL) throws -> URL {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), let identifier = CGImageSourceGetType(reader),
              let ext = UTType(identifier as String)?.preferredFilenameExtension else { throw LiveError.message("下载内容不是可识别的图片。") }
        if source.pathExtension.lowercased() == ext.lowercased() { return source }
        let output = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.copyItem(at: source, to: output)
        return output
    }

    static func compatiblePNG(_ source: URL, output: URL) throws {
        guard let reader = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(reader) == 1,
              let original = CGImageSourceCopyPropertiesAtIndex(reader, 0, nil),
              let writer = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw LiveError.message("无法无损导出这张图片；动画和多帧图片不会转换成静态图。")
        }
        CGImageDestinationAddImageFromSource(writer, reader, 0, original)
        guard CGImageDestinationFinalize(writer), let check = CGImageSourceCreateWithURL(output as CFURL, nil),
              let result = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [String: Any],
              let before = original as? [String: Any],
              result[kCGImagePropertyPixelWidth as String] as? Int == before[kCGImagePropertyPixelWidth as String] as? Int,
              result[kCGImagePropertyPixelHeight as String] as? Int == before[kCGImagePropertyPixelHeight as String] as? Int else {
            throw LiveError.message("PNG 导出尺寸校验失败，未存入相册。")
        }
    }

    static func savePlainImage(_ source: URL) async throws -> String? {
        let typed = try typedImage(source)
        do { try await save(image: typed); return nil }
        catch {
            let failure = error as NSError
            guard failure.domain == PHPhotosErrorDomain, failure.code == 3302 else { throw error }
            let directory = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("下载原文件", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let original = directory.appendingPathComponent(typed.lastPathComponent)
            try FileManager.default.copyItem(at: typed, to: original)
            let png = source.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
            try compatiblePNG(typed, output: png)
            do { try await save(image: png) }
            catch { throw LiveError.message("原文件已保留到「文件 → 原图实况 → 下载原文件」，但相册仍拒绝 PNG：\(error.localizedDescription)") }
            return "相册不接受原文件格式；已按原尺寸导出 PNG 保存，未缩放、未使用 JPEG 重压缩。原文件保留在「文件 → 原图实况 → 下载原文件」。"
        }
    }
}
