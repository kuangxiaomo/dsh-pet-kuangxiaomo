# dsh-pet-window 的原生窗口助手（Windows PowerShell 5.1 + WPF）
#
# 为什么用 PowerShell 而不是 Electron/Python/Qt：
#   1. 本机只有 PowerShell 5.1，WPF 是系统自带的，零依赖、零安装；
#   2. Electron 的 dshPlatform.open() 只允许 "usage"/"top-up" 两个页面（宿主硬校验），
#      拿不到自定义窗口；
#   3. 用户要的是"桌面上的立绘 + 对话框"，只有独立进程能画出窗口外的东西。
#
# 通信全走文件邮箱（见 $DataDir），不碰 HTTP、不碰 DSH 鉴权：
#   读  queue.jsonl  —— 我（agent）说的短句，每行一个 JSON
#   写  inbox.jsonl  —— 用户在这个窗口里打的字，每行一个 JSON
#
# 用法：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File pet-window.ps1
#   powershell.exe ... -File pet-window.ps1 -SelfTest      # 起来 6 秒后自己关，用于自检

param(
  [switch]$SelfTest,
  [switch]$DebugScroll,
  [string]$ImagePath = '',
  [string]$DataDir = '',
  [int]$PollMs = 1000
)

$ErrorActionPreference = 'Stop'

# ---------- 程序集 ----------
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms

# ---------- 路径 ----------
$dshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
if (-not $DataDir) { $DataDir = Join-Path $dshHome 'pet-window' }
if (-not $ImagePath) {
  # 优先用 whale-widget 自带的那张（用户明确指定的"眼睛水汪汪的大肥鱼"），
  # 找不到就退回本插件 assets 里的副本。
  $candidates = @(
    (Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules\dsh-whale-widget\assets\DSniang1.png'),
    (Join-Path $PSScriptRoot '..\assets\DSniang1.png')
  )
  foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { $ImagePath = $c; break } }
}

$queuePath  = Join-Path $DataDir 'queue.jsonl'
$inboxPath  = Join-Path $DataDir 'inbox.jsonl'
$statePath  = Join-Path $DataDir 'window-state.json'
$logPath    = Join-Path $DataDir 'window.log'
$lockPath   = Join-Path $DataDir 'window.lock.json'
New-Item -ItemType Directory -Force -Path $DataDir | Out-Null

# ---------- 认领"窗口存活"标记（与插件的互斥靠它） ----------
# 插件在拉起新窗口之前会看这个标记的 at 时间够不够新；够新就不重复起。
# 不这么做的话，手动重启 + 插件的退避重启会各起一个，桌面上就有两个窗口，
# 两个窗口各记各的已读行号，看起来像"有的窗口不读新消息"（2026-10-11 实测）。
# ⚠ 判据是**时间**不是 pid：本机 process.kill(pid,0) 不可信（对任何 pid 都抛 ESRCH），
#   所以插件那侧只能靠心跳时间判活。这里必须定期刷新 at，否则插件会以为窗口死了。
$myPid = $PID
function Write-WindowLock {
  # 先写临时文件再原子替换：插件可能正在读这个文件，别让它读到半截 JSON
  try {
    $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $tmp = "$lockPath.tmp"
    # ⚠ 必须**不带 BOM** 地写：PowerShell 5.1 的 `Set-Content -Encoding UTF8` 会写 BOM，
    #   而插件那侧是 Node，`JSON.parse` 遇到 BOM 直接抛 → 它判定成"没有窗口"，
    #   于是它那 5 分钟的退避重启一到就再起一个窗口，桌面上就出现两个
    #   （2026-10-11 实测踩到，表现是"同一条消息被读两遍"）。
    $json = @{ pid = $myPid; at = $stamp } | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tmp -Destination $lockPath -Force
  } catch { }
}

# 控制台输出编码：不设的话从别处 Get-Content 读这份日志会看到中文乱码
# （本机 ANSI 是 GBK，而日志是用 UTF-8 写的）。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }

function Write-Log([string]$message) {
  try {
    $stamp = (Get-Date).ToString('HH:mm:ss')
    Add-Content -LiteralPath $logPath -Value "$stamp [ps] $message" -Encoding UTF8
  } catch { }
}

Write-WindowLock
Write-Log "启动：pid=$myPid image=$ImagePath data=$DataDir"

# ---------- 读上次窗口位置 ----------
$winLeft = $null; $winTop = $null
try {
  if (Test-Path -LiteralPath $statePath) {
    $st = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($null -ne $st.left) { $winLeft = [double]$st.left }
    if ($null -ne $st.top) { $winTop = [double]$st.top }
  }
} catch { Write-Log "读位置失败：$($_.Exception.Message)" }

