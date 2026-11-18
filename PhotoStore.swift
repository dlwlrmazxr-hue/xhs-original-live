import Foundation
import Photos
import ImageIO
import AVFoundation

enum PhotoStore {
    private final class Once {
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
                if let source = CGImageSourceCreateWithURL(image as CFURL, nil), let type = CGImageSourceGetType(source) {
                    options.uniformTypeIdentifier = type as String
                }
                request.addResource(with: .photo, fileURL: image, options: options)
            }
            if let video { request.addResource(with: live ? .pairedVideo : .video, fileURL: video, options: nil) }
        }
    }
}
