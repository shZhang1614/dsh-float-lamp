# dsh-float-lamp widget — 独立置顶悬浮状态灯（极简发光版，无卡片背景）。
# 轮询 ~/.dsh/float-lamp/state.json，渲染发光圆形灯 + 文字，背景完全透明：
#   绿 running：灯体静止，周围光晕呼吸（忽亮忽暗 + 轻微涨缩）
#   橙 approval：左右紧张抖动（灯体不伸缩）
#   蓝 question：上下漂浮
#   灰 idle：静止、半透明
#   暗灰 offline：静止、更暗；离线持续 60 秒自动退出
# 动画 50ms/帧（20fps），仅在 running/approval/question 时运行，静止状态不耗 CPU。
# 背景用分层窗口（UpdateLayeredWindow）每像素 alpha 抠除：只有灯、光晕和带描边的文字可见，
# 无卡片方框；抗锯齿边缘与桌面平滑混合，无黑边、无锯齿。
# 左键拖动移动（位置记忆），右键菜单：置顶开关 / 退出。单实例（互斥锁）。
# 鼠标悬停：显示当前任务信息（每会话一行：状态 + 最近用户消息 + 正在执行的工具）。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 分层窗口（per-pixel alpha）P/Invoke：边缘抗锯齿与桌面平滑混合
Add-Type -Namespace Win32 -Name LW -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct SIZE { public int cx; public int cy; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, Pack = 1)]
public struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool UpdateLayeredWindow(System.IntPtr hwnd, System.IntPtr hdcDst, ref POINT ppt, ref SIZE psize, System.IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr hwnd, int index);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int SetWindowLong(System.IntPtr hwnd, int index, int newStyle);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindowDC(System.IntPtr hwnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int ReleaseDC(System.IntPtr hwnd, System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern System.IntPtr CreateCompatibleDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern bool DeleteDC(System.IntPtr hdc);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern System.IntPtr SelectObject(System.IntPtr hdc, System.IntPtr h);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern bool DeleteObject(System.IntPtr h);
'@

# 通用：把 32bpp 预乘 alpha 位图推给分层窗口
function Push-Layered {
  param($win, $bmp)
  $w = $bmp.Width; $h = $bmp.Height
  $hBmp = $bmp.GetHbitmap([System.Drawing.Color]::FromArgb(0))
  $hdcDst = [Win32.LW]::GetWindowDC($win.Handle)
  $hdcSrc = [Win32.LW]::CreateCompatibleDC($hdcDst)
  $old = [Win32.LW]::SelectObject($hdcSrc, $hBmp)
  $ppt = New-Object Win32.LW+POINT; $ppt.X = $win.Left; $ppt.Y = $win.Top
  $pptSrc = New-Object Win32.LW+POINT
  $psize = New-Object Win32.LW+SIZE; $psize.cx = $w; $psize.cy = $h
  $blend = New-Object Win32.LW+BLENDFUNCTION
  $blend.BlendOp = 0; $blend.BlendFlags = 0; $blend.SourceConstantAlpha = 255; $blend.AlphaFormat = 1
  $ok = [Win32.LW]::UpdateLayeredWindow($win.Handle, $hdcDst, [ref]$ppt, [ref]$psize, $hdcSrc, [ref]$pptSrc, 0, [ref]$blend, 2)
  [void][Win32.LW]::SelectObject($hdcSrc, $old)
  [void][Win32.LW]::DeleteObject($hBmp)
  [void][Win32.LW]::DeleteDC($hdcSrc)
  [void][Win32.LW]::ReleaseDC($win.Handle, $hdcDst)
  if (-not $ok) { throw ('UpdateLayeredWindow failed: ' + [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()) }
}

$mutexName = 'dsh-float-lamp-widget'
if ($env:DSH_LAMP_TAG) { $mutexName += "-$env:DSH_LAMP_TAG" }   # 测试实例用不同锁名，可与正式灯并存
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
$acquired = $false
try { $acquired = $mutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $acquired = $true }  # 上一个实例被强杀，锁已归我
if (-not $acquired) { exit 0 }

$dir = if ($env:DSH_LAMP_DIR) { $env:DSH_LAMP_DIR } else { Join-Path $env:USERPROFILE '.dsh\float-lamp' }
$stateFile = Join-Path $dir 'state.json'
$posFile = Join-Path $dir 'pos.json'
try { "$PID" | Set-Content (Join-Path $dir 'lamp.pid') -Encoding ASCII } catch { }

# ---- 状态定义 ----
$colors = @{
  running  = [System.Drawing.Color]::FromArgb(34, 197, 94)
  approval = [System.Drawing.Color]::FromArgb(249, 115, 22)
  question = [System.Drawing.Color]::FromArgb(59, 130, 246)
  idle     = [System.Drawing.Color]::FromArgb(107, 114, 128)
  offline  = [System.Drawing.Color]::FromArgb(72, 76, 86)
}
$labels = @{
  running = '运行中'; approval = '待授权'; question = '待交互'
  idle = '空闲'; offline = '宿主离线'
}
$script:state = 'idle'
$script:detail = ''
$script:topMost = $true
$script:phase = 0.0

# ---- 窗体（无卡片背景：分层窗口 per-pixel alpha，渲染失败时回退纯黑透明键） ----
$KEY = [System.Drawing.Color]::FromArgb(0, 0, 0)
$form = New-Object System.Windows.Forms.Form
$form.Text = 'dsh-float-lamp'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor = $KEY
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Size = New-Object System.Drawing.Size(184, 96)
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

# 初始位置：主屏工作区右上角（或恢复记忆位置）
$wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$px = $wa.Right - $form.Width - 24
$py = $wa.Top + 24
if (Test-Path $posFile) {
  try {
    $p = Get-Content $posFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($p.x -lt ($wa.Right - 40) -and $p.x -gt ($wa.Left - $form.Width + 40) -and $p.y -lt ($wa.Bottom - 40) -and $p.y -gt ($wa.Top - 40)) {
      $px = [int]$p.x; $py = [int]$p.y
    }
  } catch { }
}
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Location = New-Object System.Drawing.Point($px, $py)

# ---- 右键菜单 ----
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miTop = $menu.Items.Add('取消置顶')
$miExit = $menu.Items.Add('退出')
$miTop.Add_Click({
  $script:topMost = -not $script:topMost
  $form.TopMost = $script:topMost
  if ($script:topMost) { $miTop.Text = '取消置顶' } else { $miTop.Text = '恢复置顶' }
})
$miExit.Add_Click({ $form.Close() })

# ---- 悬停提示（自定义弹出卡片，不抢焦点） ----
Add-Type -TypeDefinition @'
using System.Windows.Forms;
public class LampTipForm : Form {
  protected override bool ShowWithoutActivation { get { return true; } }
}
'@ -ReferencedAssemblies System.Windows.Forms
$fontTip = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$tipForm = New-Object LampTipForm
$tipForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$tipForm.BackColor = [System.Drawing.Color]::FromArgb(22, 26, 35)
$tipForm.ShowInTaskbar = $false
$tipForm.TopMost = $true
$tipForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$tipForm.Size = New-Object System.Drawing.Size(320, 60)
$tipLabel = New-Object System.Windows.Forms.Label
$tipLabel.AutoSize = $false
$tipLabel.BackColor = [System.Drawing.Color]::Transparent
$tipLabel.ForeColor = [System.Drawing.Color]::FromArgb(230, 234, 242)
$tipLabel.Font = $fontTip
$tipLabel.UseMnemonic = $false
$tipForm.Controls.Add($tipLabel)
$tipForm.Add_Paint({
  $g2 = $args[1].Graphics
  $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(140, 120, 130, 145), 1)
  $g2.DrawRectangle($pen2, 0, 0, ($tipForm.Width - 1), ($tipForm.Height - 1))
  $pen2.Dispose()
})
$script:tipText = ''
$script:tipLayered = $false

function New-RoundedPath {
  param($w, $h, $rr)
  $p2 = New-Object System.Drawing.Drawing2D.GraphicsPath
  $dd = $rr * 2
  $p2.AddArc(0, 0, $dd, $dd, 180, 90)
  $p2.AddArc($w - 1 - $dd, 0, $dd, $dd, 270, 90)
  $p2.AddArc($w - 1 - $dd, $h - 1 - $dd, $dd, $dd, 0, 90)
  $p2.AddArc(0, $h - 1 - $dd, $dd, $dd, 90, 90)
  $p2.CloseFigure()
  return $p2
}

# 卡片走分层窗口：圆角与文字抗锯齿、与桌面平滑混合
function Render-Tip {
  if (-not $script:tipLayered) { return }
  try {
    $w = $tipForm.Width; $h = $tipForm.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $p2 = New-RoundedPath $w $h 10
    $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 22, 26, 35))
    $g.FillPath($fill, $p2)
    $fill.Dispose()
    $pen2 = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 120, 130, 145), 1)
    $g.DrawPath($pen2, $p2)
    $pen2.Dispose()
    $p2.Dispose()
    $tb = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, 234, 242))
    $yOff = 10
    foreach ($ln in ($script:tipText -split "`n")) {
      $rect = New-Object System.Drawing.RectangleF(12, $yOff, ($w - 24), 2000)
      $g.DrawString($ln, $fontTip, $tb, $rect)
      $szl = [System.Windows.Forms.TextRenderer]::MeasureText($ln, $fontTip,
        (New-Object System.Drawing.Size(($w - 24), 2000)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
      $yOff += $szl.Height
    }
    $tb.Dispose()
    $g.Dispose()
    Push-Layered $tipForm $bmp
    $bmp.Dispose()
  } catch {
    $script:tipLayered = $false
    $tipLabel.Visible = $true
    Update-TipRegion
    $tipForm.Invalidate()
  }
}

