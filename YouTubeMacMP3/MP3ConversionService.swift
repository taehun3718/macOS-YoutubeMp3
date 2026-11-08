import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox
import SwiftLAME
import LAME

struct ConversionResult {
    let file: URL
    let outputLog: String
}

enum ConversionFailure: LocalizedError {
    case invalidAddress
    case unsupportedScheme
    case noSuitableAudio
    case failedDownload
    case failedDecoding
    case failedEncoding
    case invalidVideo
    case downloadHTTP(Int)
    case downloadNotMedia(String)
    case emptyDownload
    case downloadTransport(String)
    case attemptsExhausted(String)

    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "올바른 URL을 입력하세요."
        case .unsupportedScheme: return "HTTPS 주소만 허용됩니다."
        case .noSuitableAudio: return "macOS에서 디코딩 가능한 M4A 오디오 스트림이 없습니다."
        case .failedDownload: return "오디오 파일을 다운로드하지 못했습니다."
        case .failedDecoding: return "오디오를 PCM 버퍼로 디코딩하지 못했습니다."
        case .failedEncoding: return "MP3 인코딩 결과 파일이 없습니다."
        case .invalidVideo: return "올바른 YouTube 영상 주소가 아닙니다."
        case .downloadHTTP(let code): return "다운로드 서버가 HTTP \(code)를 반환했습니다. 403이면 YouTube 측 스트림 접근 제한 또는 URL 만료 가능성이 있으며, 이 앱에서 강제로 해결할 수 없습니다."
        case .downloadNotMedia(let type): return "다운로드 응답이 오디오/영상 파일이 아닙니다 (Content-Type: \(type)). 로그인/오류 페이지일 수 있습니다."
        case .emptyDownload: return "다운로드된 파일이 비어 있습니다."
        case .downloadTransport(let reason): return "네트워크 다운로드 실패: \(reason)"
        case .attemptsExhausted(let details): return "사용 가능한 다운로드 경로를 모두 확인했지만 파일을 받지 못했습니다.\n\(details)"
        }
    }
}

