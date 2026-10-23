# Changelog

## 1.1.2 - 2026-10-23

### Improved

- Reduced playback control updates and subtitle search work on long videos across macOS and iOS.
- Reused burn-in previews when changing encoding or output quality, and cached localized language choices.
- Limited burn-in preview menus to 50 evenly sampled cues, including the first and last; exported videos still include every subtitle.
- Reduced Mac window compositing work by isolating surface shadows from text and controls.

### Fixed

- Preserved playback position when cancelling media relinking.
- Kept iOS export preview players and temporary files stable across view updates.
- Used subtitle IDs to distinguish preview choices with identical start times.

---

### 改进

- 减少 macOS 与 iOS 长视频播放控件刷新及字幕搜索开销。
- 切换编码或输出质量时复用烧录预览，缓存语言名称及其本地化排序结果。
- 烧录预览菜单最多保留 50 条均匀采样台词，包含首尾；成品仍包含全部字幕。
- 将 Mac 材质阴影与文字、控件分离，减少窗口合成开销。

### 修复

- 取消重新关联媒体时保留当前播放位置。
- iOS 成品预览在界面刷新时保留播放器及临时文件。
- 使用字幕 ID 区分起点时间相同的预览选项。

## 1.1.1 - 2026-10-21

### Improved

- Refined the Mac workspace with in-window task navigation, a docked player, standalone settings, and task creation and opening commands.
- Improved glass-style surfaces on macOS 15 with translucent fills, gradient highlights, and softer shadows.
- Reduced idle interface work, processing progress updates, and word timestamp alignment overhead.
- Streamlined iOS imports, playback cleanup, and temporary export ownership across previews and sharing.

### Fixed

- Restored focused subtitle search and protected editing drafts when switching pages or media.
- Recovered transcription text at chunk boundaries and kept whitespace and zero-duration words with adjacent speech.
- Improved subtitle export cancellation and output validation, and rejected paths in temporary export file names.
- Prevented opening another Mac window from interrupting active cloud processing with redundant service reloads.

---

### 改进

- 优化 Mac 工作区：窗口内切换任务、停靠播放器、独立设置窗口，以及新建和打开任务快捷命令。
- 改善 macOS 15 玻璃质感，调整半透明底色、渐变高光与柔和阴影。
- 减少界面空闲刷新、处理进度更新和词级时间戳对齐开销。
- 简化 iOS 导入流程，完善播放资源释放，以及预览和分享期间的临时导出文件管理。

### 修复

- 恢复当前媒体的字幕搜索与快捷键聚焦，切换页面或媒体时保护编辑草稿。
- 恢复转写分块边界文本，将空白词和零时长词保留在相邻语音字幕中。
- 改善字幕导出取消和输出校验，拒绝临时导出文件名中包含路径。
- 避免新开 Mac 窗口重复加载服务配置，干扰正在进行的云端处理。

## 1.1.0 - 2026-10-13

### Added

- Import SRT and VTT subtitles for associated audio or video on macOS and iOS. Adding MP4, MOV or M4V videos automatically imports an available tx3g text track.
- Import translations with time-based matching and a preview; save unmatched entries and assign them later. Imported source subtitles use the existing translation, proofreading and export workflow without speech recognition.
- Preserve overlapping subtitles in playback, proofreading and SRT output; display all simultaneous text in embedded and burned-in video exports.
- Check for Mac updates with Sparkle and signed update feeds. iOS supports version checks and IPA downloads for manual installation.
- Refreshed application icon and update settings.

### Fixed

- Resume update checks after leaving and reopening the update page.
- Keep subtitle import drafts consistent when reading fails or the task changes during preview.
- Undo subtitle imports and speech-recognition switches with their complete source and checkpoint state.
- Restore the Mac task menu's sync conflict recovery entry and keep unselected versions as separate tasks.

---

### 新增

