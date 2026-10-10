# Voxline

[English](README.md) · [简体中文](README.zh-CN.md)

<img src="Resources/AppIcon.png" width="112" alt="Voxline icon">

A native subtitle workspace for macOS and iOS. Transcribe local audio and video, translate the subtitles, and review the results alongside playback.

## Features

- Batch tasks with their own transcription and translation settings.
- Local WhisperKit transcription with downloadable Tiny, Base, Small, Large v3, and Turbo models.
- Cloud transcription through OpenAI-compatible Audio Transcriptions endpoints and supported Gemini / Qwen audio chat protocols.
- Apple Translation on device or a configurable OpenAI-compatible translation service, with context, batch size, and prompt controls.
- Playback, text and timing edits, and subtitle insertion, deletion, splitting, and merging.
- Original, translated, and bilingual SRT; embedded soft subtitles or burned-in subtitles for supported video.
- Interrupted-task recovery and optional iCloud Drive folder sync, with source media syncing enabled separately.
- English and Simplified Chinese, with Liquid Glass on system 26 and native materials on earlier systems.

## Availability

Voxline is in pre-release development. Official distribution packages are being prepared; source builds require Xcode 26.2 / Swift 6.2.

| Platform | Minimum system | Build |
| --- | --- | --- |
| macOS | macOS 15 | SwiftPM; current local builds target Apple silicon |
| iPhone / iPad | iOS / iPadOS 18 | Xcode; physical devices require signing |

Inputs include MP4, MOV, M4V, M4A, MP3, and WAV, subject to system codec support. Apple Translation requires installed language resources and is unavailable in the iOS Simulator. iOS processing runs in the foreground, with limited system-granted background time.

## Build and run

```sh
git clone https://github.com/yamakze/Voxline.git
cd Voxline
Scripts/compile_and_run.sh debug
```

The Mac script requires a valid Apple Development or Developer ID Application certificate. See the [development guide](docs/development.md) for signing and build options.

```sh
# Build, install, and launch in the iOS Simulator
Scripts/compile_and_run_ios.sh
# Build an unsigned IPA for your own signing
Scripts/build-ios-ipa.sh release
```

The IPA is written to `build/ios/Voxline-unsigned.ipa`; signing and installation are separate steps.

## Workflow

Create a task, add local media, and choose transcription and optional translation settings. Start processing, then open a media item to play and edit its subtitles before exporting. Failed or interrupted work can be retried while completed results and edits are preserved.

## Data and services

Local WhisperKit transcription and Apple Translation run on device; model and language downloads require a network connection. Cloud transcription sends audio to your configured provider; API translation sends subtitle text and context. Your provider handles API charges. Credentials stay in the device Keychain and are excluded from task documents. See [data handling](docs/privacy.md).

## Development and feedback

[Contributor documentation](docs/README.md) · [Release notes](https://github.com/yamakze/Voxline/releases) · [Issues](https://github.com/yamakze/Voxline/issues) · [Roadmap](https://github.com/users/yamakze/projects/1)

## License

[MIT](LICENSE). Third-party code retains its original notices; see [Licenses](Licenses/README.md). Downloaded model weights are governed by their respective licenses.
