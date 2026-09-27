import Foundation

/// HLS 播放列表（m3u8）解析结果
public struct HLSPlaylist: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// 主 playlist（多码率变体）
        case master
        /// 媒体 playlist（分片列表）
        case media
    }

    public let kind: Kind
    /// master：变体列表（原文顺序）
    public let variants: [HLSVariant]
    /// media：分片列表（原文顺序）
    public let segments: [HLSSegment]
    /// EXT-X-TARGETDURATION（media）
    public let targetDuration: Double?
    /// EXT-X-ENDLIST（点播完整流；false 可能是直播流，不应整体缓存）
    public let isVOD: Bool
    /// EXT-X-MAP 的 URI（fMP4 初始化段，media）
    public let initSegmentURI: String?
}

/// HLS 变体流（master playlist 的一项）
public struct HLSVariant: Sendable, Equatable {
    public let uri: String
    public let bandwidth: Int
    public let width: Int?
    public let height: Int?
    public let name: String?
}

/// HLS 分片（media playlist 的一项）
public struct HLSSegment: Sendable, Equatable {
    public let uri: String
    /// EXT-X-INF 的时长（秒）
    public let duration: Double
}

/// m3u8 解析错误
public enum HLSError: LocalizedError, Equatable {
    case notAPlaylist
    case emptyPlaylist

    public var errorDescription: String? {
        switch self {
        case .notAPlaylist: return "不是有效的 m3u8 播放列表"
        case .emptyPlaylist: return "播放列表为空"
        }
    }
}

/// HLS（m3u8）纯解析：无网络、无 IO，可单测。
/// 覆盖点播常见形态：master/media、EXT-X-MAP（fMP4）、EXT-X-ENDLIST。
/// 不支持加密分片（EXT-X-KEY）——遇到时按原样解析 URI，由播放内核处理。
public enum HLSParser {
    public static func parse(_ text: String) throws -> HLSPlaylist {
        // m3u8 必须以 #EXTM3U 开头（允许 BOM/前导空白）
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#EXTM3U") else { throw HLSError.notAPlaylist }

        var variants: [HLSVariant] = []
        var segments: [HLSSegment] = []
        var targetDuration: Double?
        var isVOD = false
        var initSegmentURI: String?

        var pendingVariantAttrs: String?
        var pendingDuration: Double?

        for rawLine in trimmed.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#") {
                if line.hasPrefix("#EXT-X-STREAM-INF:") {
                    pendingVariantAttrs = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
                } else if line.hasPrefix("#EXTINF:") {
                    // "#EXTINF:10.000," → 10.000
                    let body = line.dropFirst("#EXTINF:".count)
                    let durationText = body.split(separator: ",", maxSplits: 1).first.map(String.init) ?? ""
                    pendingDuration = Double(durationText.trimmingCharacters(in: .whitespaces))
                } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                    targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                } else if line.hasPrefix("#EXT-X-ENDLIST") {
                    isVOD = true
                } else if line.hasPrefix("#EXT-X-MAP:") {
                    // EXT-X-MAP 的 URI 是内联属性（fMP4 初始化段）；只传属性部分
                    initSegmentURI = Self.attribute(String(line.dropFirst("#EXT-X-MAP:".count)), name: "URI")
                }
                continue
            }

            // 非 # 行 = URI，归属最近的 tag
            if let attrs = pendingVariantAttrs {
                variants.append(HLSVariant(
                    uri: line,
                    bandwidth: Int(Self.attribute(attrs, name: "BANDWIDTH") ?? "") ?? 0,
                    width: Self.resolution(attrs)?.width,
                    height: Self.resolution(attrs)?.height,
                    name: Self.attribute(attrs, name: "NAME")
                ))
                pendingVariantAttrs = nil
            } else {
                segments.append(HLSSegment(uri: line, duration: pendingDuration ?? 0))
                pendingDuration = nil
            }
        }

        if !variants.isEmpty {
            return HLSPlaylist(kind: .master, variants: variants, segments: [],
                               targetDuration: nil, isVOD: false, initSegmentURI: nil)
        }
        if !segments.isEmpty || initSegmentURI != nil {
            return HLSPlaylist(kind: .media, variants: [], segments: segments,
                               targetDuration: targetDuration, isVOD: isVOD,
                               initSegmentURI: initSegmentURI)
        }
        throw HLSError.emptyPlaylist
    }

    /// 把 playlist 内的相对/绝对 URI 解析成绝对 URL（相对基准为 playlist 的 URL）
    public static func resolve(_ uri: String, against playlistURL: URL) -> URL? {
        if let url = URL(string: uri), url.scheme != nil { return url }
        return URL(string: uri, relativeTo: playlistURL)?.absoluteURL
    }

    /// master 变体里选码率最高的（在线播放的默认策略）
    public static func bestVariant(in playlist: HLSPlaylist) -> HLSVariant? {
        playlist.variants.max { $0.bandwidth < $1.bandwidth }
    }

    // MARK: - 属性解析

    /// 从 "NAME=\"720p\",BANDWIDTH=800000" 里取指定属性（带引号或不带）
    static func attribute(_ attrs: String, name: String) -> String? {
        for pair in attrs.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard kv.count == 2, kv[0].uppercased() == name.uppercased() else { continue }
            return kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    /// RESOLUTION=1920x1080
    static func resolution(_ attrs: String) -> (width: Int, height: Int)? {
        guard let text = attribute(attrs, name: "RESOLUTION") else { return nil }
        let parts = text.split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return nil }
        return (w, h)
    }
}
