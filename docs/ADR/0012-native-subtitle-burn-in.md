# ADR-0012：原生硬字幕视频导出

状态：已接受。当前规则见 [架构：Mac 字幕烧录](../architecture/README.md#mac-字幕烧录)。

Mac 使用 AVFoundation 离线导出与 Core Image 帧合成，Core Text 绘制字幕。预览与导出复用同一时间轴、字幕快照、字体与换行规则，直接使用本地媒体访问及已有 SRT 校验，减少两套渲染规则的差异。

Core Image 视频合成可同时供 AVAssetImageGenerator 与 AVAssetExportSession 使用；原生支持 H.264／HEVC 与所选音轨。Core Animation 离线动画层可以烧录，但其预览路径和动画时间设置需要额外维护，首轮不采用。暂不引入 FFmpeg。

所选音轨通过原生 audioMix 以单位音量重新编码。AAC 包直接复制可能重复剪裁边界、缩短尾部；处理音轨并核对导出起止时间，使声音与原轨道范围一致。具体校验规则维护于架构。

首轮明确限定 SDR，保留新文件输出与外挂字幕工作流。HDR 和高级样式需要目标输入、播放器及兼容性验证，不能通过默认转码扩大声明范围。

- [Apple：AVVideoComposition](https://developer.apple.com/documentation/avfoundation/avvideocomposition)
- [Apple：AVAssetExportSession](https://developer.apple.com/documentation/avfoundation/avassetexportsession)
- [Apple：HDR 导出与编码](https://developer.apple.com/av-foundation/Incorporating-HDR-video-with-Dolby-Vision-into-your-apps.pdf)

内封软字幕采用独立原生 tx3g 封装，保留压缩画面与所选音轨，提供可关闭字幕。复用当前字幕文本投影与文件发布规则，减少外部编码依赖；字体和样式由播放器承载。它解决 VLC／Files 直接读取视频内字幕的交接场景，不作为硬字幕合成的替代实现。当前规则见 [架构：内封软字幕](../architecture/README.md#内封软字幕)。
