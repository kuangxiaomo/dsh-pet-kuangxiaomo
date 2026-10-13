# 把 helper 读 queue 的那段逻辑原样搬出来，隔离验证：
# 一行合法 JSON 到底会不会在 helper 的写法下解析失败。
$ErrorActionPreference = 'Stop'
$dir = Join-Path $env:TEMP ('petw-read-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$queuePath = Join-Path $dir 'queue.jsonl'

# 完全按 helper 的写入方式造一行（Node 那种 UTF-8 无 BOM 追加）
$u8 = New-Object System.Text.UTF8Encoding($false)
$line = '{"ts":' + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ',"text":"宿主测试：这条应当被窗口读走"}'
[System.IO.File]::AppendAllText($queuePath, $line + "`n", $u8)

"文件字节数: " + (Get-Item $queuePath).Length

# ---- helper 里的写法（逐字照抄）----
function Read-QueueLines {
  try {
    if (-not (Test-Path -LiteralPath $queuePath)) { return @() }
    return @(Get-Content -LiteralPath $queuePath -Encoding UTF8 -ErrorAction SilentlyContinue)
  } catch { return @() }
}

$lines = Read-QueueLines
"读到的行数: $($lines.Count)"
$i = 0
foreach ($raw in $lines) {
  $i++
  "  第 $i 行 长度=$($raw.Length) 类型=$($raw.GetType().Name)"
  $parsed = $null
  try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
  if ($null -eq $parsed) {
    "    → 解析失败（照 helper 的判据）"
    "    原始字符: [$raw]"
    "    逐字符码点: " + (($raw.ToCharArray() | ForEach-Object { 'U+{0:X4}' -f [int]$_ }) -join ' ')
  } else {
    "    → 解析成功: text=$($parsed.text)"
  }
}

# 再试另一种等价写法，看是不是 -Encoding 的问题
$alt = @(Get-Content -LiteralPath $queuePath)
"不用 -Encoding 时行数: $($alt.Count)"
foreach ($raw in $alt) {
  try { $m = $raw | ConvertFrom-Json; "  解析成功: text=$($m.text)" } catch { "  解析失败: $($_.Exception.Message)" }
}
