import AudioToolbox
import Foundation

/// Thin Swift wrapper around AudioToolbox's `AudioFileStream` C API (#39).
///
/// Feed it raw container bytes as they arrive off the network (or disk) via
/// `parse(_:discontinuity:)`; it emits two callbacks:
///
///   * `onReadyToProducePackets` — fired once, when the header has been
///     parsed far enough to know the stream's `AudioStreamBasicDescription`
///     (and magic cookie, for formats that carry one). The DSP pipeline uses
///     this to build the matching `AVAudioConverter` + engine graph.
///   * `onPackets` — fired for every parsed batch of audio packets. For
///     VBR/compressed formats the packet descriptions are forwarded; for
///     CBR/LPCM they're `nil` and the bytes are frame-aligned PCM.
///
/// Threading: not internally synchronized. The owner (`DSPTrackStreamer`)
/// confines every call — including `seekByteOffset` — to its serial decode
/// queue, matching how the C API expects to be driven.
///
/// Container support is whatever `AudioFileStream` supports: MP3, AAC/ADTS,
/// FLAC, WAV/AIFF, and fast-start MP4/M4A. Ogg (Vorbis/Opus) is *not*
/// parseable by AudioToolbox — `parse` surfaces the open/parse error and the
/// caller treats the track as unplayable on the DSP path (a listed #39 gap).
final class DSPAudioFileStreamParser {
    /// One parsed batch of audio packets, exactly as the C callback delivered
    /// it. `packetDescriptions` is `nil` for CBR/LPCM streams (every packet is
    /// `bytesPerPacket` long); present for VBR streams (MP3/AAC/FLAC).
    struct PacketBatch {
        let data: Data
        let packetDescriptions: [AudioStreamPacketDescription]?
        let packetCount: Int
    }

