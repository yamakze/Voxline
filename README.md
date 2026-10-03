# Voxline

Voxline 是面向 macOS 与 iOS 的原生音视频字幕应用。Mac MVP 以 Task 批处理本地音视频：选择本次参数、排队转写翻译、进入可播放的媒体详情校对并导出 SRT。iOS 原生播放与校对随后交付。界面主题为 Liquid Glass，新系统使用原生玻璃，当前 Mac 使用原生材质。

当前源码具备单窗口任务库、Task 读写、旧文档迁移、本地混合音视频准备、参数选择和原生媒体预览。支持 MP4/MOV/M4V、M4A/MP3/WAV；多语言音轨明确选择，单项失败保留在同一任务。S001 基准模型支持固定版本下载、完整性校验、本地加载与空间管理。真实处理队列、API 翻译及完整校对导出按 [GitHub Project](https://github.com/users/yamakze/projects/1/views/1) 继续交付。iCloud 同步暂废弃，YouTube 来源后续交付。S001 短样本校对完成，长视频验证暂缓。

## 构建

开发基线为 Apple Silicon、macOS 15、Swift 6.2 / Xcode 26.2。已验证设备为 M4 / 16 GB。

```sh
Scripts/build-app.sh debug
Scripts/compile_and_run.sh debug
swift test
```

应用产物为 build/Voxline.app，采用本地 ad-hoc 签名并启用 App Sandbox。新任务保存至本地任务库；打开已有 .voxline 文件以原 URL 为保存目标，打开时不主动改写旧文档。保存验证和写入失败明确显示。旧格式迁移保留字幕、媒体身份及书签 ID。原媒体保持引用，设备书签留在应用本地。已验证范围见 [混合媒体输入验证](docs/optimize/m1-media-input-validation.md)。

`compile_and_run.sh` 构建成功后终止当前工作目录下旧应用的进程，再启动新应用；支持 debug／release。强制停止可能丢弃尚未保存的编辑，开发重启前保存任务。

### iOS 开发入口

```sh
Scripts/build-ios-ipa.sh                 # Release 未签名设备包
Scripts/compile_and_run_ios.sh           # Debug 构建、安装、启动模拟器
Scripts/compile_and_run_ios.sh --list    # 查看可用模拟器 UDID
Scripts/compile_and_run_ios.sh <UDID>    # 指定 iPhone 或 iPad
```

IPA 位于 build/ios/Voxline-unsigned.ipa。未签名包需要重新签名后才能在普通真机安装运行。Voxline.xcodeproj / VoxlineIOS scheme 可在 Xcode 中配置开发签名。

iOS 18 起支持当前开发入口：手动导入 .voxline 或 JSON 任务，设备本地保存，浏览真实媒体状态与字幕。任务／字幕只读，媒体关联、播放及编辑继续由 VXL-030 交付。iOS 使用原生导航和列表；系统 26 自动采用原生 Liquid Glass 导航控件。构建入口、验证边界与提速说明见 [开发工作流](docs/development.md)。

## 文档与依赖

- [文档入口](docs/README.md)
- [当前工程边界](docs/architecture/README.md)
- [首版执行计划](docs/plans/voxline-v1.md)
- [第三方许可](Licenses/README.md)

WhisperKit 固定在 v1.1.0 对应提交，具体锁定见 Package.swift / Package.resolved。第三方许可证随应用产物保存。
