#requires -Version 5.1

<#
.SYNOPSIS
Inspects, applies, or restores the registry configuration used by classic Notepad.

.DESCRIPTION
The default mode is read-only. Apply creates a value-level registry backup before
changing Windows capabilities, the registry, or Appx packages. Restore only
restores registry values recorded by this script; it never claims to restore Appx
packages or Windows capabilities.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Inspect', 'Apply', 'Restore')]
    [string] $Mode = 'Inspect',

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $RemoveProvisioned,

    [switch] $DisableModernRedirect,

    [switch] $InstallLegacyFeature,

    [string] $BackupPath
)

Set-StrictMode -Version 2.0

$script:UtilityVersion = '0.1.0'
$script:BackupSchemaVersion = 'classic-notepad-registry-backup.v1'
$script:ReportSchemaVersion = 'classic-notepad-report.v1'
$script:TargetPackageName = 'Microsoft.WindowsNotepad'
$script:LegacyCapabilityPrefix = 'Microsoft.Windows.Notepad.System~~~~'

function New-ResultObject {
    param(
        [Parameter(Mandatory = $true)][string] $Mode,
        [Parameter(Mandatory = $true)][string] $Scope
    )

    [pscustomobject][ordered]@{
        SchemaVersion = $script:ReportSchemaVersion
        UtilityVersion = $script:UtilityVersion
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Mode = $Mode
        Scope = $Scope
        Status = 'Unknown'
        Preconditions = [pscustomobject][ordered]@{}
        Capability = [pscustomobject][ordered]@{
            Requested = $false
            Changed = $false
            State = 'NotRequested'
            Name = $null
        }
        Appx = [pscustomobject][ordered]@{
            TargetName = $script:TargetPackageName
            Attempted = $false
            VerificationPassed = $null
            Installed = @()
            Provisioned = @()
            Removed = @()
            Errors = @()
        }
        Registry = [pscustomobject][ordered]@{
            View = 'Registry64'
            Plan = @()
            Applied = @()
            Verified = $null
            Restore = @()
            Conflicts = @()
        }
        Backup = [pscustomobject][ordered]@{
            Path = $null
            ResultPath = $null
            Created = $false
            SchemaVersion = $script:BackupSchemaVersion
        }
        ShellNotificationSent = $false
        UiVerified = $false
        Messages = @()
        Errors = @()
    }
}

function Add-ResultMessage {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [Parameter(Mandatory = $true)][string] $Message
    )
    $Result.Messages = @($Result.Messages) + $Message
}

function Add-ResultError {
    param(
        [Parameter(Mandatory = $true)] $Result,
        [Parameter(Mandatory = $true)][string] $Message
    )
    $Result.Errors = @($Result.Errors) + $Message
}

function Test-IsWindows {
    if ($PSVersionTable.PSEdition -eq 'Desktop') { return $true }
    return [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
}

function Test-IsAdministrator {
    if (-not (Test-IsWindows)) { return $false }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-OperatingSystemArchitecture {
    try { return [string][Runtime.InteropServices.RuntimeInformation]::OSArchitecture }
    catch {
        if (-not [string]::IsNullOrWhiteSpace([string]$env:PROCESSOR_ARCHITECTURE)) { return [string]$env:PROCESSOR_ARCHITECTURE }
        return 'Unknown'
    }
}

function Get-SystemRootPath {
    $root = [Environment]::GetEnvironmentVariable('SystemRoot')
    if ([string]::IsNullOrWhiteSpace($root)) { $root = 'C:\Windows' }
    return [IO.Path]::GetFullPath($root)
}

function Get-RegistryPlan {
    [CmdletBinding()]
    param(
        [string] $SystemRoot = (Get-SystemRootPath),
        [string] $UICultureName = ([Globalization.CultureInfo]::InstalledUICulture.Name),
        [switch] $DisableModernRedirect
    )

    $isChinese = $UICultureName -match '^(?i:zh)(-|$)'
    if ($isChinese) {
        # Keep the source ASCII-only so Windows PowerShell 5.1 does not depend
        # on a BOM to decode the localized literal.
        $description = [string]([char]0x6587) + [char]0x672C + [char]0x6587 + [char]0x6863
        $itemName = $description
    }
    else {
        $description = 'Text Document'
        $itemName = 'Text Document'
    }

    $notepadPath = Join-Path $SystemRoot 'System32\notepad.exe'
    $items = @(
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\.txt'; ValueName = ''; DesiredExists = $true; DesiredKind = 'String'; DesiredData = 'txtfilelegacy' },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\.txt'; ValueName = 'Content Type'; DesiredExists = $true; DesiredKind = 'String'; DesiredData = 'text/plain' },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\.txt'; ValueName = 'PerceivedType'; DesiredExists = $true; DesiredKind = 'String'; DesiredData = 'text' },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\.txt\ShellNew'; ValueName = 'NullFile'; DesiredExists = $true; DesiredKind = 'String'; DesiredData = '' },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\.txt\ShellNew'; ValueName = 'ItemName'; DesiredExists = $true; DesiredKind = 'String'; DesiredData = $itemName },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\txtfilelegacy'; ValueName = ''; DesiredExists = $true; DesiredKind = 'String'; DesiredData = $description },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\txtfilelegacy\DefaultIcon'; ValueName = ''; DesiredExists = $true; DesiredKind = 'ExpandString'; DesiredData = '%SystemRoot%\System32\notepad.exe,0' },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\txtfilelegacy\shell\open\command'; ValueName = ''; DesiredExists = $true; DesiredKind = 'String'; DesiredData = ('"{0}" "%1"' -f $notepadPath) },
        [pscustomobject][ordered]@{ KeyPath = 'SOFTWARE\Classes\Applications\notepad.exe'; ValueName = 'NoOpenWith'; DesiredExists = $false; DesiredKind = $null; DesiredData = $null }
    )

    if ($DisableModernRedirect) {
        $items += [pscustomobject][ordered]@{
            KeyPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
            ValueName = 'UseFilter'
            DesiredExists = $true
            DesiredKind = 'DWord'
            DesiredData = 0
        }
    }

    return @($items)
}

