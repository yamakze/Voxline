# Changelog

每个版本必须在此记录变更；发布流程会提取对应版本的段落，作为 GitHub Release 正文。段落格式：`## <版本号> - <日期>`，条目必须写成单行。

每个版本先写完整的**英文**部分（`### Added` / `### Fixed` / `### Improved`），再用一条 `---` 分隔，随后是完整的**中文**部分（`### 新增` / `### 修复` / `### 改进`）。英文块与中文块的条目一一对应、顺序一致。

## 1.0.0 - 2026-10-10

### Added

- **macOS + iOS**: First public release of Voxline — a high-performance native subtitle transcription, translation, and proofreading workstation for Apple platforms.
- **macOS + iOS**: Full on-device WhisperKit integration with Core ML hardware acceleration, supporting Tiny, Base, Small, Large v3, and Turbo models with zero network required once downloaded.
- **macOS + iOS**: Cloud audio transcription fallback supporting OpenAI Audio Transcriptions (`/v1/audio/transcriptions`), Google Gemini Audio Chat, and Alibaba Cloud DashScope / Qwen Audio Chat protocols.
- **macOS + iOS**: Dual translation engines — 100% offline Apple system translation using installed language models (no API key required) and OpenAI-compatible context-aware LLM batch translation.
- **macOS + iOS**: Synchronized bilingual proofreading player powered by AVPlayer with Source / Translation / Bilingual views, 0.5x–2.0x playback rates, ±5s seek, millisecond subtitle jump, and audio waveform visualization.
- **macOS + iOS**: Comprehensive subtitle timeline editing: cue insertion, timestamp adjustment, natural sentence split, adjacent cue merging, and global timecode offsets.
- **macOS + iOS**: Native subtitle export and video packaging: external SRT subtitles (Source, Translation, Bilingual), lossless tx3g soft subtitle MP4 remuxing, and GPU-accelerated hard subtitle burn-in via Core Image.
- **macOS + iOS**: Atomic checkpoint persistence and resilient workflow recovery; manual edits are strictly protected against late asynchronous responses.
- **macOS + iOS**: Multi-device continuity: portable `.voxline` task document import/export and optional synchronization via user-selected iCloud Drive shared folders.
- **macOS + iOS**: Native Apple design system featuring Liquid Glass materials, dark mode, VoiceOver accessibility labels, and HIG-compliant keyboard navigation.

---

### 新增

- **macOS + iOS**：Voxline 首个正式公开发布版本——专为 Apple 平台打造的高性能原生音视频字幕转写、翻译与校对工作台。
- **macOS + iOS**：全流程端侧 WhisperKit 集成与 Core ML 硬件加速，支持 Tiny、Base、Small、Large v3 与 Turbo 全系列模型，模型按需下载并本地缓存，全程离线零隐私泄露。
- **macOS + iOS**：云端音频转写算力补充，支持 OpenAI 兼容 Audio Transcriptions（`/v1/audio/transcriptions`）、Google Gemini 音频聊天与阿里云百炼 Qwen 音频聊天协议。
- **macOS + iOS**：双引擎智能翻译——Apple 本机 100% 离线翻译（免配 API Key 与零网络消耗）及 OpenAI 兼容具备前后上下文感知的大模型批量翻译。
- **macOS + iOS**：原生 AVPlayer 沉浸式双语校对播放器，支持原文/译文/双语三种视图，0.5x ~ 2.0x 变速回放，±5s 快速跳转，毫秒级字幕定位，纯音频声波视图。
- **macOS + iOS**：精细化时间轴与结构编辑：单句插入、时间戳微调、自然断句智能拆分、相邻字幕一键合并及整轨全局时间轴平移。
- **macOS + iOS**：全能字幕与视频导出：原文/译文/双语三种 SRT 外挂文件，无损 tx3g MP4 软字幕内封封装，以及 Core Image GPU 硬件加速的视频硬字幕压制。
- **macOS + iOS**：原子检查点与断点续做机制，持久化落地转写分段与翻译批次，严格防止迟到响应覆盖人工校对。
- **macOS + iOS**：跨设备协同与存储：支持 `.voxline` 任务文档跨端导入导出，以及用户授权的 iCloud Drive 共享文件夹无损同步。
- **macOS + iOS**：Apple 原生设计质感：适配系统 Liquid Glass 流体玻璃材质、深色模式、完整 VoiceOver 辅助功能标签与 HIG 快捷键交互。
