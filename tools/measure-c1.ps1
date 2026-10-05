<#
measure-c1.ps1 -- C1 measurement harness for tier-1 (llama-KVMem).
Protocol (must-do.json C1): long prompt (>=1k tokens) + long output (>=400) + greedy +
discard the first run + median of the remaining 3. prefill/decode are read from the
ENGINE's own timings (timings.prompt_per_second / timings.predicted_per_second), never
from client-side wall clock.

A unique nonce is prepended to every prompt so the server's prefix cache cannot inflate
prompt_per_second (we assert usage.prompt_cache_hit_tokens == 0).

Read-only w.r.t. the package: talks HTTP to the running server, writes only under -OutDir.
#>
[CmdletBinding()]
param(
  [int]$Port = 18200,
  [int]$Rounds = 4,
  [int]$Warmup = 1,
  [int]$OutTokens = 500,
  [int]$PromptWords = 900,
  [string]$OutDir = "D:\Local Model\_runs\logs",
  [string]$Tag = "default"
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath = Join-Path $OutDir "c1-$Tag-$Stamp.log"
$JsonPath = Join-Path $OutDir "c1-$Tag-$Stamp.json"

function Say([string]$m) {
  $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
  Write-Host $line
  Add-Content -Path $LogPath -Value $line -Encoding UTF8
}
function Median($xs) {
  $a = @($xs | Sort-Object)
  if ($a.Count -eq 0) { return $null }
  if ($a.Count % 2) { return [double]$a[[int](($a.Count - 1) / 2)] }
  return ([double]$a[$a.Count / 2 - 1] + [double]$a[$a.Count / 2]) / 2.0
}
function Get-VramMiB {
  try { return [int]((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | Select-Object -First 1)) }
  catch { return -1 }
}

$words = 1..$PromptWords | ForEach-Object { "topic$_" }
$basePrompt = ("Summarise the following numbered list of identifiers in continuous prose, then " +
               "write a long factual article about ternary weight quantisation. Do not stop early.`n" +
               ($words -join ' '))

Say '============================================================'
Say (' C1 measurement -- long prompt + long output + greedy + drop first + median')
Say '============================================================'
Say ("port=$Port rounds=$Rounds warmup=$Warmup promptWords=$PromptWords maxTokens=$OutTokens tag=$Tag")
Say ("vram before = " + (Get-VramMiB) + " MiB")
Say ''

$rows = @()
for ($r = 1; $r -le $Rounds; $r++) {
  $nonce = "r$r-$Tag-$Stamp"
  $prompt = "Run $nonce.`n$basePrompt"
  $body = @{
    model       = 'local'
    messages    = @(@{ role = 'user'; content = $prompt })
    max_tokens  = $OutTokens
    temperature = 0
  } | ConvertTo-Json -Depth 8
  $t0 = Get-Date
  try {
    $resp = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
             -ContentType 'application/json' -Body $body -TimeoutSec 3600
  } catch {
    Say ("round $r ERROR: " + $_.Exception.Message)
    continue
  }
  $wall = ((Get-Date) - $t0).TotalSeconds
  $t = $resp.timings
  $u = $resp.usage
  $content = [string]$resp.choices[0].message.content
  $sha = [System.BitConverter]::ToString(
           [System.Security.Cryptography.SHA256]::Create().ComputeHash(
             [System.Text.Encoding]::UTF8.GetBytes($content))).Replace('-', '').Substring(0, 16)
  $row = [pscustomobject]@{
    round          = $r
    drop           = ($r -le $Warmup)
    prompt_tokens  = [int]$u.prompt_tokens
    cache_hit      = [int]$u.prompt_cache_hit_tokens
    out_tokens     = [int]$u.completion_tokens
    prefill_tps    = [double]$t.prompt_per_second
    decode_tps     = [double]$t.predicted_per_second
    prompt_ms      = [double]$t.prompt_ms
    predicted_ms   = [double]$t.predicted_ms
    wall_s         = [math]::Round($wall, 2)
    finish         = [string]$resp.choices[0].finish_reason
    sha16          = $sha
    vram_mib       = (Get-VramMiB)
  }
  $rows += $row
  Say ("round {0} {1}  prompt={2}tok (cache_hit={3})  out={4}tok  prefill={5:N2} t/s  decode={6:N2} t/s  wall={7:N1}s  finish={8}  sha={9}" -f `
        $r, $(if ($row.drop) { '(warmup, dropped)' } else { '               ' }), `
        $row.prompt_tokens, $row.cache_hit, $row.out_tokens, $row.prefill_tps, $row.decode_tps, $row.wall_s, $row.finish, $row.sha16)
}

$meas = @($rows | Where-Object { -not $_.drop })
if ($meas.Count -gt 0) {
  $pMed = Median ($meas | ForEach-Object { $_.prefill_tps })
  $dMed = Median ($meas | ForEach-Object { $_.decode_tps })
  $pMin = ($meas | ForEach-Object { $_.prefill_tps } | Measure-Object -Minimum).Minimum
  $pMax = ($meas | ForEach-Object { $_.prefill_tps } | Measure-Object -Maximum).Maximum
  $dMin = ($meas | ForEach-Object { $_.decode_tps } | Measure-Object -Minimum).Minimum
  $dMax = ($meas | ForEach-Object { $_.decode_tps } | Measure-Object -Maximum).Maximum
  Say ''
  Say '=== medians (warmup dropped) ==='
  Say ("prefill : median={0:N2} t/s  (min {1:N2} / max {2:N2})  over rounds {3}" -f $pMed, $pMin, $pMax, (($meas | ForEach-Object { $_.round }) -join ','))
  Say ("decode  : median={0:N2} t/s  (min {1:N2} / max {2:N2})" -f $dMed, $dMin, $dMax)
  Say ("prompt tokens (measured rounds) : " + (($meas | ForEach-Object { $_.prompt_tokens }) -join ','))
  Say ("output tokens (measured rounds) : " + (($meas | ForEach-Object { $_.out_tokens }) -join ','))
  Say ("greedy sha16 per round          : " + (($meas | ForEach-Object { $_.sha16 }) -join ' '))
  Say ("same sha across measured rounds : " + ((@($meas | ForEach-Object { $_.sha16 } | Sort-Object -Unique).Count) -eq 1))
  $payload = [ordered]@{
    tag = $Tag; port = $Port; stamp = $Stamp
    protocol = 'long prompt >=1k tokens; long output >=400 tokens; greedy (temperature 0); first round dropped; median of the rest'
    prompt_words = $PromptWords; max_tokens = $OutTokens
    rounds = $rows
    prefill_median_tps = [math]::Round($pMed, 2)
    decode_median_tps = [math]::Round($dMed, 2)
    content_kind = 'text (chat completion, greedy)'
  }
  [IO.File]::WriteAllText($JsonPath, ($payload | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
  Say ("JSON: " + $JsonPath)
} else {
  Say 'NO MEASURED ROUNDS'
}
Say ("LOG : " + $LogPath)
