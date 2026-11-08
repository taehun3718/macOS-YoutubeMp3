import Foundation
import CryptoKit

// macOS helper, not a shell command. All subprocess arguments are passed separately.
// Release is pinned; SHA-256 is checked against the same release's official manifest.
enum YTDLPDownloadError: LocalizedError {
    case invalidURL
    case installFailed(String)
    case checksumMismatch
    case toolFailed(String)
    case mediaMissing
    case unsupportedMedia(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "올바른 HTTPS YouTube 공유 URL이 아닙니다."
        case .installFailed(let detail): return "yt-dlp 엔진 설치 실패: \(detail)"
        case .checksumMismatch: return "yt-dlp 공식 체크섬 검증에 실패했습니다. 파일을 실행하지 않습니다."
        case .toolFailed(let detail): return "yt-dlp 다운로드 실패: \(detail)"
        case .mediaMissing: return "yt-dlp가 완료되었지만 다운로드된 오디오 파일이 없습니다."
        case .unsupportedMedia(let name): return "다운로드 형식(\(name))을 AVFoundation이 지원하지 않습니다. M4A/MP4 형식으로 내려받을 수 있는 영상에서 사용하세요."
        }
    }
}

struct DownloadedAudio {
    let url: URL
    let originalTitle: String
}

enum YTDLPDownloader {
    // Official release. Change the version and re-check the checksum manifest when updating.
    private static let version = "2026.10.26"
    private static let baseURL = "https://github.com/yt-dlp/yt-dlp/releases/download/\(version)/"
    private static let binaryName = "yt-dlp_macos"

    private static func installDirectory() throws -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("YouTubeMacMP3/Tools", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func officialHash() async throws -> String {
        guard let url = URL(string: baseURL + "SHA2-256SUMS") else { throw YTDLPDownloadError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else {
            throw YTDLPDownloadError.installFailed("공식 SHA2-256SUMS를 받지 못했습니다")
        }
        // SHA256SUMS rows are: <64 hex characters> <file name>
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2 else { continue }
            let file = fields.last!.trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            if file == binaryName && fields[0].count == 64 { return String(fields[0]).lowercased() }
        }
        throw YTDLPDownloadError.installFailed("체크섬 목록에서 yt-dlp_macos 파일을 찾지 못했습니다")
    }

    private static func verify(_ data: Data, expected: String) -> Bool {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined() == expected
    }

    static func executable() async throws -> URL {
        let folder = try installDirectory()
        let target = folder.appendingPathComponent("yt-dlp_macos-\(version)")
        let expected = try await officialHash()
        if let data = try? Data(contentsOf: target), verify(data, expected: expected) {
            return target
        }
        guard let downloadURL = URL(string: baseURL + binaryName) else { throw YTDLPDownloadError.invalidURL }
        let (temp, response) = try await URLSession.shared.download(from: downloadURL)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw YTDLPDownloadError.installFailed("공식 GitHub 릴리스 다운로드 HTTP 오류")
        }
        let data = try Data(contentsOf: temp)
        guard verify(data, expected: expected) else { throw YTDLPDownloadError.checksumMismatch }
        let pending = folder.appendingPathComponent(UUID().uuidString)
        try data.write(to: pending, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pending.path)
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.moveItem(at: pending, to: target)
        return target
    }

    static func downloadAudio(from url: URL, progress: @escaping (Double) -> Void) async throws -> DownloadedAudio {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              ["www.youtube.com", "youtube.com", "m.youtube.com", "youtu.be"].contains(host) else {
            throw YTDLPDownloadError.invalidURL
        }
        let exe = try await executable()
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("ytmp3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        do {
            let args = [
                "--no-playlist", "--no-config", "--no-warnings", "--newline",
                "--restrict-filenames", "--no-part", "--write-info-json",
                "--progress", "--progress-template", "download:DL_PROGRESS:%(progress._percent_str)s",
                "-f", "bestaudio[ext=m4a]/bestaudio[acodec^=mp4a]/best[ext=mp4]/bestaudio",
                "-o", working.appendingPathComponent("media.%(ext)s").path,
                url.absoluteString
            ]
            let output = try await run(executable: exe, arguments: args, progress: progress)
            let files = try FileManager.default.contentsOfDirectory(at: working, includingPropertiesForKeys: [.fileSizeKey])
            guard let media = files.first(where: { ["m4a", "mp4", "mov", "aac", "webm", "opus"].contains($0.pathExtension.lowercased()) }) else {
                throw YTDLPDownloadError.toolFailed(output.suffix(1800).description)
            }
            guard ["m4a", "mp4", "mov", "aac"].contains(media.pathExtension.lowercased()) else {
                throw YTDLPDownloadError.unsupportedMedia(media.pathExtension)
            }
            let metadata = working.appendingPathComponent("media.info.json")
            let title: String
            if let data = try? Data(contentsOf: metadata),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let original = object["title"] as? String, !original.isEmpty {
                title = original
            } else {
                title = url.lastPathComponent.isEmpty ? "YouTube Audio" : url.lastPathComponent
            }
            let staged = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(media.pathExtension)
            try FileManager.default.moveItem(at: media, to: staged)
            try? FileManager.default.removeItem(at: working)
            progress(1.0)
            return DownloadedAudio(url: staged, originalTitle: title)
        } catch {
            try? FileManager.default.removeItem(at: working)
            throw error
        }
    }

    private static func run(
        executable: URL,
        arguments: [String],
        progress: @escaping (Double) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.environment = ProcessInfo.processInfo.environment.merging(["PYTHONUNBUFFERED": "1"]) { _, newer in newer }
                do {
                    try process.run()
                    // Read incrementally: readDataToEndOfFile() reports progress only after exit.
                    let handle = pipe.fileHandleForReading
                    var pending = Data()
                    var recent = ""
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        while let index = pending.firstIndex(of: 0x0A) {
                            let lineData = pending.prefix(upTo: index)
                            pending.removeSubrange(...index)
                            let line = String(decoding: lineData, as: UTF8.self)
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            if let marker = line.range(of: "DL_PROGRESS:") {
                                let value = line[marker.upperBound...]
                                    .replacingOccurrences(of: "%", with: "")
                                    .trimmingCharacters(in: .whitespaces)
                                if let number = Double(value) {
                                    let fraction = max(0, min(1, number / 100.0))
                                    DispatchQueue.main.async { progress(fraction) }
                                }
                            } else {
                                recent += line + "\n"
                                if recent.count > 15000 { recent = String(recent.suffix(10000)) }
                            }
                        }
                    }
                    process.waitUntilExit()
                    if !pending.isEmpty { recent += String(decoding: pending, as: UTF8.self) }
                    NSLog("[yt-dlp] %@", String(recent.suffix(3500)))
                    if process.terminationStatus == 0 {
                        continuation.resume(returning: recent)
                    } else {
                        continuation.resume(throwing: YTDLPDownloadError.toolFailed(String(recent.suffix(2400))))
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
