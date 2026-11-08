# SABR diagnosis and authorized-media fallback

## What the provided log proves

`formats=24, url=0, cipher=0, SABR=true, HLS=false, DASH=false` means the parsed player response has audio/video metadata but **no ordinary downloadable file URL**. `URLSession.download` cannot download this format metadata. The 403 issue and the current issue are different failures.

## Changes in this build

- Searches, YouTube WebKit playback, and endless scrolling remain unchanged.
- A SABR-only result now stops immediately rather than repeating the identical page request twice.
- The selected-video panel includes an **authorized direct media URL** input. If you have an HTTPS URL for the actual M4A/MP4 media file, the app downloads it with `URLSession`, converts it to PCM WAV using AVFoundation, and encodes MP3 via SwiftLAME.
- Local audio/video import remains supported under the MP3 tab.

## Important limitation

This revision does **not** implement SABR transport decoding or bypass YouTube's access requirements. To download a SABR-only YouTube video, a verified, authorized media delivery route is necessary. YouTube's policies generally restrict storing or separating YouTube audio without prior approval. A third-party website's download button is not evidence that its transfer path can be reused by this app.

## Build

Open `YouTubeMacMP3.xcodeproj` with Xcode, resolve SwiftLAME packages and run on macOS 14+. This environment does not include Xcode and a real Mac build has not been verified.