# ---------- XAML ----------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="大肥鱼" Width="330" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="True" ResizeMode="NoResize"
        ShowActivated="False" SnapsToDevicePixels="True">
  <Grid x:Name="RootGrid" Margin="10">
    <Grid.Resources>
      <!-- RichTextBox 默认带边框和背景，这里全清掉，只当排版容器用 -->
      <Style x:Key="PlainRich" TargetType="RichTextBox">
        <Setter Property="Background" Value="Transparent"/>
        <Setter Property="BorderThickness" Value="0"/>
        <Setter Property="Padding" Value="0"/>
        <Setter Property="IsReadOnly" Value="True"/>
        <Setter Property="IsDocumentEnabled" Value="True"/>
        <Setter Property="Focusable" Value="False"/>
        <Setter Property="CaretBrush" Value="Transparent"/>
        <!-- Hidden（不是 Disabled）：滚轮可以往回翻聊天记录，但滚动条不占地方。
             Disabled 会彻底关掉滚动，那样就翻不了历史了（2026-10-11 用户要求）。 -->
        <Setter Property="VerticalScrollBarVisibility" Value="Hidden"/>
        <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      </Style>
    </Grid.Resources>
    <Grid.RowDefinitions>
      <!-- 第 0 行是"拖动条"（2026-10-12 加）：以前整个窗口都能拖，
           结果用户打游戏时点到窗口、鼠标一动就把窗口拖到屏幕外面去了
           （状态文件里留下 left=1624 top=867 那种记录）。
           2026-10-13 反思：当时收紧成"只有这一条 12 像素的透明条能拖" ——
           而它是**看不见**的，找不到手柄就等于拖不动（用户原话：
           "那个对话框 我怎么现在拖不动"）。现在气泡、立绘、这条都能拖，
           防事故改由 Clamp-ToScreen 负责：松手时把整窗夹回屏幕内。 -->
      <RowDefinition Height="12"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <!-- 第 4 行：三只感官的开关（2026-10-13 用户要求"随时开关耳朵/守夜人/屏幕眼"） -->
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Border x:Name="DragBar" Grid.Row="0" Background="Transparent" Cursor="SizeAll"/>

    <!-- 我说的话。Cursor=SizeAll：鼠标一进气泡就是"能拖"的十字箭头，
         省得用户猜哪里能抓（2026-10-13 用户抱怨拖不动之后加的）。 -->
    <Border x:Name="Bubble" Grid.Row="1" CornerRadius="12" Padding="12,9"
            Background="#F2FFFFFF" BorderBrush="#55203170" BorderThickness="1"
            Cursor="SizeAll"
            HorizontalAlignment="Stretch" Margin="2,0,2,8">
      <Border.Effect>
        <DropShadowEffect BlurRadius="10" ShadowDepth="2" Opacity="0.22" Color="#203170"/>
      </Border.Effect>
      <!-- 用 RichTextBox 而不是 TextBlock：气泡里要内联一张鲸鱼小图，
           TextBlock 只接受 Run，塞 Paragraph 进去会被当成对象 ToString 打出来 -->
      <RichTextBox x:Name="BubbleText" Style="{StaticResource PlainRich}"
                   FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#203170"
                   MaxHeight="130">
        <FlowDocument PagePadding="0" LineHeight="20">
          <Paragraph Margin="0">……</Paragraph>
        </FlowDocument>
      </RichTextBox>
    </Border>

    <!-- 立绘（脚下原来有一行"拖动我 · 右下角 × 关闭"的提示，用户要求删掉）。
         背景给 Transparent、鼠标给 SizeAll：立绘四周的透明处也能抓住拖窗口。 -->
    <Grid x:Name="PetArea" Grid.Row="2" HorizontalAlignment="Center"
          Background="Transparent" Cursor="SizeAll">
      <Image x:Name="PetImage" Width="230" Stretch="Uniform"
             RenderOptions.BitmapScalingMode="HighQuality"/>
    </Grid>

    <!-- 你说话的地方 -->
    <Border Grid.Row="3" CornerRadius="16" Padding="6" Margin="2,8,2,0"
            Background="#F2FFFFFF" BorderBrush="#55203170" BorderThickness="1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <TextBox x:Name="InputBox" Grid.Column="0" BorderThickness="0"
                 Background="Transparent" FontFamily="Microsoft YaHei UI" FontSize="13"
                 Foreground="#203170" VerticalContentAlignment="Center" MaxLength="200"/>
        <!-- 占位文字用独立 TextBlock 叠上去。
             ⚠ 别改回"往 Text 里塞占位、聚焦时清空"那套：焦点事件不保证按顺序来，
               实测会出现输入框看着是空的（2026-10-11）。 -->
        <TextBlock x:Name="PlaceholderText" Grid.Column="0" Text="说点什么…"
                   FontFamily="Microsoft YaHei UI" FontSize="13" Foreground="#99A0B8CC"
                   VerticalAlignment="Center" IsHitTestVisible="False" Margin="2,0,0,0"/>
        <Button x:Name="SendButton" Grid.Column="1" Content="发送" Width="52" Height="28"
                Margin="6,0,0,0" Cursor="Hand"
                FontFamily="Microsoft YaHei UI" FontSize="12"/>
      </Grid>
    </Border>

    <!-- 三只感官的开关（2026-10-13 用户要求）。
         按一下 = 开/关那一只：立刻起/停对应的 pythonw 进程，并把状态写进 ~/.dsh/senses.json，
         所以关掉的不会在下次开机自己偷偷回来（开机自启走 senses.ps1 -Action start-enabled）。 -->
    <Border Grid.Row="4" CornerRadius="12" Padding="4,3" Margin="2,6,2,0"
            Background="#E6FFFFFF" BorderBrush="#33203170" BorderThickness="1">
      <Grid>
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="BtnEar"   Grid.Column="0" Margin="2" Height="24" Cursor="Hand"
                FontFamily="Microsoft YaHei UI" FontSize="11" Content="耳朵 开"/>
        <Button x:Name="BtnWatch" Grid.Column="1" Margin="2" Height="24" Cursor="Hand"
                FontFamily="Microsoft YaHei UI" FontSize="11" Content="守夜 开"/>
        <Button x:Name="BtnEye"   Grid.Column="2" Margin="2" Height="24" Cursor="Hand"
                FontFamily="Microsoft YaHei UI" FontSize="11" Content="屏幕 开"/>
      </Grid>
    </Border>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [System.Windows.Markup.XamlReader]::Load($reader)

