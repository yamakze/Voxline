# Voxline

Voxline 是面向 macOS 与 iOS 的原生音视频字幕应用。Mac MVP 以 Task 批处理本地音视频：选择本次参数、排队转写翻译、进入可播放的媒体详情校对并导出 SRT。iOS 原生播放与校对随后交付。界面主题为 Liquid Glass，新系统使用原生玻璃，当前 Mac 使用原生材质。

当前源码已具备 Task 文档读写、参数快照、旧单媒体文档迁移、本地任务列表、任务准备表单、任务概览和媒体字幕浏览。任务准备支持多选视频、逐项检查、音轨选择、排序、转写／翻译参数和三种 SRT 输出选择。处理队列、模型／服务管理、播放校对和导出按 [GitHub Project](https://github.com/users/yamakze/projects/1/views/1) 交付。iCloud 同步暂废弃，YouTube URL 为后续来源，其他平台不在产品范围内。S001 短样本人工字幕校对完成；长视频验证暂缓。

## 构建

开发基线为 Apple Silicon、macOS 15、Swift 6.2 / Xcode 26.2。已验证设备为 M4 / 16 GB。

```sh
Scripts/build-app.sh debug
Scripts/compile_and_run.sh debug
swift test
```

应用产物为 `build/Voxline.app`，采用本地 ad-hoc 签名并启用 App Sandbox。任务使用 `.voxline` 扩展名；打开旧文档迁移为 Task，保存时写版本 2。旧成果显示待确认，保留字幕与媒体访问记录。任务准备提交到同一文档，取消保留原任务；任务概览显示真实状态、完成条目数和参数，媒体列表可进入各自字幕详情。媒体保持本地引用，本地书签保存在应用的 Application Support。实际转写、翻译、播放校对和音频文件输入尚待对应条目交付。Task 界面的已验证范围与剩余验收见 [原生界面验证](docs/optimize/m1-task-ui-validation.md)。

`compile_and_run.sh` 构建成功后终止当前工作目录下旧应用的进程，再启动新应用；支持 debug／release。强制停止可能丢弃尚未保存的编辑，开发重启前保存任务。

## 文档与依赖

- [文档入口](docs/README.md)
- [当前工程边界](docs/architecture/README.md)
- [首版执行计划](docs/plans/voxline-v1.md)
- [第三方许可](Licenses/README.md)

WhisperKit 固定在 v1.1.0 对应提交，具体锁定见 Package.swift / Package.resolved。第三方许可证随应用产物保存。
