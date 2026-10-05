<#
verify-package.ps1 -- close-out verification, read-only:
  [1] src-tree-MANIFEST.sha256 : verify every entry (README "★ 源码树完整性校验")
  [2] file-count vs manifest entry count (the docs' "先数文件，再比哈希")
  [3] extra files on disk that are not in the manifest
  [4] re-run the package's own 自检-搬家.ps1 (proves the package is still byte-identical
      after the whole deployment session -- nothing was written into it)
#>
$root = 'D:\Local Model\pkg3-lowvram-llama-kvmem\pkg3-lowvram-llama-kvmem'
$tree = Join-Path $root 'src-tree\llama-kvmem'
$manifest = Join-Path $root 'src-tree-MANIFEST.sha256'

Write-Host '=== [1][2] manifest verification (3605 entries) ==='
$n = 0; $fail = @(); $missing = @(); $listed = @{}
$t0 = Get-Date
foreach ($line in [IO.File]::ReadAllLines($manifest)) {
  if ($line -notmatch '^\s*([0-9a-fA-F]{64})\s\s(.+?)\s*$') { continue }
  $h = $Matches[1].ToLower(); $rel = $Matches[2]; $listed[$rel] = $true; $n++
  $full = Join-Path $tree ($rel -replace '/', '\')
  if (-not (Test-Path -LiteralPath $full)) { $missing += $rel; continue }
  $a = (Get-FileHash -LiteralPath $full -Algorithm SHA256).Hash.ToLower()
  if ($a -ne $h) { $fail += $rel }
}
$elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
Write-Host ("checked entries : $n   (took $elapsed s)")
Write-Host ("hash mismatches : " + $fail.Count)
Write-Host ("missing files   : " + $missing.Count)
if ($fail.Count) { $fail | Select-Object -First 10 | ForEach-Object { Write-Host ("  FAIL " + $_) } }
if ($missing.Count) { $missing | Select-Object -First 10 | ForEach-Object { Write-Host ("  MISSING " + $_) } }

Write-Host ''
Write-Host '=== [3] extra files on disk not in the manifest ==='
$onDisk = @(Get-ChildItem -LiteralPath $tree -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($tree.Length).TrimStart('\') -replace '\\', '/' })
$extra = @($onDisk | Where-Object { -not $listed.ContainsKey($_) })
Write-Host ("files on disk   : " + $onDisk.Count)
Write-Host ("extra (unlisted): " + $extra.Count)
if ($extra.Count) { $extra | Select-Object -First 10 | ForEach-Object { Write-Host ("  EXTRA " + $_) } }

Write-Host ''
Write-Host '=== [4] package self-check (byte-identity of the deliverable) ==='
Push-Location $root
& powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root '自检-搬家.ps1')
$rc = $LASTEXITCODE
Pop-Location
Write-Host ("自检-搬家.ps1 exit code = $rc")

Write-Host ''
if ($fail.Count -eq 0 -and $missing.Count -eq 0 -and $extra.Count -eq 0 -and $rc -eq 0) {
  Write-Host 'CLOSE-OUT: ALL GREEN (src-tree manifest + package integrity)'
} else {
  Write-Host 'CLOSE-OUT: NOT GREEN -- see above'
}
