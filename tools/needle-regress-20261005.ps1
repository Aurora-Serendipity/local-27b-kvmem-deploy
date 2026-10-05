# 17 针质量剖面回归：两档各跑一次（与 profile-FINAL-cfg-20261005-111710 同口径）
# 深度列表与历史记录完全一致（0.5% → 99.5%）
$ErrorActionPreference = 'Continue'
$pkg = 'D:\Local Model\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem'
$out = 'D:\Local Model\_runs\logs'
$depths = '0.005,0.0669,0.1288,0.1906,0.2525,0.3144,0.3763,0.4381,0.5,0.5619,0.6238,0.6856,0.7475,0.8094,0.8713,0.9331,0.995'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $out "needle-regress-$stamp.log"
function Say([string]$m) { $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content -Path $log -Value $l -Encoding UTF8 }

function StartProfile([string]$name, [string]$cpuGb, [string]$ctx) {
  $p = (Get-NetTCPConnection -LocalPort 18200 -State Listen -ErrorAction SilentlyContinue).OwningProcess
  if ($p) { Stop-Process -Id $p -Force; Start-Sleep -Seconds 4 }
  foreach ($k in @('KVMEM_CPU_GB', 'KV_CTX', 'KVMEM_GEN', 'KVMEM_BUDGET', 'KVMEM_GPU_R', 'KVMEM_TRACE')) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
  $env:KVMEM_CPU_GB = $cpuGb; $env:KV_CTX = $ctx; $env:KVMEM_GEN = '8192'; $env:KVMEM_BUDGET = '32768'; $env:KVMEM_GPU_R = '0.25'; $env:NINFER_AGENT = '1'
  $sl = Join-Path $out "needle-server-$name-$stamp.log"
  $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$pkg\start-retrieval.bat`"") -WorkingDirectory $pkg -RedirectStandardOutput $sl -RedirectStandardError "$sl.err" -PassThru -WindowStyle Hidden
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 90) { try { if ((Invoke-WebRequest 'http://127.0.0.1:18200/v1/models' -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200) { break } } catch { }; Start-Sleep -Milliseconds 250 }
  Say ("[$name] up in " + [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) + " s")
  (Get-Content "$sl.err" | Select-String 'KVMEM_TIERS' | Select-Object -First 1).Line | ForEach-Object { Say ("  " + $_.Line.Trim()) }
}

function StopEngine { $p = (Get-NetTCPConnection -LocalPort 18200 -State Listen -ErrorAction SilentlyContinue).OwningProcess; if ($p) { Stop-Process -Id $p -Force; Start-Sleep -Seconds 4 } }

foreach ($prof in @(@{ n = 'daily'; cpu = '4'; ctx = '131072' }, @{ n = 'longctx'; cpu = '6'; ctx = '262144' })) {
  Say ''
  Say ('================ ' + $prof.n + ' (cpu-gb ' + $prof.cpu + ' / ctx ' + $prof.ctx + ') ================')
  StartProfile $prof.n $prof.cpu $prof.ctx
  & powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\Local Model\_runs\profile-needle.ps1' -Port 18200 -TargetTokens 24000 -MaxTokens 400 -Depths $depths -Tag ("17needle-" + $prof.n + "-regress") 2>&1 |
    Select-String 'retrieved :|missed|prompt_tokens|out_tokens|prefill |decode |JSON:' | ForEach-Object { Say ("  " + $_.Line.Trim()) }
  StopEngine
  Say ("  after stop: VRAM=" + (nvidia-smi --query-gpu=memory.used --format=csv,noheader))
}
Say ''
Say ('log: ' + $log)