function Get-RegistryPlanKeys {
    param([Parameter(Mandatory = $true)][object[]] $Plan)

    $all = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($item in $Plan) {
        $path = [string]$item.KeyPath
        while (-not [string]::IsNullOrWhiteSpace($path)) {
            [void]$all.Add($path)
            $index = $path.LastIndexOf('\')
            if ($index -lt 0) { break }
            $path = $path.Substring(0, $index)
            if ($path -ieq 'SOFTWARE' -or $path -ieq 'SOFTWARE\Classes' -or $path -ieq 'SOFTWARE\Microsoft') {
                break
            }
        }
    }
    return @($all | Sort-Object { ($_ -split '\\').Count }, { $_ })
}

function Convert-RegistryDataForJson {
    param($Data, [string] $Kind)
    if ($null -eq $Data) { return $null }
    if ($Kind -eq 'Binary') { return [Convert]::ToBase64String([byte[]]$Data) }
    if ($Kind -eq 'MultiString') { return @([string[]]$Data) }
    return $Data
}

function Convert-RegistryDataFromJson {
    param($Data, [string] $Kind)
    if ($null -eq $Data) { return $null }
    switch ($Kind) {
        'Binary' { return ,([Convert]::FromBase64String([string]$Data)) }
        'MultiString' { return ,([string[]]@($Data)) }
        'DWord' { return [int]$Data }
        'QWord' { return [long]$Data }
        default { return $Data }
    }
}

function Get-RegistryValueState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $KeyPath,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $ValueName
    )

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry64
    )
    try {
        $key = $base.OpenSubKey($KeyPath, $false)
        if ($null -eq $key) {
            return [pscustomobject][ordered]@{ KeyExists = $false; ValueExists = $false; Kind = $null; Data = $null }
        }
        try {
            $exists = @($key.GetValueNames()) -contains $ValueName
            if (-not $exists) {
                return [pscustomobject][ordered]@{ KeyExists = $true; ValueExists = $false; Kind = $null; Data = $null }
            }
            $kind = $key.GetValueKind($ValueName).ToString()
            $data = $key.GetValue($ValueName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            return [pscustomobject][ordered]@{
                KeyExists = $true
                ValueExists = $true
                Kind = $kind
                Data = (Convert-RegistryDataForJson -Data $data -Kind $kind)
            }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
}

function Test-RegistryKeyExists {
    param([Parameter(Mandatory = $true)][string] $KeyPath)
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey($KeyPath, $false)
        if ($null -eq $key) { return $false }
        $key.Dispose()
        return $true
    }
    finally { $base.Dispose() }
}

function Test-DataEqual {
    param($Left, $Right, [string] $Kind)
    if ($null -eq $Left -and $null -eq $Right) { return $true }
    if ($null -eq $Left -or $null -eq $Right) { return $false }
    if ($Kind -eq 'Binary') { return ([string]$Left -ceq [string]$Right) }
    if ($Kind -eq 'MultiString') {
        $leftItems = @($Left)
        $rightItems = @($Right)
        if ($leftItems.Count -ne $rightItems.Count) { return $false }
        for ($i = 0; $i -lt $leftItems.Count; $i++) {
            if ([string]$leftItems[$i] -cne [string]$rightItems[$i]) { return $false }
        }
        return $true
    }
    return ([string]$Left -ceq [string]$Right)
}

function Test-RegistryMatchesPlanItem {
    param(
        [Parameter(Mandatory = $true)] $State,
        [Parameter(Mandatory = $true)] $PlanItem
    )
    if (-not [bool]$PlanItem.DesiredExists) { return -not [bool]$State.ValueExists }
    if (-not [bool]$State.ValueExists) { return $false }
    if ([string]$State.Kind -cne [string]$PlanItem.DesiredKind) { return $false }
    return Test-DataEqual -Left $State.Data -Right $PlanItem.DesiredData -Kind ([string]$PlanItem.DesiredKind)
}

function Set-RegistryPlanItem {
    param([Parameter(Mandatory = $true)] $PlanItem)

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        if ([bool]$PlanItem.DesiredExists) {
            $key = $base.CreateSubKey([string]$PlanItem.KeyPath, $true)
            if ($null -eq $key) { throw "Unable to create or open HKLM\$($PlanItem.KeyPath)." }
            try {
                $kind = [Microsoft.Win32.RegistryValueKind]::$($PlanItem.DesiredKind)
                $data = Convert-RegistryDataFromJson -Data $PlanItem.DesiredData -Kind ([string]$PlanItem.DesiredKind)
                $key.SetValue([string]$PlanItem.ValueName, $data, $kind)
            }
            finally { $key.Dispose() }
        }
        else {
            $key = $base.OpenSubKey([string]$PlanItem.KeyPath, $true)
            if ($null -ne $key) {
                try { $key.DeleteValue([string]$PlanItem.ValueName, $false) }
                finally { $key.Dispose() }
            }
        }
    }
    finally { $base.Dispose() }
}

function Get-PlanFingerprint {
    param([Parameter(Mandatory = $true)][object[]] $Plan)
    $rows = foreach ($item in ($Plan | Sort-Object KeyPath, ValueName)) {
        [ordered]@{
            KeyPath = [string]$item.KeyPath
            ValueName = [string]$item.ValueName
            DesiredExists = [bool]$item.DesiredExists
            DesiredKind = $item.DesiredKind
            DesiredData = $item.DesiredData
        }
    }
    $json = ConvertTo-Json @($rows) -Depth 8 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function New-BackupDocument {
    param(
        [Parameter(Mandatory = $true)][object[]] $Plan,
        [Parameter(Mandatory = $true)][string] $Scope,
        [Parameter(Mandatory = $true)][string] $UICultureName,
        [bool] $RemoveProvisioned,
        [bool] $DisableModernRedirect,
        [bool] $InstallLegacyFeature,
        $AppxSnapshot,
        $CapabilitySnapshot
    )

    $values = foreach ($item in $Plan) {
        $state = Get-RegistryValueState -KeyPath ([string]$item.KeyPath) -ValueName ([string]$item.ValueName)
        [pscustomobject][ordered]@{
            KeyPath = [string]$item.KeyPath
            ValueName = [string]$item.ValueName
            OriginalKeyExisted = [bool]$state.KeyExists
            OriginalValueExisted = [bool]$state.ValueExists
            OriginalKind = $state.Kind
            OriginalData = $state.Data
            DesiredExists = [bool]$item.DesiredExists
            DesiredKind = $item.DesiredKind
            DesiredData = $item.DesiredData
            MutationState = 'NotStarted'
        }
    }

    $keys = foreach ($keyPath in (Get-RegistryPlanKeys -Plan $Plan)) {
        [pscustomobject][ordered]@{ KeyPath = $keyPath; OriginalKeyExisted = (Test-RegistryKeyExists -KeyPath $keyPath) }
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = $script:BackupSchemaVersion
        UtilityVersion = $script:UtilityVersion
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        MachineName = [Environment]::MachineName
        RegistryHive = 'LocalMachine'
        RegistryView = 'Registry64'
        Scope = $Scope
        UICultureName = $UICultureName
        Options = [pscustomobject][ordered]@{
            RemoveProvisioned = $RemoveProvisioned
            DisableModernRedirect = $DisableModernRedirect
            InstallLegacyFeature = $InstallLegacyFeature
        }
        PlanFingerprint = Get-PlanFingerprint -Plan $Plan
        Values = @($values)
        Keys = @($keys)
        StateSnapshot = [pscustomobject][ordered]@{
            Appx = $AppxSnapshot
            Capability = $CapabilitySnapshot
        }
        OperationJournal = [pscustomobject][ordered]@{
            Capability = [pscustomobject][ordered]@{ State = 'NotStarted'; Requested = $InstallLegacyFeature; Changed = $false; Before = $CapabilitySnapshot; After = $null }
            Appx = [pscustomobject][ordered]@{ State = 'NotStarted'; Scope = $Scope; RemoveProvisioned = $RemoveProvisioned; Before = $AppxSnapshot; After = $null }
        }
        NonRegistryRollbackNotice = 'This backup restores only the listed registry values. It does not restore Appx packages or Windows capabilities.'
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)] $Document,
        [Parameter(Mandatory = $true)][string] $Path
    )
    $json = ConvertTo-Json $Document -Depth 20
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }
    $temp = Join-Path $directory ('.{0}.{1}.tmp' -f ([IO.Path]::GetFileName($Path)), [Guid]::NewGuid().ToString('N'))
    $utf8 = New-Object Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($temp, $json, $utf8)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            [IO.File]::Replace($temp, $Path, $null)
        }
        else {
            [IO.File]::Move($temp, $Path)
        }
    }
    finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Resolve-ApplyBackupFile {
    param([string] $BackupDirectory)
    if ([string]::IsNullOrWhiteSpace($BackupDirectory)) {
        $programData = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
        $BackupDirectory = Join-Path $programData 'ClassicNotepadUtility\Backups'
    }
    $full = [IO.Path]::GetFullPath($BackupDirectory)
    if (Test-Path -LiteralPath $full -PathType Leaf) { throw 'For Apply, -BackupPath must be a directory, not a file.' }
    $name = 'ClassicNotepadRegistry-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
    return Join-Path $full $name
}

