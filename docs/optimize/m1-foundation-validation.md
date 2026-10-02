# M1 工程与文档基础验证

日期：2026-10-01。设备为 M4 / 16 GB、macOS 15.7.9、Xcode 26.2 / Swift 6.2.3。

## 实现与证据

SwiftPM 建立 Core、WhisperKit 集成和 SwiftUI App 边界，固定 Argmax v1.1.0 对应提交，只链接 WhisperKit 产品。第三方许可随应用打包。

`.voxline` 文档保存版本、稳定 ID、媒体身份、非敏感设置、毫秒时间和译文来源版本。新项目明确显示未关联媒体、零字幕和无处理任务；旧译文在原文修改后保留并标记需重译。

- `swift test`：9 项测试通过，覆盖读写保留、未来版本、损坏数据、重复 ID、非法时间、重叠、媒体边界、译文失败及配置中夹带凭据。
- `Scripts/build-app.sh debug`：生成 `build/Voxline.app`；`codesign --verify --deep --strict` 通过。本地 ad-hoc 签名用于开发运行。
- 原生界面：新建项目空状态正确；打开 S001 文档显示 208 条字幕。修改名称并保存，关闭后重新打开显示保存名称与 208 条字幕；JSON 比对确认除名称外的全部内容一致。
- S001 界面夹具由第 03 组冻结原始结果生成，显式排除一个空白文本段，保存在忽略目录 `tmp/project-governance/`。该夹具验证文档与界面读写，不代表视频导入或校对后最终字幕已接入应用。

## 后续边界

VXL-005 工程与依赖边界完成。此处证据针对初始文档基础；后续设备书签、重新关联与沙盒验证见 [视频导入与本地关联验证](m1-media-import-validation.md)。Task、生产转写 Provider、字幕切分、任务恢复、翻译、播放校对、SRT 导出和随后 iOS 应用仍需各条目验收。当前范围以 [ADR-0004](../ADR/0004-task-workflow-and-native-design.md) 为准，iCloud 暂废弃。

30–120 分钟长视频验证由 [VXL-045](https://github.com/users/yamakze/projects/1/views/1?pane=issue&itemId=259733484) 暂缓跟踪，短样本人工校对完成的结论见 [M0 报告](m0-asr-first-sample.md)。
