import SwiftUI
import AppKit

struct ContentView: View {
    @State private var query = ""
    @State private var videos: [Video] = []
    @State private var selectedVideoID: String?
    @State private var isSearching = false
    @State private var isLoadingMore = false
    @State private var searchError: String?
    @State private var continuation: String?
    @State private var context: [String: Any] = [:]
    @State private var internalKey: String?
    @State private var consumedTokens = Set<String>()
    @State private var pageError: String?
    @State private var bitrate = 192
    @State private var rightsConfirmed = false
    @State private var converting = false
    @State private var downloadFraction: Double = 0
    @State private var mp3Fraction: Double = 0
    @State private var conversionPhase = ""
    @State private var conversionStatus = ""
    @State private var savedFile: URL?

    private var selectedVideo: Video? { videos.first { $0.id == selectedVideoID } }

    var body: some View {
        HSplitView {
            leftPane.frame(minWidth: 350, idealWidth: 430)
            rightPane.frame(minWidth: 480)
        }
        .frame(minWidth: 940, minHeight: 640)
    }

    private var leftPane: some View {
        VStack(spacing: 12) {
            HStack {
                TextField("YouTube 검색어", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await search() } }
                Button("검색") { Task { await search() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSearching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding([.top, .horizontal])
            if isSearching { ProgressView("검색 중...") }
            if let searchError {
                Text(searchError).foregroundStyle(.red).font(.caption).padding(.horizontal)
                Button("웹 검색 열기") { openWebSearch() }
            }
            List(selection: $selectedVideoID) {
                ForEach(videos) { video in
                    HStack(spacing: 12) {
                        AsyncImage(url: video.thumbnail) { img in
                            img.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(.gray.opacity(0.15))
                        }
                        .frame(width: 130, height: 76)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(video.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                            Text(video.channel).font(.caption).foregroundStyle(.secondary)
                            Text(video.duration).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(video.id)
                    .onAppear {
                        if videos.suffix(5).contains(where: { $0.id == video.id }) {
                            Task { await loadMore() }
                        }
                    }
                }
                if isLoadingMore {
                    ProgressView("다음 결과 불러오는 중...")
                } else if let pageError {
                    VStack(alignment: .leading) {
                        Text(pageError).font(.caption).foregroundStyle(.red)
                        Button("다시 시도") { Task { await loadMore() } }
                    }
                } else if continuation != nil {
                    Button("다음 목록 불러오기") { Task { await loadMore() } }
                }
            }
            .listStyle(.inset)
        }
    }

    private var rightPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let video = selectedVideo {
                YouTubePlayer(videoID: video.id)
                    .id(video.id)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .background(.black)
                Text(video.title).font(.title3.bold()).lineLimit(2)
                Text(video.channel).foregroundStyle(.secondary)
                HStack(spacing: 12) {
                    Toggle("이 영상의 다운로드 및 MP3 변환 권한이 있습니다", isOn: $rightsConfirmed)
                        .toggleStyle(.checkbox)
                    Spacer(minLength: 8)
                    Picker("MP3 음질", selection: $bitrate) {
                        ForEach([128, 192, 256, 320], id: \.self) { rate in
                            Text("\(rate) kbps").tag(rate)
                        }
                    }
                    .frame(width: 195)
                }
                HStack {
                    Link("YouTube 원본 열기", destination: video.watchURL)
                    Spacer()
                    Button("공유 URL → MP3 자동 변환") {
                        Task { await convertURL(video.watchURL) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!rightsConfirmed || converting)
                }
                if !rightsConfirmed {
                    Label("위 권한 확인에 체크하면 MP3 변환 버튼이 활성화됩니다.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if converting { conversionProgressView }
                if !conversionStatus.isEmpty {
                    Text(conversionStatus)
                        .font(.callout)
                        .foregroundStyle(savedFile == nil ? Color.orange : Color.green)
                        .textSelection(.enabled)
                }
                if let savedFile {
                    HStack {
                        Button("Finder에서 MP3 보기") {
                            NSWorkspace.shared.activateFileViewerSelecting([savedFile])
                        }
                        Button("MP3 열기") { NSWorkspace.shared.open(savedFile) }
                    }
                }
                Text("YouTube 스트림 분석과 다운로드는 yt-dlp가 처리합니다. yt-dlp가 접근을 거부당하는 영상은 변환할 수 없습니다. 다운로드 권한이 있는 콘텐츠만 사용하세요.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 54)).foregroundStyle(.secondary)
                    Text("왼쪽에서 동영상을 선택하세요").font(.headline)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
    }

    private var conversionProgressView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(conversionPhase).font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("파일 다운로드").font(.callout)
                Spacer()
                Text("\(Int(downloadFraction * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: downloadFraction, total: 1)
            HStack {
                Text("MP3 변환 (PCM 버퍼 → 인코딩)").font(.callout)
                Spacer()
                Text("\(Int(mp3Fraction * 100))%")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            ProgressView(value: mp3Fraction, total: 1)
        }
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
    }

    @MainActor private func beginProgress(downloadIsRequired: Bool) {
        downloadFraction = downloadIsRequired ? 0 : 1
        mp3Fraction = 0
        conversionPhase = downloadIsRequired ? "다운로드 준비 중..." : "MP3 변환 준비 중..."
    }

    private func onDownload(_ value: Double) {
        Task { @MainActor in
            downloadFraction = max(downloadFraction, value)
            conversionPhase = value >= 1 ? "오디오 디코딩 중..." : "오디오 다운로드 중..."
        }
    }

    private func onConvert(_ value: Double) {
        Task { @MainActor in
            mp3Fraction = max(mp3Fraction, value)
            conversionPhase = value >= 1 ? "MP3 저장 완료" : ("PCM 버퍼 디코딩 및 MP3 인코딩 중...")
        }
    }

    private func openWebSearch() {
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: query)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }

    @MainActor private func search() async {
        guard !isSearching else { return }
        isSearching = true
        videos = []
        selectedVideoID = nil
        continuation = nil
        searchError = nil
        pageError = nil
        consumedTokens = []
        defer { isSearching = false }
        do {
            let page = try await SearchParser.search(query)
            videos = page.videos
            continuation = page.continuation
            context = page.context
            internalKey = page.apiKey
        } catch { searchError = error.localizedDescription }
    }

    @MainActor private func loadMore() async {
        guard !isSearching, !isLoadingMore, let token = continuation,
              !consumedTokens.contains(token) else { return }
        isLoadingMore = true
        pageError = nil
        defer { isLoadingMore = false }
        do {
            let page = try await SearchParser.nextPage(token: token, context: context, apiKey: internalKey)
            consumedTokens.insert(token)
            let seen = Set(videos.map(\.id))
            videos.append(contentsOf: page.videos.filter { !seen.contains($0.id) })
            continuation = (page.continuation == token || (page.continuation.map { consumedTokens.contains($0) } ?? false)) ? nil : page.continuation
        } catch { pageError = error.localizedDescription }
    }

    @MainActor private func convertURL(_ videoURL: URL) async {
        guard rightsConfirmed, !converting else { return }
        converting = true
        savedFile = nil
        beginProgress(downloadIsRequired: true)
        conversionStatus = "yt-dlp 다운로드 → PCM 버퍼 디코딩·MP3 직접 인코딩 중..."
        defer { converting = false }
        do {
            let result = try await MP3ConversionService.fromAuthorizedVideoURL(
                videoURL.absoluteString, bitrate: bitrate,
                downloadProgress: onDownload,
                conversionProgress: onConvert
            )
            downloadFraction = 1
            mp3Fraction = 1
            savedFile = result.file
            conversionStatus = "완료: \(result.file.path)"
        } catch {
            conversionStatus = "변환 실패: \(error.localizedDescription)"
            NSLog("[MP3Conversion] %@", String(reflecting: error))
        }
    }
}
