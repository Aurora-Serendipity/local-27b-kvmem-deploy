<#
launch-and-wait.ps1 -- start the tier-1 launcher with documented env-var overrides
(03-基础部署后的调优方案.md: "不编辑 bat，用环境变量覆盖") and measure cold-start ready time.

The launcher itself is untouched; overrides are applied inside the child cmd.exe only
(set "K=V" && start-lowvram.bat), so nothing leaks into this session or the system.

Writes only under -OutDir. Never modifies the package.
#>
[CmdletBinding()]
param(
  [string]$Tag = 'run',
  [string]$Set = '',            # 'K=1;K2=2'  (powershell -File flattens real arrays, so use a string)
  [int]$Port = 18200,
  [int]$TimeoutSec = 300,
  [string]$OutDir = 'D:\Local Model\_runs\logs'
)
$ErrorActionPreference = 'Stop'
$pkg = 'D:\Local Model\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "start-$Tag-$stamp.log"
$err = Join-Path $OutDir "start-$Tag-$stamp.err.log"

$Set = @($Set -split '[;,]' | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
$parts = @()
foreach ($s in $Set) { $parts += ('set "' + $s + '"') }
$parts += ('"' + (Join-Path $pkg 'start-lowvram.bat') + '"')
$cmdline = ($parts -join ' && ')

Write-Host "cmd /c $cmdline"
Write-Host "log -> $log"
$t0 = Get-Date
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $cmdline) -WorkingDirectory $pkg `
       -RedirectStandardOutput $log -RedirectStandardError $err -PassThru -WindowStyle Hidden

# poll readiness (light HTTP GET every 250 ms)
$ready = $false; $readyAt = $null; $last = ''
$deadline = $t0.AddSeconds($TimeoutSec)
while ((Get-Date) -lt $deadline) {
  if ($p.HasExited) { Write-Host "[FAIL] launcher/engine exited early: exit=$($p.ExitCode)"; break }
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/v1/models" -UseBasicParsing -TimeoutSec 3
    $last = [string]$r.StatusCode
    if ($r.StatusCode -eq 200) { $ready = $true; $readyAt = Get-Date; break }
  } catch { $last = $_.Exception.Message }
  Start-Sleep -Milliseconds 250
}
$elapsed = if ($readyAt) { [math]::Round(($readyAt - $t0).TotalSeconds, 2) } else { $null }
Write-Host ''
if ($ready) {
  Write-Host ("READY: HTTP 200 after {0} s  (cold start, launcher start -> /v1/models = 200)" -f $elapsed)
} else {
  Write-Host ("NOT READY within {0}s (last: {1})" -f $TimeoutSec, $last)
  if (Test-Path $err) { Write-Host '--- stderr ---'; Get-Content -LiteralPath $err -Tail 20 }
}
Write-Host ''
Write-Host '--- launcher stdout ---'
if (Test-Path $log) { Get-Content -LiteralPath $log }
Write-Host '--- engine stderr ---'
if (Test-Path $err) { Get-Content -LiteralPath $err }
Write-Host ''
Write-Host ("pid={0}  ready_s={1}  log={2}" -f $p.Id, $elapsed, $log)

$meta = [ordered]@{ tag = $tag; stamp = $stamp; set = $Set; pid = $p.Id; ready_s = $elapsed
                    ready = $ready; log = $log; err = $err; cmdline = $cmdline }
[IO.File]::WriteAllText((Join-Path $OutDir "start-$tag-$stamp.json"),
  ($meta | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
