# 대체 플레이어 메타데이터 조회 버전

기존 YouTube 검색·재생, SwiftLAME 변환 코드는 유지합니다.

## 변경점
- 처음 영상 페이지가 `SABR=true`, `url=0`이면 두 번째 플레이어 메타데이터 요청을 시도합니다.
- 응답에서 HTTPS M4A 또는 오디오 포함 MP4 파일 URL이 제공되면 기존 다운로드 + MP3 인코딩 파이프라인으로 연결합니다.
- 양쪽 응답 모두 SABR 전용이면 명확하게 실패를 표시합니다. SABR 조각 프로토콜을 다운로드하는 엔진은 포함하지 않습니다.
- 외부 ffmpeg, Python, yt-dlp는 필요하지 않습니다. SwiftLAME 패키지는 Xcode에서 내려받습니다.

## 제한
두 번째 플레이어에서도 직접 URL이 없거나 서버가 HTTP 403을 반환하면 다운로드할 수 없습니다. YouTube의 이용약관과 콘텐츠 권한을 준수해야 합니다.

## 진단
Xcode 콘솔의 `[NativeExtractor] secondary player:` 줄에서 `direct`가 0인지 확인하세요. `direct > 0`이어도 미디어 URL의 HTTP 응답이 403이면 실제 다운로드가 실패할 수 있습니다.

## 검증
Linux Swift 구문 파싱만 수행, macOS Xcode 빌드 및 실서버 다운로드는 미검증.