$rootGrid   = $window.FindName('RootGrid')
$bubble     = $window.FindName('Bubble')
$bubbleText = $window.FindName('BubbleText')
$petImage   = $window.FindName('PetImage')
$inputBox   = $window.FindName('InputBox')
$sendButton = $window.FindName('SendButton')
$btnEar     = $window.FindName('BtnEar')
$btnWatch   = $window.FindName('BtnWatch')
$btnEye     = $window.FindName('BtnEye')

# ---------- 立绘 ----------
if ($ImagePath -and (Test-Path -LiteralPath $ImagePath)) {
  try {
    $bmp = New-Object System.Windows.Media.Imaging.BitmapImage
    $bmp.BeginInit()
    $bmp.UriSource = New-Object System.Uri($ImagePath)
    $bmp.CacheOption = 'OnLoad'
    $bmp.EndInit()
    $petImage.Source = $bmp
    Write-Log "立绘已加载：$ImagePath ($($bmp.PixelWidth)x$($bmp.PixelHeight))"
  } catch {
    Write-Log "立绘加载失败：$($_.Exception.Message)"
    $bubbleText.Text = '（立绘没加载出来，但对话仍然可用）'
  }
} else {
  Write-Log "没找到立绘文件"
  $bubbleText.Text = '（找不到立绘图，把 DSniang1.png 放到 assets 里）'
}

# ---------- 定位（默认屏幕右下角，任务栏之上） ----------
$work = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ($null -eq $winLeft) { $winLeft = $work.Right - 330 - 12 }
if ($null -eq $winTop)  { $winTop  = $work.Bottom - 430 - 12 }
# 🔴 位置兜底（2026-10-12 实测踩到：用户说"对话框模组不见了"）：
#   保存下来的位置可能是屏幕外的（拖动、分辨率变化、或脚本误触）；
#   实测有一次存成 left=1675 top=1021，而工作区只有 1920×1032 —— 窗口只剩 11 像素露在边上，
#   看起来就是"不见了"。所以这里夹一下：至少留 80×60 像素在可见区域内。
if ($winLeft -gt ($work.Right - 80)) { $winLeft = $work.Right - 330 - 12 }
if ($winLeft -lt ($work.Left - 330 + 80)) { $winLeft = $work.Left + 12 }
if ($winTop -gt ($work.Bottom - 60)) { $winTop = $work.Bottom - 430 - 12 }
if ($winTop -lt $work.Top) { $winTop = $work.Top + 12 }
$window.Left = $winLeft
$window.Top  = $winTop
Write-Log "定位：Left=$winLeft Top=$winTop（工作区 $($work.Width)x$($work.Height)）"

# ---------- 拖动（气泡 / 立绘 / 顶上那条都能拖） ----------
# 🔴 2026-10-12 事故：以前整个 RootGrid 都能拖，用户在游戏里点到窗口、鼠标一动，
#   窗口就被拖到屏幕外面（状态文件留下 left=1624 top=867），看起来是"模组不见了"。
#   当时的对策是"只有顶上 12 像素的透明条能拖" —— 但那条**看不见**。
# 🔴 2026-10-13 用户原话："那个对话框 我怎么现在拖不动" —— 找不到手柄 = 不能拖。
#   所以现在改成：看得见的地方（气泡、立绘）都能抓，防事故交给 Clamp-ToScreen ——
#   松手时把整窗夹回工作区。误拖的代价从"窗口消失"降到"挪了一下"。
$script:dragging = $false
$rootGrid = $window.FindName('RootGrid')
$dragBar  = $window.FindName('DragBar')
$petArea  = $window.FindName('PetArea')

# 夹回屏幕：整窗留在工作区内（不加额外边距，免得把用户熟悉的右下角位置顶上去）。
# ⚠ 边距必须是 0：默认位置正好贴着工作区下沿（562+470=1032），留边距会让它每次拖动都往上跳。
function Clamp-ToScreen {
  try {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = $window.ActualWidth;  if (-not $w) { $w = 330 }
    $h = $window.ActualHeight; if (-not $h) { $h = 430 }
    $minL = [double]$area.Left
    $minT = [double]$area.Top
    $maxL = [Math]::Max($minL, [double]($area.Right  - $w))
    $maxT = [Math]::Max($minT, [double]($area.Bottom - $h))
    $l = [double]$window.Left
    $t = [double]$window.Top
    $nl = [Math]::Min([Math]::Max($l, $minL), $maxL)
    $nt = [Math]::Min([Math]::Max($t, $minT), $maxT)
    if ([Math]::Abs($nl - $l) -ge 1 -or [Math]::Abs($nt - $t) -ge 1) {
      $window.Left = $nl
      $window.Top  = $nt
      Write-Log ("拖动越界，已夹回 " + [int]$nl + "," + [int]$nt + "（原 " + [int]$l + "," + [int]$t + "）")
    }
  } catch { Write-Log "夹位置失败：$($_.Exception.Message)" }
}

