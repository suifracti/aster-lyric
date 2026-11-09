# Aster · Lyric｜必要提交与交付核对

入口见 [AGENTS](../AGENTS.md)。用户已有每次相关修改后同步 GitHub 的持续授权，明确禁止同步的单轮任务除外；正式安装、费用、迁移和发布仍分别需要对应授权。本页不创建任务、分支/PR、自动 checkpoint 或另一套审批。

## 提交前

```sh
git status --short
git branch --show-current
git rev-parse HEAD
git diff --stat
```

实际源码是 HEAD 加尚未提交差异；实际 App、数据目录、正式 Release 单独识别。只提交本次相关路径，保护他人 dirty/untracked。检查 diff、敏感内容及 `git diff --check`；不公开凭据、OAuth、正式 SQLite、受限歌词/音频、私人原话或私有日志。

业务代码做最小充分检查，文档只核文字、链接、导航和差异。截图需标真实运行还是离屏；视觉认可、性能、模型调用和正式数据未核实就写 NOT_RUN，不用旧 PR 或缩略图冒充验收。

## 同步

先获取并核对目标 main，确认安全快进/整合条件，普通 commit/push；非快进、网络失败或并发修改先核实，不 force、不覆盖拉取、不改共享历史。通过 GitHub 文件 API 写文档时使用新读的 SHA 或预期 ref，发生冲突重新读取，不盲写。

执行后读回实际提交及文件列表。远端修改成功不证明用户 Mac 工作树或 App 已更新；本机同步完成须核本地 HEAD、读回的远端和遗漏改动，远程工具不可见的部分明确保留未知。

## 写回

当前规格与任务结果回 [TOOLBAR_BEHAVIOR](TOOLBAR_BEHAVIOR.md) 中对应范围或用户明确指定的现行任务；经验回 [PROJECT_MEMORY](PROJECT_MEMORY.md)，不要复制提交日志或第二份待办。私人阶段体验/交接回已授权的 Vault 原项目页。附件仅在需要时上传既有私有目录，成功读回后登记，不把源码 ZIP 上传当 Git 同步。

[STATUS](STATUS.md) 及其归档是有日期的历史证据，不自动派发下一阶段。全周期历史复盘的覆盖游标另按 AGENTS 判断，不能把这次提交号当所有历史已读完。
