# 数据处理与隐私说明 · Data Handling & Privacy

Voxline 不运营账号服务，亦不设立中心化数据收集或字幕后端服务。所有处理均在用户本地设备，或由用户显式配置的第三方服务终端进行。

Voxline does not operate an account service or a centralized subtitle backend. All processing occurs on the local device or via service endpoints explicitly configured by the user.

## 数据去向与网络边界 · Data Destinations

| 业务操作 / Operation | 数据流向 / Destination | 说明 / Description |
| --- | --- | --- |
| 端侧 WhisperKit 转写<br>Local WhisperKit Transcription | 本地设备处理<br>On-device processing | 音频在设备本地 Core ML 环境下解码并转写，模型权重经由沙盒独立下载与存储。<br>Audio is decoded and transcribed locally via Core ML; model weights are downloaded directly to the application sandbox. |
| Apple 本机翻译<br>Apple Translation | 本地设备处理<br>On-device processing | 调用系统翻译框架与本地已安装的离线语言包完成翻译，无外部网络请求。<br>Processed locally using system translation frameworks and installed offline language assets. |
| 云端语音转写<br>Cloud Transcription | 用户配置的服务端点<br>Configured provider endpoint | 提取后的音频切片通过 HTTPS 发送至用户填写的服务接口（如 OpenAI Audio、Gemini、百炼）。<br>Extracted audio chunks are transmitted via HTTPS to the user-specified provider endpoint. |
| API 智能翻译<br>API Translation | 用户配置的服务端点<br>Configured provider endpoint | 待翻译字幕文本、前后滑动上下文（各 2 句）与自定义系统提示词发送至配置的服务接口。<br>Subtitle text, surrounding sliding context (2 cues), and system prompts are sent to the configured endpoint. |
| iCloud 同步（可选）<br>Optional iCloud Sync | 用户授权的 iCloud Drive 目录<br>User-selected iCloud Drive folder | 仅在用户手动选择授权目录后生效；同步任务元数据与字幕文本，源媒体文件需显式勾选后才参与拷贝。<br>Active only when explicitly enabled; synchronizes task metadata and subtitle text. Source media is copied only if configured. |

## 凭据安全与敏感信息 · Credentials & Storage

- **API 凭据安全存储**：所有第三方服务的 API Key 均异步保存在系统 Keychain 中，使用平台安全加密机制保护。
- **任务文档隔离**：导出的 `.voxline` 任务文档、检查点文件与同步数据均不包含任何 API Key。共享任务文件可能包含字幕台词、媒体文件名/时长元数据、已配置的服务 Base URL 以及系统提示词。

## 本地存储与诊断数据 · Local Data & Diagnostics

- **设备存储内容**：应用沙盒内保存任务状态、下载的模型权重、媒体访问安全书签、提取的临时 PCM 音频分块以及用于断点恢复的检查点文件。
- **诊断证据记录**：执行日志与检查点可能包含部分识别出的文本片段与服务端原始返回结果，仅保存在本机用于错误排查与恢复。
- **导出与分享**：导出的 SRT 字幕文件、压制视频与软字幕 MP4 均通过系统标准保存面板或系统分享表单进行分发，生命周期归属于目标路径。

## 第三方服务与支持反馈 · Third-Party Services & Reporting

- **数据留存与账单**：第三方云端转写与翻译服务的数据留存策略、处理延迟与调用计费完全由各服务提供商决定；iCloud 存储由用户个人的 Apple ID 控制。在使用第三方服务处理敏感音视频前，请审阅对应服务商的隐私与数据协议。
- **问题反馈规范**：在提交 Issue 或公开错误日志时，请使用公开可分发的测试样例，并务必剔除私有台词、API 凭据、私有媒体信息及敏感诊断缓存。