$dragHandler = {
  param($sender, $e)
  if ($script:dragging) { return }        # DragMove 会重入，挡一下
  $script:dragging = $true
  $srcName = ''
  try { $srcName = $e.OriginalSource.GetType().Name } catch { }
  try {
    $window.DragMove()                    # 阻塞到鼠标松开
    Clamp-ToScreen
    Save-Position
    # 每次拖动都留一行：用户再说"拖不动"时，日志里有没有这行就能分清
    # 是"根本没抓到"还是"抓到了但没动"（2026-10-13 排查时正缺这一行证据）。
    Write-Log ("拖动结束：Left=" + [int]$window.Left + " Top=" + [int]$window.Top + "（抓的是 " + $srcName + "）")
  } catch {
    Write-Log "拖动失败：$($_.Exception.Message)"
  } finally {
    $script:dragging = $false
  }
}

# handledEventsToo=$true：气泡里的 RichTextBox 会把鼠标事件标记成"已处理"，
# 不带上它，点文字那一片照样拖不动（只剩气泡边框能拖，用户仍然会说"拖不动"）。
# 只挂这三个元素，**不要挂 RootGrid**：那样输入框上的点击也会被当成拖动。
$mbHandler = [System.Windows.Input.MouseButtonEventHandler]$dragHandler
foreach ($el in @($dragBar, $bubble, $petArea)) {
  if ($null -ne $el) {
    $el.AddHandler([System.Windows.UIElement]::MouseLeftButtonDownEvent, $mbHandler, $true)
  }
}
Write-Log ("拖动手柄已挂上：" + (@($dragBar, $bubble, $petArea) | Where-Object { $null -ne $_ }).Count + " 处")

# ---------- 三只感官的开关（2026-10-13 用户要求"随时开关耳朵/守夜人/屏幕眼"） ----------
# 🔴 2026-10-13 血的教训：**绝对不要 dot-source senses.ps1**
#   它里面写的是 `$StatePath`，本脚本用的是 `$statePath` —— PowerShell 变量**不区分大小写**，
#   dot-source 之后本脚本的 `$statePath` 被顶成了 `~/.dsh/senses.json`，
#   于是"窗口位置"被写进了感官开关的状态文件（e2e 的「位置记忆文件已写出」就是这么挂的）。
#   现在改成**起子进程**调用 senses.ps1：变量互不污染，这类撞车从根上消失；代价是每次点击多约 1 秒。
$script:senseButtons = [ordered]@{ ear = $btnEar; watchman = $btnWatch; eye = $btnEye }
$script:senseShort   = @{ ear = '耳朵'; watchman = '守夜'; eye = '屏幕' }
$script:senseFull    = @{ ear = '耳朵'; watchman = '守夜人'; eye = '屏幕眼' }
$script:sensePath    = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'senses.ps1'
$script:sensesOk     = (Test-Path -LiteralPath $script:sensePath)
if ($script:sensesOk) { Write-Log "感官开关已接入（子进程模式）：$script:sensePath" }
else { Write-Log "找不到 senses.ps1（$script:sensePath）：开关按钮不可用" }

function Invoke-SensesCli {
  param([string[]]$CliArgs)
  try {
    # ⚠ 这里必须用 splat（`@CliArgs`）把数组摊成独立参数；写成 `-CliArgs $CliArgs`
    #   会把 "-CliArgs" 当成 senses.ps1 的参数名传过去（它根本没有这个参数）。
    $txt = (& powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:sensePath @CliArgs 2>$null | Out-String).Trim()
    if (-not $txt) { return @() }
    $obj = $txt | ConvertFrom-Json
    if ($null -eq $obj) { return @() }
    return @($obj.senses)
  } catch {
    Write-Log "调用 senses.ps1 失败：$($_.Exception.Message)"
    return @()
  }
}

function Set-SenseButton($row) {
  $b = $script:senseButtons[$row.key]
  if ($null -eq $b) { return }
  $b.Content = $script:senseShort[$row.key] + ' ' + $(if ($row.enabled) { '开' } else { '关' })
  $conv = New-Object System.Windows.Media.BrushConverter
  if ($row.enabled) {
    $b.Background = $conv.ConvertFromString('#FFE3F6E6')
    $b.Foreground = $conv.ConvertFromString('#FF1B5E20')
  } else {
    $b.Background = $conv.ConvertFromString('#FFF1F1F3')
    $b.Foreground = $conv.ConvertFromString('#FF9A9A9A')
  }
}

function Update-SenseButtons {
  if (-not $script:sensesOk) {
    foreach ($b in $script:senseButtons.Values) {
      if ($null -ne $b) { $b.Content = '开关不可用'; $b.IsEnabled = $false }
    }
    return
  }
  $rows = Invoke-SensesCli -CliArgs @('-Action', 'status', '-Json')
  if ($rows.Count -eq 0) { return }        # 拿不到就保持原样，别把按钮刷成空白
  try { foreach ($row in $rows) { Set-SenseButton $row } }
  catch { Write-Log "刷新感官按钮失败：$($_.Exception.Message)" }
}