function Test-ObjectHasProperties {
    param(
        [Parameter(Mandatory = $true)] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    if ($null -eq $InputObject) { return $false }
    foreach ($name in $Names) {
        if ($null -eq $InputObject.PSObject.Properties[$name]) { return $false }
    }
    return $true
}

function Test-ObjectHasExactProperties {
    param(
        [Parameter(Mandatory = $true)] $InputObject,
        [Parameter(Mandatory = $true)][string[]] $Names
    )
    if (-not (Test-ObjectHasProperties -InputObject $InputObject -Names $Names)) { return $false }
    $actualNames = @($InputObject.PSObject.Properties | ForEach-Object { $_.Name })
    return $actualNames.Count -eq $Names.Count
}

function Test-BackupDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] $Document)

    $errors = New-Object 'System.Collections.Generic.List[string]'
    if ($null -eq $Document) { $errors.Add('Backup document is null.'); return [pscustomobject]@{ IsValid = $false; Errors = $errors.ToArray() } }
    $topProperties = @('SchemaVersion', 'UtilityVersion', 'CreatedUtc', 'MachineName', 'RegistryHive', 'RegistryView', 'Scope', 'UICultureName', 'Options', 'PlanFingerprint', 'Values', 'Keys', 'StateSnapshot', 'OperationJournal', 'NonRegistryRollbackNotice')
    if (-not (Test-ObjectHasExactProperties -InputObject $Document -Names $topProperties)) {
        $errors.Add('Backup document top-level properties do not exactly match the schema.')
        return [pscustomobject][ordered]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    if ([string]$Document.SchemaVersion -cne $script:BackupSchemaVersion) { $errors.Add('Unsupported backup schema version.') }
    if ([string]$Document.RegistryHive -cne 'LocalMachine' -or [string]$Document.RegistryView -cne 'Registry64') { $errors.Add('Backup registry hive or view is not allowed.') }
    if ([string]::IsNullOrWhiteSpace([string]$Document.UICultureName)) { $errors.Add('Backup UICultureName is missing.') }
    if ($null -eq $Document.Options -or -not (Test-ObjectHasExactProperties -InputObject $Document.Options -Names @('RemoveProvisioned', 'DisableModernRedirect', 'InstallLegacyFeature'))) {
        $errors.Add('Backup options do not exactly match the schema.')
        return [pscustomobject][ordered]@{ IsValid = $false; Errors = $errors.ToArray() }
    }
    foreach ($optionName in @('RemoveProvisioned', 'DisableModernRedirect', 'InstallLegacyFeature')) {
        if ($Document.Options.$optionName -isnot [bool]) { $errors.Add("Backup option $optionName must be boolean.") }
    }
    if (-not (Test-ObjectHasExactProperties -InputObject $Document.StateSnapshot -Names @('Appx', 'Capability'))) {
        $errors.Add('Backup state snapshot does not exactly match the schema.')
    }
    if (-not (Test-ObjectHasExactProperties -InputObject $Document.OperationJournal -Names @('Capability', 'Appx'))) {
        $errors.Add('Backup operation journal does not exactly match the schema.')
    }

    $expectedPlan = @()
    if ($errors.Count -eq 0) {
        try {
            $expectedPlan = @(Get-RegistryPlan -SystemRoot (Get-SystemRootPath) -UICultureName ([string]$Document.UICultureName) -DisableModernRedirect:([bool]$Document.Options.DisableModernRedirect))
            $fingerprint = Get-PlanFingerprint -Plan $expectedPlan
            if ([string]$Document.PlanFingerprint -cne $fingerprint) { $errors.Add('Backup plan fingerprint does not match the allowed plan.') }
        }
        catch { $errors.Add("Unable to reconstruct allowed plan: $($_.Exception.Message)") }
    }
    if ($errors.Count -gt 0 -or $expectedPlan.Count -eq 0) {
        if ($expectedPlan.Count -eq 0 -and $errors.Count -eq 0) { $errors.Add('Allowed registry plan is empty.') }
        return [pscustomobject][ordered]@{ IsValid = $false; Errors = $errors.ToArray() }
    }

    $values = @($Document.Values)
    if ($values.Count -ne $expectedPlan.Count) { $errors.Add('Backup value count does not match the allowed plan.') }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($value in $values) {
        $valueProperties = @('KeyPath', 'ValueName', 'OriginalKeyExisted', 'OriginalValueExisted', 'OriginalKind', 'OriginalData', 'DesiredExists', 'DesiredKind', 'DesiredData', 'MutationState')
        if (-not (Test-ObjectHasExactProperties -InputObject $value -Names $valueProperties)) {
            $errors.Add('A backup value record does not exactly match the schema.')
            continue
        }
        if ($value.OriginalKeyExisted -isnot [bool] -or $value.OriginalValueExisted -isnot [bool] -or $value.DesiredExists -isnot [bool]) {
            $errors.Add("Registry existence flags must be boolean: $($value.KeyPath)|$($value.ValueName)")
            continue
        }
        if ([bool]$value.OriginalValueExisted -and -not [bool]$value.OriginalKeyExisted) {
            $errors.Add("A value cannot exist when its key did not exist: $($value.KeyPath)|$($value.ValueName)")
        }
        $identity = ('{0}|{1}' -f [string]$value.KeyPath, [string]$value.ValueName)
        if (-not $seen.Add($identity)) { $errors.Add("Duplicate backup value identity: $identity") }
        $expected = @($expectedPlan | Where-Object { $_.KeyPath -ieq [string]$value.KeyPath -and $_.ValueName -ieq [string]$value.ValueName })
        if ($expected.Count -ne 1) { $errors.Add("Registry value is outside the allowlist: $identity"); continue }
        if ([bool]$value.DesiredExists -ne [bool]$expected[0].DesiredExists -or [string]$value.DesiredKind -cne [string]$expected[0].DesiredKind -or -not (Test-DataEqual -Left $value.DesiredData -Right $expected[0].DesiredData -Kind ([string]$expected[0].DesiredKind))) {
            $errors.Add("Desired value differs from the allowed plan: $identity")
        }
        if ([string]$value.MutationState -notin @('NotStarted', 'Pending', 'Applied')) { $errors.Add("Invalid mutation state: $identity") }
        if ([bool]$value.OriginalValueExisted -and [string]$value.OriginalKind -notin @('String', 'ExpandString', 'Binary', 'DWord', 'MultiString', 'QWord', 'Unknown')) {
            $errors.Add("Invalid original registry kind: $identity")
        }
    }

    $expectedKeys = @(Get-RegistryPlanKeys -Plan $expectedPlan)
    $keys = @($Document.Keys)
    if ($keys.Count -ne $expectedKeys.Count) { $errors.Add('Backup key count does not match the allowed plan.') }
    $seenKeys = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in $keys) {
        if (-not (Test-ObjectHasExactProperties -InputObject $key -Names @('KeyPath', 'OriginalKeyExisted'))) { $errors.Add('A backup key record does not exactly match the schema.'); continue }
        if ($key.OriginalKeyExisted -isnot [bool]) { $errors.Add("OriginalKeyExisted must be boolean: $($key.KeyPath)"); continue }
        if (-not $seenKeys.Add([string]$key.KeyPath)) { $errors.Add("Duplicate backup key identity: $($key.KeyPath)") }
        if (@($expectedKeys | Where-Object { $_ -ieq [string]$key.KeyPath }).Count -ne 1) { $errors.Add("Registry key is outside the allowlist: $($key.KeyPath)") }
    }
    return [pscustomobject][ordered]@{ IsValid = ($errors.Count -eq 0); Errors = $errors.ToArray() }
}

