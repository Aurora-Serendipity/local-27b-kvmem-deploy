<#
vram-peak.ps1 -- sample GPU memory during an arm so the scan in 复现手册 §4.1-1
("每次记录显存峰值 → 找不爆的上限") has a real peak, not an after-the-fact reading.
#>
param([int]$Seconds = 240, [int]$IntervalMs = 300, [string]$Out = 'D:\Local Model\_runs\logs\vram-peak.txt')
$max = 0; $maxAt = ''; $n = 0
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
  try {
    $v = [int]((& nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | Select-Object -First 1))
    $n++
    if ($v -gt $max) { $max = $v; $maxAt = (Get-Date -Format 'HH:mm:ss') }
  } catch { }
  Start-Sleep -Milliseconds $IntervalMs
}
$line = "peak_vram_mib=$max at $maxAt samples=$n window_s=$Seconds"
Set-Content -LiteralPath $Out -Value $line -Encoding UTF8
Write-Host $line