function Update-TipRegion {
  $p2 = New-RoundedPath $tipForm.Width $tipForm.Height 10
  $tipForm.Region = New-Object System.Drawing.Region($p2)
  $p2.Dispose()
}

function Update-LampTip {
  if ($script:tipText -eq '') { $tipForm.Hide(); return }
  # 逐行测量再求和：TextRenderer 对多行串会少算最后一行高度，导致末行被裁掉
  $tw = 0; $th = 0
  foreach ($ln in ($script:tipText -split "`n")) {
    $szl = [System.Windows.Forms.TextRenderer]::MeasureText($ln, $fontTip,
      (New-Object System.Drawing.Size(340, 2000)), [System.Windows.Forms.TextFormatFlags]::WordBreak)
    if ($szl.Width -gt $tw) { $tw = $szl.Width }
    $th += $szl.Height
  }
  $w = [Math]::Min(380, $tw + 24)
  if ($w -lt 120) { $w = 120 }
  $h = $th + 26
  $tipForm.Size = New-Object System.Drawing.Size($w, $h)
  $tipLabel.Location = New-Object System.Drawing.Point(12, 10)
  $tipLabel.Size = New-Object System.Drawing.Size(($w - 24), ($h - 26))
  $x = $form.Left - $w - 8
  if ($x -lt $wa.Left) { $x = $form.Right + 8 }
  if ($x -gt ($wa.Right - $w)) { $x = $wa.Right - $w }
  $y = $form.Top
  if ($y -gt ($wa.Bottom - $h)) { $y = $wa.Bottom - $h }
  if ($y -lt $wa.Top) { $y = $wa.Top }
  $tipForm.Location = New-Object System.Drawing.Point($x, $y)
  if (-not $tipForm.Visible) { $tipForm.Show($form) }
  if (-not $script:tipLayered) {
    try {
      $ex = [Win32.LW]::GetWindowLong($tipForm.Handle, -20)
      [void][Win32.LW]::SetWindowLong($tipForm.Handle, -20, ($ex -bor 0x80000))
      $script:tipLayered = $true
      $tipLabel.Text = $script:tipText
      $tipLabel.Visible = $false
    } catch {
      $script:tipLayered = $false
      $tipLabel.Text = $script:tipText
      $tipLabel.Visible = $true
      Update-TipRegion
    }
  } else {
    $tipLabel.Text = $script:tipText
    $tipLabel.Visible = $false
  }
  Render-Tip
  if (-not $script:tipLayered) { $tipForm.Invalidate() }
}
$tipTimer = New-Object System.Windows.Forms.Timer
$tipTimer.Interval = 300
$tipTimer.Add_Tick({ $tipTimer.Stop(); if (-not $script:dragging) { Update-LampTip } })

