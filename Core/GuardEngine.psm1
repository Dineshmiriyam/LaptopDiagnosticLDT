#Requires -Version 5.1
<#
.SYNOPSIS
    LDT GuardEngine -- Central Remediation Override Authority

.DESCRIPTION
    The GuardEngine is the highest-authority component in the LDT platform.
    It sits between the diagnostic output and ALL remediation actions.
    No repair operation executes without GuardEngine clearance.

    Authority Functions:
      1. OEM Mode Guard               -- Forces read-only when OEM Validation Mode is active
      2. Prohibited Action Enforcement -- Blocks any action on the absolute prohibition list
      3. EscalationLevel Hard-Stop     -- Halts all remediation at EscalationLevel >= 4
      4. Escalation Threshold Gate     -- Applies enhanced logging at elevated levels
      5. Config AutoRepair Gate        -- Per-module authorization from config.json
      6. Audit Trail                   -- Every guard decision is logged with full rationale

    EscalationLevel Scale:
      0  = No issues
      1  = Advisory / informational
      2  = Warning -- remediation permitted with logging
      3  = Error   -- remediation permitted, enhanced logging, snapshot mandatory
      4  = HARD STOP -- ALL remediation blocked, human escalation required
      5  = CRITICAL HARDWARE -- Hard stop + immediate escalation record

    Absolute Prohibition List (immutable, not overridable by config):
      - BIOS / UEFI firmware flashing
      - Firmware modification of any kind
      - BitLocker recovery key reset or decryption
      - Secure Boot policy modification or bypass
      - TPM ownership modification, clearing, or provisioning
      - Any internet or network call
      - Destructive disk operations (format, diskpart clean)
      - Domain trust reset without explicit credential confirmation
      - Group Policy modification
      - Credential Store access
      - Any action in OEM Validation Mode

.NOTES
    Version : 7.0.0
    Platform: PowerShell 5.1+
    Ported  : From WinDRE v2.1.0 GuardEngine with LDT adaptations
#>

Set-StrictMode -Version Latest

#region -- Prohibition Registry (immutable)

# These action identifiers are permanently prohibited regardless of config or operator intent.
# Attempting to execute any of these causes an immediate FATAL log entry and throws.
$script:_AbsoluteProhibitions = @(
    'BIOS_Flash'
    'UEFI_Firmware_Modify'
    'Firmware_Flash'
    'BitLocker_Reset'
    'BitLocker_Decrypt'
    'SecureBoot_Disable'
    'SecureBoot_Bypass'
    'TPM_Clear'
    'TPM_Ownership_Take'
    'TPM_Provision'
    'Internet_Call'
    'HTTP_Request'
    'DNS_External_Resolve'
    'Disk_Format'
    'DiskPart_Clean'
    'DiskPart_Delete_Partition'
    'Domain_Trust_Reset_Unconfirmed'
    'OEM_Mode_Write_Any'
    'Registry_Hive_Unload'
    'SAM_Database_Modify'
    'Group_Policy_Modify'
    'Credential_Store_Access'
)

# EscalationLevel definitions sourced from config, but these are the minimums.
$script:_DefaultEscalationThresholds = @{
    HardStop          = 4
    SnapshotMandatory = 3
    EnhancedLogging   = 2
}

#endregion

#region -- Guard State

$script:_GuardState = @{
    Initialized       = $false
    OEMModeActive     = $false
    CurrentLevel      = 0
    HardStopTriggered = $false
    SessionId         = $null
    Config            = $null
    DecisionLog       = [System.Collections.Generic.List[PSCustomObject]]::new()
}

#endregion

#region -- Public Functions

function Initialize-GuardEngine {
    <#
    .SYNOPSIS
        Initializes the GuardEngine for a session. Must be called before any guard checks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string]        $SessionId,
        [Parameter(Mandatory)] [PSCustomObject] $Config,
        [switch] $OEMMode
    )

    $script:_GuardState.SessionId         = $SessionId
    $script:_GuardState.Config            = $Config
    $script:_GuardState.OEMModeActive     = $OEMMode.IsPresent
    $script:_GuardState.CurrentLevel      = 0
    $script:_GuardState.HardStopTriggered = $false
    $script:_GuardState.Initialized       = $true
    $script:_GuardState.DecisionLog.Clear()

    Write-EngineLog -SessionId $SessionId -Level 'AUDIT' -Source 'GuardEngine' `
        -Message "GuardEngine initialized" `
        -Data @{
            oemMode          = $script:_GuardState.OEMModeActive
            hardStopLevel    = (Get-ThresholdValue -Key 'HardStop')
            prohibitionCount = $script:_AbsoluteProhibitions.Count
        }
}