enum MP3ConversionService {
    static func outputDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("YouTubeMacMP3", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Only use this pipeline for media the user has permission to download and convert.
    // A rejected 403 is a server-side denial; this code does not override access controls.
    // We re-resolve signed URLs and try genuinely different, natively decodable formats.
    static func fromAuthorizedVideoURL(
        _ address: String,
        bitrate: Int,
        allowRemoteFallback: Bool = false,
        downloadProgress: @escaping (Double) -> Void = { _ in },
        conversionProgress: @escaping (Double) -> Void = { _ in },
    ) async throws -> ConversionResult {
        guard let url = URL(string: address), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            throw ConversionFailure.invalidAddress
        }
        _ = allowRemoteFallback // Deprecated: no external extraction provider is used.
        let isYouTube = ["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be"].contains(host)
        let downloaded: URL
        let originalTitle: String
        if isYouTube {
            let info = try await YTDLPDownloader.downloadAudio(from: url, progress: downloadProgress)
            downloaded = info.url
            originalTitle = info.originalTitle
        } else {
            downloaded = try await downloadValidatedMedia(from: url, expectedExtension: nil)
            originalTitle = url.deletingPathExtension().lastPathComponent
            downloadProgress(1)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        return try await fromLocalFile(
            downloaded, bitrate: bitrate, originalTitle: originalTitle,
            conversionProgress: conversionProgress
        )
    }

    private static func downloadValidatedMedia(
        from media: URL,
        expectedExtension: String?
    ) async throws -> URL {
        let downloaded: URL
        let response: URLResponse
        do {
            var request = URLRequest(url: media)
            request.timeoutInterval = 40
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            (downloaded, response) = try await URLSession.shared.download(for: request)
        } catch {
            throw ConversionFailure.downloadTransport(error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard let http = response as? HTTPURLResponse else {
            throw ConversionFailure.failedDownload
        }
        guard (200...299).contains(http.statusCode) else {
            throw ConversionFailure.downloadHTTP(http.statusCode)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
        let type = contentType.lowercased()
        guard !type.contains("text/html"), !type.contains("application/json"),
              !type.contains("text/plain"), !type.contains("xml") else {
            throw ConversionFailure.downloadNotMedia(contentType)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: downloaded.path)
        guard (attrs[.size] as? NSNumber)?.int64Value ?? 0 > 0 else {
            throw ConversionFailure.emptyDownload
        }
        let suffix = expectedExtension ?? media.pathExtension.lowercased()
        let ext = ["m4a", "mp4", "mov", "wav", "aif", "aiff", "caf"].contains(suffix)
            ? suffix : (type.contains("mp4") ? "mp4" : "m4a")
        let staged = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        try FileManager.default.copyItem(at: downloaded, to: staged)
        return staged
    }

    /// Streams decoded 16-bit stereo PCM directly into the LAME encoder.
    /// No intermediate WAV/PCM file is created on disk.
    static func fromLocalFile(
        _ source: URL, bitrate: Int,
        originalTitle: String? = nil,
        conversionProgress: @escaping (Double) -> Void = { _ in }
    ) async throws -> ConversionResult {
        guard [128, 192, 256, 320].contains(bitrate) else {
            throw ConversionFailure.failedEncoding
        }
        let folder = try outputDirectory()
        let rawTitle = originalTitle ?? source.deletingPathExtension().lastPathComponent
        let destination = uniqueDestination(in: folder, title: safeFileTitle(rawTitle))
        // Keep synchronous CoreMedia extraction and LAME CPU work off the SwiftUI main actor.
        return try await Task.detached(priority: .userInitiated) {
            try await streamPCMToMP3(
                source: source,
                destination: destination,
                bitrate: bitrate,
                progress: conversionProgress
            )
            return ConversionResult(
                file: destination,
                outputLog: "AVAssetReader PCM buffer -> LAME MP3 (no intermediate WAV)"
            )
        }.value
    }

    private static func streamPCMToMP3(
        source: URL,
        destination: URL,
        bitrate: Int,
        progress: @escaping (Double) -> Void
    ) async throws {
        let asset = AVURLAsset(url: source)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw ConversionFailure.failedDecoding }

        // The PCM is interleaved, signed Int16, stereo, 44.1kHz (4 bytes per frame).
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(readerOutput)

        guard let lame = lame_init() else { throw ConversionFailure.failedEncoding }
        defer { lame_close(lame) }
        guard lame_set_in_samplerate(lame, 44_100) == 0,
              lame_set_out_samplerate(lame, 44_100) == 0,
              lame_set_num_channels(lame, 2) == 0,
              lame_set_brate(lame, Int32(bitrate)) == 0,
              lame_set_quality(lame, 5) == 0,
              lame_set_bWriteVbrTag(lame, 0) == 0,
              lame_init_params(lame) == 0 else {
            throw ConversionFailure.failedEncoding
        }

        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let outputFile = try FileHandle(forWritingTo: destination)
        defer { try? outputFile.close() }
        var succeeded = false
        defer {
            if !succeeded { try? FileManager.default.removeItem(at: destination) }
        }
        guard reader.startReading() else {
            throw reader.error ?? ConversionFailure.failedDecoding
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }
        progress(0)
        var writtenBytes = 0
        var lastReported = -1
        // Reuse PCM and output storage instead of allocating per sample buffer.
        var pcm = [Int16](repeating: 0, count: 65_536 * 2)
        var mp3Bytes = [UInt8](repeating: 0, count: 65_536 * 2)

        while let sample = readerOutput.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount > 0 else { continue }
            guard byteCount % 4 == 0 else { throw ConversionFailure.failedDecoding }
            let frames = byteCount / 4
            guard frames <= Int(Int32.max) else { throw ConversionFailure.failedDecoding }

            // Grow only if needed; the allocation is reused for every audio block.
            if pcm.count < byteCount / 2 {
                pcm = [Int16](repeating: 0, count: byteCount / 2)
            }
            let copyResult = pcm.withUnsafeMutableBytes { raw -> OSStatus in
                guard let destination = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    block, atOffset: 0, dataLength: byteCount, destination: destination
                )
            }
            guard copyResult == noErr else { throw ConversionFailure.failedDecoding }

            // LAME's documented safe MP3 buffer size: 1.25 * samples + 7200.
            let capacity = Int(Double(frames) * 1.25) + 7_200
            if mp3Bytes.count < capacity {
                mp3Bytes = [UInt8](repeating: 0, count: capacity)
            }
            guard mp3Bytes.count <= Int(Int32.max) else {
                throw ConversionFailure.failedEncoding
            }
            let encodedCount: Int32 = pcm.withUnsafeMutableBufferPointer { samples in
                mp3Bytes.withUnsafeMutableBufferPointer { mp3 in
                    lame_encode_buffer_interleaved(
                        lame, samples.baseAddress, Int32(frames), mp3.baseAddress, Int32(mp3.count)
                    )
                }
            }
            guard encodedCount >= 0 else { throw ConversionFailure.failedEncoding }
            if encodedCount > 0 {
                try outputFile.write(contentsOf: Data(mp3Bytes.prefix(Int(encodedCount))))
                writtenBytes += Int(encodedCount)
            }

            let elapsed = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            if seconds.isFinite, seconds > 0, elapsed.isFinite {
                let percent = Int(min(99, max(0, elapsed / seconds * 100)))
                if percent >= lastReported + 2 {
                    lastReported = percent
                    progress(Double(percent) / 100)
                }
            }
        }
        guard reader.status == .completed else {
            throw reader.error ?? ConversionFailure.failedDecoding
        }
        var flushBytes = [UInt8](repeating: 0, count: 7_200)
        let flushCount = flushBytes.withUnsafeMutableBufferPointer { buffer in
            lame_encode_flush(lame, buffer.baseAddress, Int32(buffer.count))
        }
        guard flushCount >= 0 else { throw ConversionFailure.failedEncoding }
        if flushCount > 0 {
            try outputFile.write(contentsOf: Data(flushBytes.prefix(Int(flushCount))))
            writtenBytes += Int(flushCount)
        }
        guard writtenBytes > 0 else { throw ConversionFailure.failedEncoding }
        try outputFile.synchronize()
        succeeded = true
        progress(1)
    }

    private static func safeFileTitle(_ raw: String) -> String {
        // Keep the original title as far as possible; remove invalid path/control chars.
        let forbidden = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(150))
    }

    private static func uniqueDestination(in folder: URL, title: String) -> URL {
        let manager = FileManager.default
        var result = folder.appendingPathComponent(title).appendingPathExtension("mp3")
        var suffix = 2
        while manager.fileExists(atPath: result.path) {
            result = folder.appendingPathComponent("\(title) (\(suffix))").appendingPathExtension("mp3")
            suffix += 1
        }
        return result
    }

}