# ---- 拖动 ----
$script:dragging = $false
$script:dragOff = New-Object System.Drawing.Point(0, 0)
$form.Add_MouseDown({
  $e = $args[1]
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
    $script:dragging = $true
    $tipTimer.Stop()
    if ($tipForm.Visible) { $tipForm.Hide() }
    $mp = [System.Windows.Forms.Cursor]::Position
    $script:dragOff = New-Object System.Drawing.Point(($mp.X - $form.Left), ($mp.Y - $form.Top))
  } elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
    $menu.Show($form, [int]$e.X, [int]$e.Y)
  }
})
$form.Add_MouseMove({
  if ($script:dragging) {
    $mp = [System.Windows.Forms.Cursor]::Position
    $form.Location = New-Object System.Drawing.Point(($mp.X - $script:dragOff.X), ($mp.Y - $script:dragOff.Y))
  }
})
$form.Add_MouseUp({
  if ($script:dragging) {
    $script:dragging = $false
    try {
      "{`"x`":$($form.Left),`"y`":$($form.Top)}" | Set-Content $posFile -Encoding UTF8
    } catch { }
  }
})
$form.Add_MouseEnter({ if (-not $script:dragging) { $tipTimer.Start() } })
$form.Add_MouseLeave({ $tipTimer.Stop(); if ($tipForm.Visible) { $tipForm.Hide() } })

