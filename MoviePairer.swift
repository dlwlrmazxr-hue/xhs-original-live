import Foundation
import AVFoundation
import CoreMedia

enum MoviePairer {
    private static func waitUntilReady(_ input: AVAssetWriterInput, writer: AVAssetWriter, deadline: Date) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            guard writer.status == .writing else { throw writer.error ?? LiveError.message("视频封装已停止。") }
            guard Date() < deadline else { throw LiveError.message("本地封装等待超时。") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    static func pair(source: URL, output: URL, identifier: String) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        guard duration.seconds.isFinite, duration.seconds > 0, duration.seconds <= 60 else {
            throw LiveError.message("首版仅支持 60 秒以内的实况动态片段。")
        }
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let tracks = videoTracks + audioTracks
        guard tracks.contains(where: { $0.mediaType == .video }) else { throw LiveError.message("动态文件没有视频轨道。") }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
        let identity = AVMutableMetadataItem()
        identity.keySpace = .quickTimeMetadata
        identity.key = "com.apple.quicktime.content.identifier" as NSString
        identity.value = identifier as NSString
        writer.metadata = [identity]
        var channels: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in tracks {
            let descriptions = try await track.load(.formatDescriptions)
            let out = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            out.alwaysCopiesSampleData = false
            let input = AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: descriptions.first)
            input.expectsMediaDataInRealTime = false
            if track.mediaType == .video { input.transform = try await track.load(.preferredTransform) }
            guard reader.canAdd(out), writer.canAdd(input) else { throw LiveError.message("该视频编码暂不支持无重编码封装。") }
            reader.add(out); writer.add(input); channels.append((out,input))
        }
        var metadataDescription: CMFormatDescription?
        let specification: [String: Any] = [
            kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: "mdta/com.apple.quicktime.still-image-time",
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8
        ]
        let status = CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault,
                    metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray,
                    formatDescriptionOut: &metadataDescription)
        guard status == noErr, let metadataDescription else { throw LiveError.message("无法创建实况时间标记。") }
        let metadataInput = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: metadataDescription)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadataInput)
        guard writer.canAdd(metadataInput) else { throw LiveError.message("无法添加实况元数据轨道。") }
        writer.add(metadataInput)
        guard writer.startWriting() else { throw writer.error ?? LiveError.message("无法开始视频封装。") }
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? LiveError.message("无法读取动态片段。") }
        let deadline = Date().addingTimeInterval(120)
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for (out,input) in channels {
                    group.addTask {
                        while true {
                            try Task.checkCancellation()
                            guard Date() < deadline else { throw LiveError.message("本地封装超时。") }
                            guard let buffer = out.copyNextSampleBuffer() else {
                                if reader.status == .failed { throw reader.error ?? LiveError.message("视频读取失败。") }
                                input.markAsFinished(); return
                            }
                            try await waitUntilReady(input, writer: writer, deadline: deadline)
                            guard input.append(buffer) else { throw writer.error ?? LiveError.message("写入原始视频采样失败。") }
                        }
                    }
                }
                group.addTask {
                    let item = AVMutableMetadataItem()
                    item.keySpace = .quickTimeMetadata
                    item.key = "com.apple.quicktime.still-image-time" as NSString
                    item.value = NSNumber(value: Int8(0))
                    item.dataType = kCMMetadataBaseDataType_SInt8 as String
                    let time = CMTime(seconds: duration.seconds / 2, preferredTimescale: 600)
                    let timed = AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: time, duration: CMTime(value: 1, timescale: 30)))
                    try await waitUntilReady(metadataInput, writer: writer, deadline: deadline)
                    guard adaptor.append(timed) else { throw writer.error ?? LiveError.message("实况时间标记写入失败。") }
                    metadataInput.markAsFinished()
                }
                try await group.waitForAll()
            }
            await writer.finishWriting()
            guard writer.status == .completed else { throw writer.error ?? LiveError.message("视频封装未完成。") }
        } catch {
            reader.cancelReading(); writer.cancelWriting(); throw error
        }
    }
}