- macOS 与 iOS 支持为关联的音视频导入 SRT、VTT 字幕；添加 MP4、MOV、M4V 视频时自动导入可用的 tx3g 文本字幕轨。
- 译文导入支持按时间匹配与结果预览；未匹配内容可保存并稍后分配。导入原文后沿用翻译、校对与导出流程，无需语音识别。
- 播放、校对与 SRT 保留重叠字幕；软字幕与硬字幕视频同时呈现重叠区的完整文本。
- Mac 接入 Sparkle 更新检查及签名更新源；iOS 支持版本检查和 IPA 下载，安装由用户自行完成。
- 更新应用图标和更新设置。

### 修复

- 离开更新页面后重新进入，可继续检查更新。
- 字幕读取失败或预览期间任务发生变化时，导入草稿保持一致。
- 撤销字幕导入或切换语音识别时，完整恢复字幕来源与检查点状态。
- 恢复 Mac 任务菜单的同步冲突恢复入口，未选版本另存为独立任务。

## 1.0.0 - 2026-10-10

### Added

macOS and iOS.

- First public release of Voxline — a high-performance native subtitle transcription, translation, and proofreading workstation for Apple platforms.
- Full on-device WhisperKit integration with Core ML hardware acceleration, supporting Tiny, Base, Small, Large v3, and Turbo models with zero network required once downloaded.
- Cloud audio transcription fallback supporting OpenAI Audio Transcriptions (`/v1/audio/transcriptions`), Google Gemini Audio Chat, and Alibaba Cloud DashScope / Qwen Audio Chat protocols.
- Dual translation engines — 100% offline Apple system translation using installed language models (no API key required) and OpenAI-compatible context-aware LLM batch translation.
- Synchronized bilingual proofreading player powered by AVPlayer with Source / Translation / Bilingual views, 0.5x–2.0x playback rates, ±5s seek, millisecond subtitle jump, and audio waveform visualization.
- Comprehensive subtitle timeline editing: cue insertion, timestamp adjustment, natural sentence split, adjacent cue merging, and global timecode offsets.
- Native subtitle export and video packaging: external SRT subtitles (Source, Translation, Bilingual), lossless tx3g soft subtitle MP4 remuxing, and GPU-accelerated hard subtitle burn-in via Core Image.
- Atomic checkpoint persistence and resilient workflow recovery; manual edits are strictly protected against late asynchronous responses.
- Multi-device continuity: portable `.voxline` task document import/export and optional synchronization via user-selected iCloud Drive shared folders.
- Native Apple design system featuring Liquid Glass materials, dark mode, VoiceOver accessibility labels, and HIG-compliant keyboard navigation.

---

### 新增

macOS 与 iOS。

- Voxline 首个正式公开发布版本——专为 Apple 平台打造的高性能原生音视频字幕转写、翻译与校对工作台。
- 全流程端侧 WhisperKit 集成与 Core ML 硬件加速，支持 Tiny、Base、Small、Large v3 与 Turbo 全系列模型，模型下载后可离线转写，音频保留在本机。
- 云端音频转写算力补充，支持 OpenAI 兼容 Audio Transcriptions（`/v1/audio/transcriptions`）、Google Gemini 音频聊天与阿里云百炼 Qwen 音频聊天协议。
- 双引擎智能翻译——Apple 本机离线翻译（语言模型下载后无需联网或 API Key）及 OpenAI 兼容具备前后上下文感知的大模型批量翻译。
- 原生 AVPlayer 沉浸式双语校对播放器，支持原文/译文/双语三种视图，0.5x ~ 2.0x 变速回放，±5s 快速跳转，毫秒级字幕定位，纯音频声波视图。
- 精细化时间轴与结构编辑：单句插入、时间戳微调、自然断句智能拆分、相邻字幕一键合并及整轨全局时间轴平移。
- 全能字幕与视频导出：原文/译文/双语三种 SRT 外挂文件，无损 tx3g MP4 软字幕内封封装，以及 Core Image GPU 硬件加速的视频硬字幕压制。
- 原子检查点与断点续做机制，持久化落地转写分段与翻译批次，严格防止迟到响应覆盖人工校对。
- 跨设备协同与存储：支持 `.voxline` 任务文档跨端导入导出，以及用户授权的 iCloud Drive 共享文件夹无损同步。
- Apple 原生设计质感：适配系统 Liquid Glass 流体玻璃材质、深色模式、完整 VoiceOver 辅助功能标签与 HIG 快捷键交互。
