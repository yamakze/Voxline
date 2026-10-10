# Contributor documentation

User-facing introductions are maintained in [English](../README.md) and [Simplified Chinese](../README.zh-CN.md). Most engineering documents are currently written in Simplified Chinese.

| Document | Purpose |
| --- | --- |
| [Development](development.md) | Toolchain, signing, build commands, tests, and local artifacts |
| [Architecture](architecture/README.md) | Current module boundaries, persistence, processing, and platform rules |
| [Decisions](ADR/) | Accepted long-term choices and their reasons |
| [Product scope](RFC/voxline-v1.md) | Product behavior and page specifications |
| [Delivery plan](plans/voxline-v1.md) | Dependencies and stage boundaries |
| [Release preparation](release.md) | Versions, release notes, packaging, and distribution requirements |
| [Data handling](privacy.md) | Local processing, external services, credentials, and sync |

The [GitHub Project](https://github.com/users/yamakze/projects/1) owns work-item scope, progress, acceptance results, and deferred work. Documents describe rules and decisions; they do not duplicate task status.

## Historical material

[Archive](archive/) contains frozen research, old validation snapshots, superseded decisions, and [completed code audits](archive/audits/). These describe their original code baseline and are not current setup instructions. New active audits belong in `docs/optimize/`; completed audits are archived after their decisions enter the architecture or Project.

Private media, transcripts, logs, local credentials, and collaboration artifacts stay in ignored directories such as `tmp/` and `.local/`. They are not part of the repository or application packages. `docs/` remains contributor material in Git; application packages contain runtime resources and license notices.
