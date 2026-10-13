# dsh-pet-window 端到端自检
# 验证四件事：
#   ① 窗口进程能起来、立绘能加载（读数据目录的 window.log）
#   ② queue.jsonl → 窗口（我说话，窗口显示；通过窗口把收到的行数写回 log 来间接确认）
#   ③ inbox.jsonl 格式正确、能被读回（用户打字 → 我读）
#   ④ 窗口位置记忆文件能写
#
# 用法：powershell.exe -NoProfile -ExecutionPolicy Bypass -File e2e.ps1

$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot 'helper\pet-window.ps1'
$testDir = Join-Path $env:TEMP ('petw-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $testDir | Out-Null

$log  = Join-Path $testDir 'window.log'
$q    = Join-Path $testDir 'queue.jsonl'
$in   = Join-Path $testDir 'inbox.jsonl'

$pass = 0; $fail = 0
function Check([string]$what, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host ("  [OK ] " + $what + $(if ($detail) { "  $detail" } else { '' })) }
  else     { $script:fail++; Write-Host ("  [FAIL] " + $what + $(if ($detail) { "  $detail" } else { '' })) }
}

Write-Host "测试数据目录：$testDir"

# ---------- 预置一条"我刚说的话" ----------
$said = '端到端自检：这条应该出现在窗口里'
(@{ ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); text = $said } | ConvertTo-Json -Compress) |
  Set-Content -LiteralPath $q -Encoding UTF8

# ---------- 起窗口（自检模式，6 秒后自己关） ----------
$proc = Start-Process -FilePath 'powershell.exe' `
  -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$helper,
                  '-SelfTest','-DataDir',$testDir,'-PollMs','500') `
  -PassThru -WindowStyle Hidden

Check '窗口进程已启动' ($null -ne $proc -and -not $proc.HasExited) "pid=$($proc.Id)"

Start-Sleep -Milliseconds 300

# ---------- ① 等窗口真的写日志，不要靠固定 sleep ----------
# ⚠ 2026-10-11 实测：从起进程到写下「窗口已显示」要 5 秒上下
#   （PowerShell 5.1 裸启动 1.3s + 加载 WPF 程序集到 1.7s + XAML 解析到 ~5s）。
#   原来的"睡 2.5 秒再看日志"必然假失败，所以改成等真实信号，最多等 25 秒。
$logText = ''
$deadlineShown = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $deadlineShown) {
  $logText = if (Test-Path $log) { Get-Content -LiteralPath $log -Raw -Encoding UTF8 } else { '' }
  if ($logText -match '窗口已显示') { break }
  if ($proc.HasExited) { break }
  Start-Sleep -Milliseconds 200
}

$aliveDuring = -not $proc.HasExited
Check '窗口显示后进程仍在运行' $aliveDuring
Check '日志里有「立绘已加载」' ($logText -match '立绘已加载') 
Check '日志里有「窗口已显示」' ($logText -match '窗口已显示')
Check '立绘路径指向 DSniang1.png' ($logText -match 'DSniang1\.png')

$m = [regex]::Match($logText, '窗口已显示（Left=(\d+) Top=(\d+)）')
Check '窗口拿到了坐标' $m.Success $(if ($m.Success) { "Left=$($m.Groups[1].Value) Top=$($m.Groups[2].Value)" } else { '' })
if ($m.Success) {
  $left = [int]$m.Groups[1].Value; $top = [int]$m.Groups[2].Value
  Check '坐标落在屏幕内' ($left -ge 0 -and $top -ge 0 -and $left -lt 2000 -and $top -lt 1200)
  Check '坐标靠右下（Left > 屏宽/2）' ($left -gt 960)
}

# ---------- ② 我在轮询生效后再追加一条，窗口应能读到 ----------
$second = '第二条：轮询增量'
Add-Content -LiteralPath $q -Value (@{ ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); text = $second } | ConvertTo-Json -Compress) -Encoding UTF8
Start-Sleep -Milliseconds 1500
$lines = @(Get-Content -LiteralPath $q -Encoding UTF8)
Check 'queue.jsonl 现在有 2 行' ($lines.Count -eq 2) "实际 $($lines.Count)"
$parsed = $null
try { $parsed = $lines[-1] | ConvertFrom-Json } catch { }
Check 'queue 最后一行是可解析 JSON 且 text 正确' ($null -ne $parsed -and $parsed.text -eq $second)

# ---------- ③ inbox 往返（模拟窗口写入的一条用户输入） ----------
$userLine = '自检用户输入：你好呀'
Add-Content -LiteralPath $in -Value (@{ ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); text = $userLine; local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json -Compress) -Encoding UTF8
Start-Sleep -Milliseconds 400
$inLines = @(Get-Content -LiteralPath $in -Encoding UTF8)
Check 'inbox.jsonl 有 1 行' ($inLines.Count -eq 1)
$inParsed = $null
try { $inParsed = $inLines[0] | ConvertFrom-Json } catch { }
Check 'inbox 能被读回且中文完好' ($null -ne $inParsed -and $inParsed.text -eq $userLine) "读回：$($inParsed.text)"

# ---------- ④ 关窗后位置记忆 ----------
$deadline = (Get-Date).AddSeconds(15)
while (-not $proc.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
Check '自检模式到点自行退出' $proc.HasExited "ExitCode=$($proc.ExitCode)"

$statePath = Join-Path $testDir 'window-state.json'
Check '位置记忆文件已写出' (Test-Path $statePath)
if (Test-Path $statePath) {
  $st = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
  Check '位置记忆含 left/top' ($null -ne $st.left -and $null -ne $st.top) "left=$($st.left) top=$($st.top)"
}

# ---------- ⑤ 心跳锁必须"不带 BOM"（这是插件认窗口的唯一依据） ----------
# 为什么单独测：PowerShell 5.1 的 `Set-Content -Encoding UTF8` **会写 BOM**，
# 而插件那侧是 Node，`JSON.parse` 碰到 BOM 直接抛 → 判定成"没有窗口"，
# 于是它那 5 分钟的退避重启一到就再起一个（桌面上两个大肥鱼、同一条消息读两遍）。
$lockPath = Join-Path $testDir 'window.lock.json'
Check '心跳锁存在' (Test-Path $lockPath)
if (Test-Path $lockPath) {
  $lb = [System.IO.File]::ReadAllBytes($lockPath)
  $hasBom = ($lb[0] -eq 0xEF -and $lb[1] -eq 0xBB -and $lb[2] -eq 0xBF)
  Check '心跳锁不带 BOM（带 BOM 会让插件误判、多起窗口）' (-not $hasBom)
  $lockText = [System.Text.Encoding]::UTF8.GetString($lb)
  $lockObj = $null
  try { $lockObj = $lockText | ConvertFrom-Json } catch { }
  Check '心跳锁是可解析 JSON 且有 at' ($null -ne $lockObj -and $null -ne $lockObj.at)
}

Write-Host ""
Write-Host "=== pet-window 端到端：$pass 通过 / $fail 失败 ==="
if ($fail -gt 0) { exit 1 }
