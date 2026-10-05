# 部署自检：验证 launchers 工具层在你自己的机器上是否工作正常
#
# 用法（在本仓库根目录下）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\selfcheck-launchers.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\selfcheck-launchers.ps1 -PkgPath "D:\somewhere\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem"
#
# 它做 9 项检查：两档启动/就绪/参数、重复启动拦截、状态检查、停机、显式 -PkgPath、
# 错误路径拒绝。每项输出 PASS/FAIL，最后写一份 JSON 到 -OutDir。
# 注意：它会**真实启停引擎**（每次几秒），请勿与其他引擎同时跑。
[CmdletBinding()]
param(
  [string]$Launchers = '',
  [string]$PkgPath = '',
  [string]$OutDir = '',
  [int]$Port = 18200
)
$ErrorActionPreference = 'Continue'
if (-not $Launchers) { $Launchers = Join-Path (Split-Path -Parent $PSScriptRoot) 'launchers' }
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'evidence' }
if (-not (Test-Path $Launchers)) { Write-Host ("[错误] 找不到 launchers 目录：" + $Launchers) -ForegroundColor Red; exit 2 }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$res = New-Object System.Collections.Generic.List[object]

function Rec([string]$n, [bool]$p, [string]$d) {
  $res.Add([pscustomobject]@{ test = $n; pass = $p; detail = $d })
  $c = 'Green'; if (-not $p) { $c = 'Red' }
  $t = 'PASS'; if (-not $p) { $t = 'FAIL' }
  Write-Host ("  [{0}] {1}  {2}" -f $t, $n, $d) -ForegroundColor $c
}
function Props { try { return (curl.exe -s ("http://127.0.0.1:$Port/props") | ConvertFrom-Json) } catch { return $null } }
function Listening { return [bool]@(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue).Count }
function NCtx($p) { if ($p) { return $p.default_generation_settings.n_ctx } else { return 'null' } }
# 用拼接 + 单引号构造 cmd 命令行：避免在双引号字符串里写 < NUL（PowerShell 会把它当保留运算符）
function RunCmd([string]$cmdName) {
  $line = '"' + (Join-Path $Launchers $cmdName) + '" < NUL'
  return ((cmd.exe /c $line 2>&1) -join "`n")
}
function StopAll { RunCmd '一键停机-日常推荐.cmd' | Out-Null; Start-Sleep -Seconds 1 }

Write-Host "=== 部署自检（launchers: $Launchers）==="
StopAll

# 默认布局（launchers 与交付包同父目录）是否存在？不存在就跳过依赖它的 1-5 组，
# 而不是误报 FAIL —— 用 -PkgPath 指定包位置是完全合法的用法。
$defaultPkg = Join-Path (Split-Path -Parent $Launchers) 'pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem'
$hasDefault = Test-Path (Join-Path $defaultPkg 'start-retrieval.bat')

