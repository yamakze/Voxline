# Voxline 文档

| 维护入口 | 职责 |
| --- | --- |
| [GitHub Project](https://github.com/users/yamakze/projects/1) | 条目范围、前置、进度、验收结果、暂缓原因与重启条件 |
| [产品与页面需求](RFC/voxline-v1.md) | 产品行为、页面和状态设计；可直接交付 UI 设计 |
| [架构](architecture/README.md) | 当前模块、数据、文件与执行规则 |
| [ADR](ADR/) | 长期选择与理由；实现细节引用架构或源码 |
| [执行顺序](plans/voxline-v1.md) | 阶段关系和退出条件 |
| [开发工作流](development.md) | 构建、启动、测试、产物与开发缓存 |

验证日志、私有样本与临时研究材料放在本地忽略目录 tmp；执行结果只回写 Project。optimize 仅保存仍有行动价值的质量审计，完成后归档。README 保留介绍和快速启动，避免复制详细使用说明。

## 历史归档

- [M0 ASR 时间边界研究与长样本协议](archive/m0-asr-first-sample.md)
- [M1 开发验证快照](archive/m1-validation.md)
- [ADR-0001 历史字幕工作流](archive/0001-subtitle-workflow-and-data-boundaries.md)
- [ADR-0002 历史基线与文档方案](archive/0002-m1-baseline-and-project-document.md)

归档不随当前实现更新。旧方案的替代关系由当前 ADR 明确说明，当前状态以 Project 为准。
