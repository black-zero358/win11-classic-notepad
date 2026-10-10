#requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0

function Assert-True {
    param([bool] $Condition, [string] $Message = 'Expected condition to be true.')
    if (-not $Condition) { throw $Message }
}

function Assert-False {
    param([bool] $Condition, [string] $Message = 'Expected condition to be false.')
    if ($Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $Message = 'Values differ.')
    if ($null -eq $Expected -and $null -eq $Actual) { return }
    if ($null -eq $Expected -or $null -eq $Actual -or [string]$Expected -cne [string]$Actual) {
        throw ("{0} Expected: <{1}> Actual: <{2}>" -f $Message, $Expected, $Actual)
    }
}

function Assert-Contains {
    param([object[]] $Collection, $Expected, [string] $Message = 'Collection does not contain the expected value.')
    if (@($Collection) -notcontains $Expected) { throw ("{0} Expected: <{1}>" -f $Message, $Expected) }
}

function Assert-Match {
    param([string] $Actual, [string] $Pattern, [string] $Message = 'Text does not match the expected pattern.')
    if ($Actual -notmatch $Pattern) { throw ("{0} Pattern: <{1}> Actual: <{2}>" -f $Message, $Pattern, $Actual) }
}

function Test-Case {
    param([Parameter(Mandatory = $true)][string] $Name, [Parameter(Mandatory = $true)][scriptblock] $Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ("PASS {0}" -f $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host ("FAIL {0}`n     {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
}

function Copy-TestObject {
    param([Parameter(Mandatory = $true)] $InputObject)
    return ($InputObject | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
}

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$utilityPath = Join-Path $repositoryRoot 'Restore-ClassicNotepad.ps1'
if (-not (Test-Path -LiteralPath $utilityPath -PathType Leaf)) {
    throw "Utility script was not found: $utilityPath"
}

$parseTokens = $null
$parseErrors = $null
[void][Management.Automation.Language.Parser]::ParseFile($utilityPath, [ref]$parseTokens, [ref]$parseErrors)
Test-Case 'main script parses in the current PowerShell host' {
    Assert-Equal 0 @($parseErrors).Count (@($parseErrors | ForEach-Object { $_.Message }) -join '; ')
}

$dotSourceOutput = @(. $utilityPath)
Test-Case 'dot-sourcing only defines functions and produces no report' {
    Assert-Equal 0 $dotSourceOutput.Count 'Dot-sourcing unexpectedly executed the entry point.'
}

function New-TestBackupDocument {
    param(
        [switch] $DisableModernRedirect,
        [string] $MutationState = 'Applied'
    )

    $culture = 'en-US'
    $plan = @(Get-RegistryPlan -SystemRoot (Get-SystemRootPath) -UICultureName $culture -DisableModernRedirect:$DisableModernRedirect)
    $values = foreach ($item in $plan) {
        [pscustomobject][ordered]@{
            KeyPath = [string]$item.KeyPath
            ValueName = [string]$item.ValueName
            OriginalKeyExisted = $false
            OriginalValueExisted = $false
            OriginalKind = $null
            OriginalData = $null
            DesiredExists = [bool]$item.DesiredExists
            DesiredKind = $item.DesiredKind
            DesiredData = $item.DesiredData
            MutationState = $MutationState
        }
    }
    $keys = foreach ($keyPath in (Get-RegistryPlanKeys -Plan $plan)) {
        [pscustomobject][ordered]@{ KeyPath = $keyPath; OriginalKeyExisted = $false }
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = $script:BackupSchemaVersion
        UtilityVersion = $script:UtilityVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        MachineName = [Environment]::MachineName
        RegistryHive = 'LocalMachine'
        RegistryView = 'Registry64'
        Scope = 'CurrentUser'
        UICultureName = $culture
        Options = [pscustomobject][ordered]@{
            RemoveProvisioned = $false
            DisableModernRedirect = [bool]$DisableModernRedirect
            InstallLegacyFeature = $false
        }
        PlanFingerprint = Get-PlanFingerprint -Plan $plan
        Values = @($values)
        Keys = @($keys)
        StateSnapshot = [pscustomobject][ordered]@{
            Appx = [pscustomobject]@{ Before = @(); ProvisionedBefore = @() }
            Capability = [pscustomobject]@{ Name = 'Microsoft.Windows.Notepad.System~~~~0.0.1.0'; AfterState = 'Installed' }
        }
        OperationJournal = [pscustomobject][ordered]@{
            Capability = [pscustomobject]@{ State = 'NotStarted'; Requested = $false; Changed = $false; Before = $null; After = $null }
            Appx = [pscustomobject]@{ State = 'NotStarted'; Scope = 'CurrentUser'; RemoveProvisioned = $false; Before = $null; After = $null }
        }
        NonRegistryRollbackNotice = 'This backup restores only the listed registry values. It does not restore Appx packages or Windows capabilities.'
    }
}

Test-Case 'default registry plan is bounded to the nine documented values' {
    $plan = @(Get-RegistryPlan -SystemRoot 'C:\Windows' -UICultureName 'en-US')
    Assert-Equal 9 $plan.Count
    Assert-False (@($plan | Where-Object { $_.KeyPath -match '(?i)UserChoice|HKEY_CURRENT_USER|^HKCU' }).Count -gt 0) 'The plan must not touch UserChoice or HKCU.'
    Assert-True (@($plan | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\.txt\ShellNew' -and $_.ValueName -ceq 'NullFile' -and $_.DesiredExists -and $_.DesiredData -ceq '' }).Count -eq 1) 'ShellNew NullFile is missing or incorrect.'
    Assert-True (@($plan | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\Applications\notepad.exe' -and $_.ValueName -ceq 'NoOpenWith' -and -not $_.DesiredExists }).Count -eq 1) 'NoOpenWith removal is missing.'
}

Test-Case 'open command quotes both the executable and percent-one argument' {
    $plan = @(Get-RegistryPlan -SystemRoot 'C:\Windows With Space' -UICultureName 'en-US')
    $command = @($plan | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\txtfilelegacy\shell\open\command' })
    Assert-Equal 1 $command.Count
    Assert-Equal '"C:\Windows With Space\System32\notepad.exe" "%1"' $command[0].DesiredData
}

Test-Case 'Chinese UI culture uses the localized document name' {
    $plan = @(Get-RegistryPlan -SystemRoot 'C:\Windows' -UICultureName 'zh-CN')
    $description = @($plan | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\txtfilelegacy' -and $_.ValueName -ceq '' })[0]
    $itemName = @($plan | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\.txt\ShellNew' -and $_.ValueName -ceq 'ItemName' })[0]
    $expectedChineseName = [string]([char]0x6587) + [char]0x672C + [char]0x6587 + [char]0x6863
    Assert-Equal $expectedChineseName $description.DesiredData
    Assert-Equal $expectedChineseName $itemName.DesiredData
}

Test-Case 'redirect option adds only the UseFilter DWORD item' {
    $base = @(Get-RegistryPlan -SystemRoot 'C:\Windows' -UICultureName 'en-US')
    $extended = @(Get-RegistryPlan -SystemRoot 'C:\Windows' -UICultureName 'en-US' -DisableModernRedirect)
    Assert-Equal ($base.Count + 1) $extended.Count
    $added = @($extended | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe' -and $_.ValueName -ceq 'UseFilter' })
    Assert-Equal 1 $added.Count
    Assert-Equal 'DWord' $added[0].DesiredKind
    Assert-Equal 0 $added[0].DesiredData
}

Test-Case 'plan fingerprint is stable across input order' {
    $plan = @(Get-RegistryPlan -SystemRoot 'C:\Windows' -UICultureName 'en-US')
    $reversed = @($plan)
    [array]::Reverse($reversed)
    Assert-Equal (Get-PlanFingerprint -Plan $plan) (Get-PlanFingerprint -Plan $reversed)
}

Test-Case 'registry matching requires exact existence kind and data' {
    $item = [pscustomobject]@{ DesiredExists = $true; DesiredKind = 'DWord'; DesiredData = 0 }
    Assert-True (Test-RegistryMatchesPlanItem -State ([pscustomobject]@{ ValueExists = $true; Kind = 'DWord'; Data = 0 }) -PlanItem $item)
    Assert-False (Test-RegistryMatchesPlanItem -State ([pscustomobject]@{ ValueExists = $true; Kind = 'String'; Data = '0' }) -PlanItem $item)
    Assert-False (Test-RegistryMatchesPlanItem -State ([pscustomobject]@{ ValueExists = $false; Kind = $null; Data = $null }) -PlanItem $item)
    $removeItem = [pscustomobject]@{ DesiredExists = $false; DesiredKind = $null; DesiredData = $null }
    Assert-True (Test-RegistryMatchesPlanItem -State ([pscustomobject]@{ ValueExists = $false }) -PlanItem $removeItem)
}

Test-Case 'operation arguments reject unsafe option combinations' {
    Assert-False (Test-OperationArguments -Mode Inspect -Scope AllUsers -RemoveProvisioned $true -BackupPath '').IsValid
    Assert-False (Test-OperationArguments -Mode Apply -Scope CurrentUser -RemoveProvisioned $true -BackupPath '').IsValid
    Assert-True (Test-OperationArguments -Mode Apply -Scope AllUsers -RemoveProvisioned $true -BackupPath '').IsValid
    Assert-False (Test-OperationArguments -Mode Restore -Scope CurrentUser -RemoveProvisioned $false -BackupPath '').IsValid
    Assert-True (Test-OperationArguments -Mode Restore -Scope CurrentUser -RemoveProvisioned $false -BackupPath 'backup.json').IsValid
}

Test-Case 'valid backup document matches the exact allowlisted plan' {
    $validation = Test-BackupDocument -Document (New-TestBackupDocument)
    Assert-True $validation.IsValid ($validation.Errors -join '; ')
}

Test-Case 'backup validator rejects schema fingerprint and hive corruption' {
    $schema = Copy-TestObject (New-TestBackupDocument)
    $schema.SchemaVersion = 'other.v1'
    Assert-False (Test-BackupDocument -Document $schema).IsValid

    $fingerprint = Copy-TestObject (New-TestBackupDocument)
    $fingerprint.PlanFingerprint = ('0' * 64)
    Assert-False (Test-BackupDocument -Document $fingerprint).IsValid

    $hive = Copy-TestObject (New-TestBackupDocument)
    $hive.RegistryHive = 'CurrentUser'
    Assert-False (Test-BackupDocument -Document $hive).IsValid
}

Test-Case 'backup validator rejects malicious path and desired command data' {
    $pathAttack = Copy-TestObject (New-TestBackupDocument)
    $pathAttack.Values[0].KeyPath = 'SOFTWARE\Classes\..\..\HKEY_USERS\S-1-5-18\Software\Injected'
    Assert-False (Test-BackupDocument -Document $pathAttack).IsValid

    $commandAttack = Copy-TestObject (New-TestBackupDocument)
    $commandEntry = @($commandAttack.Values | Where-Object { $_.KeyPath -ceq 'SOFTWARE\Classes\txtfilelegacy\shell\open\command' })[0]
    $commandEntry.DesiredData = 'cmd.exe /c calc.exe'
    Assert-False (Test-BackupDocument -Document $commandAttack).IsValid
}

Test-Case 'backup validator rejects duplicate keys and values' {
    $duplicateValue = Copy-TestObject (New-TestBackupDocument)
    $duplicateValue.Values[1].KeyPath = $duplicateValue.Values[0].KeyPath
    $duplicateValue.Values[1].ValueName = $duplicateValue.Values[0].ValueName
    Assert-False (Test-BackupDocument -Document $duplicateValue).IsValid

    $duplicateKey = Copy-TestObject (New-TestBackupDocument)
    $duplicateKey.Keys[1].KeyPath = $duplicateKey.Keys[0].KeyPath
    Assert-False (Test-BackupDocument -Document $duplicateKey).IsValid 'Duplicate key entries can conceal an omitted allowlisted key.'
}

Test-Case 'backup validator rejects missing or wrongly typed value fields' {
    $missing = Copy-TestObject (New-TestBackupDocument)
    $missing.Values[0].PSObject.Properties.Remove('OriginalKeyExisted')
    Assert-False (Test-BackupDocument -Document $missing).IsValid 'A required backup value property is missing.'

    $wrongType = Copy-TestObject (New-TestBackupDocument)
    $wrongType.Values[0].OriginalValueExisted = 'false'
    Assert-False (Test-BackupDocument -Document $wrongType).IsValid 'Boolean strings must not pass as JSON booleans.'

    $unexpected = Copy-TestObject (New-TestBackupDocument)
    $unexpected.Values[0] | Add-Member -NotePropertyName Injected -NotePropertyValue 'ignored payload'
    Assert-False (Test-BackupDocument -Document $unexpected).IsValid 'Unexpected backup value properties must fail closed.'
}

# Capture the generated Appx worker program without starting Windows PowerShell.
$script:CapturedWorkerCommand = $null
function Invoke-WindowsPowerShellJson {
    param([string] $Command)
    $script:CapturedWorkerCommand = $Command
    return [pscustomobject]@{ ExitCode = 0; Data = $null; RawOutput = '' }
}
[void](Invoke-AppxWorker -Action Inspect -Scope CurrentUser -RemoveProvisioned $false)

Test-Case 'generated Appx worker parses as a standalone PowerShell program' {
    Assert-True (-not [string]::IsNullOrWhiteSpace($script:CapturedWorkerCommand))
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseInput($script:CapturedWorkerCommand, [ref]$tokens, [ref]$errors)
    Assert-Equal 0 @($errors).Count (@($errors | ForEach-Object { $_.Message }) -join '; ')
}

$script:CapturedGetAppxName = $null
$script:CapturedPackageTypes = @()
function Get-AppxPackage {
    [CmdletBinding()]
    param([string] $Name, [string[]] $PackageTypeFilter, [switch] $AllUsers)
    $script:CapturedGetAppxName = $Name
    $script:CapturedPackageTypes = @($PackageTypeFilter)
    return [pscustomobject]@{
        Name = 'Microsoft.WindowsNotepad'
        PackageFullName = 'Microsoft.WindowsNotepad_1.0.0.0_x64__8wekyb3d8bbwe'
        PackageFamilyName = 'Microsoft.WindowsNotepad_8wekyb3d8bbwe'
        InstallLocation = 'C:\Program Files\WindowsApps\Microsoft.WindowsNotepad_1.0.0.0_x64__8wekyb3d8bbwe'
        IsBundle = $false
    }
}

Test-Case 'generated Appx worker runs against a mocked exact target package' {
    $json = Invoke-Expression $script:CapturedWorkerCommand
    $data = $json | ConvertFrom-Json
    Assert-Equal 'Microsoft.WindowsNotepad' $script:CapturedGetAppxName
    Assert-Contains $script:CapturedPackageTypes 'Bundle'
    Assert-Contains $script:CapturedPackageTypes 'Main'
    Assert-False ([bool]$data.VerificationPassed) 'Inspect should not claim removal verification.'
    Assert-Equal 1 @($data.Before).Count
    Assert-Equal 'Main' @($data.Before)[0].PackageType
}

# Restore the utility definitions after the worker-capture mock, then install
# process-local mocks for all host and mutation boundaries used below.
. $utilityPath
$script:RestoreStateQueue = @()
$script:RestoreSetItems = @()
function Get-RegistryValueState {
    param([string] $KeyPath, [AllowEmptyString()][string] $ValueName)
    if ($script:RestoreStateQueue.Count -eq 0) { throw 'Restore state mock was called more times than expected.' }
    $next = $script:RestoreStateQueue[0]
    if ($script:RestoreStateQueue.Count -eq 1) { $script:RestoreStateQueue = @() }
    else { $script:RestoreStateQueue = @($script:RestoreStateQueue[1..($script:RestoreStateQueue.Count - 1)]) }
    return $next
}
function Set-RegistryPlanItem {
    param($PlanItem)
    $script:RestoreSetItems = @($script:RestoreSetItems) + $PlanItem
}

Test-Case 'restore skips a value changed after Apply and records a conflict' {
    $script:RestoreSetItems = @()
    $script:RestoreStateQueue = @([pscustomobject]@{ KeyExists = $true; ValueExists = $true; Kind = 'String'; Data = 'changed later' })
    $document = [pscustomobject]@{
        Values = @([pscustomobject]@{
            KeyPath = 'SOFTWARE\Classes\.txt'
            ValueName = ''
            MutationState = 'Applied'
            DesiredExists = $true
            DesiredKind = 'String'
            DesiredData = 'txtfilelegacy'
            OriginalValueExisted = $true
            OriginalKind = 'String'
            OriginalData = 'original-owner'
        })
        Keys = @()
    }
    $result = New-ResultObject -Mode Restore -Scope CurrentUser
    Restore-RegistryBackup -Document $document -Result $result
    Assert-Equal 1 @($result.Registry.Conflicts).Count
    Assert-Equal 0 @($script:RestoreSetItems).Count 'A conflicting value was overwritten.'
}

Test-Case 'restore uses compare-and-swap and writes only the recorded original value' {
    $script:RestoreSetItems = @()
    $script:RestoreStateQueue = @(
        [pscustomobject]@{ KeyExists = $true; ValueExists = $true; Kind = 'String'; Data = 'txtfilelegacy' },
        [pscustomobject]@{ KeyExists = $true; ValueExists = $true; Kind = 'String'; Data = 'original-owner' }
    )
    $document = [pscustomobject]@{
        Values = @([pscustomobject]@{
            KeyPath = 'SOFTWARE\Classes\.txt'
            ValueName = ''
            MutationState = 'Applied'
            DesiredExists = $true
            DesiredKind = 'String'
            DesiredData = 'txtfilelegacy'
            OriginalValueExisted = $true
            OriginalKind = 'String'
            OriginalData = 'original-owner'
        })
        Keys = @()
    }
    $result = New-ResultObject -Mode Restore -Scope CurrentUser
    Restore-RegistryBackup -Document $document -Result $result
    Assert-Equal 0 @($result.Registry.Conflicts).Count
    Assert-Equal 1 @($script:RestoreSetItems).Count
    Assert-Equal 'original-owner' $script:RestoreSetItems[0].DesiredData
    Assert-Equal 1 @($result.Registry.Restore).Count
}

$script:MockCounters = $null
$script:MockAppxRemoveExitCode = 0
$script:MockAppxRemoveVerification = $true

function Reset-MockCounters {
    $script:MockCounters = [ordered]@{
        RegistryWriteAccess = 0
        BackupWrites = 0
        RegistryApply = 0
        RegistryRestore = 0
        AppxInspect = 0
        AppxRemove = 0
        CapabilityInspect = 0
        CapabilityInstall = 0
        ShellNotify = 0
    }
}

function Test-IsWindows { return $true }
function Test-IsAdministrator { return $true }
function Get-SystemRootPath { return 'C:\Windows' }
function Get-WindowsInstallationType { return 'Client' }
function Get-UserAssociationInspection { return @() }
function Get-Process {
    [CmdletBinding()]
    param([string] $Name)
    return @()
}
function Get-IfeoInspection {
    return [pscustomobject]@{ KeyPath = 'mock'; Entries = @(); Blocking = @(); HasBlockingDebugger = $false }
}
function Get-UserAppPathInspection {
    return [pscustomobject]@{ Exists = $false; Path = 'mock'; Values = [pscustomobject]@{} }
}
function Test-ClassicNotepadBinary {
    return [pscustomobject]@{ Path = 'C:\Windows\System32\notepad.exe'; Exists = $true; SignatureStatus = 'Valid'; SignerSubject = 'Microsoft'; CompanyName = 'Microsoft'; IsValidMicrosoftBinary = $true }
}
function Get-RegistryValueState {
    param([string] $KeyPath, [AllowEmptyString()][string] $ValueName)
    return [pscustomobject]@{ KeyExists = $false; ValueExists = $false; Kind = $null; Data = $null }
}
function Test-RegistryKeyExists { param([string] $KeyPath) return $false }
function Test-RegistryPlan {
    param([object[]] $Plan)
    return [pscustomobject]@{ Passed = $true; Details = @($Plan) }
}
function Test-RegistryWriteAccess { $script:MockCounters.RegistryWriteAccess++ }
function Write-JsonAtomic { param($Document, [string] $Path) $script:MockCounters.BackupWrites++ }
function Apply-RegistryPlan { param([object[]] $Plan, $BackupDocument, [string] $BackupFile, $Result) $script:MockCounters.RegistryApply++ }
function Restore-RegistryBackup { param($Document, $Result) $script:MockCounters.RegistryRestore++ }
function Send-ShellAssociationChanged { $script:MockCounters.ShellNotify++ }
function Invoke-CapabilityWorker {
    param([bool] $Install)
    if ($Install) { $script:MockCounters.CapabilityInstall++ } else { $script:MockCounters.CapabilityInspect++ }
    return [pscustomobject]@{ ExitCode = 0; Data = [pscustomobject]@{ Name = 'Microsoft.Windows.Notepad.System~~~~0.0.1.0'; BeforeState = 'Installed'; AfterState = 'Installed'; Changed = $false; Error = $null }; RawOutput = '' }
}
function Invoke-AppxWorker {
    param([string] $Action, [string] $Scope, [bool] $RemoveProvisioned)
    if ($Action -eq 'Inspect') {
        $script:MockCounters.AppxInspect++
        return [pscustomobject]@{ ExitCode = 0; Data = [pscustomobject]@{ Before = @(); ProvisionedBefore = @(); Removed = @(); Errors = @(); After = @(); ProvisionedAfter = @(); VerificationPassed = $null }; RawOutput = '' }
    }
    $script:MockCounters.AppxRemove++
    $errors = if ($script:MockAppxRemoveExitCode -eq 0) { @() } else { @('mocked removal failure') }
    return [pscustomobject]@{ ExitCode = $script:MockAppxRemoveExitCode; Data = [pscustomobject]@{ Before = @(); ProvisionedBefore = @(); Removed = @(); Errors = @($errors); After = @(); ProvisionedAfter = @(); VerificationPassed = $script:MockAppxRemoveVerification }; RawOutput = '' }
}

$originalProcessorArchitecture = $env:PROCESSOR_ARCHITECTURE
$env:PROCESSOR_ARCHITECTURE = 'AMD64'

Test-Case 'Apply WhatIf performs no writes removal installation or notification' {
    Reset-MockCounters
    $script:MockAppxRemoveExitCode = 0
    $script:MockAppxRemoveVerification = $true
    $unusedBackupDirectory = Join-Path ([IO.Path]::GetTempPath()) ('classic-notepad-whatif-' + [Guid]::NewGuid().ToString('N'))
    $result = Invoke-ClassicNotepadUtility -Mode Apply -Scope CurrentUser -BackupPath $unusedBackupDirectory -WhatIf
    Assert-Equal 'WouldApply' $result.Status ($result.Errors -join '; ')
    Assert-Equal 1 $script:MockCounters.AppxInspect
    Assert-Equal 0 $script:MockCounters.AppxRemove
    Assert-Equal 0 $script:MockCounters.RegistryWriteAccess
    Assert-Equal 0 $script:MockCounters.BackupWrites
    Assert-Equal 0 $script:MockCounters.RegistryApply
    Assert-Equal 0 $script:MockCounters.RegistryRestore
    Assert-Equal 0 $script:MockCounters.CapabilityInstall
    Assert-Equal 0 $script:MockCounters.ShellNotify
    Assert-False (Test-Path -LiteralPath $unusedBackupDirectory) 'WhatIf created the backup directory.'
}

Test-Case 'Restore WhatIf validates a backup but performs no registry mutation' {
    Reset-MockCounters
    $tempFile = Join-Path ([IO.Path]::GetTempPath()) ('classic-notepad-restore-' + [Guid]::NewGuid().ToString('N') + '.json')
    try {
        $json = ConvertTo-Json (New-TestBackupDocument) -Depth 30
        [IO.File]::WriteAllText($tempFile, $json, (New-Object Text.UTF8Encoding($false)))
        $result = Invoke-ClassicNotepadUtility -Mode Restore -Scope CurrentUser -BackupPath $tempFile -WhatIf
        Assert-Equal 'WouldRestore' $result.Status ($result.Errors -join '; ')
        Assert-Equal 0 $script:MockCounters.RegistryWriteAccess
        Assert-Equal 0 $script:MockCounters.RegistryRestore
        Assert-Equal 0 $script:MockCounters.ShellNotify
    }
    finally {
        if (Test-Path -LiteralPath $tempFile -PathType Leaf) { Remove-Item -LiteralPath $tempFile -Force }
    }
}

Test-Case 'partial Appx failure is reported after mocked registry reapplication' {
    Reset-MockCounters
    $script:MockAppxRemoveExitCode = 23
    $script:MockAppxRemoveVerification = $false
    $backupDirectory = Join-Path ([IO.Path]::GetTempPath()) ('classic-notepad-partial-' + [Guid]::NewGuid().ToString('N'))
    $result = Invoke-ClassicNotepadUtility -Mode Apply -Scope CurrentUser -BackupPath $backupDirectory -Confirm:$false
    Assert-Equal 'Partial' $result.Status ($result.Errors -join '; ')
    Assert-Equal 1 $script:MockCounters.AppxRemove
    Assert-Equal 1 $script:MockCounters.RegistryWriteAccess
    Assert-Equal 2 $script:MockCounters.RegistryApply 'The registry plan must be applied before and after Appx removal.'
    Assert-Equal 1 $script:MockCounters.ShellNotify
    Assert-Contains @($result.Appx.Errors) 'mocked removal failure'
    Assert-False ([bool]$result.Appx.VerificationPassed)
}

Write-Host ''
Write-Host ("Tests: {0} passed, {1} failed, {2} total" -f $script:Passed, $script:Failed, ($script:Passed + $script:Failed))
$env:PROCESSOR_ARCHITECTURE = $originalProcessorArchitecture
if ($script:Failed -gt 0) { exit 1 }