if ($hasDefault) {
Write-Host '--- 1) 日常档：默认路径启动 ---'
$o = RunCmd '一键启动-日常推荐.cmd'
$p = Props
Rec '1.1 启动就绪 + 真推理自检' ([bool](($o -match '\[就绪\] HTTP 200') -and ($o -match '真推理返回：OK'))) '见输出'
Rec '1.2 /props n_ctx = 131072' ($p -and $p.default_generation_settings.n_ctx -eq 131072) ("n_ctx=" + (NCtx $p))
Rec '1.3 generation_limit = 8192' ($p -and $p.kvmem.generation_limit -eq 8192) ("gen=" + $(if ($p) { $p.kvmem.generation_limit } else { 'null' }))

Write-Host '--- 2) 重复启动应被拦下（退出码 3）---'
RunCmd '一键启动-日常推荐.cmd' | Out-Null
Rec '2.1 第二次启动被拦（exit=3）' ($LASTEXITCODE -eq 3) ("exit=" + $LASTEXITCODE)

Write-Host '--- 3) 状态检查应识别档位 ---'
$s = RunCmd '状态检查.cmd'
Rec '3.1 识别为日常推荐配置' ([bool]($s -match '日常推荐配置')) '见输出'

Write-Host '--- 4) 停机应释放资源 ---'
RunCmd '一键停机-日常推荐.cmd' | Out-Null
Rec '4.1 端口释放且无残留进程' (-not (Listening)) ("监听=" + (Listening))

Write-Host '--- 5) 长上下文档 ---'
$o2 = RunCmd '一键启动-长上下文.cmd'
$p2 = Props
Rec '5.1 启动就绪' ([bool]($o2 -match '\[就绪\] HTTP 200')) '见输出'
Rec '5.2 /props n_ctx = 262144' ($p2 -and $p2.default_generation_settings.n_ctx -eq 262144) ("n_ctx=" + (NCtx $p2))
$cl = (Get-CimInstance Win32_Process -Filter "Name='llama-kvmem-server.exe'" -ErrorAction SilentlyContinue).CommandLine
Rec '5.3 host 池 = cpu-gb 6' ([bool]($cl -match '--kvmem-cpu-gb 6')) 'cpu-gb=6'
StopAll
} else {
  Write-Host '--- 1~5) 跳过：默认布局下找不到交付包 ---' -ForegroundColor Yellow
  Write-Host ("     默认会去找：" + $defaultPkg) -ForegroundColor DarkGray
  Write-Host '     这在使用 -PkgPath 指定包位置时是正常的；把 launchers\ 与交付包放同一父目录后重跑即可测这 5 组。' -ForegroundColor DarkGray
}

Write-Host '--- 6) 显式 -PkgPath（目录结构不同时用）---'
if ($PkgPath) {
  # 注意：带空格的路径必须整体加引号传参，否则会被拆开（本仓库测试脚本早期就踩过这个坑）
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Profile daily -PkgPath "{1}" -ReadyTimeoutSec 90' -f (Join-Path $Launchers 'start-engine.ps1'), $PkgPath
  $log = Join-Path $OutDir ("selfcheck-pkgpath-$stamp.log")
  $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError "$log.err"
  $proc.WaitForExit(150000) | Out-Null
  Start-Sleep -Seconds 2
  $lg = Get-Content $log -Raw -ErrorAction SilentlyContinue
  $p3 = Props
  Rec '6.1 -PkgPath 启动就绪' ([bool]($lg -match '\[就绪\] HTTP 200')) '见日志'
  Rec '6.2 起的是该路径的包（n_ctx=131072）' ($p3 -and $p3.default_generation_settings.n_ctx -eq 131072) ("n_ctx=" + (NCtx $p3))
  StopAll
} else {
  Write-Host '  （未提供 -PkgPath，跳过第 6 组）'
}

Write-Host '--- 7) 错误的 -PkgPath 应被拒绝 ---'
$inner = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $Launchers 'start-engine.ps1') + '" -Profile daily -PkgPath "' + (Join-Path $OutDir '__no_such_pkg__') + '" < NUL'
$w = ((cmd.exe /c $inner) 2>&1) -join "`n"
Rec '7.1 报"找不到交付包"且不启动' ([bool](($w -match '找不到交付包') -and (-not (Listening)))) '见输出'

Write-Host ''
$passN = @($res | Where-Object { $_.pass }).Count
$col = 'Green'; if ($passN -ne $res.Count) { $col = 'Red' }
Write-Host ("================ 通过 {0} / {1} ================" -f $passN, $res.Count) -ForegroundColor $col
$res | Where-Object { -not $_.pass } | ForEach-Object { Write-Host ("  [未通过] " + $_.test) -ForegroundColor Red }
$json = Join-Path $OutDir "selfcheck-launchers-$stamp.json"
[IO.File]::WriteAllText($json, ($res | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
Write-Host ("  JSON: " + $json)
if ($passN -ne $res.Count) { exit 1 }
