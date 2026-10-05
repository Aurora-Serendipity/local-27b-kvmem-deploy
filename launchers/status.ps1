<#
状态检查 · 本地模型（llama-KVMem）

一次性告出：是否在跑 / 跑的是哪套配置 / 显存与内存 / 接口是否 200 / 真推理是否正常。
排障第一步就跑它。本文件是 UTF-8 带 BOM。
#>
[CmdletBinding()]
param([int]$Port = 18200, [switch]$NoTest, [string]$PkgPath = '')
$ErrorActionPreference = 'Continue'

if ($PkgPath) { $Pkg = $PkgPath }
else { $Pkg = Join-Path (Split-Path -Parent $PSScriptRoot) 'pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem' }

function Title([string]$t) { Write-Host ''; Write-Host ('=' * 66); Write-Host ("  " + $t); Write-Host ('=' * 66) }

Title '本地模型 · 状态检查'

# 1) 进程与端口
$procs = @(Get-Process -Name 'llama-kvmem-server' -ErrorAction SilentlyContinue)
$listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
Write-Host ("  引擎进程 ：" + $procs.Count + " 个")
Write-Host ("  端口 {0}：" -f $Port) -NoNewline
if ($listen) { Write-Host ' 正在监听' -ForegroundColor Green } else { Write-Host ' 未监听（没在跑）' -ForegroundColor Yellow }

# 2) 跑的是哪套配置
foreach ($p in $procs) {
  $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $p.Id) -ErrorAction SilentlyContinue
  if ($cim -and $cim.CommandLine) {
    $cl = ($cim.CommandLine -replace '.*llama-kvmem-server.exe"', '') -replace '\s+', ' '
    $ctx = if ($cl -match '-c (\d+)') { $Matches[1] } else { '?' }
    $cpu = if ($cl -match '--kvmem-cpu-gb (\d+)') { $Matches[1] } else { '?' }
    $gen = if ($cl -match '--kvmem-gen-reserve (\d+)') { $Matches[1] } else { '?' }
    $bud = if ($cl -match '--kvmem-budget (\d+)') { $Matches[1] } else { '?' }
    $med = if ($cl -match '--kvmem-method (\w+)') { $Matches[1] } else { '?' }
    $tag = '（未识别的配置）'
    # 只有"档位 ctx/cpu-gb"对、且其它取值也是推荐值时，才敢叫"推荐配置"
    $std = ($bud -eq '32768' -and $gen -eq '8192' -and $med -eq 'retrieval')
    $suffix = ''
    if (-not $std) { $suffix = '   [注意] 推荐取值是 budget=32768 / gen-reserve=8192 / method=retrieval，当前与此不符' }
    if ($ctx -eq '131072' -and $cpu -eq '4') { $tag = '＝ 日常推荐配置' }
    if ($ctx -eq '262144' -and $cpu -eq '6') { $tag = '＝ 长上下文配置' }
    Write-Host ''
    Write-Host ("  PID {0}  {1}" -f $p.Id, $tag)
    Write-Host ("    ctx={0}  cpu-gb={1}  gen-reserve={2}  budget={3}  method={4}{5}" -f $ctx, $cpu, $gen, $bud, $med, $suffix)
  }
}

# 3) 显存 / 内存
try { Write-Host ("  显存     ：" + (& nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader)) } catch { }
$os = Get-CimInstance Win32_OperatingSystem
Write-Host ("  内存     ：可用 " + [math]::Round($os.FreePhysicalMemory / 1MB, 2) + " GB / 共 " + [math]::Round($os.TotalVisibleMemorySize / 1MB, 2) + " GB")

# 4) 接口与真推理
if ($listen) {
  $code = ''
  try { $code = (Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/v1/models") -UseBasicParsing -TimeoutSec 5).StatusCode } catch { $code = 'ERR' }
  Write-Host ("  接口     ：/v1/models → " + $code)
  if (-not $NoTest -and "$code" -eq '200') {
    try {
      $body = '{"model":"local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":8}'
      $r = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/v1/chat/completions") -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 180
      Write-Host ("  真推理   ：返回 '" + $r.choices[0].message.content + "'，prefill " + [math]::Round($r.timings.prompt_per_second, 1) + " t/s，decode " + [math]::Round($r.timings.predicted_per_second, 1) + " t/s")
    } catch {
      Write-Host ("  真推理   ：失败 —— " + $_.Exception.Message) -ForegroundColor Yellow
    }
  }
} else {
  Write-Host '  接口     ：（没在跑，跳过）'
}

Write-Host ''
Write-Host '  提示：聊天用 launchers\聊天.html；停机双击「一键停机-*.cmd」。'
Write-Host '  本窗口 20 秒后自动关闭。' -ForegroundColor DarkGray
Start-Sleep -Seconds 20
