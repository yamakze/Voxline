# Voxline

Voxline 是面向个人使用的 macOS 与 iOS 原生音视频字幕应用。Mac 以 Task 批处理本地媒体，完成转写、翻译、播放校对和 SRT 导出；iOS 播放与校对随后交付。界面使用 Liquid Glass，旧系统使用原生材质。

## 快速启动

```sh
Scripts/compile_and_run.sh debug
```

构建后停止当前仓库对应的旧进程，再启动 build/Voxline.app。开发重启前保存编辑。

Mac／iOS 构建、未签名 IPA、模拟器启动、工具链与测试命令见 [开发工作流](docs/development.md)。需求、架构和历史材料见 [文档入口](docs/README.md)，执行状态与验收见 [GitHub Project](https://github.com/users/yamakze/projects/1)。第三方许可见 [Licenses](Licenses/README.md)。
