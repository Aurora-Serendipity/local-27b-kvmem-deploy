<#
一键启动 · 本地模型（Ternary-Bonsai-2-27B · llama-KVMem · 第3包）

由同目录的 .cmd 调用（双击即可），也可以直接：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\start-engine.ps1 -Profile daily
    powershell -NoProfile -ExecutionPolicy Bypass -File .\start-engine.ps1 -Profile longctx

它做四件事：① 检查是否已经有引擎在跑（本机允许同端口重复绑定，必须自己拦）
② 按档位设好环境变量（只影响本次启动的进程，不动系统）③ 在新窗口启动引擎
④ 轮询直到 200，并告诉你"已就绪"以及怎么停。

本文件是 UTF-8 带 BOM（PowerShell 5.1 才不会把中文读成乱码）。
#>
[CmdletBinding()]
param(
  [ValidateSet('daily', 'longctx')][string]$Profile = 'daily',
  [int]$Port = 18200,
  [int]$ReadyTimeoutSec = 180,
  # 交付包位置。留空＝按默认约定推导（launchers\ 与 pkg3-lowvram-llama-kvmem\ 同父目录）。
  # 目录结构不同时显式传：-PkgPath 'D:\somewhere\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem'
  [string]$PkgPath = ''
)
$ErrorActionPreference = 'Continue'

# ---------- 找到交付包 ----------
if ($PkgPath) { $Pkg = $PkgPath }
else { $Pkg = Join-Path (Split-Path -Parent $PSScriptRoot) 'pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem' }
$Launcher = Join-Path $Pkg 'start-retrieval.bat'

function Title([string]$t) { Write-Host ''; Write-Host ('=' * 66); Write-Host ("  " + $t); Write-Host ('=' * 66) }
function Line([string]$k, [string]$v) { Write-Host ("  {0,-14}{1}" -f $k, $v) }

$cfg = @{
  daily   = @{ Name = '日常推荐配置';  CpuGb = '4'; Ctx = '131072'; Gen = '8192'; Budget = '32768'; Ratio = '0.25'
               Vram = '≈6.4 GB';  Host = '≈11 GB';   Note = '材料 ≤130k token 时的首选：省内存、速度同长上下文档' }
  longctx = @{ Name = '长上下文配置'; CpuGb = '6'; Ctx = '262144'; Gen = '8192'; Budget = '32768'; Ratio = '0.25'
               Vram = '≈6.8 GB';  Host = '≈13 GB 起，把 25 万 token 灌满时约 19 GB'; Note = '要一次读入 ≥130k token 的大材料时用' }
}
$c = $cfg[$Profile]

Title ("启动本地模型 · " + $c.Name)

if (-not (Test-Path -LiteralPath $Launcher)) {
  Write-Host '  [错误] 找不到交付包：' -ForegroundColor Red
  Write-Host ("         " + $Launcher)
  Write-Host '  说明：本脚本假定 launchers\ 与 pkg3-lowvram-llama-kvmem\ 在同一个父目录下。'
  Write-Host '        如果你挪动了其中任何一个，请把 launchers\ 和交付包放回同一父目录，或改本脚本顶部的 $Pkg 那一行。'
  Read-Host '  按回车退出'
  exit 2
}

# ---------- 已经在跑吗？（本机实测：同端口可重复绑定，所以必须自己拦） ----------
$already = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($already) {
  Write-Host '  [注意] 已经有引擎在监听 ' -NoNewline -ForegroundColor Yellow
  Write-Host ("http://127.0.0.1:$Port") -ForegroundColor Yellow
  $running = Get-CimInstance Win32_Process -Filter "Name='llama-kvmem-server.exe'" -ErrorAction SilentlyContinue
  foreach ($r in $running) {
    $cl = ($r.CommandLine -replace '.*llama-kvmem-server.exe"', '') -replace '\s+', ' '
    Write-Host ("         当前配置：" + $cl.Trim())
  }
  Write-Host ''
  Write-Host '  不要重复启动（本机允许同端口重复绑定，两台一起跑会让请求落到哪台变得不确定）。'
  Write-Host '  想换配置：先双击「一键停机」脚本，再启动新配置。'
  Read-Host '  按回车退出'
  exit 3
}