function Test-RegistryWriteAccess {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $key = $base.OpenSubKey('SOFTWARE\Classes', $true)
        if ($null -eq $key) { throw 'HKLM\SOFTWARE\Classes could not be opened for writing.' }
        $key.Dispose()
    }
    finally { $base.Dispose() }
}

function Get-IfeoInspection {
    $rootPath = 'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\notepad.exe'
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $root = $base.OpenSubKey($rootPath, $false)
        if ($null -ne $root) {
            try {
                foreach ($name in $root.GetValueNames()) {
                    $entries.Add([pscustomobject]@{ KeyPath = $rootPath; ValueName = $name; Data = $root.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) })
                }
                foreach ($childName in $root.GetSubKeyNames()) {
                    $childPath = "$rootPath\$childName"
                    $child = $base.OpenSubKey($childPath, $false)
                    if ($null -ne $child) {
                        try {
                            foreach ($name in $child.GetValueNames()) {
                                $entries.Add([pscustomobject]@{ KeyPath = $childPath; ValueName = $name; Data = $child.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) })
                            }
                        }
                        finally { $child.Dispose() }
                    }
                }
            }
            finally { $root.Dispose() }
        }
    }
    finally { $base.Dispose() }

    $blocking = @($entries | Where-Object { $_.ValueName -ieq 'Debugger' -and -not [string]::IsNullOrWhiteSpace([string]$_.Data) })
    [pscustomobject][ordered]@{ KeyPath = $rootPath; Entries = $entries.ToArray(); Blocking = @($blocking); HasBlockingDebugger = ($blocking.Count -gt 0) }
}

function Get-UserAppPathInspection {
    $path = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\App Paths\notepad.exe'
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ Exists = $false; Path = $path; Values = @{} } }
    $item = Get-ItemProperty -LiteralPath $path
    $values = [ordered]@{}
    foreach ($property in $item.PSObject.Properties) {
        if ($property.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $values[$property.Name] = $property.Value }
    }
    return [pscustomobject]@{ Exists = $true; Path = $path; Values = [pscustomobject]$values }
}

function Get-UserAssociationInspection {
    $paths = @(
        'Registry::HKEY_CURRENT_USER\Software\Classes\.txt',
        'Registry::HKEY_CURRENT_USER\Software\Classes\.txt\ShellNew',
        'Registry::HKEY_CURRENT_USER\Software\Classes\txtfilelegacy',
        'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.txt\UserChoice'
    )
    $entries = foreach ($path in $paths) {
        if (-not (Test-Path -LiteralPath $path)) {
            [pscustomobject]@{ Path = $path; Exists = $false; Values = $null }
            continue
        }
        $item = Get-ItemProperty -LiteralPath $path -ErrorAction Stop
        $values = [ordered]@{}
        foreach ($property in $item.PSObject.Properties) {
            if ($property.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { $values[$property.Name] = $property.Value }
        }
        [pscustomobject]@{ Path = $path; Exists = $true; Values = [pscustomobject]$values }
    }
    return @($entries)
}

function Get-WindowsInstallationType {
    $path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    return [string](Get-ItemPropertyValue -LiteralPath $path -Name InstallationType -ErrorAction Stop)
}

function Test-ClassicNotepadBinary {
    $path = Join-Path (Get-SystemRootPath) 'System32\notepad.exe'
    $result = [ordered]@{ Path = $path; Exists = $false; SignatureStatus = $null; SignerSubject = $null; CompanyName = $null; IsValidMicrosoftBinary = $false }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return [pscustomobject]$result }
    $result.Exists = $true
    $file = Get-Item -LiteralPath $path
    $result.CompanyName = $file.VersionInfo.CompanyName
    $signature = Get-AuthenticodeSignature -LiteralPath $path
    $result.SignatureStatus = [string]$signature.Status
    if ($null -ne $signature.SignerCertificate) { $result.SignerSubject = $signature.SignerCertificate.Subject }
    $microsoftIdentity = ([string]$result.CompanyName -match '(?i)^Microsoft') -and ([string]$result.SignerSubject -match '(?i)Microsoft')
    $result.IsValidMicrosoftBinary = ($signature.Status -eq [Management.Automation.SignatureStatus]::Valid -and $microsoftIdentity)
    return [pscustomobject]$result
}