    enum ParserError: Error, LocalizedError {
        case openFailed(OSStatus)
        case parseFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .openFailed(let status): return "AudioFileStreamOpen failed (\(status))"
            case .parseFailed(let status): return "AudioFileStreamParseBytes failed (\(status))"
            }
        }
    }

    /// Fired once the stream header is fully parsed. Carries the source
    /// format and the magic cookie (nil for cookie-less formats like MP3).
    var onReadyToProducePackets: ((AudioStreamBasicDescription, Data?) -> Void)?

    /// Fired per parsed packet batch, after `onReadyToProducePackets`.
    var onPackets: ((PacketBatch) -> Void)?

    /// Source format, available once `onReadyToProducePackets` has fired.
    private(set) var streamDescription: AudioStreamBasicDescription?

    /// Byte offset of the first audio packet within the container — the
    /// header size. Seek math is `dataOffset + packetByteOffset`.
    private(set) var dataOffset: Int64 = 0

    /// Total audio-data byte count when the container declares it (0 when
    /// unknown, e.g. a chunked transcode with no length).
    private(set) var audioDataByteCount: UInt64 = 0

    /// Total audio packet count when the container declares it (0 = unknown).
    private(set) var audioDataPacketCount: UInt64 = 0

    /// Largest possible packet size, used to size compressed buffers. Falls
    /// back to a generous default when the stream doesn't declare one.
    private(set) var maxPacketSize: UInt32 = 0

    private(set) var isReadyToProducePackets = false

    private var streamID: AudioFileStreamID?

    /// `fileTypeHint` biases container sniffing (`kAudioFileFLACType`, …);
    /// pass 0 to let AudioToolbox detect from the bytes alone.
    init(fileTypeHint: AudioFileTypeID = 0) throws {
        var stream: AudioFileStreamID?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = AudioFileStreamOpen(
            context,
            { context, streamID, propertyID, _ in
                let parser = Unmanaged<DSPAudioFileStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handleProperty(streamID: streamID, propertyID: propertyID)
            },
            { context, byteCount, packetCount, bytes, packetDescriptions in
                let parser = Unmanaged<DSPAudioFileStreamParser>.fromOpaque(context).takeUnretainedValue()
                parser.handlePackets(
                    byteCount: byteCount,
                    packetCount: packetCount,
                    bytes: bytes,
                    packetDescriptions: packetDescriptions
                )
            },
            fileTypeHint,
            &stream
        )
        guard status == noErr, let stream else {
            throw ParserError.openFailed(status)
        }
        self.streamID = stream
    }

    deinit {
        if let streamID {
            AudioFileStreamClose(streamID)
        }
    }

    /// Push the next chunk of container bytes through the parser. Set
    /// `discontinuity` after a seek (the bytes don't follow the previous
    /// call's bytes) so the parser resynchronizes on packet boundaries.
    func parse(_ data: Data, discontinuity: Bool = false) throws {
        guard let streamID else { return }
        guard !data.isEmpty else { return }
        let flags: AudioFileStreamParseFlags = discontinuity ? [.discontinuity] : []
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return noErr }
            return AudioFileStreamParseBytes(streamID, UInt32(raw.count), base, flags)
        }
        guard status == noErr else {
            throw ParserError.parseFailed(status)
        }
    }

    /// Map a packet index to the container byte offset its data starts at
    /// (relative to the whole file — `dataOffset` already added). Returns
    /// `nil` when the stream can't seek (header not parsed yet, or the
    /// format carries no packet table and no bitrate estimate).
    /// `isEstimated` is true for VBR streams where the offset is the
    /// parser's average-bitrate guess rather than an exact table lookup.
    func seekByteOffset(forPacket packet: Int64) -> (byteOffset: Int64, isEstimated: Bool)? {
        guard let streamID, isReadyToProducePackets else { return nil }
        var packetByteOffset: Int64 = 0
        var flags = AudioFileStreamSeekFlags()
        let status = AudioFileStreamSeek(streamID, packet, &packetByteOffset, &flags)
        guard status == noErr else { return nil }
        return (dataOffset + packetByteOffset, flags.contains(.offsetIsEstimated))
    }

    // MARK: - C callback handlers

    private func handleProperty(streamID: AudioFileStreamID, propertyID: AudioFileStreamPropertyID) {
        switch propertyID {
        case kAudioFileStreamProperty_ReadyToProducePackets:
            var asbd = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataFormat, &size, &asbd) == noErr else {
                return
            }
            streamDescription = asbd

            var offset: Int64 = 0
            var offsetSize = UInt32(MemoryLayout<Int64>.size)
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset) == noErr {
                dataOffset = offset
            }

            var byteCount: UInt64 = 0
            var byteCountSize = UInt32(MemoryLayout<UInt64>.size)
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &byteCount) == noErr {
                audioDataByteCount = byteCount
            }

            var packetCount: UInt64 = 0
            var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_AudioDataPacketCount, &packetCountSize, &packetCount) == noErr {
                audioDataPacketCount = packetCount
            }

            var upperBound: UInt32 = 0
            var upperBoundSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_PacketSizeUpperBound, &upperBoundSize, &upperBound) == noErr, upperBound > 0 {
                maxPacketSize = upperBound
            } else {
                var maxSize: UInt32 = 0
                var maxSizeSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_MaximumPacketSize, &maxSizeSize, &maxSize) == noErr, maxSize > 0 {
                    maxPacketSize = maxSize
                }
            }
            if maxPacketSize == 0 {
                // No declared bound (some chunked streams) — a generous
                // ceiling that comfortably covers MP3 (≤1.5 KB), AAC and
                // FLAC (≤16 KB typical) frames.
                maxPacketSize = 32_768
            }

            // Magic cookie (codec private data — AAC/ALAC carry one, MP3/
            // FLAC-in-flac don't). Optional by design.
            var cookieSize: UInt32 = 0
            var writable: DarwinBoolean = false
            var cookie: Data?
            if AudioFileStreamGetPropertyInfo(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &writable) == noErr, cookieSize > 0 {
                var cookieBytes = [UInt8](repeating: 0, count: Int(cookieSize))
                if AudioFileStreamGetProperty(streamID, kAudioFileStreamProperty_MagicCookieData, &cookieSize, &cookieBytes) == noErr {
                    cookie = Data(cookieBytes)
                }
            }

            isReadyToProducePackets = true
            onReadyToProducePackets?(asbd, cookie)
        default:
            break
        }
    }

    private func handlePackets(
        byteCount: UInt32,
        packetCount: UInt32,
        bytes: UnsafeRawPointer,
        packetDescriptions: UnsafeMutablePointer<AudioStreamPacketDescription>?
    ) {
        guard byteCount > 0 else { return }
        let data = Data(bytes: bytes, count: Int(byteCount))
        var descriptions: [AudioStreamPacketDescription]?
        if let packetDescriptions, packetCount > 0 {
            descriptions = Array(UnsafeBufferPointer(start: packetDescriptions, count: Int(packetCount)))
        }
        // LPCM streams report packetCount in packets (== frames); compressed
        // streams match the description count. Either way `packetCount` is
        // authoritative.
        onPackets?(PacketBatch(data: data, packetDescriptions: descriptions, packetCount: Int(packetCount)))
    }
}