# ---- 状态轮询 ----
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$script:lastRender = ''
$script:offlineSince = $null
$timer.Add_Tick({
 try {
  $nowMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  $s = $null
  try {
    if (Test-Path $stateFile) {
      $s = Get-Content $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    }
  } catch { }
  $offline = $false
  $newTip = ''
  if ($null -eq $s -or $s.hostDown) {
    $script:state = 'offline'
    $script:detail = ''
    $newTip = '无法连接 DeepSeek Harness 宿主'
    $offline = $true
  } else {
    $ts = 0.0
    if (-not [double]::TryParse([string]$s.updatedAt, [ref]$ts)) { $ts = 0 }
    if (($nowMs - $ts) -gt 15000) {
      $script:state = 'offline'
      $script:detail = ''
      $newTip = '无法连接 DeepSeek Harness 宿主'
      $offline = $true
    } else {
      $script:state = [string]$s.state
      $c = $s.counts
      $parts = @()
      if ($c.running -gt 0) { $parts += "运行 $($c.running)" }
      if ($c.approval -gt 0) { $parts += "授权 $($c.approval)" }
      if ($c.question -gt 0) { $parts += "交互 $($c.question)" }
      $script:detail = ($parts -join ' · ')
      # 悬停内容：每个会话一行任务信息
      $lines = @()
      foreach ($t in @($s.tasks)) {
        if ($null -eq $t) { continue }
        $tag = $labels[[string]$t.state]
        if (-not $tag) { $tag = [string]$t.state }
        $line = "[$tag] $([string]$t.title)"
        if ($t.tool) { $line += "（正在: $([string]$t.tool)）" }
        $lines += $line
      }
      if ($lines.Count -eq 0) { $lines = @('当前没有任务') }
      $newTip = $lines -join "`n"
    }
  }
  if ($newTip -ne $script:tipText) {
    $script:tipText = $newTip
    if ($tipForm.Visible) { Update-LampTip }
  }
  if ($env:DSH_LAMP_TEST_TIP -eq '1' -and -not $script:testTipShown) {
    $script:testTipShown = $true
    Update-LampTip
  }
  if ($offline) {
    if ($null -eq $script:offlineSince) { $script:offlineSince = $nowMs }
    elseif (($nowMs - $script:offlineSince) -gt 60000) { $form.Close(); return }
  } else {
    $script:offlineSince = $null
  }
  # 动画开关：只有 running/approval/question 需要逐帧动画
  if ($script:state -in @('running', 'approval', 'question')) {
    if (-not $animTimer.Enabled) { $animTimer.Start() }
  } else {
    if ($animTimer.Enabled) { $animTimer.Stop() }
    # 静止状态：只在显示内容变化时重绘（避免每 tick 重绘导致闪烁）
    $key = "$($script:state)|$($script:detail)"
    if ($key -ne $script:lastRender) {
      $script:lastRender = $key
      Render-Lamp
      if (-not $script:layered) { $form.Invalidate() }
    }
  }
 } catch { }
})
$timer.Start()

# ---- 动画时钟（20fps，仅动画状态运行） ----
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$animTimer.Add_Tick({
  $script:phase += 0.28
  if ($script:layered) { Render-Lamp } else { $form.Invalidate() }
})

# ---- 绘制 ----
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$grayText = [System.Drawing.Color]::FromArgb(190, 197, 205)
$outlineColor = [System.Drawing.Color]::FromArgb(12, 15, 20)

# 带暗色描边的文字：任何桌面背景下都可读（背景已完全透明）
function Draw-OutlinedText {
  param($g, [string]$text, $font, [single]$x, [single]$y, $color)
  $b = New-Object System.Drawing.SolidBrush($outlineColor)
  foreach ($dx in -1, 0, 1) {
    foreach ($dy in -1, 0, 1) {
      if ($dx -eq 0 -and $dy -eq 0) { continue }
      $g.DrawString($text, $font, $b, ($x + $dx), ($y + $dy))
    }
  }
  $b.Dispose()
  $b = New-Object System.Drawing.SolidBrush($color)
  $g.DrawString($text, $font, $b, $x, $y)
  $b.Dispose()
}

