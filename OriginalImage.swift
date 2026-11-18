import Foundation
import ImageIO

struct PreparedImage {
    let url: URL
    let identifier: String
    let unchanged: Bool
}

enum OriginalImage {
    static func identifier(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let maker = properties[kCGImagePropertyMakerAppleDictionary] as? NSDictionary else { return nil }
        let value = (maker["17"] ?? maker[17]) as? String
        return value?.trimmingCharacters(in: .controlCharacters)
    }

    static func prepare(source: URL, output: URL) throws -> PreparedImage {
        guard let image = CGImageSourceCreateWithURL(source as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
            throw LiveError.message("下载的封面不是可读取的图片。")
        }
        if let id = identifier(at: source), UUID(uuidString: id) != nil {
            // Reuse the original photo's identity: no image or metadata rewrite at all.
            try FileManager.default.copyItem(at: source, to: output)
            guard try Data(contentsOf: source) == Data(contentsOf: output) else { throw LiveError.message("原图复制校验失败。") }
            return PreparedImage(url: output, identifier: id, unchanged: true)
        }
        let original = try Data(contentsOf: source)
        let id = UUID().uuidString
        let tagged = try LosslessJPEG.tag(original, identifier: id)
        try tagged.write(to: output, options: .atomic)
        guard identifier(at: output) == id,
              try LosslessJPEG.scanData(original) == LosslessJPEG.scanData(tagged) else {
            throw LiveError.message("图片配对标识或压缩数据校验失败，已停止，未降低原图画质。")
        }
        return PreparedImage(url: output, identifier: id, unchanged: false)
    }
}

// JPEG metadata-only writer. The entropy-coded image, later MPO images and all
// non-EXIF segments are copied byte-for-byte. No image decoding/encoding occurs.
enum LosslessJPEG {
    struct Segment { let marker: UInt8; let range: Range<Int>; let payload: Range<Int> }

    static func segments(_ data: Data) throws -> [Segment] {
        guard data.count >= 4, data[0] == 0xff, data[1] == 0xd8 else {
            throw LiveError.message("此图没有现成实况标识，且不是可无损补写的 JPEG。首版不会转码 HEIC/PNG 封面。")
        }
        var cursor = 2, result: [Segment] = []
        while cursor + 1 < data.count {
            let start = cursor
            guard data[cursor] == 0xff else { throw LiveError.message("JPEG 标记损坏。") }
            while cursor < data.count, data[cursor] == 0xff { cursor += 1 }
            guard cursor < data.count else { throw LiveError.message("JPEG 文件截断。") }
            let marker = data[cursor]; cursor += 1
            if marker == 0xda || marker == 0xd9 {
                result.append(Segment(marker: marker, range: start..<data.count, payload: cursor..<data.count))
                return result
            }
            guard cursor + 2 <= data.count else { throw LiveError.message("JPEG 长度缺失。") }
            let length = Int(data[cursor]) * 256 + Int(data[cursor + 1])
            guard length >= 2, cursor + length <= data.count else { throw LiveError.message("JPEG 段长度错误。") }
            result.append(Segment(marker: marker, range: start..<(cursor + length), payload: (cursor + 2)..<(cursor + length)))
            cursor += length
        }
        throw LiveError.message("JPEG 缺少图像数据。")
    }

    static func scanData(_ data: Data) throws -> Data {
        guard let scan = try segments(data).first(where: { $0.marker == 0xda }) else { throw LiveError.message("JPEG 无扫描数据。") }
        return Data(data[scan.range])
    }

