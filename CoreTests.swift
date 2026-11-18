import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CoreVideo
import CoreMedia
import Photos
@testable import XHSOriginalLive

final class CoreTests: XCTestCase {
    func imageJPEG() throws -> Data {
        let pixels = [UInt8](repeating: 128, count: 96 * 64 * 4)
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let image = CGImage(width: 96, height: 64, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 96*4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testJPEGPairingKeepsCompressedImageAndOrientation() throws {
        let dir = try DownloadService.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let original = try imageJPEG(), id = UUID().uuidString
        let tagged = try LosslessJPEG.tag(original, identifier: id)
        XCTAssertEqual(try LosslessJPEG.scanData(original), try LosslessJPEG.scanData(tagged))
        let url = dir.appendingPathComponent("photo.jpg"); try tagged.write(to: url)
        XCTAssertEqual(OriginalImage.identifier(at: url), id)
        let image = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 96)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 64)
        XCTAssertEqual(properties[kCGImagePropertyOrientation] as? Int, 6)
        let prepared = try OriginalImage.prepare(source: url, output: dir.appendingPathComponent("copy.jpg"))
        XCTAssertTrue(prepared.unchanged)
        XCTAssertEqual(try Data(contentsOf: prepared.url), tagged)
    }

    func testMalformedJPEGDoesNotProduceFakeSuccess() throws {
        XCTAssertThrowsError(try LosslessJPEG.tag(Data([1,2,3]), identifier: UUID().uuidString))
        XCTAssertThrowsError(try LosslessJPEG.tag(Data([0xff,0xd8,0xff,0xe1,0xff,0xff]), identifier: UUID().uuidString))
        var untaggedMPO = try imageJPEG()
        untaggedMPO.insert(contentsOf: [0xff,0xe2,0,6,77,80,70,0], at: 2)
        XCTAssertThrowsError(try LosslessJPEG.tag(untaggedMPO, identifier: UUID().uuidString))
    }

    func testNetworkAllowlistAndShareText() throws {
        XCTAssertFalse(NetworkPolicy.allows(URL(string: "https://xiaohongshu.com.evil.test/a")!))
        XCTAssertFalse(NetworkPolicy.allows(URL(string: "https://www.xiaohongshu.com@evil.test/a")!))
        XCTAssertFalse(NetworkPolicy.allows(URL(string: "http://www.xiaohongshu.com/a")!))
        XCTAssertEqual(try NetworkPolicy.shareLink(in: "笔记 https://xhslink.cn/o/fixture 来看看").host, "xhslink.cn")
    }

    func testMobileNoteAndUndefinedInsideStrings() throws {
        let id = "123456789012345678901234"
        let html = #"<script>window.__INITIAL_STATE__={"unused":undefined,"noteData":{"data":{"noteData":{"noteId":"123456789012345678901234","title":"undefined {quoted}","imageList":[{"fileId":"abc/fixture","livePhoto":true,"stream":{"h264":[{"width":640,"height":480,"masterUrl":"https://sns-video-bd.xhscdn.com/low.mp4"},{"width":1080,"height":1440,"masterUrl":"https://sns-video-bd.xhscdn.com/high.mp4"}]}}]}}}};</script>"#
        let note = try NoteResolver.parse(html: html, url: URL(string: "https://www.xiaohongshu.com/discovery/item/\(id)")!)
        XCTAssertEqual(note.title, "undefined {quoted}")
        XCTAssertEqual(note.items.first?.video?.lastPathComponent, "high.mp4")
        XCTAssertEqual(note.items.first?.image?.path, "/abc/fixture")
        XCTAssertTrue(note.items.first!.isLive)
        XCTAssertThrowsError(try NoteResolver.parse(html: html, url: URL(string: "https://www.xiaohongshu.com/explore/aaaaaaaaaaaaaaaaaaaaaaaa")!))
    }

