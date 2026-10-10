# Windows 11 Classic Notepad

卸载 Microsoft Store 版记事本，启用系统旧版记事本，并恢复资源管理器“新建 → 文本文档（.txt）”。独立 PowerShell 实现；默认只检查，支持 Windows PowerShell 5.1 与 PowerShell 7。本预览版的 Apply 限于 Windows 11 x64，不支持 ARM64 或 Windows Server。

> v0.1.0 是预览版。自动化测试覆盖受控逻辑，不代表所有 Windows 11 版本的真实卸载、恢复和菜单验收。执行前请保存记事本中的内容并关闭记事本。

## 使用

从 [Releases](https://github.com/black-zero358/win11-classic-notepad/releases) 下载并解压，阅读脚本后在该目录运行。使用本机原生 64 位 PowerShell；执行修改需要以管理员身份打开终端。管理员应为待处理用户本人，使用另一管理员账户提升会改变 CurrentUser 的含义。

```powershell
# 默认只读诊断
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1

# 预览当前用户操作，不写注册表、不卸载应用
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Apply -WhatIf

# 卸载当前用户新版记事本，设置系统级旧版入口和新建菜单
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Apply

# 可选：旧版系统组件缺失时尝试通过 Windows 功能安装
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Apply -InstallLegacyFeature

# 显式全机操作：所有现有用户卸载，同时移除未来用户的预配包
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Apply -Scope AllUsers -RemoveProvisioned

# 可选：关闭 Winhance 所使用的现代记事本 IFEO 重定向过滤
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Apply -DisableModernRedirect
```

没有安装 PowerShell 7 时，把 `pwsh` 换成 `powershell.exe`。脚本通过系统 Windows PowerShell 5.1 子进程调用 Appx / DISM，避免宿主模块兼容性差异。它不永久调整执行策略；若组织策略阻止脚本，请按组织要求处理。

`Scope` 只限定 Appx 卸载范围。旧版入口与 ShellNew 位于 HKLM，影响整台机器；即使 CurrentUser 模式也需要管理员。其他用户保留新版包时，仍可能通过其默认应用打开新版。

## 参数与结果

| 参数 | 默认值与用途 |
| --- | --- |
| `-Mode` | `Inspect`；`Apply` 执行，`Restore` 恢复注册表 |
| `-Scope` | `CurrentUser`；`AllUsers` 处理所有用户的新版包 |
| `-RemoveProvisioned` | 关闭；仅可配合 Apply / AllUsers |
| `-InstallLegacyFeature` | 关闭；显式允许安装缺失的系统旧版组件 |
| `-DisableModernRedirect` | 关闭；显式调整 IFEO UseFilter |
| `-BackupPath` | Apply 为备份目录；Restore 必填具体 JSON 文件 |
| `-WhatIf` / `-Confirm` | PowerShell 标准预览 / 确认机制 |

输出包含 JSON 状态、检查结果、错误和备份路径。Apply 执行后会在备份旁保存 `.result.json` 报告；Inspect 和 WhatIf 不创建文件。非管理员 Inspect 的组件查询可能无法完成，会明确记录原因。`Failed`、`Partial`、`Conflict` 退出码为 1；只读检查、预览和成功完成为 0。`UiVerified` 始终为 false：脚本不会假定菜单点击和双击打开已验收。WhatIf 的提示文字会与 JSON 一同显示，重定向后不能当作纯 JSON 文件读取。

## 行为和边界

- 精确处理 `Microsoft.WindowsNotepad`，不批量删除其他应用，也不直接删除 WindowsApps 文件。
- 在卸载前检查旧版程序、签名和运行中的记事本。缺少旧版时默认停止；`-InstallLegacyFeature` 使用系统 capability 安装机制，可能访问 Windows Update / WSUS。
- 在修改前保存涉及的注册表值、原类型、是否存在及应用包清单。操作失败报告失败或部分完成，不把写入成功当作菜单验收通过。
- 设置 `.txt` 的 ShellNew 空文件入口和旧版 ProgID、图标、带引号的打开命令；移除旧版 `NoOpenWith`。卸载之后重新应用并核验注册项。
- `-DisableModernRedirect` 使用 `UseFilter=0`，参考 Winhance 当前实现，属于版本相关选项。它不是微软对所有 Windows 11 版本的保证。
- 不修改受保护的 `UserChoice`、不强制关闭应用、不强制重启 Explorer、不清理其他软件的 OpenWith 项。
- 系统更新、Store 更新、现有用户级覆盖或默认应用设置可能改变最终行为。

## 恢复

Apply 输出备份 JSON 文件位置，默认保存在 `%ProgramData%\ClassicNotepadUtility\Backups`。Apply 的 `-BackupPath` 可指定目录；Restore 的同名参数必须指向具体 JSON 文件。保管整个备份目录，仅使用本机可信备份：

```powershell
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Restore -BackupPath 'C:\ProgramData\ClassicNotepadUtility\Backups\ClassicNotepadRegistry-时间戳.json' -WhatIf
pwsh -NoProfile -File .\Restore-ClassicNotepad.ps1 -Mode Restore -BackupPath 'C:\ProgramData\ClassicNotepadUtility\Backups\ClassicNotepadRegistry-时间戳.json'
```

Restore 只还原本脚本记录的注册表值，并检测后来改动的冲突。它不保证重装现代应用，不恢复应用数据、未保存标签页或旧版本包，也不卸载后来安装的系统 capability。需要新版时可打开 [Microsoft Store 记事本](https://apps.microsoft.com/detail/9msmlrh6lzf3) 重新安装。包清单不是应用安装包备份。

`-WhatIf` 仍会检查管理员权限及其他前置条件；未满足条件时会返回 Failed，不会执行改动。`-Confirm` 被拒绝时也不会写入。

## 实际验收与排查

1. 关闭再打开右键菜单；Windows 11 可能需要“显示更多选项 → 新建”。菜单仍旧时，保存工作后自行注销或重启资源管理器。
2. 确认出现“文本文档”，点击并检查文件扩展名 `.txt`、初始大小 0 字节。
3. 双击文件，核对实际运行程序为系统 `System32\notepad.exe`。若仍打开其他编辑器，在 Windows 设置的默认应用中为 `.txt` 选择旧版记事本。
4. 菜单仍缺失时重新 Inspect，检查 HKCU 覆盖、App Paths、默认应用及输出错误。注册表回读成功并不证明 Explorer 使用同一视图；不要盲目反复叠加注册项。

## 开发与验证

```powershell
pwsh -NoProfile -File .\tests\Run-Tests.ps1
powershell.exe -NoProfile -File .\tests\Run-Tests.ps1
```

测试不卸载本机应用，不写入真实系统注册表。真实 Apply / Restore 应在可回退的 Windows 11 虚拟机中验证，再用于需要保留数据的系统。请勿把包含本机包路径、用户信息的备份和诊断输出直接上传到公开 issue。

实现依据与差异见 [SOURCES.md](SOURCES.md)。本项目使用 MIT 许可证，与 Winhance 无隶属关系，未复制其实现代码。
