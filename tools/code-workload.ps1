<#
code-workload.ps1 -- measure the user's actual use case at the recommended work point:
  A) code question, DEFAULT settings (thinking state as shipped)
  B) same question with request-level enable_thinking=true  -> proves the thinking lever/cost
  C) long CODE material (~25k tokens) with a needle planted at 50% depth -> the
     "长材料问答" case for programming work

Read-only w.r.t. the package; writes only under -OutDir.
#>
[CmdletBinding()]
param(
  [int]$Port = 18200,
  [string]$OutDir = 'D:\Local Model\_runs\logs',
  [string]$Tag = 'code'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "code-$Tag-$stamp.log"
$json = Join-Path $OutDir "code-$Tag-$stamp.json"
function Say([string]$m) { $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content -Path $log -Value $l -Encoding UTF8 }

function Ask([string]$name, [string]$prompt, [int]$maxTokens, $extra) {
  $payload = @{ model = 'local'; messages = @(@{ role = 'user'; content = $prompt }); max_tokens = $maxTokens; temperature = 0 }
  if ($extra) { foreach ($k in $extra.Keys) { $payload[$k] = $extra[$k] } }
  $body = $payload | ConvertTo-Json -Depth 8
  $t0 = Get-Date
  try { $r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 3600 }
  catch { Say ("$name ERROR: " + $_.Exception.Message); return $null }
  $wall = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
  $msg = $r.choices[0].message
  $reasoning = [string]$msg.reasoning_content
  $content = [string]$msg.content
  Say ''
  Say ("=== $name ===")
  Say ("prompt_tokens={0}  out_tokens={1}  finish={2}  cache_hit={3}" -f $r.usage.prompt_tokens, $r.usage.completion_tokens, $r.choices[0].finish_reason, $r.usage.prompt_cache_hit_tokens)
  Say ("prefill={0:N2} t/s  decode={1:N2} t/s  wall={2}s" -f $r.timings.prompt_per_second, $r.timings.predicted_per_second, $wall)
  Say ("reasoning_content present: {0}  (chars={1})" -f [bool]$reasoning, $reasoning.Length)
  if ($reasoning) { Say ("reasoning head: " + $reasoning.Substring(0, [Math]::Min(160, $reasoning.Length)).Replace("`n", ' ')) }
  Say ("answer head: " + $content.Substring(0, [Math]::Min(240, $content.Length)).Replace("`n", ' '))
  return [pscustomobject]@{
    name = $name; prompt_tokens = [int]$r.usage.prompt_tokens; out_tokens = [int]$r.usage.completion_tokens
    finish = [string]$r.choices[0].finish_reason; prefill_tps = [double]$r.timings.prompt_per_second
    decode_tps = [double]$r.timings.predicted_per_second; wall_s = $wall
    has_reasoning = [bool]$reasoning; reasoning_chars = $reasoning.Length
    content = $content; reasoning = $reasoning
  }
}

Say '============================================================'
Say ' code workload @ recommended work point'
Say '============================================================'

# ---- A: code question, default (shipped) settings ----
$qA = "Write a Python function merge_intervals(intervals) that merges overlapping intervals. Include a docstring and 3 unit tests. Output only code."
$a = Ask 'A-code-default' $qA 700 $null

# ---- B: same question, thinking explicitly ON (request-level override) ----
$b = Ask 'B-code-thinking-on' $qA 700 @{ chat_template_kwargs = @{ enable_thinking = $true } }

# ---- C: long CODE material + mid-document needle (long-material Q&A for code) ----
$code = 'KIWI-4821-QX'
$lines = New-Object System.Collections.Generic.List[string]
$total = 2400
for ($i = 1; $i -le $total; $i++) {
  if ($i -eq [int]($total / 2)) {
    $lines.Add("def get_api_key_vault7():")
    $lines.Add("    return `"$code`"")
  }
  $lines.Add("def helper_$i(x):")
  $lines.Add("    return x * $i + 7")
}
$material = ($lines -join "`n")
$qC = @"
Below is a source file. Read it, then answer the question at the end.

$material

Question: What exact string does get_api_key_vault7() return? Answer with just that string.
"@
$c = Ask 'C-long-code-needle' $qC 64 $null
if ($c) { Say ("needle found in answer: " + $c.content.Contains($code)) }

[IO.File]::WriteAllText($json, ([ordered]@{ tag = $tag; stamp = $stamp; a = $a; b = $b; c = $c } | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Say ("JSON: " + $json)
