<#
full-config-test.ps1 -- final configuration test. PURE ASCII ON PURPOSE: Windows PowerShell 5.1
reads a BOM-less file as ANSI (GBK here), so non-ASCII text can swallow the next quote and break
the parser. (Cost me two runs already.)

  config : KVMEM_CPU_GB=6  KV_CTX=262144  KVMEM_GEN=8192  KVMEM_BUDGET=32768  KVMEM_GPU_R=0.25
           start-retrieval.bat supplies retrieval / ub 128 / b 512 / sink 4096 / kv q4_0
  client : max_tokens = 8192 (generous; engine caps generation at generation_limit=8192)

  T1 (FIRST request, fresh engine) : ~249k-token code material, needle at 50% depth
  T2 : C1 short-prompt speed
  T3 : long answer to the engine ceiling (client max_tokens=8192)
#>
[CmdletBinding()]
param(
  [string]$Pkg = 'D:\Local Model\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem',
  [string]$OutDir = 'D:\Local Model\_runs\logs',
  [string]$CpuGb = '6', [string]$Ctx = '262144', [string]$Gen = '8192', [string]$Budget = '32768', [string]$Ratio = '0.25',
  [int]$PromptLines = 11000,
  [int]$ClientMaxTokens = 8192
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "fullcfg-$stamp.log"
function Say([string]$m) { $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content -Path $log -Value $l -Encoding UTF8 }

$p = (Get-NetTCPConnection -LocalPort 18200 -State Listen -ErrorAction SilentlyContinue).OwningProcess
if ($p) { Stop-Process -Id $p -Force; Start-Sleep -Seconds 5 }
foreach ($k in @('KVMEM_CPU_GB','KV_CTX','KVMEM_GEN','KVMEM_BUDGET','KVMEM_GPU_R','KVMEM_TRACE')) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
$env:KVMEM_CPU_GB=$CpuGb; $env:KV_CTX=$Ctx; $env:KVMEM_GEN=$Gen; $env:KVMEM_BUDGET=$Budget; $env:KVMEM_GPU_R=$Ratio
$l = Join-Path $OutDir "fullcfg-server-$stamp.log"
$proc = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', "`"$Pkg\start-retrieval.bat`"") -WorkingDirectory $Pkg -RedirectStandardOutput $l -RedirectStandardError "$l.err" -PassThru -WindowStyle Hidden
$t0=Get-Date; while(((Get-Date)-$t0).TotalSeconds -lt 120){ if($proc.HasExited){break}; try{$r=Invoke-WebRequest 'http://127.0.0.1:18200/v1/models' -UseBasicParsing -TimeoutSec 3; if($r.StatusCode -eq 200){break}}catch{}; Start-Sleep -Milliseconds 250 }
$pid0=(Get-NetTCPConnection -LocalPort 18200 -State Listen).OwningProcess
Say ("START up={0}s" -f [math]::Round(((Get-Date)-$t0).TotalSeconds,2))
Say ("CMD: " + ((Get-CimInstance Win32_Process -Filter "Name='llama-kvmem-server.exe'").CommandLine -replace '.*llama-kvmem-server.exe"','' -replace '\s+',' '))
(Get-Content "$l.err" | Select-String 'KVMEM_TIERS' | Select-Object -First 1).Line | ForEach-Object { Say ("  " + $_) }
$props = curl.exe -s http://127.0.0.1:18200/props | ConvertFrom-Json
Say ("  props: n_ctx={0} generation_limit={1}" -f $props.default_generation_settings.n_ctx, $props.kvmem.generation_limit)
Say ("  VRAM={0} host_private={1}GB freeRAM={2}GB" -f (nvidia-smi --query-gpu=memory.used --format=csv,noheader), [math]::Round((Get-Process -Id $pid0).PrivateMemorySize64/1GB,2), [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,2))

# ---------------- T1: fill the context ----------------
Say ''
Say ("### T1 long context fill: {0} lines of code material (~249k tokens), needle at 50 percent, FIRST request of the session ###" -f $PromptLines)
$code='KIWI-4821-QX'
$lines = New-Object System.Collections.Generic.List[string]
$needleAt=[int]($PromptLines/2)
for($i=1;$i -le $PromptLines;$i++){
  if($i -eq $needleAt){ $lines.Add("def get_api_key_vault7():"); $lines.Add("    return `"$code`"") }
  $lines.Add("def helper_$i(x):"); $lines.Add("    return x * $i + 7")
}
$material = ($lines -join "`n")
$prompt = "Below is a source file. Read it, then answer the question at the end.`n`n$material`n`nQuestion: What exact string does get_api_key_vault7() return? Answer with just that string."
$b = @{ model='local'; messages=@(@{role='user';content=$prompt}); max_tokens=32; temperature=0 } | ConvertTo-Json -Depth 6
$f = Join-Path $OutDir "_fullcfg_t1.json"; [IO.File]::WriteAllText($f,$b,(New-Object Text.UTF8Encoding($false)))
$t1=Get-Date
$r1 = curl.exe -s -H "Content-Type: application/json" -d "@$f" http://127.0.0.1:18200/v1/chat/completions | ConvertFrom-Json
$ans1=([string]$r1.choices[0].message.content).Trim()
$t1wall=[math]::Round(((Get-Date)-$t1).TotalSeconds,1)
Say ("  prompt_tokens={0}  cache_hit={1}  prefill={2:N2} t/s  wall={3}s" -f $r1.usage.prompt_tokens,$r1.usage.prompt_cache_hit_tokens,$r1.timings.prompt_per_second,$t1wall)
Say ("  answer: " + ($ans1 -replace "`n",' '))
Say ("  needle exact match = " + $ans1.Contains($code))
Say ("  VRAM={0} host_private={1}GB freeRAM={2}GB" -f (nvidia-smi --query-gpu=memory.used --format=csv,noheader), [math]::Round((Get-Process -Id $pid0).PrivateMemorySize64/1GB,2), [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,2))

# ---------------- T2: short-prompt speed ----------------
Say ''
Say '### T2 short-prompt speed (C1) ###'
& powershell -NoProfile -ExecutionPolicy Bypass -File 'D:\Local Model\_runs\measure-c1.ps1' -Port 18200 -Rounds 4 -Warmup 1 -OutTokens 500 -PromptWords 900 -Tag fullcfg | Select-String 'prefill : median|decode  : median' | ForEach-Object { Say ("  " + $_.Line) }

# ---------------- T3: long answer to the ceiling ----------------
Say ''
Say ("### T3 long answer: client max_tokens={0} (engine ceiling {1}) ###" -f $ClientMaxTokens,$Gen)
$prompt3 = "Write a complete Python module called toolkit.py containing exactly 200 small, self-contained functions numbered 1 through 200. Each function must have a one-line docstring and its own unit test. Do not stop early, do not summarise, and do not end the module until all 200 functions are written."
$b3 = @{ model='local'; messages=@(@{role='user';content=$prompt3}); max_tokens=$ClientMaxTokens; temperature=0 } | ConvertTo-Json -Depth 6
$f3 = Join-Path $OutDir "_fullcfg_t3.json"; [IO.File]::WriteAllText($f3,$b3,(New-Object Text.UTF8Encoding($false)))
$t3=Get-Date
$r3 = curl.exe -s -H "Content-Type: application/json" -d "@$f3" http://127.0.0.1:18200/v1/chat/completions | ConvertFrom-Json
$out3=[int]$r3.usage.completion_tokens
Say ("  out_tokens={0}  finish={1}  decode={2:N2} t/s  wall={3}s" -f $out3,$r3.choices[0].finish_reason,$r3.timings.predicted_per_second,[math]::Round(((Get-Date)-$t3).TotalSeconds,1))
if($out3 -ge 8192){ Say "  RESULT: hit 8192 = gen-reserve (engine ceiling), still truncated by the cap" }
else { Say ("  RESULT: model finished on its own at {0} tokens (finish={1}); the 8192 ceiling was not reached. Raise KVMEM_GEN for longer outputs." -f $out3,$r3.choices[0].finish_reason) }

[IO.File]::WriteAllText((Join-Path $OutDir "fullcfg-$stamp.json"), ([ordered]@{
  cpu_gb=$CpuGb; ctx=$Ctx; gen=$Gen; budget=$Budget; ratio=$Ratio; client_max_tokens=$ClientMaxTokens
  t1_prompt_tokens=[int]$r1.usage.prompt_tokens; t1_prefill=[double]$r1.timings.prompt_per_second; t1_wall_s=$t1wall; t1_needle=$ans1.Contains($code); t1_answer=$ans1
  t3_out_tokens=$out3; t3_finish=[string]$r3.choices[0].finish_reason; t3_decode=[double]$r3.timings.predicted_per_second
} | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))
$p=(Get-NetTCPConnection -LocalPort 18200 -State Listen -ErrorAction SilentlyContinue).OwningProcess; if($p){Stop-Process -Id $p -Force}
Start-Sleep -Seconds 5
Say ("AFTER STOP: VRAM={0} procs={1} freeRAM={2}GB" -f (nvidia-smi --query-gpu=memory.used --format=csv,noheader), (Get-Process -Name llama-kvmem-server -ErrorAction SilentlyContinue|Measure-Object).Count, [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory/1MB,2))
Say ("log: " + $log)