    func makeVideo(at url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 96])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 96])
        writer.add(input); XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<36 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 96, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            let address = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixel))
            memset(address, Int32(frame * 5), CVPixelBufferGetBytesPerRow(pixel) * 96)
            CVPixelBufferUnlockBaseAddress(pixel, [])
            XCTAssertTrue(adaptor.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
    }

    func compressedSamples(at url: URL) async throws -> [Data] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: nil)
        // The output's track must belong to the reader's AVAsset instance.
        let actualReader = try AVAssetReader(asset: asset)
        actualReader.add(output); XCTAssertTrue(actualReader.startReading())
        var samples: [Data] = []
        while let sample = output.copyNextSampleBuffer() {
            // AVAssetReader can emit zero-byte timing/end markers. They are not
            // compressed video payloads; still reject a missing nonempty buffer.
            if CMSampleBufferGetTotalSampleSize(sample) == 0 { continue }
            let block = try XCTUnwrap(CMSampleBufferGetDataBuffer(sample), "Missing compressed payload in \(url.lastPathComponent)")
            var bytes = Data(count: CMBlockBufferGetDataLength(block))
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            XCTAssertEqual(status, noErr); samples.append(bytes)
        }
        XCTAssertEqual(actualReader.status, .completed, actualReader.error?.localizedDescription ?? "")
        return samples
    }

    func testNativePairValidatesAndMovieSamplesAreUnchanged() async throws {
        let dir = try DownloadService.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.jpg"), input = dir.appendingPathComponent("input.mp4"), movie = dir.appendingPathComponent("pair.mov")
        try imageJPEG().write(to: source)
        try await makeVideo(at: input)
        let image = try OriginalImage.prepare(source: source, output: dir.appendingPathComponent("paired.jpg"))
        try await MoviePairer.pair(source: input, output: movie, identifier: image.identifier)
        let before = try await compressedSamples(at: input), after = try await compressedSamples(at: movie)
        XCTAssertEqual(before.count, 36); XCTAssertEqual(before, after)
        try await PhotoStore.validateLive(image: image.url, video: movie)
        // No CI test writes to a person's real photo library.
    }
}

extension CoreTests {
    func testNewPlatformLinksAndHostBoundaries() throws {
        for text in ["https://v.douyin.com/fixture/", "https://weibo.com/1/fixture", "https://www.instagram.com/p/Fixture/"] {
            XCTAssertNotNil(MediaPlatform.identify(try NetworkPolicy.shareLink(in: text)))
        }
        for raw in ["https://instagram.com.evil.test/p/x", "https://douyin.com@evil.test/video/1", "https://evil.test/file.mp4", "http://weibo.com/1/2"] {
            XCTAssertFalse(NetworkPolicy.allows(URL(string: raw)!, media: true))
        }
        XCTAssertFalse(NetworkPolicy.allows(URL(string: "https://cdninstagram.com/file.jpg")!))
        XCTAssertTrue(NetworkPolicy.allows(URL(string: "https://scontent.fixture.cdninstagram.com/file.jpg")!, media: true))
    }

    func testDouyinLiveImagesAndWrongPostRejection() throws {
        let data = #"{"loaderData":{"note_(id)/page":{"aweme_detail":{"aweme_id":"123456","images":[{"url_list":["https://p.example.byteimg.com/original.jpg"],"video":{"play_addr":{"url_list":["https://v.example.douyinvod.com/live.mp4"]}}}]}}}}"#
        let html = "<script>window._ROUTER_DATA = " + data + ";</script>"
        let note = try SocialResolver.parse(html: html, platform: .douyin, target: "123456")
        XCTAssertEqual(note.items.count, 1); XCTAssertTrue(note.items[0].isLive)
        XCTAssertEqual(note.items[0].image?.lastPathComponent, "original.jpg")
        XCTAssertThrowsError(try SocialResolver.parse(html: html, platform: .douyin, target: "999999"))
    }

