# 更新记录

## 0.1.0 — 2026-10-10

首次预发布。

- 默认只读检查；显式执行卸载新版记事本并注册旧版记事本与 `.txt` 新建菜单。
- 区分当前用户、所有用户和预配包清理。
- 支持 PowerShell 7 入口及 Windows PowerShell 5.1；应用包操作交给系统 Windows PowerShell。
- 注册表按值备份和恢复，并检查恢复冲突。
- 支持 `-WhatIf`；记录失败和部分完成状态。
- 不修改 UserChoice、不强制关闭记事本、不自动重启 Explorer。

自动化测试使用模拟系统接口。首次发布未完成安装着新版记事本的干净 Windows 11 虚拟机全流程卸载与恢复验收。
- 本预览版 Apply 仅支持 Windows 11 x64；ARM64 和 Windows Server 会拒绝执行。Restore 不依赖 Appx、DISM 或记事本当前状态。