    static func tag(_ jpeg: Data, identifier: String) throws -> Data {
        guard UUID(uuidString: identifier) != nil else { throw LiveError.message("配对标识必须为 UUID。") }
        let parts = try segments(jpeg)
        let exif = parts.first { $0.marker == 0xe1 && jpeg[$0.payload].starts(with: Data("Exif\0\0".utf8)) }
        // MPF stores both image sizes and offsets. Updating EXIF without rebuilding
        // those tables could damage an HDR gain map. Existing-ID MPOs take the
        // unchanged-file path above; untagged MPOs must fail rather than lose HDR.
        if parts.contains(where: { $0.marker == 0xe2 && jpeg[$0.payload].starts(with: Data("MPF\0".utf8)) }) {
            throw LiveError.message("这张 MPO/HDR 图片没有可复用的实况标识，首版暂不补写，以免损坏增益图。原图未改变。")
        }
        var tiff = exif.map { Data(jpeg[($0.payload.lowerBound + 6)..<$0.payload.upperBound]) } ?? Data([0x49,0x49,42,0,8,0,0,0,0,0,0,0,0,0])
        let little = tiff.prefix(2) == Data([0x49,0x49])
        guard little || tiff.prefix(2) == Data([0x4d,0x4d]) else { throw LiveError.message("EXIF 字节序不受支持。") }
        func read(_ offset: Int, _ size: Int) throws -> UInt32 {
            guard offset >= 0, offset + size <= tiff.count else { throw LiveError.message("EXIF 数据越界。") }
            var value: UInt32 = 0
            for i in 0..<size { value |= UInt32(tiff[offset+i]) << ((little ? i : size-1-i)*8) }
            return value
        }
        func bytes(_ value: UInt32, _ size: Int) -> Data {
            Data((0..<size).map { UInt8(truncatingIfNeeded: value >> ((little ? $0 : size-1-$0)*8)) })
        }
        func entries(_ offset: Int) throws -> ([Data], UInt32) {
            let count = Int(try read(offset,2))
            guard count < 4096, offset + 2 + count*12 + 4 <= tiff.count else { throw LiveError.message("EXIF 目录损坏。") }
            return ((0..<count).map { Data(tiff[(offset+2+$0*12)..<(offset+14+$0*12)]) }, try read(offset+2+count*12,4))
        }
        func tagNumber(_ entry: Data) -> Int {
            little ? Int(entry[0]) + Int(entry[1])*256 : Int(entry[0])*256 + Int(entry[1])
        }
        func entry(_ tag: UInt32, _ type: UInt32, _ count: UInt32, _ value: UInt32) -> Data {
            bytes(tag,2) + bytes(type,2) + bytes(count,4) + bytes(value,4)
        }
        guard try read(2,2) == 42 else { throw LiveError.message("EXIF TIFF 头无效。") }
        let ifd0 = Int(try read(4,4))
        var (root, rootNext) = try entries(ifd0)
        let pointerIndex = root.firstIndex { tagNumber($0) == 0x8769 }
        var exifEntries: [Data] = [], exifNext: UInt32 = 0
        if let pointerIndex {
            let p = ifd0 + 2 + pointerIndex*12 + 8
            (exifEntries, exifNext) = try entries(Int(read(p,4)))
        }
        // Apple MakerNote: signature + version + big-endian IFD containing key 17.
        var maker = Data([65,112,112,108,101,32,105,79,83,0,0,1,77,77,0,1])
        maker.append(contentsOf: [0,17,0,2,0,0,0,37,0,0,0,32,0,0,0,0])
        maker.append(Data((identifier.uppercased() + "\0").utf8))
        if tiff.count % 2 != 0 { tiff.append(0) }
        let makerOffset = tiff.count; tiff.append(maker)
        exifEntries.removeAll { tagNumber($0) == 0x927c }
        exifEntries.append(entry(0x927c,7,UInt32(maker.count),UInt32(makerOffset)))
        exifEntries.sort { tagNumber($0) < tagNumber($1) }
        if tiff.count % 2 != 0 { tiff.append(0) }
        let exifOffset = tiff.count
        tiff.append(bytes(UInt32(exifEntries.count),2)); exifEntries.forEach { tiff.append($0) }; tiff.append(bytes(exifNext,4))
        if let pointerIndex {
            let start = ifd0 + 2 + pointerIndex*12 + 8
            tiff.replaceSubrange(start..<(start+4), with: bytes(UInt32(exifOffset),4))
        } else {
            root.append(entry(0x8769,4,1,UInt32(exifOffset))); root.sort { tagNumber($0) < tagNumber($1) }
            let rootOffset = tiff.count
            tiff.append(bytes(UInt32(root.count),2)); root.forEach { tiff.append($0) }; tiff.append(bytes(rootNext,4))
            tiff.replaceSubrange(4..<8, with: bytes(UInt32(rootOffset),4))
        }
        let payload = Data("Exif\0\0".utf8) + tiff
        guard payload.count + 2 <= 65535 else { throw LiveError.message("EXIF 太大，无法无损补写配对信息。") }
        var segment = Data([0xff,0xe1,UInt8((payload.count+2)>>8),UInt8((payload.count+2)&255)])
        segment.append(payload)
        var result = jpeg
        if let exif { result.replaceSubrange(exif.range, with: segment) }
        else { result.insert(contentsOf: segment, at: 2) }
        return result
    }
}