    func testInstagramRouteMetadataIsNotMistakenForPost() throws {
        let data = #"{"route":{"shortcode":"Fixture"},"post":{"code":"Fixture","carousel_media":[{"media_type":1,"image_versions2":{"candidates":[{"width":100,"height":100,"url":"https://s.cdninstagram.com/low.jpg"},{"width":2000,"height":1500,"url":"https://s.cdninstagram.com/high.jpg"}]}},{"media_type":2,"video_versions":[{"width":1920,"height":1080,"url":"https://s.cdninstagram.com/movie.mp4"}]}]}}"#
        let note = try SocialResolver.parse(html: data, platform: .instagram, target: "Fixture")
        XCTAssertEqual(note.items.count, 2)
        XCTAssertEqual(note.items[0].image?.lastPathComponent, "high.jpg")
        XCTAssertEqual(note.items[1].video?.lastPathComponent, "movie.mp4")
        XCTAssertNil(note.items[1].image); XCTAssertFalse(note.items[1].isLive)
        XCTAssertThrowsError(try SocialResolver.parse(html: data, platform: .instagram, target: "Other"))
        XCTAssertEqual(SocialResolver.instagramPK("BA"), "64")
    }

    func testWeiboMixedPostOrderAndQuality() throws {
        let data = #"{"idstr":"12345","bid":"Example","mix_media_info":{"items":[{"type":"pic","data":{"largest":{"url":"https://wx1.sinaimg.cn/large/original.jpg"}}},{"type":"video","data":{"media_info":{"playback_list":[{"play_info":{"width":640,"height":360,"url":"https://f.video.weibocdn.com/low.mp4"}},{"play_info":{"width":1920,"height":1080,"url":"https://f.video.weibocdn.com/high.mp4"}}]}}}]}}"#
        let note = try SocialResolver.parse(html: data, platform: .weibo, target: "Example")
        XCTAssertEqual(note.items.count, 2)
        XCTAssertEqual(note.items[0].image?.lastPathComponent, "original.jpg")
        XCTAssertEqual(note.items[1].video?.lastPathComponent, "high.mp4")
        XCTAssertThrowsError(try SocialResolver.parse(html: data, platform: .weibo, target: "54321"))
    }

    func testCapturedPayloadsCannotDownloadRecommendedPost() throws {
        let payload = #"{"aweme_detail":{"aweme_id":"1234","video":{"play_addr":{"url_list":["https://v.douyinvod.com/post.mp4"]}}}}"#
        XCTAssertThrowsError(try SocialResolver.parse(html: "<html>login</html>", platform: .douyin, target: "9999", payloads: [payload]))
        let note = try SocialResolver.parse(html: "<html></html>", platform: .douyin, target: "1234", payloads: [payload])
        XCTAssertEqual(note.items[0].video?.lastPathComponent, "post.mp4")
    }
}


extension CoreTests {
    func generatedWebP() -> Data { Data(base64Encoded: "UklGRiQAAABXRUJQVlA4TBcAAAAvd8ATAAdQvJIUuf9hABLC//1SRP9TVwA=")! }
    func testTypedImagePreservesOriginalBytes() throws {
        let dir = try DownloadService.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("photo.data"), data = try imageJPEG()
        try data.write(to: source)
        let typed = try PhotoStore.typedImage(source)
        XCTAssertTrue(["jpg", "jpeg"].contains(typed.pathExtension))
        XCTAssertEqual(try Data(contentsOf: typed), data)
    }
    func testWebPCompatibilityPNGKeepsDimensions() throws {
        let dir = try DownloadService.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("image.data"), output = dir.appendingPathComponent("image.png")
        let bytes = generatedWebP(); try bytes.write(to: source)
        try PhotoStore.compatiblePNG(source, output: output)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil)! as NSDictionary
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth] as? Int, 120)
        XCTAssertEqual(properties[kCGImagePropertyPixelHeight] as? Int, 80)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }
    func testSimulatorPhotoLibraryImportsJPEGAndWebP() async throws {
        #if targetEnvironment(simulator)
        guard PHPhotoLibrary.authorizationStatus(for: .addOnly) == .authorized else {
            XCTFail("CI must grant photos-add permission before running import tests"); return
        }
        let dir = try DownloadService.folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let jpeg = dir.appendingPathComponent("plain.data"), webp = dir.appendingPathComponent("web.data")
        try imageJPEG().write(to: jpeg); try generatedWebP().write(to: webp)
        _ = try await PhotoStore.savePlainImage(jpeg)
        _ = try await PhotoStore.savePlainImage(webp)
        // This test writes only to an ephemeral CI simulator, never a real phone.
        #else
        throw XCTSkip("Only the disposable simulator library may be used")
        #endif
    }
}
