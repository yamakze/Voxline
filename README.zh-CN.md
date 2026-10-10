# Voxline

[English](README.md) · [简体中文](README.zh-CN.md)

<img src="Resources/AppIcon.png" width="112" alt="Voxline 图标">

面向 macOS 与 iOS 的原生字幕工作台。将本地音视频转写为字幕，翻译后结合播放进行校对。

## 功能

- 批量任务，为本次处理选择转写与翻译参数。
- WhisperKit 本地转写，可下载 Tiny、Base、Small、Large v3 与 Turbo 模型。
- 云端转写，支持 OpenAI 兼容 Audio Transcriptions 端点，以及已接入的 Gemini／Qwen 音频聊天协议。
- Apple 本机翻译或自行配置的 OpenAI 兼容翻译服务，支持上下文、批量数量与提示词。
- 播放校对、原文译文和时间编辑，以及增删字幕、拆句与合句。
- 原文、译文、双语 SRT；支持的视频可导出内封软字幕或烧录硬字幕。
- 中断恢复与可选的 iCloud Drive 文件夹同步，源媒体同步单独开启。
- 简体中文与英文；系统 26 使用 Liquid Glass，旧系统使用原生材质。

## 使用条件

当前处于预发布开发阶段，正式分发安装包正在准备。源码构建需要 Xcode 26.2／Swift 6.2。

| 平台 | 最低系统 | 构建方式 |
| --- | --- | --- |
| macOS | macOS 15 | SwiftPM；当前本机构建面向 Apple silicon |
| iPhone／iPad | iOS／iPadOS 18 | Xcode；真机安装需要签名 |

支持 MP4、MOV、M4V、M4A、MP3、WAV，实际解码取决于系统支持的编码。Apple 翻译需安装语言资源，不支持 iOS 模拟器。iOS 主要在前台处理，进入后台后仅使用系统授予的有限执行时间。

## 构建与启动

```sh
git clone https://github.com/yamakze/Voxline.git
cd Voxline
Scripts/compile_and_run.sh debug
```

Mac 脚本需要有效的 Apple Development 或 Developer ID Application 证书，签名与构建选项见[开发工作流](docs/development.md)。

```sh
# 构建、安装并启动 iOS 模拟器
Scripts/compile_and_run_ios.sh
# 构建供自行签名的未签名 IPA
Scripts/build-ios-ipa.sh release
```

IPA 产物为 `build/ios/Voxline-unsigned.ipa`，签名与安装需另行完成。

## 工作流

新建任务，加入本地音视频，选择转写与可选的翻译参数。开始处理后进入媒体详情播放、编辑字幕，再导出结果。失败或中断后可重试，已完成成果与人工编辑保持。

## 数据与服务

WhisperKit 转写和 Apple 翻译在设备上运行，模型与语言下载需要联网。云端转写向所选服务发送音频，API 翻译发送字幕文本和上下文，费用由服务商收取。密钥保存在设备钥匙串中，不进入任务文档。详见[数据处理说明](docs/privacy.md)。

## 开发与反馈

[开发文档](docs/README.md) · [版本记录](https://github.com/yamakze/Voxline/releases) · [问题与功能请求](https://github.com/yamakze/Voxline/issues) · [项目规划](https://github.com/users/yamakze/projects/1)

## 许可

[MIT 许可证](LICENSE)。第三方代码保留各自许可与署名，见 [Licenses](Licenses/README.md)；下载的模型权重适用其各自许可。
