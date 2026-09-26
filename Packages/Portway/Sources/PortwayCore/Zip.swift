// SPDX-License-Identifier: MIT
// Copyright © 2026 Portway. All Rights Reserved.
//
// Just enough zip for configs: read stored and deflated entries (what every provider's export
// tool writes), and write stored entries (configs are tiny; compression buys nothing).

import Foundation
#if canImport(Compression)
import Compression
#endif

public enum Zip {
    public struct Entry: Sendable {
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }
    }

    public static func looksLikeZip(_ data: Data) -> Bool {
        data.count >= 4 && data.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04])
    }

    // MARK: Read (via the central directory, which is authoritative)

    /// Configs are under a kilobyte; these bounds only have to stop a crafted archive. Without them
    /// an 18 KB zip whose entries all point at one deflated blob inflated to hundreds of MB.
    static let maxEntries = 256
    static let maxEntryBytes = 256 * 1024
    static let maxTotalBytes = 2 * 1024 * 1024

    public static func read(_ data: Data) -> [Entry]? {
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { o + 2 <= bytes.count ? Int(bytes[o]) | Int(bytes[o + 1]) << 8 : 0 }
        func u32(_ o: Int) -> Int { o + 4 <= bytes.count ? u16(o) | u16(o + 2) << 16 : 0 }

        // End of central directory: scan back over a possible comment.
        var eocd = -1
        var i = bytes.count - 22
        while i >= max(0, bytes.count - 22 - 65_535) {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let count = u16(eocd + 10)
        guard count <= maxEntries else { return nil }
        var offset = u32(eocd + 16)
        var entries: [Entry] = []
        var seenLocal = Set<Int>()
        var total = 0
        for _ in 0..<count {
            guard u32(offset) == 0x0201_4B50 else { return nil }
            let method = u16(offset + 10)
            let compressed = u32(offset + 20)
            let uncompressed = u32(offset + 24)
            let nameLength = u16(offset + 28)
            let extraLength = u16(offset + 30)
            let commentLength = u16(offset + 32)
            let local = u32(offset + 42)
            guard offset + 46 + nameLength <= bytes.count else { return nil }
            let name = String(decoding: bytes[(offset + 46)..<(offset + 46 + nameLength)], as: UTF8.self)
            offset += 46 + nameLength + extraLength + commentLength

            guard u32(local) == 0x0403_4B50, seenLocal.insert(local).inserted else { continue }
            guard uncompressed <= maxEntryBytes, compressed <= maxEntryBytes else { continue }
            total += uncompressed
            guard total <= maxTotalBytes else { return entries }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + compressed <= bytes.count, !name.hasSuffix("/") else { continue }
            let body = Data(bytes[start..<(start + compressed)])
            switch method {
            case 0: entries.append(Entry(name: name, data: body))
            case 8: if let inflated = inflate(body, expected: uncompressed) { entries.append(Entry(name: name, data: inflated)) }
            default: continue
            }
        }
        return entries
    }

    private static func inflate(_ data: Data, expected: Int) -> Data? {
        #if canImport(Compression)
        // COMPRESSION_ZLIB is raw DEFLATE (RFC 1951), which is exactly what zip stores.
        if expected == 0 { return Data() }
        let capacity = expected
        guard capacity <= maxEntryBytes else { return nil }
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst in
            data.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        return written == expected ? out : nil
        #else
        return nil
        #endif
    }

    // MARK: Write (stored)

    public static func write(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        func le16(_ v: Int, _ d: inout Data) { d.append(UInt8(v & 0xFF)); d.append(UInt8(v >> 8 & 0xFF)) }
        func le32(_ v: Int, _ d: inout Data) { le16(v & 0xFFFF, &d); le16(v >> 16 & 0xFFFF, &d) }

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = Int(crc32(entry.data))
            let offset = out.count
            le32(0x0403_4B50, &out); le16(20, &out); le16(0x0800, &out); le16(0, &out)
            le16(0, &out); le16(0x21, &out)   // time 00:00, date 1980-01-01
            le32(crc, &out); le32(entry.data.count, &out); le32(entry.data.count, &out)
            le16(name.count, &out); le16(0, &out)
            out.append(name); out.append(entry.data)

            le32(0x0201_4B50, &central); le16(20, &central); le16(20, &central); le16(0x0800, &central)
            le16(0, &central); le16(0, &central); le16(0x21, &central)
            le32(crc, &central); le32(entry.data.count, &central); le32(entry.data.count, &central)
            le16(name.count, &central); le16(0, &central); le16(0, &central); le16(0, &central)
            le16(0, &central); le32(0, &central); le32(offset, &central)
            central.append(name)
        }
        let centralOffset = out.count
        out.append(central)
        le32(0x0605_4B50, &out); le16(0, &out); le16(0, &out)
        le16(entries.count, &out); le16(entries.count, &out)
        le32(central.count, &out); le32(centralOffset, &out); le16(0, &out)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
