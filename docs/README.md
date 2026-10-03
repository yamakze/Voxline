# Voxline 文档

[GitHub Project](https://github.com/users/yamakze/projects/1/views/1) 管理任务、依赖和进度。源码文档保留需求边界、稳定规则与设计理由。

- [首版需求与技术边界](RFC/voxline-v1.md)
- [UI 页面需求](RFC/voxline-ui-requirements.md)
- [首版执行计划](plans/voxline-v1.md)
- [当前工程边界](architecture/README.md)
- [开发工作流与构建入口](development.md)
- [iOS 开发入口验证](optimize/ios-development-entry-validation.md)
- [ADR-0001：字幕工作流与数据边界](ADR/0001-subtitle-workflow-and-data-boundaries.md)
- [ADR-0002：M1 基线与项目文档](ADR/0002-m1-baseline-and-project-document.md)
- [ADR-0003：设备本地媒体关联](ADR/0003-local-media-association.md)
- [ADR-0004：Task 工作流与原生界面](ADR/0004-task-workflow-and-native-design.md)
- [ADR-0005：本地 Task 文档格式与迁移](ADR/0005-task-document-format.md)
- [ADR-0006：单窗口任务库与显式持久化](ADR/0006-single-window-task-library.md)
- [M1 混合媒体输入与重构后持久化验证](optimize/m1-media-input-validation.md)
- [M0 真实媒体验证](plans/m0-validation.md)
- [M0 首个真实样本结果](optimize/m0-asr-first-sample.md)
- [M1 工程与文档基础验证](optimize/m1-foundation-validation.md)
- [M1 视频导入与本地关联验证](optimize/m1-media-import-validation.md)
- [M1 Task 文档与迁移验证](optimize/m1-task-document-validation.md)
- [M1 原生 Task 界面验证](optimize/m1-task-ui-validation.md)

文档职责：architecture 保存当前依赖边界和禁止模式；ADR 保存接受的长期决策；RFC 保存方案与讨论状态；plans 保存活跃执行顺序和验收；optimize 保存质量审计与后续治理建议。完成或废弃的 RFC、计划归档，避免保留多份活跃基准。