function Switch-Sense($key) {
  if (-not $script:sensesOk) { return }
  try {
    # 一次子进程就够：toggle 之后它会回传三只的最新状态，按钮和气泡都用这份
    $rows = Invoke-SensesCli -CliArgs @('-Action', 'toggle', '-Target', $key, '-Json')
    if ($rows.Count -eq 0) { Write-Log "切换感官失败（$key）：没拿到状态"; return }
    foreach ($row in $rows) { Set-SenseButton $row }
    $mine = $rows | Where-Object { $_.key -eq $key } | Select-Object -First 1
    $word = if ($mine -and $mine.enabled) { '打开' } else { '关掉' }
    Add-Line 'me' ('（' + $script:senseFull[$key] + '已' + $word + '）')
    Write-Log ('感官开关：' + $script:senseFull[$key] + ' → ' + $word)
  } catch {
    Write-Log "切换感官失败（$key）：$($_.Exception.Message)"
  }
}

$btnEar.Add_Click({   Switch-Sense 'ear' })
$btnWatch.Add_Click({ Switch-Sense 'watchman' })
$btnEye.Add_Click({   Switch-Sense 'eye' })

# 按钮状态**延迟**刷（别在 ShowDialog 之前阻塞 —— 那会让窗口晚出现将近 1 秒）
$senseTimer = New-Object System.Windows.Threading.DispatcherTimer
$senseTimer.Interval = [TimeSpan]::FromMilliseconds(800)
$senseTimer.Add_Tick({ $senseTimer.Stop(); Update-SenseButtons })
$window.Add_Loaded({ $senseTimer.Start() })

