# 实现依据

核验日期：2026-10-10。

## Microsoft

- [Extending the New Submenu](https://learn.microsoft.com/en-us/windows/win32/shell/context#extending-the-new-submenu)：扩展名下 ShellNew / NullFile 创建空文件，ProgID 提供类型描述。
- [Windows Features on Demand](https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/features-on-demand-non-language-fod?view=windows-11)：旧版 Notepad(system) capability 为 Microsoft.Windows.Notepad.System~~~~0.0.1.0，在新版不可用时提供旧版。
- [Add-WindowsCapability](https://learn.microsoft.com/en-us/powershell/module/dism/add-windowscapability)：系统组件安装与 Windows Update / WSUS 来源。
- [Remove-AppxPackage](https://learn.microsoft.com/en-us/powershell/module/appx/remove-appxpackage)：当前用户 / AllUsers 范围及 bundle 父包处理。
- [Remove-AppxProvisionedPackage](https://learn.microsoft.com/en-us/powershell/module/dism/remove-appxprovisionedpackage)：去预配影响未来用户，不等同于卸载现有用户包。
- [Store app troubleshooting](https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/modern-inbox-store-apps-troubleshooting-guidance)：重新注册依赖包文件仍然存在，不是无条件完整恢复。
- [PowerShell module compatibility](https://learn.microsoft.com/en-us/powershell/windows/module-compatibility)：Appx / DISM 的支持与版本有关。本工具统一调用 Windows PowerShell 5.1，不声称 PowerShell 7 一律不支持。

## Winhance 行为参考

固定提交：[db80ecfcf6762a7b856860930d9f4ee17bf1e67c](https://github.com/memstechtips/Winhance/commit/db80ecfcf6762a7b856860930d9f4ee17bf1e67c)。

- [ExplorerCustomizations.cs](https://github.com/memstechtips/Winhance/blob/db80ecfcf6762a7b856860930d9f4ee17bf1e67c/src/Winhance.Core/Features/Customize/Models/ExplorerCustomizations.cs#L1713-L1763)：启用旧版时删除 NoOpenWith、设置 IFEO UseFilter=0、删除当前用户 App Paths 的 notepad.exe 键。
- [WindowsAppDefinitions.cs](https://github.com/memstechtips/Winhance/blob/db80ecfcf6762a7b856860930d9f4ee17bf1e67c/src/Winhance.Core/Features/SoftwareApps/Models/WindowsAppDefinitions.cs#L458-L467)：现代包 Microsoft.WindowsNotepad，Store 产品 9MSMLRH6LZF3。
- [BloatRemovalScriptGenerator.cs](https://github.com/memstechtips/Winhance/blob/db80ecfcf6762a7b856860930d9f4ee17bf1e67c/src/Winhance.Core/Features/SoftwareApps/Utilities/BloatRemovalScriptGenerator.cs#L301-L355)：其全机卸载同时处理预配及所有用户。

本工具自行实现：默认只读；默认卸载范围为当前用户；去预配、安装组件、UseFilter 调整需要显式参数；保留用户 App Paths，报告冲突；采用值级备份与冲突检查。UseFilter 的意义来源于 Winhance 实现，未找到微软承诺其跨版本 Notepad 行为的正式契约。

Winhance 使用 [PolyForm Shield 1.0.0](https://github.com/memstechtips/Winhance/blob/db80ecfcf6762a7b856860930d9f4ee17bf1e67c/LICENSE.txt)，不是 MIT。本项目仅参考公开行为与微软文档，未复制其代码。
