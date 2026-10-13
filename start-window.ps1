# 手动启动桌面大肥鱼窗口（不依赖 DSH，方便先看效果）
#
# 正规路径是"装好插件 + 重启 DSH"，窗口由插件自动拉起。
# 这个脚本是给你的手动通道：想马上看一眼、或者排查插件是不是有问题时用。
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\start-window.ps1

$ErrorActionPreference = 'Stop'

$helper = Join-Path $PSScriptRoot 'helper\pet-window.ps1'
if (-not (Test-Path -LiteralPath $helper)) { throw "找不到 helper：$helper" }

# 用真实的数据目录，这样日志和你重启后的窗口是同一份
$env:DSH_HOME = Join-Path $env:USERPROFILE '.dsh'

$existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'pet-window\.ps1' }
if ($existing) {
  Write-Host "窗口好像已经在跑了（pid $($existing.ProcessId -join ', ')）。"
  Write-Host "要重开就先关掉那个窗口，或者执行："
  Write-Host "  Get-CimInstance Win32_Process -Filter `"Name='powershell.exe'`" | Where-Object { `$_.CommandLine -match 'pet-window.ps1' } | ForEach-Object { Stop-Process -Id `$_.ProcessId -Force }"
  exit 0
}

Write-Host "启动窗口…（它会独立于这个终端继续存在）"
Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $helper) `
  -WindowStyle Hidden

Start-Sleep -Seconds 3

$log = Join-Path $env:DSH_HOME 'pet-window\window.log'
if (Test-Path -LiteralPath $log) {
  Write-Host ''
  Write-Host "最近日志（$log）："
  Get-Content -LiteralPath $log -Encoding UTF8 -Tail 6 | ForEach-Object { "  $_" }
}
Write-Host ''
Write-Host '看到「窗口已显示」就应该出现了。没有的话看上面的日志。'
