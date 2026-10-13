#Requires -Version 5.1
<#
.SYNOPSIS
    Maximaler Performance-Modus bis zum naechsten Neustart (Windows 11).

.DESCRIPTION
    - Aktiviert Ultimate Performance (Fallback: Hohe Leistung)
    - Setzt Windows-11-Leistungsmodus auf "Beste Leistung"
    - Kein Standby/Display-Timeout, kein USB-Suspend, PCIe ASPM aus
    - Stoppt SysMain, WSearch, DiagTrack (nur Laufzeit, Starttyp bleibt)
    - Registriert einen Startup-Task, der beim Neustart den alten Plan
      wiederherstellt und sich selbst loescht.

    Manuell zurueck: .\Max-Performance.ps1 -Undo
#>
[CmdletBinding()]
param([switch]$Undo)

$ErrorActionPreference = 'Stop'
$TaskName  = 'MaxPerf-Restore'
$StateFile = Join-Path $env:ProgramData 'MaxPerf-state.json'
$UltimateTemplate = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$HighPerformance  = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$ServicesToStop   = 'SysMain', 'WSearch', 'DiagTrack'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole('Administrator')) {
    Write-Error 'Als Administrator ausfuehren.'
}

function Get-ActiveGuid {
    if ((powercfg /getactivescheme) -match '([0-9a-fA-F-]{36})') { $Matches[1] }
    else { throw 'Aktiven Energieplan nicht lesbar.' }
}

function Restore-State {
    if (-not (Test-Path $StateFile)) { Write-Warning 'Kein gespeicherter Zustand.'; return }
    $s = Get-Content $StateFile -Raw | ConvertFrom-Json
    powercfg /overlaysetactive OVERLAY_SCHEME_NONE 2>$null
    powercfg /setactive $s.Original
    if ($s.Created) { powercfg /delete $s.Created 2>$null }
    foreach ($svc in $s.Stopped) { Start-Service $svc -ErrorAction SilentlyContinue }
    Remove-Item $StateFile -Force
    Write-Host "Ursprungszustand wiederhergestellt ($($s.Original))."
}

if ($Undo) {
    Restore-State
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    return
}

if (Test-Path $StateFile) { Write-Error 'Bereits aktiv. Erst mit -Undo zuruecksetzen.' }

$original = Get-ActiveGuid
$created  = $null
$target   = $null

# Ultimate Performance anlegen (auf manchen Geraeten, z.B. Modern Standby, nicht verfuegbar)
$out = powercfg /duplicatescheme $UltimateTemplate 2>&1
if ($LASTEXITCODE -eq 0 -and "$out" -match '([0-9a-fA-F-]{36})') {
    $created = $Matches[1]
    $target  = $created
    powercfg /changename $created 'MaxPerf (temporaer)' 'Bis zum Neustart' | Out-Null
} else {
    Write-Warning 'Ultimate Performance nicht verfuegbar, nutze Hohe Leistung.'
    $target = $HighPerformance
}

powercfg /setactive $target
if ($LASTEXITCODE -ne 0) { Write-Error 'Energieplan konnte nicht aktiviert werden.' }

# Feintuning am temporaeren Plan (AC und DC)
$tweaks = @(
    @('SUB_SLEEP',      'STANDBYIDLE',      0),    # kein Standby
    @('SUB_SLEEP',      'HIBERNATEIDLE',    0),    # kein Ruhezustand
    @('SUB_VIDEO',      'VIDEOIDLE',        0),    # Display bleibt an
    @('SUB_DISK',       'DISKIDLE',         0),    # Platte nie abschalten
    @('SUB_PROCESSOR',  'PROCTHROTTLEMIN',  100),  # CPU min 100 %
    @('SUB_PROCESSOR',  'PROCTHROTTLEMAX',  100),
    @('SUB_PCIEXPRESS', 'ASPM',             0),    # PCIe Link State aus
    @('2a737441-1930-4402-8d77-b2bebba308a3', '48e6b7a6-50f5-4782-a5d4-53bb8f07e226', 0)  # USB selective suspend aus
)
foreach ($t in $tweaks) {
    powercfg /setacvalueindex $target $t[0] $t[1] $t[2] 2>$null
    powercfg /setdcvalueindex $target $t[0] $t[1] $t[2] 2>$null
}
powercfg /setactive $target

# Win11-Leistungsmodus-Slider auf "Beste Leistung" (best effort)
powercfg /overlaysetactive OVERLAY_SCHEME_MAX 2>$null

# Dienste nur zur Laufzeit stoppen
$stopped = @()
foreach ($name in $ServicesToStop) {
    $svc = Get-Service $name -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        try { Stop-Service $name -Force; $stopped += $name }
        catch { Write-Warning "$name nicht stoppbar: $($_.Exception.Message)" }
    }
}

[pscustomobject]@{ Original = $original; Created = $created; Stopped = $stopped } |
    ConvertTo-Json | Set-Content $StateFile -Encoding UTF8

# Beim naechsten Start: Plan zurueck, temporaeren Plan loeschen, Task entfernen, State-Datei loeschen
$cmd = "powercfg /overlaysetactive OVERLAY_SCHEME_NONE; powercfg /setactive $original;"
if ($created) { $cmd += " powercfg /delete $created;" }
$cmd += " Remove-Item '$StateFile' -Force -ErrorAction SilentlyContinue;" +
        " Unregister-ScheduledTask -TaskName '$TaskName' -Confirm:`$false"

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
             -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"$cmd`""
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Force | Out-Null

Write-Host "Max-Performance aktiv. Plan: $target"
Write-Host "Gestoppte Dienste: $($stopped -join ', ')"
Write-Host 'Wird beim naechsten Neustart automatisch zurueckgesetzt (oder: -Undo).'
