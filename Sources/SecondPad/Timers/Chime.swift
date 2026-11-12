import AVFoundation

/// The tablet plays the Mac's own "Glass" sound when the Quick timer ends. It is read from macOS
/// at run time (never shipped with the app) and handed over as WAV, which Chrome can decode.
enum Chime {
    private static var cached: Data?

    static func glassWAV() -> Data? {
        if let cached { return cached }
        let url = URL(fileURLWithPath: "/System/Library/Sounds/Glass.aiff")
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil,
              let channels = buffer.floatChannelData else { return nil }
        let data = wav(channels: (0..<Int(buffer.format.channelCount)).map { UnsafePointer(channels[$0]) },
                       frames: Int(buffer.frameLength), sampleRate: Int(buffer.format.sampleRate))
        cached = data
        return data
    }

    /// 16-bit PCM WAV from float samples. Pure, unit-tested.
    nonisolated static func wav(channels: [UnsafePointer<Float>], frames: Int, sampleRate: Int) -> Data {
        let channelCount = max(1, channels.count)
        let dataBytes = frames * channelCount * 2
        var out = Data()
        func put(_ text: String) { out.append(contentsOf: Array(text.utf8)) }
        func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
        put("RIFF"); put32(UInt32(36 + dataBytes)); put("WAVE")
        put("fmt "); put32(16); put16(1); put16(UInt16(channelCount)); put32(UInt32(sampleRate))
        put32(UInt32(sampleRate * channelCount * 2)); put16(UInt16(channelCount * 2)); put16(16)
        put("data"); put32(UInt32(dataBytes))
        out.reserveCapacity(out.count + dataBytes)
        for frame in 0..<frames {
            for channel in 0..<channelCount {
                let sample = channels.isEmpty ? 0 : max(-1, min(1, channels[channel][frame]))
                put16(UInt16(bitPattern: Int16(sample * 32_767)))
            }
        }
        return out
    }
}