function Draw-LampContent {
  param($g)
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::GammaCorrected
  $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
  $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

  $st = $script:state
  $base = $colors[$st]
  $alpha = 255
  if ($st -eq 'idle') { $alpha = 175 }
  if ($st -eq 'offline') { $alpha = 120 }

  # ---- 动画参数（按状态） ----
  $p = $script:phase
  $sx = 1.0; $sy = 1.0; $bobX = 0.0; $bobY = 0.0
  $glowF = 1.0; $glowR = 0.0
  switch ($st) {
    'running' {
      # 光晕呼吸：忽亮忽暗（alpha 涨落）+ 光圈轻微涨缩，灯体保持静止
      $gp = 0.5 + 0.5 * [Math]::Sin($p * 1.4)
      $glowF = 0.30 + 1.05 * $gp
      $glowR = 3.0 * $gp
    }
    'approval' {
      # 紧张抖动：左右小幅晃动，灯体不伸缩
      $bobX = 2.4 * [Math]::Sin($p * 1.7)
    }
    'question' {
      # 上下漂浮
      $bobY = -2.4 * (0.5 + 0.5 * [Math]::Sin($p * 0.9))
    }
  }

  $cx = 46; $cy = 48; $cr = 19
  $rx = $cr * $sx; $ry = $cr * $sy
  # 底部锚定：伸缩时灯的底边不动，顶部伸缩
  $cyc = $cy + ($cr - $ry) + $bobY
  $cx2 = $cx + $bobX

  # 光晕：10 层平滑衰减（alpha 按二次方从内到外递减），running 时随呼吸忽亮忽暗
  for ($i = 10; $i -ge 1; $i--) {
    $t = $i / 10.0
    $grx = $rx + 18 * $t + $glowR; $gry = $ry + 18 * $t + $glowR
    $ga = [int](54 * (1 - $t) * (1 - $t) * ($alpha / 255.0) * $glowF)
    if ($ga -le 0) { continue }
    if ($ga -gt 255) { $ga = 255 }
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ga, $base.R, $base.G, $base.B))
    $g.FillEllipse($b, ($cx2 - $grx), ($cyc - $gry), ($grx * 2), ($gry * 2))
    $b.Dispose()
  }
  # 灯芯
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, $base.R, $base.G, $base.B))
  $g.FillEllipse($b, ($cx2 - $rx), ($cyc - $ry), ($rx * 2), ($ry * 2))
  $b.Dispose()
  # 高光
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int](70 * ($alpha / 255.0)), 255, 255, 255))
  $g.FillEllipse($b, ($cx2 - 0.48 * $rx), ($cyc - 0.66 * $ry), (0.62 * $rx), (0.46 * $ry))
  $b.Dispose()

  # 文字（带描边，无卡片背景）
  Draw-OutlinedText $g $labels[$st] $fontTitle ([single]80) ([single]22) ([System.Drawing.Color]::White)
  if ($script:detail -ne '') {
    Draw-OutlinedText $g $script:detail $fontSmall ([single]80) ([single]50) $grayText
  }
}

# 回退路径：ULW 不可用时走传统 WM_PAINT + 纯黑透明键
$form.Add_Paint({
  if (-not $script:layered) {
    if ($form.TransparencyKey -ne $KEY) { $form.TransparencyKey = $KEY }
    Draw-LampContent $args[1].Graphics
  }
})

# ---- 分层窗口渲染：32bpp 预乘 alpha 位图 → UpdateLayeredWindow，边缘与桌面平滑混合 ----
$script:layered = $false
function Render-Lamp {
  if (-not $script:layered) { return }
  try {
    $w = $form.Width; $h = $form.Height
    $bmp = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppPArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    Draw-LampContent $g
    $g.Dispose()
    Push-Layered $form $bmp
    $bmp.Dispose()
  } catch {
    # 降级：回到透明键模式（旧渲染路径）
    $script:layered = $false
    $form.TransparencyKey = $KEY
    $form.Invalidate()
  }
}

$form.Add_Shown({
  try {
    $ex = [Win32.LW]::GetWindowLong($form.Handle, -20)   # GWL_EXSTYLE
    [void][Win32.LW]::SetWindowLong($form.Handle, -20, ($ex -bor 0x80000))  # WS_EX_LAYERED
    $script:layered = $true
  } catch { $script:layered = $false }
  Render-Lamp
})

$form.Add_FormClosed({
  $timer.Dispose()
  $animTimer.Dispose()
  $tipTimer.Dispose()
  try { $tipForm.Close() } catch { }
  try { $mutex.ReleaseMutex() } catch { }
  try { $mutex.Dispose() } catch { }
})

[System.Windows.Forms.Application]::Run($form)
