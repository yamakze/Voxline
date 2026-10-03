# Voxline 首版执行计划

状态：活跃；Task 批处理重构优先，Mac MVP 后交付 iOS 原生播放与校对。

任务与进度以 [GitHub Project](https://github.com/users/yamakze/projects/1/views/1) 为准。本计划保存执行顺序与验收边界。

## 阶段与退出条件

| 阶段 | 工作范围 | 退出条件 |
| --- | --- | --- |
| M0 需求与验证 | S001、模型与性能基线、Task 范围 | 短样本校对完成；Task 与平台决定明确；长验证单独暂缓 |
| M1 任务与转写恢复 | Task、本地存储、旧数据迁移、原生任务界面、音视频导入、模型、抽音频、队列、转写和恢复 | 可创建多媒体任务；参数冻结；单项失败不阻塞其余；已完成成果可恢复 |
| M2 翻译与播放校对 | API 翻译、凭据配置、媒体详情播放、编辑、偏移、三种 SRT | 处理结果可进入详情播放校对；手工结果保留；字幕导出正确 |
| M3 Mac 原生应用验收 | 本地批量任务完整工作流、Liquid Glass 与旧系统材质、运行证据 | 本地视频与音频完成排队、处理、播放校对和导出；真实失败及恢复可见 |
| 后续 iOS | 原生媒体播放、字幕校对与手动文件导入 | 独立设备上的播放与校对验证通过；不依赖自动同步 |

## 当前执行顺序

[VXL-046](https://github.com/users/yamakze/projects/1/views/1?pane=issue&itemId=260521032) 的 Task 模型、参数快照、系统文档读写与旧数据迁移已交付，证据见 [Task 验证](../optimize/m1-task-document-validation.md)。当前单窗口任务库可保存混合音视频与独立失败条目，尚无真实处理队列。

1. [VXL-047](https://github.com/users/yamakze/projects/1/views/1?pane=issue&itemId=260521035) 界面阶段已人工验收：任务列表、准备参数、概览与媒体导航已实现。系统 26 运行视觉和队列／播放校对连接继续跟踪，整体 Status 为 In Progress，证据见 [原生任务界面验证](../optimize/m1-task-ui-validation.md)。
2. VXL-006 输入范围已完成；VXL-034 的 M4A/MP3/WAV 格式检查、混合 Task 和错误显示已交付，处理与校对完整链路待接通。证据见 [混合媒体输入验证](../optimize/m1-media-input-validation.md)。
3. VXL-007 的基准模型下载与本地加载已交付，证据见 [模型安装验证](../optimize/m1-model-installation-validation.md)。继续 VXL-008／009／010／012／026：音频提取、转写、字幕切分、顺序队列与持久恢复。
4. VXL-013／014／015／016／017：翻译、媒体详情播放校对与三种 SRT。
5. VXL-020：Mac MVP 批处理完整验收；VXL-030 随后交付 iOS 原生播放与校对。

VXL-030 已提前建立 iOS 构建与 UI 开发入口：未签名 IPA、模拟器安装启动、手动导入任务与只读字幕浏览。该基础不代替媒体播放、编辑或真机验收；完整功能继续依赖 Mac 工作流与共享校对能力。说明见 [开发工作流](../development.md)。

任务库生命周期采用 [ADR-0006](../ADR/0006-single-window-task-library.md)。模型目录、固定版本与实例生命周期采用 [ADR-0007](../ADR/0007-pinned-local-model-installation.md)；VXL-026 的模拟处理已移除，等待真实 Provider。

独立工作可按已满足的前置推进。阶段不是工期承诺；原有单媒体基础通过的检查不代替 Task 工作流完成。
VXL-047 的本地 Task 准备入口已实现，VXL-006／034 可继续媒体输入工作；VXL-047 的实时队列和播放校对连接在相应能力交付后返回验收，避免把整体验收作为其自身依赖的开发前置。

## 跟踪规则

Status 为 Todo、In Progress、Done，表示执行状态。Scope 为首版、后续、暂缓、待决策、排除，表示当前交付范围；排除的平台不是扩展候选。Phase 表示阶段，Category 表示职责，Priority 表示阻塞程度。

暂缓事项保留原因与重启条件，范围变化更新原条目。iCloud 相关事项暂废弃，不再作为任何 MVP 条目的前置；YouTube 来源保留为后续。Windows/Linux 已排除。

[ADR-0004](../ADR/0004-task-workflow-and-native-design.md) 为当前长期决定，需求见 [RFC](../RFC/voxline-v1.md)。S001 人工字幕校对完成，VXL-045 的 30–120 分钟验证继续暂缓；持久恢复、明确错误与字幕正确性要求保持。

## Project 视图

- [总览](https://github.com/users/yamakze/projects/1/views/1)
- [首版与待决策](https://github.com/users/yamakze/projects/1/views/2)
- [后续路线](https://github.com/users/yamakze/projects/1/views/3)
- [暂缓与排除](https://github.com/users/yamakze/projects/1/views/4)