function Test-GuardClearance {
    <#
    .SYNOPSIS
        Primary gate function. Returns $true if action is cleared, $false if blocked.
        Throws on prohibited actions.

    .PARAMETER ActionId
        A string identifier for the action being requested. Checked against prohibition list.

    .PARAMETER ModuleName
        The requesting module name. Used for audit logging.

    .PARAMETER EscalationLevel
        The escalation level the calling context is operating at.

    .PARAMETER ActionDescription
        Human-readable description of what will happen if cleared.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)] [string] $ActionId,
        [Parameter(Mandatory)] [string] $ModuleName,
        [Parameter(Mandatory)] [int]    $EscalationLevel,
        [Parameter(Mandatory)] [string] $ActionDescription
    )

    Assert-GuardInitialized

    $sessionId = $script:_GuardState.SessionId
    $decision  = [ordered]@{
        timestamp        = Get-Date -Format 'o'
        actionId         = $ActionId
        moduleName       = $ModuleName
        escalationLevel  = $EscalationLevel
        description      = $ActionDescription
        cleared          = $false
        reason           = $null
    }

    # ── Gate 1: OEM Mode -- absolute block on any write action ────────────────
    if ($script:_GuardState.OEMModeActive) {
        $decision.reason  = "OEM_VALIDATION_MODE: All write actions are prohibited in read-only mode"
        $decision.cleared = $false
        _Record-GuardDecision -Decision $decision
        Write-EngineLog -SessionId $sessionId -Level 'WARN' -Source 'GuardEngine' `
            -Message "GUARD BLOCKED [OEM Mode]: $ActionId requested by $ModuleName" `
            -Data @{ actionId = $ActionId; module = $ModuleName }
        return $false
    }

    # ── Gate 2: Absolute Prohibition Check ───────────────────────────────────
    if ($ActionId -in $script:_AbsoluteProhibitions) {
        $decision.reason  = "ABSOLUTE_PROHIBITION: This action is permanently blocked by platform policy"
        $decision.cleared = $false
        _Record-GuardDecision -Decision $decision
        Write-EngineLog -SessionId $sessionId -Level 'FATAL' -Source 'GuardEngine' `
            -Message "GUARD FATAL BLOCK [Prohibited]: $ActionId -- This action is on the absolute prohibition list" `
            -Data @{ actionId = $ActionId; module = $ModuleName; prohibition = $true }
        throw "GuardEngine: PROHIBITED ACTION '$ActionId' attempted by module '$ModuleName'. This action is permanently blocked."
    }

    # ── Gate 3: Hard Stop Check ───────────────────────────────────────────────
    if ($script:_GuardState.HardStopTriggered) {
        $decision.reason  = "HARD_STOP_ACTIVE: Platform is in hard-stop state -- no remediation permitted"
        $decision.cleared = $false
        _Record-GuardDecision -Decision $decision
        Write-EngineLog -SessionId $sessionId -Level 'ERROR' -Source 'GuardEngine' `
            -Message "GUARD BLOCKED [Hard Stop Active]: $ActionId by $ModuleName" `
            -Data @{ actionId = $ActionId; currentLevel = $script:_GuardState.CurrentLevel }
        return $false
    }

    # ── Gate 4: EscalationLevel Hard-Stop Threshold ───────────────────────────
    $hardStopThreshold = Get-ThresholdValue -Key 'HardStop'
    if ($EscalationLevel -ge $hardStopThreshold) {
        $script:_GuardState.HardStopTriggered = $true
        $script:_GuardState.CurrentLevel      = $EscalationLevel

        $decision.reason  = "ESCALATION_HARD_STOP: Level $EscalationLevel >= threshold $hardStopThreshold"
        $decision.cleared = $false
        _Record-GuardDecision -Decision $decision

        Write-EngineLog -SessionId $sessionId -Level 'FATAL' -Source 'GuardEngine' `
            -Message "HARD STOP TRIGGERED: EscalationLevel $EscalationLevel >= $hardStopThreshold -- ALL remediation suspended" `
            -Data @{
                actionId        = $ActionId
                moduleName      = $ModuleName
                escalationLevel = $EscalationLevel
                threshold       = $hardStopThreshold
            }
        return $false
    }

    # ── Gate 5: Enhanced Logging Threshold ────────────────────────────────────
    $enhancedThreshold = Get-ThresholdValue -Key 'EnhancedLogging'
    if ($EscalationLevel -ge $enhancedThreshold) {
        Write-EngineLog -SessionId $sessionId -Level 'WARN' -Source 'GuardEngine' `
            -Message "GUARD ENHANCED LOG: EscalationLevel $EscalationLevel -- action cleared with enhanced audit" `
            -Data @{ actionId = $ActionId; module = $ModuleName; level = $EscalationLevel }
    }

    # ── Gate 6: Config AutoRepair Check ──────────────────────────────────────
    $moduleConfig = $script:_GuardState.Config.modules.$ModuleName
    if ($moduleConfig -and $moduleConfig.autoRepair -eq $false) {
        $decision.reason  = "MODULE_AUTOREPAIR_DISABLED: $ModuleName has autoRepair=false in config"
        $decision.cleared = $false
        _Record-GuardDecision -Decision $decision
        Write-EngineLog -SessionId $sessionId -Level 'INFO' -Source 'GuardEngine' `
            -Message "GUARD BLOCKED [AutoRepair Off]: $ActionId by $ModuleName" `
            -Data @{ actionId = $ActionId; module = $ModuleName }
        return $false
    }

    # ── Cleared ───────────────────────────────────────────────────────────────
    if ($EscalationLevel -gt $script:_GuardState.CurrentLevel) {
        $script:_GuardState.CurrentLevel = $EscalationLevel
    }

    $decision.cleared = $true
    $decision.reason  = "CLEARED: All guard gates passed"
    _Record-GuardDecision -Decision $decision

    Write-EngineLog -SessionId $sessionId -Level 'DEBUG' -Source 'GuardEngine' `
        -Message "GUARD CLEARED: $ActionId by $ModuleName (Level: $EscalationLevel)" `
        -Data @{ actionId = $ActionId; module = $ModuleName }

    return $true
}

