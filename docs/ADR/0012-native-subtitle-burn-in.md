# ADR-0012：原生硬字幕视频导出

状态：已接受。当前规则见 [架构：Mac 字幕烧录](../architecture/README.md#mac-字幕烧录)。

Mac 使用 AVFoundation 离线导出与 Core Image 帧合成，Core Text 绘制字幕。预览与导出复用同一时间轴、字幕快照、字体与换行规则，直接使用本地媒体访问及已有 SRT 校验，减少两套渲染规则的差异。

Core Image 视频合成可同时供 AVAssetImageGenerator 与 AVAssetExportSession 使用；原生支持 H.264／HEVC 与所选音轨。Core Animation 离线动画层可以烧录，但其预览路径和动画时间设置需要额外维护，首轮不采用。暂不引入 FFmpeg。

首轮明确限定 SDR，保留新文件输出与外挂字幕工作流。HDR、内封软字幕和高级样式各自需要目标输入、播放器及兼容性验证，不能通过默认转码扩大声明范围。

- [Apple：AVVideoComposition](https://developer.apple.com/documentation/avfoundation/avvideocomposition)
- [Apple：AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession)
- [Apple：HDR 导出与编码](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)
