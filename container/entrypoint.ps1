#!/usr/bin/env pwsh
[CmdletBinding()]
param(
    [string]$SyncScriptPath = '/app/src/Sync-SumatraAction1Release.ps1'
)

$ErrorActionPreference = 'Stop'

Import-Module '/app/src/SumatraManagedUpdate.Common.psm1' -Force

$config = Get-SumatraContainerRuntimeConfig
$schedule = New-SumatraContainerScheduleCommand -Config $config -SyncScriptPath $SyncScriptPath

$null = Invoke-SumatraContainerStartupSync -OneShot $config.OneShot -SyncCommand {
    Invoke-SumatraContainerSyncOnce -ScriptPath $SyncScriptPath
}

if ($config.OneShot) {
    exit 0
}

if ($schedule.Kind -eq 'Interval') {
    while ($true) {
        Start-Sleep -Seconds $schedule.Seconds
        try {
            Invoke-SumatraContainerSyncOnce -ScriptPath $SyncScriptPath
        }
        catch {
            Write-Error $_ -ErrorAction Continue
        }
    }
}

$envFile = '/etc/action1-sumatra-container.env'
$envSpec = New-SumatraContainerCronEnvironmentSpec
$envSpec.Lines | Set-Content -LiteralPath $envFile -Encoding ASCII
chmod $envSpec.Mode $envFile

$runner = '/usr/local/bin/action1-sumatra-sync.sh'
@(
    '#!/usr/bin/env bash'
    'set -a'
    ". $envFile"
    'set +a'
    $schedule.Command
) | Set-Content -LiteralPath $runner -Encoding ASCII
chmod +x $runner

$cronFile = '/etc/cron.d/action1-sumatra-sync'
"$($schedule.Expression) root $runner >> /proc/1/fd/1 2>> /proc/1/fd/2" | Set-Content -LiteralPath $cronFile -Encoding ASCII
chmod 0644 $cronFile

& /usr/sbin/cron -f