function Set-EscalationLevel {
    <#
    .SYNOPSIS
        Updates the session's current escalation level.
        Automatically triggers hard-stop if threshold is reached.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int]    $Level,
        [Parameter(Mandatory)] [string] $Reason,
        [Parameter(Mandatory)] [string] $Source
    )

    Assert-GuardInitialized

    $previous = $script:_GuardState.CurrentLevel
    if ($Level -gt $previous) {
        $script:_GuardState.CurrentLevel = $Level
    }

    $hardStopThreshold = Get-ThresholdValue -Key 'HardStop'

    $logLevel = if ($Level -ge $hardStopThreshold) { 'FATAL' } elseif ($Level -ge 3) { 'ERROR' } else { 'WARN' }
    Write-EngineLog -SessionId $script:_GuardState.SessionId `
        -Level $logLevel `
        -Source 'GuardEngine' `
        -Message "Escalation level set: $previous -> $Level" `
        -Data @{ level = $Level; reason = $Reason; source = $Source; hardStopThreshold = $hardStopThreshold }

    if ($Level -ge $hardStopThreshold -and -not $script:_GuardState.HardStopTriggered) {
        $script:_GuardState.HardStopTriggered = $true
        Write-EngineLog -SessionId $script:_GuardState.SessionId -Level 'FATAL' `
            -Source 'GuardEngine' `
            -Message "HARD STOP ENGAGED: EscalationLevel $Level reached hard-stop threshold $hardStopThreshold" `
            -Data @{ reason = $Reason; source = $Source }
    }
}

function Get-GuardStatus {
    <#
    .SYNOPSIS
        Returns current GuardEngine state for reporting.
    #>
    [OutputType([PSCustomObject])]
    param()

    return [PSCustomObject]@{
        initialized       = $script:_GuardState.Initialized
        oemModeActive     = $script:_GuardState.OEMModeActive
        currentLevel      = $script:_GuardState.CurrentLevel
        hardStopTriggered = $script:_GuardState.HardStopTriggered
        totalDecisions    = $script:_GuardState.DecisionLog.Count
        blockedActions    = @($script:_GuardState.DecisionLog | Where-Object { -not $_.cleared }).Count
        clearedActions    = @($script:_GuardState.DecisionLog | Where-Object { $_.cleared }).Count
        prohibitionList   = $script:_AbsoluteProhibitions
    }
}

function Get-GuardDecisionLog {
    <#
    .SYNOPSIS
        Returns the full decision log for compliance export.
    #>
    return $script:_GuardState.DecisionLog.ToArray()
}

function Test-ProhibitedAction {
    <#
    .SYNOPSIS
        Non-throwing version -- returns $true if action is prohibited.
        Use this for pre-flight checks in module code.
    #>
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $ActionId)
    return ($ActionId -in $script:_AbsoluteProhibitions)
}

#endregion

#region -- Private Functions

function Assert-GuardInitialized {
    if (-not $script:_GuardState.Initialized) {
        throw "GuardEngine has not been initialized. Call Initialize-GuardEngine before any guard operations."
    }
}

function Get-ThresholdValue {
    param([string] $Key)

    # Prefer config-driven thresholds
    try {
        $configThreshold = $script:_GuardState.Config.engine.escalationThresholds.$Key
        if ($null -ne $configThreshold) { return [int]$configThreshold }
    }
    catch { }

    # Fall back to defaults
    return $script:_DefaultEscalationThresholds[$Key]
}

function _Record-GuardDecision {
    param([hashtable] $Decision)
    $script:_GuardState.DecisionLog.Add([PSCustomObject]$Decision)
}

#endregion

Export-ModuleMember -Function @(
    'Initialize-GuardEngine',
    'Test-GuardClearance',
    'Set-EscalationLevel',
    'Get-GuardStatus',
    'Get-GuardDecisionLog',
    'Test-ProhibitedAction'
)