function Save-Position {
  try {
    $o = [ordered]@{ left = [math]::Round($window.Left); top = [math]::Round($window.Top); at = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
    ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $statePath -Encoding UTF8
  } catch { Write-Log "存位置失败：$($_.Exception.Message)" }
}

# ---------- 会话显示（全部聊天记录都留着，滚轮往回翻） ----------
#
# 以前这里只保留最近 3 条、每来一条就把整段重画一遍，所以根本没法往回看。
# 现在改成：全部保留（上限 200 条），**只往后追加**，滚轮自己滚。
# ⚠ 别再改回"清空重画"（$doc.Blocks.Clear()）：那会把滚动位置一起清掉，
#   用户正翻着历史呢，来一条新消息就被弹回底部（2026-10-11 要加滚动时想到的）。
#
# 我说的话前面要有个鲸鱼标记（用户 2026-10-11 要求）。
# ⚠ 不能用 emoji 字符：Segoe UI Emoji 里确实有 U+1F40B 的字形，但 WPF 在
#   "中文 + emoji" 混排时没回退过去，实际画出来是豆腐块（看着像图标，其实是缺字形）。
#   所以改成**内联一张预渲染好的小图**（..\assets\whale-prefix.png），彻底绕开字体回退。
# ⚠ 用 InlineUIContainer 必须设 BaselineAlignment=Bottom 并给固定宽高，
#   否则它会按基线对齐、把整行撑歪。
$script:maxHistory = 200   # 气泡里最多留多少条；再多就不叫聊天记录、叫内存增长了
$whaleImagePath = Join-Path $PSScriptRoot '..\assets\whale-prefix.png'
$script:whaleSource = $null
if (Test-Path -LiteralPath $whaleImagePath) {
  try {
    $wb = New-Object System.Windows.Media.Imaging.BitmapImage
    $wb.BeginInit(); $wb.UriSource = New-Object System.Uri($whaleImagePath); $wb.CacheOption = 'OnLoad'; $wb.EndInit()
    $script:whaleSource = $wb
  } catch { Write-Log "鲸鱼标记图加载失败：$($_.Exception.Message)" }
} else {
  Write-Log "找不到鲸鱼标记图：$whaleImagePath（回退成文字「我：」）"
}

# 气泡现在是不是"基本停在最底部"。只有停在底部时才自动跟着新消息走——
# 否则用户正往回翻历史时来了新消息，画面会被顶回底部，白翻了。
# ⚠ 容差 30px 不是随手写的：WPF 报出来的 ExtentHeight 比真正能滚到的最底部还多出
#   约 20px 的底部留白（2026-10-11 实测：已经在最底下时 offset=950，而 extent-viewport=970）。
#   用严格相等（容差 2px）会让"停在底部"永远判成 false，新消息就再也不自动跟下来了。
function Test-AtBottom {
  try {
    return (($bubbleText.VerticalOffset + $bubbleText.ViewportHeight) -ge ($bubbleText.ExtentHeight - 30))
  } catch { return $true }
}

# 把一条消息变成气泡里的一段（我的带鲸鱼小图，你的带「你：」）
function New-ChatParagraph([string]$who, [string]$text) {
  $p = New-Object System.Windows.Documents.Paragraph
  $p.Margin = New-Object System.Windows.Thickness(0)
  $p.LineHeight = 20
  if ($who -eq 'me' -and $null -ne $script:whaleSource) {
    $img = New-Object System.Windows.Controls.Image
    $img.Source = $script:whaleSource
    $img.Height = 15; $img.Width = 15
    $img.Stretch = 'Uniform'
    $img.Margin = New-Object System.Windows.Thickness(0, 0, 4, 0)
    $holder = New-Object System.Windows.Documents.InlineUIContainer($img)
    $holder.BaselineAlignment = 'Bottom'
    $p.Inlines.Add($holder)
  } else {
    $label = if ($who -eq 'me') { '我：' } else { '你：' }
    $p.Inlines.Add((New-Object System.Windows.Documents.Run($label)))
  }
  $p.Inlines.Add((New-Object System.Windows.Documents.Run($text)))
  return $p
}

function Add-Line([string]$who, [string]$text) {
  $doc = $bubbleText.Document
  $follow = Test-AtBottom
  $keepOffset = $bubbleText.VerticalOffset
  [void]$doc.Blocks.Add((New-ChatParagraph $who $text))
  # 超出了就丢最老的（从文档开头删，滚动位置会跟着上移，这是可接受的）
  while ($doc.Blocks.Count -gt $script:maxHistory) { [void]$doc.Blocks.Remove($doc.Blocks.FirstBlock) }
  if ($follow) { $bubbleText.ScrollToEnd(); return }
  # 🔴 2026-10-11 实测踩到：窗口是 SizeToContent="Height"，往文档里追加内容会让整窗
  #   重新量一次，这期间 ScrollViewer 的 offset 会被夹回 0 —— 表现就是"用户正往回翻着，
  #   来一条新消息，画面被弹到最早那几条"。所以先把位置记下来，等这轮布局跑完再放回去。
  $script:keepOffset = $keepOffset
  Write-Log ("不跟底部：offset=" + [math]::Round($keepOffset) + " viewport=" + [math]::Round($bubbleText.ViewportHeight) + " extent=" + [math]::Round($bubbleText.ExtentHeight))
  [void]$bubbleText.Dispatcher.BeginInvoke(
    [System.Windows.Threading.DispatcherPriority]::ContextIdle,
    [Action]{
      try {
        if ($DebugScroll) { Write-Log ("恢复前 offset=" + [math]::Round($bubbleText.VerticalOffset) + " 目标=" + [math]::Round($script:keepOffset)) }
        $bubbleText.ScrollToVerticalOffset($script:keepOffset)
        if ($DebugScroll) { Write-Log ("恢复后 offset=" + [math]::Round($bubbleText.VerticalOffset)) }
      } catch { Write-Log ("恢复滚动位置失败：" + $_.Exception.Message) }
    })
}

# 开机时把两个文件里的聊天记录合起来按时间排一遍：
# inbox 是你说的，queue 是我说的。这样窗口重启后往回翻还能看到之前的对话，
# 而不是像以前那样只剩最后两句。
function Read-ChatLines([string]$path, [string]$who) {
  $rows = New-Object System.Collections.Generic.List[object]
  try {
    if (-not (Test-Path -LiteralPath $path)) { return $rows }
    foreach ($raw in (Get-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
      if ([string]::IsNullOrWhiteSpace($raw)) { continue }
      $m = $null
      try { $m = $raw | ConvertFrom-Json } catch { $m = $null }
      if ($null -eq $m -or -not $m.text) { continue }   # marker 行（pet-window-start 之类）没有 text
      $ts = 0
      if ($null -ne $m.ts) { $ts = [double]$m.ts }
      $rows.Add(@{ who = $who; text = [string]$m.text; ts = $ts })
    }
  } catch { Write-Log "读聊天记录失败（$path）：$($_.Exception.Message)" }
  return $rows
}

function Load-History {
  $all = New-Object System.Collections.Generic.List[object]
  foreach ($row in (Read-ChatLines $inboxPath 'user')) { $all.Add($row) }
  foreach ($row in (Read-ChatLines $queuePath 'me')) { $all.Add($row) }
  foreach ($row in (@($all | Sort-Object { $_['ts'] }) | Select-Object -Last $script:maxHistory)) {
    [void]$bubbleText.Document.Blocks.Add((New-ChatParagraph $row.who $row.text))
  }
  $bubbleText.ScrollToEnd()
}

# ---------- 发送 ----------
$script:lastQueueLine = 0
# 坏行追踪：同一行连续解析失败几次（见轮询里的注释，防止一条坏 JSON 堵死队列）
$script:badLine = -1
$script:badLineTries = 0
function Send-Input {
  $text = $inputBox.Text
  if ([string]::IsNullOrWhiteSpace($text)) { return }
  try {
    $o = [ordered]@{
      ts    = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
      text  = $text.Trim()
      local = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    Add-Content -LiteralPath $inboxPath -Value ($o | ConvertTo-Json -Compress) -Encoding UTF8
    Write-Log "收到用户输入：$($text.Trim())"
  } catch { Write-Log "写 inbox 失败：$($_.Exception.Message)" }
  Add-Line 'user' $text.Trim()
  $inputBox.Text = ''
}
$sendButton.Add_Click({ Send-Input })
$inputBox.Add_KeyDown({
  param($sender, $e)
  if ($e.Key -eq [System.Windows.Input.Key]::Enter) {
    $e.Handled = $true
    Send-Input
  }
})

# ---------- 输入框占位文字 ----------
# 独立的 TextBlock 负责显示，规则只有一条：输入框里有字就藏起来。
# 不用焦点事件做状态机 —— 那套实测会翻车（见 XAML 里的注释）。
$placeholderText = $window.FindName('PlaceholderText')
$syncPlaceholder = {
  if ($null -eq $placeholderText) { return }
  $placeholderText.Visibility = if ([string]::IsNullOrEmpty($inputBox.Text)) { 'Visible' } else { 'Hidden' }
}
$inputBox.Add_TextChanged({ & $syncPlaceholder })
& $syncPlaceholder

# ---------- 读 queue ----------
# ⚠ 必须显式指定 UTF8：PowerShell 5.1 的 Get-Content 默认按系统 ANSI(GBK) 解码，
#   而 queue.jsonl 是 UTF-8。不指定的话，中文消息在气泡里会变成乱码
#   （2026-10-11 实测：气泡显示「鍗婃埅琛屽厛钀界洏」）。
function Read-QueueLines {
  try {
    if (-not (Test-Path -LiteralPath $queuePath)) { return @() }
    return @(Get-Content -LiteralPath $queuePath -Encoding UTF8 -ErrorAction SilentlyContinue)
  } catch { return @() }
}

# ---------- 轮询 queue.jsonl ----------
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($PollMs)
$timer.Add_Tick({
  try {
    if (-not (Test-Path -LiteralPath $queuePath)) { return }
    $lines = Read-QueueLines
    # 🔴 2026-10-11 实测踩到：已读行号记在内存里，如果文件被**重写变短**
    # （清空重来、切换会话、手工编辑），行数会一直 <= 已读行号，
    # 窗口就永远不再读新内容 —— 表现为"写了话它不理你"。
    # 所以行数倒退就认定为"文件被重写了"，从头读一遍。
    if ($lines.Count -lt $script:lastQueueLine) {
      Write-Log ("queue 被重写了（" + $script:lastQueueLine + " → " + $lines.Count + " 行），重置读取位置")
      $script:lastQueueLine = 0
    }
    if ($lines.Count -le $script:lastQueueLine) { return }
    # 解析失败就停下、不推进位置，下一轮从这一行重来。
    # ⚠ 以前这里是"跳过坏行、位置照样推到文件末尾"，而我留的日志却写着"下一轮会重试" ——
    #   注释和行为不一致，结果一条正好撞上写入瞬间的消息会被**永久丢掉**（2026-10-11 实测）。
    for ($i = $script:lastQueueLine; $i -lt $lines.Count; $i++) {
      $raw = $lines[$i]
      if ([string]::IsNullOrWhiteSpace($raw)) { $script:lastQueueLine = $i + 1; continue }
      $parsed = $null
      try { $parsed = $raw | ConvertFrom-Json } catch { $parsed = $null }
      if ($null -eq $parsed) {
        # 先当"正撞上写入"等一轮（这是 2026-10-11 那条原意：不能丢消息）。
        # 🔴 但 2026-10-12 实测到另一半风险：**一条永久坏的 JSON 会把整条队列堵死** ——
        #   我在文本里裸打了一个双引号，从此窗口再也不显示任何新消息，而且它每轮都
        #   重试同一行、日志只有一句"下一轮重来"。所以现在加一道期限：
        #   同一行连续失败 3 次就认定是坏行，跳过并大声记一笔，别让它拖住后面的消息。
        if ($script:badLine -eq $i) { $script:badLineTries++ } else { $script:badLine = $i; $script:badLineTries = 1 }
        if ($script:badLineTries -lt 3) {
          Write-Log ("queue 第 " + ($i + 1) + " 行暂时解析不了（大概正撞上写入），这一轮停在这里，下一轮重来")
          break
        }
        Write-Log ("queue 第 " + ($i + 1) + " 行连续 " + $script:badLineTries + " 次解析不了，认定是坏行，跳过它：" + $raw)
        $script:lastQueueLine = $i + 1
        $script:badLine = -1
        $script:badLineTries = 0
        continue
      }
      $script:badLine = -1
      $script:badLineTries = 0
      if ($parsed.text) {
        $t = [string]$parsed.text
        Add-Line 'me' $t
        # 记一行"读到了什么"，方便事后确认消息真的进了窗口，而不是只看进程没崩
        Write-Log ("读到 queue 第 " + ($i + 1) + " 行：" + $t.Substring(0, [Math]::Min(24, $t.Length)))
      }
      $script:lastQueueLine = $i + 1
    }
  } catch { Write-Log "轮询失败：$($_.Exception.Message)" }
})
$timer.Start()

# ---------- 心跳：定期刷新存活标记 ----------
# 插件靠这个文件的 at 时间判断"窗口还在不在"，所以必须一直刷。
# 3 秒一次、过期判据 30 秒 —— 留了足够余量，偶尔一次写失败也不会被误判成死亡。
$heartbeat = New-Object System.Windows.Threading.DispatcherTimer
$heartbeat.Interval = [TimeSpan]::FromSeconds(3)
$heartbeat.Add_Tick({
  Write-WindowLock
  # 🔴 顺手做"位置自愈"（2026-10-12 用户说"对话框模组好像不见了"）：
  #   实测窗口被拖到 left=1675 top=1021、只剩 11 像素露在屏幕边，
  #   看起来就是"消失了"。启动时夹一次不够 —— 运行中也可能被拖出去，
  #   所以每 3 秒检查一次：几乎全在屏幕外就拉回右下角。
  try {
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = $window.ActualWidth; if (-not $w) { $w = 330 }
    $h = $window.ActualHeight; if (-not $h) { $h = 430 }
    $visibleX = [Math]::Min($window.Left + $w, $area.Right) - [Math]::Max($window.Left, $area.Left)
    $visibleY = [Math]::Min($window.Top + $h, $area.Bottom) - [Math]::Max($window.Top, $area.Top)
    # 判据：底下或右边被切掉超过 20 像素就拉回来 —— 因为**输入框在最底下**，
    # 窗口下沿被切掉就等于"能看不能说话"（2026-10-12 实测：top=867 时输入框整条看不见）。
    if ($visibleX -lt ($w - 20) -or $visibleY -lt ($h - 20) -or $visibleX -lt 60 -or $visibleY -lt 40) {
      $window.Left = $area.Right - $w - 12
      $window.Top  = $area.Bottom - $h - 12
      Write-Log ("位置自愈：原本几乎在屏幕外（可见 " + [int]$visibleX + "×" + [int]$visibleY + "），已拉回 " + [int]$window.Left + "," + [int]$window.Top)
    }
  } catch { }
})
$heartbeat.Start()

# ---------- 滚动侦察（-DebugScroll 才开） ----------
# 为什么留着它：滚轮到底有没有到达窗口、"追加内容"有没有把滚动位置弹走，
# 光看画面是判断不了的（2026-10-11 排查时就是靠这几行日志看清 offset 的变化）。
if ($DebugScroll) {
  $window.Add_PreviewMouseWheel({
    param($sender, $e)
    Write-Log ("滚轮到达窗口层：delta=" + $e.Delta + " offset=" + [math]::Round($bubbleText.VerticalOffset))
  })
  $bubbleText.Add_PreviewMouseWheel({
    param($sender, $e)
    Write-Log ("滚轮到达气泡层：delta=" + $e.Delta + " offset=" + [math]::Round($bubbleText.VerticalOffset))
  })
  $scrollWatch = New-Object System.Windows.Threading.DispatcherTimer
  $scrollWatch.Interval = [TimeSpan]::FromSeconds(2)
  $scrollWatch.Add_Tick({
    Write-Log ("位置轮询：offset=" + [math]::Round($bubbleText.VerticalOffset) + " viewport=" + [math]::Round($bubbleText.ViewportHeight) + " extent=" + [math]::Round($bubbleText.ExtentHeight) + " blocks=" + $bubbleText.Document.Blocks.Count)
  })
  $scrollWatch.Start()
  Write-Log '滚动侦察已开启（-DebugScroll）'
}

# 首屏：把 inbox + queue 的聊天记录合起来铺进气泡（而不是只剩最后两句）。
# 铺完把已读行号推到 queue 末尾，免得下一轮轮询把同样的消息再加一遍。
try {
  Load-History
  $script:lastQueueLine = (Read-QueueLines).Count
} catch { Write-Log "首屏加载失败：$($_.Exception.Message)" }

# ---------- 首屏滚到底：要补几次，不能只叫一次 ----------
# ShowDialog 之前还没排版，ScrollToEnd 是空喊；而 Loaded 这一轮里 FlowDocument 也未必
# 量完了 —— 2026-10-11 在**真窗口**上实测：只滚一次会停在 offset=950，而真正到底要 990。
# 后果有两层：① 最新那条看不见；② "停在底部"判成 false，新消息就再也不自动跟下来。
# 所以起来后 1.8 秒内每 300ms 补滚一次；用户一开始自己滚就立刻停手（别跟他抢）。
$script:userScrolled = $false
$script:settleTicks = 0
$settleTimer = New-Object System.Windows.Threading.DispatcherTimer
$settleTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$settleTimer.Add_Tick({
  $script:settleTicks += 1
  if (-not $script:userScrolled) { try { $bubbleText.ScrollToEnd() } catch { } }
  if ($script:settleTicks -ge 6 -or $script:userScrolled) { $settleTimer.Stop() }
})
$bubbleText.Add_PreviewMouseWheel({
  param($sender, $e)
  $script:userScrolled = $true
})
$window.Add_Loaded({ $settleTimer.Start() })

# 关闭时存位置。心跳不用手动清：进程一走 at 就不再刷新，
# 插件那边 30 秒后自然判定为"窗口没了"（用时间判活就不用担心清理失败）。
$window.Add_Closed({ Save-Position; Write-Log '窗口关闭' })

# ---------- 自检：起来几秒后自己关 ----------
if ($SelfTest) {
  $closeTimer = New-Object System.Windows.Threading.DispatcherTimer
  $closeTimer.Interval = [TimeSpan]::FromSeconds(6)
  $closeTimer.Add_Tick({ $closeTimer.Stop(); $window.Close() })
  $closeTimer.Start()
  Write-Log '自检模式：6 秒后自动关闭'
}

Write-Log "窗口已显示（Left=$winLeft Top=$winTop）"
[void]$window.ShowDialog()
Write-Log '进程退出'