function Get-EncodedCommand {
    param([Parameter(Mandatory = $true)][string] $Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

function Invoke-WindowsPowerShellJson {
    param([Parameter(Mandatory = $true)][string] $Command)
    $exe = Join-Path (Get-SystemRootPath) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Windows PowerShell 5.1 was not found at $exe." }
    $encoded = Get-EncodedCommand -Command $Command
    $output = & $exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
    $exitCode = $LASTEXITCODE
    $text = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    $jsonLine = @($output | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\{.*\}$' } | Select-Object -Last 1)
    $parsed = $null
    if ($jsonLine.Count -eq 1) {
        try { $parsed = $jsonLine[0] | ConvertFrom-Json }
        catch { throw "Windows PowerShell returned invalid JSON. ExitCode=$exitCode Output=$text" }
    }
    if ($null -eq $parsed) { throw "Windows PowerShell returned no JSON. ExitCode=$exitCode Output=$text" }
    return [pscustomobject][ordered]@{ ExitCode = $exitCode; Data = $parsed; RawOutput = $text }
}

function Invoke-AppxWorker {
    [CmdletBinding()]
    param(
        [ValidateSet('Inspect', 'Remove')][string] $Action,
        [ValidateSet('CurrentUser', 'AllUsers')][string] $Scope,
        [bool] $RemoveProvisioned
    )
    $allUsersLiteral = if ($Scope -eq 'AllUsers') { '$true' } else { '$false' }
    $removeLiteral = if ($Action -eq 'Remove') { '$true' } else { '$false' }
    $provisionedLiteral = if ($RemoveProvisioned) { '$true' } else { '$false' }
    $command = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$target = '$($script:TargetPackageName)'
`$allUsers = $allUsersLiteral
`$doRemove = $removeLiteral
`$removeProvisioned = $provisionedLiteral
function Get-ExactPackages {
    `$params = @{ Name = `$target; PackageTypeFilter = @('Bundle','Main'); ErrorAction = 'Stop' }
    if (`$allUsers) { `$params.AllUsers = `$true }
    return @(Get-AppxPackage @params | Where-Object { `$_.Name -ceq `$target })
}
function Convert-Package(`$p) {
    `$isBundle = `$false
    if (`$null -ne `$p.PSObject.Properties['IsBundle']) { `$isBundle = [bool]`$p.IsBundle }
    elseif ([string]`$p.PackageFullName -match '_~_') { `$isBundle = `$true }
    `$packageType = if (`$isBundle) { 'Bundle' } else { 'Main' }
    [pscustomobject]@{ Name=[string]`$p.Name; PackageFullName=[string]`$p.PackageFullName; PackageFamilyName=[string]`$p.PackageFamilyName; InstallLocation=[string]`$p.InstallLocation; IsBundle=`$isBundle; PackageType=`$packageType }
}
`$beforeObjects = @(Get-ExactPackages)
`$before = @(`$beforeObjects | ForEach-Object { Convert-Package `$_ })
`$bundles = @(`$beforeObjects | Where-Object { (`$null -ne `$_.PSObject.Properties['IsBundle'] -and [bool]`$_.IsBundle) -or [string]`$_.PackageFullName -match '_~_' })
`$selected = if (`$bundles.Count -gt 0) { @(`$bundles) } else { @(`$beforeObjects) }
`$selected = @(`$selected | Sort-Object PackageFullName -Unique)
`$provisionedBefore = @()
if (`$allUsers) { `$provisionedBefore = @(Get-AppxProvisionedPackage -Online | Where-Object { `$_.DisplayName -ceq `$target } | ForEach-Object { [pscustomobject]@{ DisplayName=[string]`$_.DisplayName; PackageName=[string]`$_.PackageName } }) }
`$removed = New-Object 'System.Collections.Generic.List[object]'
`$errors = New-Object 'System.Collections.Generic.List[string]'
if (`$doRemove) {
    foreach (`$package in `$selected) {
        try {
            if (`$allUsers) { Remove-AppxPackage -Package `$package.PackageFullName -AllUsers -Confirm:`$false -ErrorAction Stop }
            else { Remove-AppxPackage -Package `$package.PackageFullName -Confirm:`$false -ErrorAction Stop }
            `$removed.Add((Convert-Package `$package))
        }
        catch { `$errors.Add("Package `$(`$package.PackageFullName): `$(`$_.Exception.Message)") }
    }
    if (`$removeProvisioned) {
        foreach (`$package in `$provisionedBefore) {
            try {
                `$outcome = Remove-AppxProvisionedPackage -Online -PackageName `$package.PackageName -ErrorAction Stop
                if (-not `$outcome.Online) { throw 'DISM did not report an online-image operation.' }
                `$removed.Add([pscustomobject]@{ Name=`$package.DisplayName; PackageFullName=`$package.PackageName; PackageFamilyName=`$null; InstallLocation=`$null; IsBundle=`$false; PackageType='Provisioned' })
            }
            catch { `$errors.Add("Provisioned package `$(`$package.PackageName): `$(`$_.Exception.Message)") }
        }
    }
}
`$after = @(Get-ExactPackages | ForEach-Object { Convert-Package `$_ })
`$provisionedAfter = @()
if (`$allUsers) { `$provisionedAfter = @(Get-AppxProvisionedPackage -Online | Where-Object { `$_.DisplayName -ceq `$target } | ForEach-Object { [pscustomobject]@{ DisplayName=[string]`$_.DisplayName; PackageName=[string]`$_.PackageName } }) }
`$verification = if (-not `$doRemove) { `$null } elseif (`$removeProvisioned) { (`$after.Count -eq 0 -and `$provisionedAfter.Count -eq 0) } else { (`$after.Count -eq 0) }
`$result = [pscustomobject]@{ Before=`$before; Selected=@(`$selected | ForEach-Object { Convert-Package `$_ }); ProvisionedBefore=`$provisionedBefore; Removed=`$removed.ToArray(); Errors=`$errors.ToArray(); After=`$after; ProvisionedAfter=`$provisionedAfter; VerificationPassed=`$verification }
`$result | ConvertTo-Json -Depth 8 -Compress
if (`$errors.Count -gt 0 -or (`$doRemove -and -not `$verification)) { exit 23 }
"@
    return Invoke-WindowsPowerShellJson -Command $command
}

function Invoke-CapabilityWorker {
    param([bool] $Install)
    $installLiteral = if ($Install) { '$true' } else { '$false' }
    $command = @"
`$ErrorActionPreference = 'Stop'
`$ProgressPreference = 'SilentlyContinue'
`$prefix = '$($script:LegacyCapabilityPrefix)'
`$install = $installLiteral
`$matches = @(Get-WindowsCapability -Online -ErrorAction Stop | Where-Object { [string]`$_.Name -like "`$prefix*" })
if (`$matches.Count -ne 1) {
    [pscustomobject]@{ Name=`$null; BeforeState=`$null; AfterState=`$null; Changed=`$false; Error="Expected exactly one capability beginning with `$prefix; found `$(`$matches.Count)." } | ConvertTo-Json -Compress
    exit 31
}
`$capability = `$matches[0]
`$before = [string]`$capability.State
`$changed = `$false
if (`$install -and `$before -ne 'Installed') {
    `$outcome = Add-WindowsCapability -Online -Name `$capability.Name -ErrorAction Stop
    `$changed = `$true
}
`$afterObject = Get-WindowsCapability -Online -Name `$capability.Name -ErrorAction Stop
`$after = [string]`$afterObject.State
`$errorText = `$null
if (`$install -and `$after -ne 'Installed') { `$errorText = "Capability state is `$after after installation." }
[pscustomobject]@{ Name=[string]`$capability.Name; BeforeState=`$before; AfterState=`$after; Changed=`$changed; Error=`$errorText } | ConvertTo-Json -Compress
if (`$null -ne `$errorText) { exit 32 }
"@
    return Invoke-WindowsPowerShellJson -Command $command
}

function Send-ShellAssociationChanged {
    if (-not ('ClassicNotepad.NativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace ClassicNotepad {
    public static class NativeMethods {
        [DllImport("shell32.dll")]
        public static extern void SHChangeNotify(uint eventId, uint flags, IntPtr item1, IntPtr item2);
    }
}

function Save-ApplyResultSidecar {
    param([Parameter(Mandatory = $true)] $Result)
    if (-not [bool]$Result.Backup.Created -or [string]::IsNullOrWhiteSpace([string]$Result.Backup.Path)) { return }
    $path = [string]$Result.Backup.Path + '.result.json'
    $Result.Backup.ResultPath = $path
    Write-JsonAtomic -Document $Result -Path $path
}
'@
    }
    [ClassicNotepad.NativeMethods]::SHChangeNotify(0x08000000, 0x0000, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Apply-RegistryPlan {
    param(
        [Parameter(Mandatory = $true)][object[]] $Plan,
        [Parameter(Mandatory = $true)] $BackupDocument,
        [Parameter(Mandatory = $true)][string] $BackupFile,
        [Parameter(Mandatory = $true)] $Result
    )
    for ($i = 0; $i -lt $Plan.Count; $i++) {
        $item = $Plan[$i]
        $BackupDocument.Values[$i].MutationState = 'Pending'
        Write-JsonAtomic -Document $BackupDocument -Path $BackupFile
        Set-RegistryPlanItem -PlanItem $item
        $state = Get-RegistryValueState -KeyPath ([string]$item.KeyPath) -ValueName ([string]$item.ValueName)
        if (-not (Test-RegistryMatchesPlanItem -State $state -PlanItem $item)) { throw "Registry verification failed for HKLM\$($item.KeyPath) [$($item.ValueName)]." }
        $BackupDocument.Values[$i].MutationState = 'Applied'
        Write-JsonAtomic -Document $BackupDocument -Path $BackupFile
        $Result.Registry.Applied = @($Result.Registry.Applied) + [pscustomobject]@{ KeyPath = $item.KeyPath; ValueName = $item.ValueName; DesiredExists = $item.DesiredExists }
    }
}

function Test-RegistryPlan {
    param([Parameter(Mandatory = $true)][object[]] $Plan)
    $details = foreach ($item in $Plan) {
        $state = Get-RegistryValueState -KeyPath ([string]$item.KeyPath) -ValueName ([string]$item.ValueName)
        [pscustomobject][ordered]@{
            KeyPath = $item.KeyPath
            ValueName = $item.ValueName
            DesiredExists = $item.DesiredExists
            DesiredKind = $item.DesiredKind
            DesiredData = $item.DesiredData
            Current = $state
            Matches = (Test-RegistryMatchesPlanItem -State $state -PlanItem $item)
        }
    }
    [pscustomobject][ordered]@{ Passed = (@($details | Where-Object { -not $_.Matches }).Count -eq 0); Details = @($details) }
}

function Restore-RegistryBackup {
    param(
        [Parameter(Mandatory = $true)] $Document,
        [Parameter(Mandatory = $true)] $Result
    )

    foreach ($entry in @($Document.Values)) {
        if ([string]$entry.MutationState -eq 'NotStarted') { continue }
        $current = Get-RegistryValueState -KeyPath ([string]$entry.KeyPath) -ValueName ([string]$entry.ValueName)
        $restoreItem = [pscustomobject][ordered]@{
            KeyPath = [string]$entry.KeyPath
            ValueName = [string]$entry.ValueName
            DesiredExists = [bool]$entry.OriginalValueExisted
            DesiredKind = $entry.OriginalKind
            DesiredData = $entry.OriginalData
        }
        if (Test-RegistryMatchesPlanItem -State $current -PlanItem $restoreItem) {
            $Result.Registry.Restore = @($Result.Registry.Restore) + [pscustomobject]@{ KeyPath = $entry.KeyPath; ValueName = $entry.ValueName; RestoredExists = $entry.OriginalValueExisted; AlreadyRestored = $true }
            continue
        }
        if (-not (Test-RegistryMatchesPlanItem -State $current -PlanItem $entry)) {
            $conflict = [pscustomobject]@{ KeyPath = $entry.KeyPath; ValueName = $entry.ValueName; Reason = 'Current value no longer equals the value applied by this script.' }
            $Result.Registry.Conflicts = @($Result.Registry.Conflicts) + $conflict
            continue
        }

        Set-RegistryPlanItem -PlanItem $restoreItem
        $after = Get-RegistryValueState -KeyPath ([string]$entry.KeyPath) -ValueName ([string]$entry.ValueName)
        if (-not (Test-RegistryMatchesPlanItem -State $after -PlanItem $restoreItem)) { throw "Restore verification failed for HKLM\$($entry.KeyPath) [$($entry.ValueName)]." }
        $Result.Registry.Restore = @($Result.Registry.Restore) + [pscustomobject]@{ KeyPath = $entry.KeyPath; ValueName = $entry.ValueName; RestoredExists = $entry.OriginalValueExisted; AlreadyRestored = $false }
    }

    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        foreach ($keyEntry in @($Document.Keys | Sort-Object { -($_.KeyPath -split '\\').Count })) {
            if ([bool]$keyEntry.OriginalKeyExisted) { continue }
            $key = $base.OpenSubKey([string]$keyEntry.KeyPath, $false)
            if ($null -eq $key) { continue }
            try { $isEmpty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) }
            finally { $key.Dispose() }
            if ($isEmpty) { $base.DeleteSubKey([string]$keyEntry.KeyPath, $false) }
        }
    }
    finally { $base.Dispose() }
}

function Test-OperationArguments {
    [CmdletBinding()]
    param(
        [ValidateSet('Inspect', 'Apply', 'Restore')][string] $Mode,
        [ValidateSet('CurrentUser', 'AllUsers')][string] $Scope,
        [bool] $RemoveProvisioned,
        [string] $BackupPath
    )
    $errors = @()
    if ($RemoveProvisioned -and ($Mode -ne 'Apply' -or $Scope -ne 'AllUsers')) { $errors += '-RemoveProvisioned is valid only with -Mode Apply -Scope AllUsers.' }
    if ($Mode -eq 'Restore' -and [string]::IsNullOrWhiteSpace($BackupPath)) { $errors += '-Mode Restore requires -BackupPath pointing to a backup JSON file.' }
    return [pscustomobject][ordered]@{ IsValid = ($errors.Count -eq 0); Errors = $errors }
}

function Invoke-ClassicNotepadUtility {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
    param(
        [ValidateSet('Inspect', 'Apply', 'Restore')][string] $Mode = 'Inspect',
        [ValidateSet('CurrentUser', 'AllUsers')][string] $Scope = 'CurrentUser',
        [switch] $RemoveProvisioned,
        [switch] $DisableModernRedirect,
        [switch] $InstallLegacyFeature,
        [string] $BackupPath
    )

    $result = New-ResultObject -Mode $Mode -Scope $Scope
    try {
        $argumentCheck = Test-OperationArguments -Mode $Mode -Scope $Scope -RemoveProvisioned ([bool]$RemoveProvisioned) -BackupPath $BackupPath
        if (-not $argumentCheck.IsValid) { throw ($argumentCheck.Errors -join ' ') }
        if (-not (Test-IsWindows)) { throw 'This utility supports Windows only.' }

        $cultureName = [Globalization.CultureInfo]::InstalledUICulture.Name
        $plan = @(Get-RegistryPlan -SystemRoot (Get-SystemRootPath) -UICultureName $cultureName -DisableModernRedirect:$DisableModernRedirect)
        $isAdmin = Test-IsAdministrator
        $result.Preconditions | Add-Member -NotePropertyName WindowsBuild -NotePropertyValue ([Environment]::OSVersion.Version.Build)
        $result.Preconditions | Add-Member -NotePropertyName InstallationType -NotePropertyValue (Get-WindowsInstallationType)
        $result.Preconditions | Add-Member -NotePropertyName OperatingSystemArchitecture -NotePropertyValue (Get-OperatingSystemArchitecture)
        $result.Preconditions | Add-Member -NotePropertyName IsAdministrator -NotePropertyValue $isAdmin
        $result.Preconditions | Add-Member -NotePropertyName Is64BitOperatingSystem -NotePropertyValue ([Environment]::Is64BitOperatingSystem)
        $result.Preconditions | Add-Member -NotePropertyName Is64BitProcess -NotePropertyValue ([Environment]::Is64BitProcess)

        # Restore deliberately avoids Appx, DISM/capability, binary-signature,
        # running-process, and IFEO preflights. Its authority is registry-only.
        if ($Mode -eq 'Restore') {
            if (-not $isAdmin) { throw 'Restore requires an elevated administrator process.' }
            $fullBackup = [IO.Path]::GetFullPath($BackupPath)
            if (-not (Test-Path -LiteralPath $fullBackup -PathType Leaf)) { throw "Backup file was not found: $fullBackup" }
            $document = Get-Content -LiteralPath $fullBackup -Raw -Encoding UTF8 | ConvertFrom-Json
            $validation = Test-BackupDocument -Document $document
            if (-not $validation.IsValid) { throw ('Backup validation failed: ' + ($validation.Errors -join ' ')) }
            if ([string]$document.MachineName -cne [Environment]::MachineName) { throw 'Backup machine name does not match this computer.' }
            $result.Backup.Path = $fullBackup
            if (-not $PSCmdlet.ShouldProcess('HKLM Registry64', "restore only values recorded in $fullBackup")) {
                $result.Status = 'WouldRestore'
                return $result
            }
            Test-RegistryWriteAccess
            Restore-RegistryBackup -Document $document -Result $result
            Send-ShellAssociationChanged
            $result.ShellNotificationSent = $true
            if ($result.Registry.Conflicts.Count -gt 0) { $result.Status = 'Conflict' } else { $result.Status = 'Restored' }
            Add-ResultMessage -Result $result -Message 'Registry restore completed. Appx packages and Windows capabilities were not restored.'
            Add-ResultMessage -Result $result -Message 'Explorer was notified with SHChangeNotify; Explorer was not restarted and UI behavior was not tested.'
            return $result
        }

        $result.Preconditions | Add-Member -NotePropertyName RunningNotepadProcesses -NotePropertyValue @((Get-Process -Name notepad -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, Path))
        $ifeo = Get-IfeoInspection
        $result.Preconditions | Add-Member -NotePropertyName Ifeo -NotePropertyValue $ifeo
        $userAppPath = Get-UserAppPathInspection
        $result.Preconditions | Add-Member -NotePropertyName CurrentUserAppPath -NotePropertyValue $userAppPath
        $result.Preconditions | Add-Member -NotePropertyName CurrentUserAssociations -NotePropertyValue @(Get-UserAssociationInspection)
        $binary = Test-ClassicNotepadBinary
        $result.Preconditions | Add-Member -NotePropertyName ClassicNotepadBinary -NotePropertyValue $binary
        $registryInspection = Test-RegistryPlan -Plan $plan
        $result.Registry.Verified = $registryInspection.Passed
        $result.Registry.Plan = $registryInspection.Details

        $appxInventory = $null
        try {
            $appxInventory = Invoke-AppxWorker -Action Inspect -Scope $Scope -RemoveProvisioned ([bool]$RemoveProvisioned)
            if ($appxInventory.ExitCode -ne 0) { throw "Appx inventory worker exited with code $($appxInventory.ExitCode)." }
            $result.Appx.Installed = @($appxInventory.Data.Before)
            $result.Appx.Provisioned = @($appxInventory.Data.ProvisionedBefore)
        }
        catch {
            $appxInventory = $null
            Add-ResultMessage -Result $result -Message ("Appx inventory was unavailable: " + $_.Exception.Message)
        }

        $capabilityInventory = $null
        try {
            $capabilityInventory = Invoke-CapabilityWorker -Install $false
            $result.Capability.Name = $capabilityInventory.Data.Name
            $result.Capability.State = $capabilityInventory.Data.AfterState
            if ($capabilityInventory.ExitCode -ne 0) { Add-ResultMessage -Result $result -Message ([string]$capabilityInventory.Data.Error) }
        }
        catch {
            Add-ResultMessage -Result $result -Message ("Capability inventory was unavailable: " + $_.Exception.Message)
        }

        if ($userAppPath.Exists) { Add-ResultMessage -Result $result -Message 'A current-user App Paths redirect for notepad.exe exists. It was only reported and was not changed.' }
        if ($ifeo.Entries.Count -gt 0) { Add-ResultMessage -Result $result -Message 'IFEO configuration for notepad.exe exists. Only a non-empty Debugger value blocks Apply; stock alias filter entries are preserved.' }

        if ($Mode -eq 'Inspect') {
            $result.Status = 'InspectOnly'
            Add-ResultMessage -Result $result -Message 'Explorer UI creation/open behavior was not tested.'
            return $result
        }

        if (-not $isAdmin) { throw 'Apply requires an elevated administrator process.' }
        if (-not [Environment]::Is64BitOperatingSystem -or -not [Environment]::Is64BitProcess) { throw 'Apply requires a native 64-bit process on 64-bit Windows.' }
        if ([string]$result.Preconditions.OperatingSystemArchitecture -notin @('X64', 'AMD64')) { throw "This preview release supports x64 Windows only; detected architecture '$($result.Preconditions.OperatingSystemArchitecture)'." }
        if ([Environment]::OSVersion.Version.Build -lt 22000 -or [string]$result.Preconditions.InstallationType -cne 'Client') { throw 'Apply requires Windows 11 client (build 22000 or later).' }
        if ($ifeo.HasBlockingDebugger) { throw 'A non-empty IFEO Debugger value for notepad.exe is present. This utility will not bypass or delete it.' }
        if ($result.Preconditions.RunningNotepadProcesses.Count -gt 0) { throw 'One or more notepad processes are running. Close them before Apply; this utility will not terminate them.' }
        if ($null -eq $appxInventory) { throw 'Apply requires a successful Appx inventory before the backup is created.' }
        if ($InstallLegacyFeature -and ($null -eq $capabilityInventory -or $capabilityInventory.ExitCode -ne 0)) { throw 'Apply with -InstallLegacyFeature requires a successful, unambiguous capability inventory.' }
        if (-not $InstallLegacyFeature -and -not $binary.IsValidMicrosoftBinary) { throw 'System32\notepad.exe is missing or does not have a valid Microsoft signature. Apply is blocked before Appx removal.' }

        $backupFile = Resolve-ApplyBackupFile -BackupDirectory $BackupPath
        if (-not $PSCmdlet.ShouldProcess('Windows 11 classic Notepad configuration', "create backup, repair HKLM associations, and remove exact $($script:TargetPackageName) packages for $Scope")) {
            $result.Status = 'WouldApply'
            $result.Backup.Path = $backupFile
            Add-ResultMessage -Result $result -Message 'WhatIf made no changes and created no backup or log files.'
            return $result
        }

        $capabilitySnapshot = if ($null -ne $capabilityInventory) { $capabilityInventory.Data } else { [pscustomobject]@{ Error = 'Inventory unavailable'; Name = $null; BeforeState = $null; AfterState = $null } }
        $backupDocument = New-BackupDocument -Plan $plan -Scope $Scope -UICultureName $cultureName -RemoveProvisioned ([bool]$RemoveProvisioned) -DisableModernRedirect ([bool]$DisableModernRedirect) -InstallLegacyFeature ([bool]$InstallLegacyFeature) -AppxSnapshot $appxInventory.Data -CapabilitySnapshot $capabilitySnapshot
        Write-JsonAtomic -Document $backupDocument -Path $backupFile
        $result.Backup.Path = $backupFile
        $result.Backup.Created = $true

        if ($InstallLegacyFeature) {
            $result.Capability.Requested = $true
            $backupDocument.OperationJournal.Capability.State = 'Pending'
            Write-JsonAtomic -Document $backupDocument -Path $backupFile
            $capability = Invoke-CapabilityWorker -Install $true
            $result.Capability.Name = $capability.Data.Name
            $result.Capability.State = $capability.Data.AfterState
            $result.Capability.Changed = [bool]$capability.Data.Changed
            $backupDocument.OperationJournal.Capability.After = $capability.Data
            $backupDocument.OperationJournal.Capability.Changed = [bool]$capability.Data.Changed
            $backupDocument.OperationJournal.Capability.State = if ($capability.ExitCode -eq 0) { 'Applied' } else { 'Failed' }
            Write-JsonAtomic -Document $backupDocument -Path $backupFile
            if ($capability.ExitCode -ne 0) { throw "Legacy Notepad capability installation failed before Appx removal: $($capability.Data.Error)" }
            $binary = Test-ClassicNotepadBinary
            $result.Preconditions.ClassicNotepadBinary = $binary
        }
        if (-not $binary.IsValidMicrosoftBinary) { throw 'System32\notepad.exe failed Microsoft signature verification before Appx removal.' }

        Test-RegistryWriteAccess
        Apply-RegistryPlan -Plan $plan -BackupDocument $backupDocument -BackupFile $backupFile -Result $result
        $preRemovalRegistry = Test-RegistryPlan -Plan $plan
        if (-not $preRemovalRegistry.Passed) { throw 'Registry repair did not verify before Appx removal.' }

        $result.Appx.Attempted = $true
        $backupDocument.OperationJournal.Appx.State = 'Pending'
        Write-JsonAtomic -Document $backupDocument -Path $backupFile
        $appxRemoval = Invoke-AppxWorker -Action Remove -Scope $Scope -RemoveProvisioned ([bool]$RemoveProvisioned)
        $result.Appx.Removed = @($appxRemoval.Data.Removed)
        $result.Appx.Errors = @($appxRemoval.Data.Errors)
        $result.Appx.Installed = @($appxRemoval.Data.After)
        $result.Appx.Provisioned = @($appxRemoval.Data.ProvisionedAfter)
        $result.Appx.VerificationPassed = [bool]$appxRemoval.Data.VerificationPassed
        $backupDocument.OperationJournal.Appx.After = $appxRemoval.Data
        $backupDocument.OperationJournal.Appx.State = if ($appxRemoval.ExitCode -eq 0 -and $result.Appx.VerificationPassed) { 'Applied' } else { 'Failed' }
        Write-JsonAtomic -Document $backupDocument -Path $backupFile

        # Package removal can recreate or remove associations. Reapply from the
        # same backed-up plan, then independently read back every value.
        Apply-RegistryPlan -Plan $plan -BackupDocument $backupDocument -BackupFile $backupFile -Result $result
        $finalRegistry = Test-RegistryPlan -Plan $plan
        $result.Registry.Verified = $finalRegistry.Passed
        $result.Registry.Plan = $finalRegistry.Details
        Send-ShellAssociationChanged
        $result.ShellNotificationSent = $true

        if ($appxRemoval.ExitCode -ne 0 -or -not $result.Appx.VerificationPassed -or -not $result.Registry.Verified) {
            $result.Status = 'Partial'
            Add-ResultError -Result $result -Message 'Apply completed only partially. The registry backup was preserved; Appx/capability changes are not automatically reversible.'
        } else { $result.Status = 'Succeeded' }
        Add-ResultMessage -Result $result -Message 'Explorer was notified with SHChangeNotify; Explorer was not restarted.'
        Add-ResultMessage -Result $result -Message 'Explorer New-menu visibility and file-open behavior require manual UI verification.'
        try { Save-ApplyResultSidecar -Result $result } catch { Add-ResultError -Result $result -Message ("Failed to write the result sidecar: " + $_.Exception.Message); $result.Status = 'Partial' }
        return $result
    }
    catch {
        Add-ResultError -Result $result -Message $_.Exception.Message
        if ($result.Backup.Created -or $result.Registry.Applied.Count -gt 0 -or $result.Registry.Restore.Count -gt 0 -or $result.Capability.Changed -or $result.Appx.Attempted) { $result.Status = 'Partial' } else { $result.Status = 'Failed' }
        if ($result.Backup.Created) {
            try { Save-ApplyResultSidecar -Result $result } catch { Add-ResultError -Result $result -Message ("Failed to write the result sidecar: " + $_.Exception.Message) }
        }
        return $result
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    $invokeParams = @{
        Mode = $Mode
        Scope = $Scope
        RemoveProvisioned = $RemoveProvisioned
        DisableModernRedirect = $DisableModernRedirect
        InstallLegacyFeature = $InstallLegacyFeature
        BackupPath = $BackupPath
        WhatIf = [bool]$WhatIfPreference
    }
    if ($PSBoundParameters.ContainsKey('Confirm')) { $invokeParams.Confirm = $PSBoundParameters['Confirm'] }
    $report = Invoke-ClassicNotepadUtility @invokeParams
    $report | ConvertTo-Json -Depth 20
    if ($report.Status -in @('Failed', 'Partial', 'Conflict')) { exit 1 }
}
