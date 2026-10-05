<#
一键停机 · 本地模型（llama-KVMem）

做法：先按端口反查（文档规定的姿势），再按**exe 精确路径**兜底清理孤儿进程
（不按进程名乱杀，避免误伤别人的引擎）。杀完会验证端口释放、显存回落。

用法（双击同目录的「一键停机」.cmd 即可）：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\stop-engine.ps1
本文件是 UTF-8 带 BOM。
#>
[CmdletBinding()]
param([int]$Port = 18200, [string]$PkgPath = '')
$ErrorActionPreference = 'Continue'

if ($PkgPath) { $Pkg = $PkgPath }
else { $Pkg = Join-Path (Split-Path -Parent $PSScriptRoot) 'pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem' }
$ExePath = Join-Path $Pkg 'engine\llama-kvmem-server.exe'

function Title([string]$t) { Write-Host ''; Write-Host ('=' * 66); Write-Host ("  " + $t); Write-Host ('=' * 66) }
function VramNow { try { return (& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | Select-Object -First 1).ToString() + ' MiB' } catch { return '(nvidia-smi 不可用)' } }
function FreeRamGb { return [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2) }

Title '停机 · 本地模型'

$listen = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
$killed = @()

foreach ($conn in $listen) {
  $procId = $conn.OwningProcess
  if ($killed -contains $procId) { continue }
  $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
  if ($p) {
    Write-Host ("  停止 PID {0}  ({1})  监听端口 {2}" -f $procId, $p.ProcessName, $Port)
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    $killed += $procId
  }
}

# 兜底：按精确 exe 路径清理"引擎还在但端口已不监听"的孤儿（文档提到这种最常见）
$orphans = @(Get-Process -Name 'llama-kvmem-server' -ErrorAction SilentlyContinue |
             Where-Object { $_.Path -and ($_.Path -eq $ExePath) -and ($killed -notcontains $_.Id) })
foreach ($o in $orphans) {
  Write-Host ("  清理孤儿进程 PID {0}（端口已释放但进程还在占显存）" -f $o.Id)
  Stop-Process -Id $o.Id -Force -ErrorAction SilentlyContinue
  $killed += $o.Id
}

# 顺手关掉"承载启动件的窗口壳"：引擎死后它们只会停在"请按任意键继续"，留着碍事。
# 只匹配本交付包的两个启动件，不碰别的 cmd 窗口。
$shells = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and ($_.CommandLine -like '*start-retrieval.bat*' -or $_.CommandLine -like '*start-lowvram.bat*') })
foreach ($sh in $shells) {
  Write-Host ("  关闭引擎窗口壳 PID {0}" -f $sh.ProcessId)
  Stop-Process -Id $sh.ProcessId -Force -ErrorAction SilentlyContinue
}

if ($killed.Count -eq 0) {
  Write-Host '  [信息] 没有在跑的引擎（端口没有监听，也没有残留进程）。'
} else {
  # 等端口真正释放
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt 20) {
    if (-not (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 500
  }
  Write-Host ''
  $still = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
  if ($still) {
    Write-Host ("  [警告] 端口 {0} 仍在监听，请到任务管理器确认。" -f $Port) -ForegroundColor Yellow
  } else {
    Write-Host ("  [完成] 端口 {0} 已释放。" -f $Port) -ForegroundColor Green
  }
}

Write-Host ''
Write-Host ("  显存占用 ：" + (VramNow))
Write-Host ("  可用内存 ：" + (FreeRamGb) + " GB")
Write-Host ("  残留进程 ：" + (@(Get-Process -Name 'llama-kvmem-server' -ErrorAction SilentlyContinue).Count) + " 个")
Write-Host ''
Write-Host '  本窗口 8 秒后自动关闭。' -ForegroundColor DarkGray
Start-Sleep -Seconds 8
