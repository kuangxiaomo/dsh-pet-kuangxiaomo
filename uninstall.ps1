# 把 dsh-pet-window 从 DSH profile 里干净卸载 / 或回滚安装
#
# 做什么：
#   ① 删掉 profile\node_modules\dsh-pet-window 这个链接（不动你的源码目录）
#   ② 从 profile\package.json 里去掉 dsh-pet-window 的依赖项与 bundle 项
#   ③ 关掉正在运行的窗口进程
#   ④ 数据目录（~/.dsh/pet-window）**保留**，除非你加 -PurgeData
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -PurgeData

param([switch]$PurgeData)

$ErrorActionPreference = 'Stop'
$profileDir = Join-Path $env:USERPROFILE '.dsh\profiles\desktop'
$pkgPath = Join-Path $profileDir 'package.json'
$link = Join-Path $profileDir 'node_modules\dsh-pet-window'
$backup = Join-Path $PSScriptRoot 'install-backup\profile-package.json.orig'

# ---------- ① 关窗口进程 ----------
$procs = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -match 'pet-window\.ps1' }
foreach ($p in $procs) {
  try { Stop-Process -Id $p.ProcessId -Force; Write-Host "已关闭窗口进程 pid=$($p.ProcessId)" } catch { }
}
if (-not $procs) { Write-Host '没有正在运行的窗口进程。' }

# ---------- ② 删链接 ----------
if (Test-Path -LiteralPath $link) {
  # 注意：只删链接本身，不递归删目标目录（源码在工作区里，不能动）
  [System.IO.Directory]::Delete($link, $false)
  Write-Host "已删除链接：$link"
} else {
  Write-Host "链接不存在（可能已经卸过）：$link"
}

# ---------- ③ 改 package.json ----------
if (Test-Path -LiteralPath $pkgPath) {
  if (Test-Path -LiteralPath $backup) {
    Copy-Item -LiteralPath $backup -Destination $pkgPath -Force
    Write-Host '已用安装前的备份还原 profile\package.json'
  } else {
    # 没有备份就按行剔除，尽量不做整体重写
    $raw = [System.IO.File]::ReadAllText($pkgPath, [System.Text.Encoding]::UTF8)
    $lines = $raw -split "`r?`n" | Where-Object { $_ -notmatch '"dsh-pet-window"' }
    [System.IO.File]::WriteAllText($pkgPath, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '没有备份，已按行剔除 dsh-pet-window 的两处配置'
  }
  try { $null = [System.IO.File]::ReadAllText($pkgPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json; Write-Host 'package.json 仍是合法 JSON' }
  catch { Write-Warning "package.json 可能坏了，请手工检查：$pkgPath" }
}

# ---------- ④ 数据目录 ----------
$dataDir = Join-Path $env:USERPROFILE '.dsh\pet-window'
if ($PurgeData) {
  if (Test-Path -LiteralPath $dataDir) { Remove-Item -LiteralPath $dataDir -Recurse -Force; Write-Host "已删除数据目录：$dataDir" }
} else {
  Write-Host "数据目录保留：$dataDir（加 -PurgeData 可一并删除）"
}

Write-Host ''
Write-Host '卸载完成。完整退出 DSH 再启动，就不会再加载这个插件了。'
