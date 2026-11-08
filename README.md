# YouTubeMacMP3 — yt-dlp 다운로드 엔진 전환

macOS 14+ SwiftUI Xcode 프로젝트입니다. 기존 웹 파싱 YouTube 검색·무한 스크롤·WKWebView 재생을 유지하고, 영상 다운로드 엔진을 자체 `NativeYouTubeExtractor`에서 공식 `yt-dlp_macos`로 교체했습니다. 받은 오디오는 AVFoundation으로 WAV 변환 후 SwiftLAME으로 MP3 인코딩합니다.

## 실행
1. `YouTubeMacMP3.xcodeproj`를 Xcode로 열고 SwiftLAME 패키지 다운로드를 허용합니다.
2. My Mac 대상으로 빌드/실행합니다.
3. 권한이 있는 영상 검색 → 선택 → 권한 확인 → MP3 변환을 클릭합니다.
4. **첫 다운로드에서** 앱이 [yt-dlp 공식 GitHub 릴리스](https://github.com/yt-dlp/yt-dlp/releases/tag/2026.10.26)의 `yt-dlp_macos`를 `~/Library/Application Support/YouTubeMacMP3/Tools/`에 다운로드하고, 같은 릴리스의 `SHA2-256SUMS`와 대조해 검증합니다. 검증 후 앱에서 실행합니다. Python, yt-dlp, ffmpeg를 수동 설치할 필요는 없습니다.
5. 결과는 `~/Downloads/YouTubeMacMP3`에 저장됩니다.

## 주의
- 이 ZIP에는 바이너리가 포함되지 않습니다. 제작 환경에서 GitHub에 연결되지 않았기 때문입니다. 첫 사용에는 GitHub 네트워크 접근이 필요합니다.
- 다운로드에 성공해도 WebM/Opus만 제공되면 기본 AVFoundation으로 디코딩할 수 없어 변환이 불가할 수 있습니다. M4A/MP4 우선 선택을 적용했습니다.
- 유효한 스트림이나 다운로드 권한이 없는 경우 실패합니다. yt-dlp 최신판도 YouTube 제한이나 PO Token/JavaScript 런타임 요구 때문에 일부 영상에서 실패할 수 있습니다.
- 공식 standalone 바이너리는 PyInstaller 구성 요소에 따라 GPLv3+ 라이선스 요건이 있을 수 있습니다.
- App Sandbox는 기존 개발 프로젝트처럼 비활성화되어 있습니다. 개인 테스트용입니다.
- macOS Xcode 빌드/실제 다운로드 성공은 이 환경에서 검증할 수 없습니다.

## 2026-11-08: Separate download and MP3 conversion progress

- Both tabs now show a **download progress bar** and an independent **MP3 conversion progress bar** during a task.
- The downloader uses yt-dlp's `--progress-template` and streams stdout line by line (instead of waiting until process exit), delivering reported percentages to SwiftUI.
- Conversion progress combines PCM/WAV decoding (first 35%) and SwiftLAME encoding (remaining 65%). SwiftLAME's `Progress` is sampled every 0.15 seconds. Percentages are based on reported decoder/encoder progress; if an upstream library does not report accurately, the bar can pause until completion.
- The original video title from yt-dlp's `media.info.json` is used for the MP3 basename; unsupported filename characters are replaced. If the same title already exists, names use ` (2)`, ` (3)`, etc., without overwriting.
- Local file conversion preserves the input filename. Direct HTTP media files use the URL's filename.
- Note: the progress bar cannot start if yt-dlp cannot download that video. An unsupported media container (e.g. WebM-only) still requires another decoder.

### Modified files

- `YouTubeMacMP3/YTDLPDownloader.swift`
- `YouTubeMacMP3/MP3ConversionService.swift`
- `YouTubeMacMP3/ContentView.swift`

Build status: Linux Swift syntax parsing and Xcode project plist lint pass; actual macOS Xcode build and YouTube downloads not tested in this environment.


## UI cleanup (2026-11-08)
- Removed unused MP3 conversion tab and authorized direct media URL input.
- Retained search, playback, yt-dlp download, separate download/encoding progress, original-title naming.
- Moved the 128/192/256/320 kbps MP3 bitrate selector beside the video authorization checkbox. Default is **192 kbps CBR**, 44.1 kHz stereo.


## PCM 스트리밍 인코딩 변경

- 다운로드한 M4A/MP4 파일을 `AVAssetReaderTrackOutput`로 44.1kHz/16-bit/2채널 interleaved PCM 블록으로 디코딩합니다.
- 각 PCM 블록을 `lame_encode_buffer_interleaved`에 곧바로 전달해 출력 MP3에 기록합니다. `lame_encode_flush`로 종료합니다.
- **중간 WAV/PCM 파일은 생성하지 않습니다.** 소스 다운로드 파일과 최종 MP3는 디스크에 남고, PCM은 블록 단위 메모리에만 존재합니다.
- SwiftLAME의 C 타겟 `LAME` 모듈을 직접 import합니다. Xcode에서 `No such module LAME`가 발생하면 Swift Package의 모듈 가시성 문제이므로 LAME 타겟을 앱에 직접 노출하는 로컬 패키지 구성이 필요합니다. 이 환경은 Xcode가 없어 전체 빌드는 검증하지 못했습니다.
- 변환률은 디코딩된 오디오 시각을 바탕으로 표시합니다(블록 처리와 인코딩을 같은 루프에서 수행). 비트레이트 기본 192kbps CBR, 선택 128/192/256/320kbps.


## 빠른 MP3 인코딩 최적화 (2026-11-08)

- `lame_set_quality(lame, 0)`에서 `lame_set_quality(lame, 5)`로 변경했습니다. CBR 128/192/256/320kbps 선택 값은 유지되지만, LAME 내부 연산 품질/속도 절충값이 바뀝니다. 음질 차이가 있을 수 있습니다.
- PCM 및 MP3 임시 배열을 매 블록마다 다시 만들지 않고, 필요 시 크기를 늘려 반복 사용합니다.
- 기존 AVAssetReader -> PCM 메모리 -> LAME -> MP3 순서, 다운로드 진행률, 변환 진행률, 원본 파일명 저장을 유지합니다.
- macOS 빌드 및 실제 성능 향상률은 확인하지 못했습니다. 같은 음원으로 전후 변환 시간과 청감 품질을 비교해 주세요.