# ---------- 内存体检（长上下文档尤其要看） ----------
$os = Get-CimInstance Win32_OperatingSystem
$freeGb = [math]::Round($os.FreePhysicalMemory / 1MB, 2)
Write-Host ''
Line '交付包' $Pkg
Line '配置' ("cpu-gb {0} / ctx {1} / gen {2} / budget {3} / gpu-ratio {4}" -f $c.CpuGb, $c.Ctx, $c.Gen, $c.Budget, $c.Ratio)
Line '预计占用' ("显存 " + $c.Vram + "；内存 " + $c.Host)
Line '可用内存' ($freeGb.ToString() + ' GB（启动前）')
Line '说明' $c.Note
if ($Profile -eq 'longctx' -and $freeGb -lt 10) {
  Write-Host '  [警告] 可用内存不足 10 GB：长上下文档在灌满 25 万 token 时会用到 ~19 GB。' -ForegroundColor Yellow
  Write-Host '         建议先关掉吃内存的程序，或改用「日常推荐配置」。' -ForegroundColor Yellow
}

# ---------- 设环境变量（只作用于本进程及其子进程） ----------
foreach ($k in @('KVMEM_CPU_GB','KV_CTX','KVMEM_GEN','KVMEM_BUDGET','KVMEM_GPU_R','KVMEM_TRACE','NINFER_AGENT')) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
$env:KVMEM_CPU_GB = $c.CpuGb
$env:KV_CTX       = $c.Ctx
$env:KVMEM_GEN    = $c.Gen
$env:KVMEM_BUDGET = $c.Budget
$env:KVMEM_GPU_R  = $c.Ratio
# 让启动件结尾不 pause：引擎退出时窗口自动关闭，而不是停在"请按任意键继续"。
# 安全性：NINFER_AGENT 在引擎二进制里 0 命中（只有启动件的 `if not defined ... pause` 用它），
# 所以它不改变引擎任何行为。
$env:NINFER_AGENT = '1'

# ---------- 在新窗口启动引擎 ----------
Write-Host ''
Write-Host '  正在启动引擎（新开一个窗口，那个窗口就是引擎本体，别关）…'
$inner = 'title Bonsai-27B engine [' + $Profile + '] && "' + $Launcher + '"'
$engine = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', $inner) -WorkingDirectory $Pkg -PassThru

# ---------- 等就绪 ----------
$t0 = Get-Date
$ready = $false
while (((Get-Date) - $t0).TotalSeconds -lt $ReadyTimeoutSec) {
  if ($engine.HasExited) { break }
  try {
    $r = Invoke-WebRequest -Uri ("http://127.0.0.1:$Port/v1/models") -UseBasicParsing -TimeoutSec 3
    if ($r.StatusCode -eq 200) { $ready = $true; break }
  } catch { }
  Start-Sleep -Milliseconds 300
}
$secs = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)

Write-Host ''
if ($ready) {
  Write-Host ("  [就绪] HTTP 200，用时 " + $secs + " 秒") -ForegroundColor Green
  # 顺手做一次真推理，确认不是"只开了个壳"
  try {
    $body = '{"model":"local","messages":[{"role":"user","content":"Reply with exactly: OK"}],"max_tokens":8}'
    $resp = Invoke-RestMethod -Uri ("http://127.0.0.1:$Port/v1/chat/completions") -Method Post `
              -ContentType 'application/json' -Body $body -TimeoutSec 120
    Write-Host ("  [自检] 真推理返回：" + $resp.choices[0].message.content + "  (decode " + [math]::Round($resp.timings.predicted_per_second, 1) + " t/s)") -ForegroundColor Green
  } catch {
    Write-Host ("  [自检] 真推理失败：" + $_.Exception.Message) -ForegroundColor Yellow
  }
  Write-Host ''
  Line '接口' ("http://127.0.0.1:$Port/v1   （模型名用 local；不需要 API key）")
  Line '聊天页' '双击 launchers\聊天.html（本包没带网页 UI，引擎地址本身打开是 404，属正常）'
  Line '状态' '双击 状态检查.cmd'
  Line '停机' '双击「一键停机」脚本，或关掉那个引擎窗口'
  Write-Host ''
  Write-Host '  本窗口 12 秒后自动关闭。' -ForegroundColor DarkGray
  Start-Sleep -Seconds 12
  exit 0
} else {
  Write-Host '  [失败] 在超时时间内没有等到 HTTP 200。' -ForegroundColor Red
  if ($engine.HasExited) { Write-Host ('         引擎进程已退出，退出码 ' + $engine.ExitCode + '。') -ForegroundColor Red }
  Write-Host '  请看引擎窗口最后几行（那里有原始报错），或查手册「故障排查」一节。'
  Write-Host '  常见原因：端口被别的程序占用 / 内存不够 / 交付包路径被移动。'
  Read-Host '  按回车退出'
  exit 4
}
