<#
profile-needle.ps1 -- depth profile (mini version of the docs' "17-needle profile"): one long
material per configuration, with a distinct needle planted at each requested depth.

Why this shape: docs\复现手册-排错篇.md warns the 3-needle fixture is a BROKEN INSTRUMENT
because two of its three needles sit in always-retained bands. So this fixture keeps only the
bands that discriminate: one control inside the sink band (first --kvmem-sink-tokens), one
control in the recent band, and the rest spread over the middle, which can only be answered if
the host tier + block selection actually work.

Scoring: which planted codes appear verbatim in the reply.

Read-only w.r.t. the package; writes only under -OutDir.
#>
[CmdletBinding()]
param(
  [int]$Port = 18200,
  [int]$TargetTokens = 24000,
  [double]$WordsPerToken = 0.2533,
  [string]$Depths = '0.05,0.25,0.40,0.55,0.70,0.85,0.98',
  # 默认 400：17 针要一口气列出 17 个编号，实测需要 ~277 输出 token。
  # 用 160 会把列表截断、把"没输出"误判成"没检索到"（2026-10-05 踩过：160 → 假 10/17，400 → 真 17/17）。
  [int]$MaxTokens = 400,
  [string]$OutDir = 'D:\Local Model\_runs\logs',
  [string]$Tag = 'profile'
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$log = Join-Path $OutDir "profile-$Tag-$stamp.log"
$json = Join-Path $OutDir "profile-$Tag-$stamp.json"
function Say([string]$m) { $l = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content -Path $log -Value $l -Encoding UTF8 }

$depthList = @($Depths -split ',' | ForEach-Object { [double]$_.Trim() })
$words = [int]($TargetTokens * $WordsPerToken)

# build filler word list, plant one needle per depth
$needles = @()
for ($i = 0; $i -lt $depthList.Count; $i++) {
  $suffix = [string]([char](65 + ($i % 26))) + [string]([char](65 + [int][math]::Floor($i / 26)))
  $code = 'ZULU-{0}{1}-{2}' -f (($i + 1) * 1101), ($i + 1), $suffix
  $needles += [pscustomobject]@{ idx = ($i + 1); depth = $depthList[$i]; wordPos = [int]($words * $depthList[$i]); code = $code }
}
$lines = New-Object System.Collections.Generic.List[string]
for ($w = 1; $w -le $words; $w++) {
  foreach ($n in $needles) { if ($n.wordPos -eq $w) { $lines.Add("VAULT RECORD A$($n.idx): the access code is $($n.code).") } }
  $lines.Add("topic$w")
}
# make sure every needle actually landed (wordPos beyond range would silently drop it)
$body = ($lines -join ' ')
foreach ($n in $needles) { if (-not $body.Contains($n.code)) { Say ("WARN needle A$($n.idx) was not inserted") } }

$prompt = @"
Run $Tag-$stamp.
Read the long record below. It contains several numbered vault records.
$body
Question: List the access code of EVERY vault record mentioned above, one per line, exactly in the form A1=<code>. Do not invent codes.
"@

Say '============================================================'
Say " depth profile: $($depthList -join ', ')   (target ~$TargetTokens tokens)"
Say '============================================================'
Say ("vram before = " + (& nvidia-smi --query-gpu=memory.used --format=csv,noheader))
$payload = @{ model = 'local'; messages = @(@{ role = 'user'; content = $prompt })
              max_tokens = $MaxTokens; temperature = 0 } | ConvertTo-Json -Depth 8
$t0 = Get-Date
$r = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/v1/chat/completions" -Method Post `
       -ContentType 'application/json' -Body $payload -TimeoutSec 3600
$wall = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2)
$ans = ([string]$r.choices[0].message.content).Trim()
$cacheN = [int]$r.usage.prompt_cache_hit_tokens
$found = @(); $missed = @()
foreach ($n in $needles) {
  if ($ans.Contains($n.code)) { $found += ("A$($n.idx)@$([math]::Round($n.depth*100))%") } else { $missed += ("A$($n.idx)@$([math]::Round($n.depth*100))%") }
}
Say ''
Say ("prompt_tokens : " + $r.usage.prompt_tokens + "  (prefix-cache hit: $cacheN  -- 0 means a real full prefill)")
Say ("out_tokens    : " + $r.usage.completion_tokens + "  finish=" + $r.choices[0].finish_reason)
Say ("prefill       : {0:N2} t/s  ({1:N0} ms)" -f $r.timings.prompt_per_second, $r.timings.prompt_ms)
Say ("decode        : {0:N2} t/s   wall={1} s" -f $r.timings.predicted_per_second, $wall)
Say ''
Say ("retrieved : " + $(if ($found.Count) { $found -join ' ' } else { '(none)' }) + "   -> $($found.Count)/$($needles.Count)")
Say ("missed    : " + $(if ($missed.Count) { $missed -join ' ' } else { '(none)' }))
# 关键守卫：列 17 条针需要 ~280 输出 token。若输出刚好撞到 -MaxTokens，
# 后面的针"缺失"其实是**被截断**，不是检索失败 —— 必须显式报出来，否则会得出假低分。
# （2026-10-05 实测教训：用默认 160 跑出 10/17，把 MaxTokens 提到 400 后是 17/17。）
if ([int]$r.usage.completion_tokens -ge $MaxTokens) {
  Say ''
  Say ("!! 结论无效：out_tokens=" + $r.usage.completion_tokens + " 撞到 -MaxTokens=" + $MaxTokens + "，列表被截断，") -ForegroundColor Yellow
  Say ("!! 后面的针不是没检索到，而是没来得及输出。请加大 -MaxTokens（17 针建议 >=400）后重跑。") -ForegroundColor Yellow
  Say ("!! 截断状态下的分数（不要采信）：" + $found.Count + "/" + $needles.Count) -ForegroundColor Yellow
}
Say ''
Say '--- answer ---'
Say $ans
[IO.File]::WriteAllText($json, ([ordered]@{
  tag = $tag; stamp = $stamp; target_tokens = $TargetTokens; depths = $depthList
  prompt_tokens = [int]$r.usage.prompt_tokens; prefix_cache_hit = $cacheN
  out_tokens = [int]$r.usage.completion_tokens
  prefill_tps = [double]$r.timings.prompt_per_second; decode_tps = [double]$r.timings.predicted_per_second
  wall_s = $wall; needles = $needles; found = $found; missed = $missed; answer = $ans
} | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
Say ("JSON: " + $json)
