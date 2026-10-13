# dsh-float-lamp widget — 独立置顶悬浮状态灯。
# 轮询 ~/.dsh/float-lamp/state.json，渲染四色灯（静态色，无闪烁动画）：
#   绿 running / 橙 approval / 蓝 question / 灰 idle；宿主失联显示暗灰“宿主离线”，
#   离线持续 60 秒自动退出。
# 左键拖动移动（位置记忆），右键菜单：置顶开关 / 退出。单实例（互斥锁）。
# 鼠标悬停：显示当前任务信息（每会话一行：状态 + 最近用户消息 + 正在执行的工具）。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = New-Object System.Threading.Mutex($false, 'dsh-float-lamp-widget')
if (-not $mutex.WaitOne(0)) { exit 0 }

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

# ---- 窗体 ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'dsh-float-lamp'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.BackColor = [System.Drawing.Color]::FromArgb(22, 26, 35)
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.Opacity = 0.96
$form.Size = New-Object System.Drawing.Size(184, 96)
$form.Cursor = [System.Windows.Forms.Cursors]::Hand

# 圆角
$path = New-Object System.Drawing.Drawing2D.GraphicsPath
$r = 16
$d = $r * 2
$path.AddArc(0, 0, $d, $d, 180, 90)
$path.AddArc($form.Width - 1 - $d, 0, $d, $d, 270, 90)
$path.AddArc($form.Width - 1 - $d, $form.Height - 1 - $d, $d, $d, 0, 90)
$path.AddArc(0, $form.Height - 1 - $d, $d, $d, 90, 90)
$path.CloseFigure()
$form.Region = New-Object System.Drawing.Region($path)
$script:path = $path

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
$tipForm.Opacity = 0.98
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

function Update-LampTip {
  if ($script:tipText -eq '') { $tipForm.Hide(); return }
  $tipLabel.Text = $script:tipText
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
  $p2 = New-Object System.Drawing.Drawing2D.GraphicsPath
  $rr = 10; $dd = $rr * 2
  $p2.AddArc(0, 0, $dd, $dd, 180, 90)
  $p2.AddArc($w - 1 - $dd, 0, $dd, $dd, 270, 90)
  $p2.AddArc($w - 1 - $dd, $h - 1 - $dd, $dd, $dd, 0, 90)
  $p2.AddArc(0, $h - 1 - $dd, $dd, $dd, 90, 90)
  $p2.CloseFigure()
  $tipForm.Region = New-Object System.Drawing.Region($p2)
  $p2.Dispose()
  $x = $form.Left - $w - 8
  if ($x -lt $wa.Left) { $x = $form.Right + 8 }
  if ($x -gt ($wa.Right - $w)) { $x = $wa.Right - $w }
  $y = $form.Top
  if ($y -gt ($wa.Bottom - $h)) { $y = $wa.Bottom - $h }
  if ($y -lt $wa.Top) { $y = $wa.Top }
  $tipForm.Location = New-Object System.Drawing.Point($x, $y)
  $tipForm.Show($form)
  $tipForm.Invalidate()
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

# ---- 轮询 ----
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 400
$script:lastRender = ''
$script:offlineSince = $null
$timer.Add_Tick({
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
    if (($nowMs - [double]$s.updatedAt) -gt 15000) {
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
  # 只在显示内容变化时重绘（避免每 tick 重绘导致的闪烁）
  $key = "$($script:state)|$($script:detail)"
  if ($key -ne $script:lastRender) {
    $script:lastRender = $key
    $form.Invalidate()
  }
})
$timer.Start()

# ---- 绘制 ----
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$grayText = [System.Drawing.Color]::FromArgb(156, 163, 175)

$form.Add_Paint({
  $g = $args[1].Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  # 边框
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 120, 130, 145), 1)
  $g.DrawPath($pen, $script:path)
  $pen.Dispose()

  $base = $colors[$script:state]
  $alpha = 255
  if ($script:state -eq 'idle') { $alpha = 175 }
  if ($script:state -eq 'offline') { $alpha = 120 }

  $cx = 46; $cy = 48; $cr = 19
  # 光晕
  for ($i = 3; $i -ge 1; $i--) {
    $gr = $cr + 6 * $i
    $ga = [int](14 * $i * ($alpha / 255.0))
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ga, $base.R, $base.G, $base.B))
    $g.FillEllipse($b, ($cx - $gr), ($cy - $gr), ($gr * 2), ($gr * 2))
    $b.Dispose()
  }
  # 灯芯
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, $base.R, $base.G, $base.B))
  $g.FillEllipse($b, ($cx - $cr), ($cy - $cr), ($cr * 2), ($cr * 2))
  $b.Dispose()
  # 高光
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int](70 * ($alpha / 255.0)), 255, 255, 255))
  $g.FillEllipse($b, ($cx - 9), ($cy - 12), 12, 9)
  $b.Dispose()

  # 文字
  $label = $labels[$script:state]
  $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter
  [System.Windows.Forms.TextRenderer]::DrawText($g, $label, $fontTitle,
    (New-Object System.Drawing.Rectangle(80, 20, 96, 24)),
    [System.Drawing.Color]::White, $flags)
  if ($script:detail -ne '') {
    [System.Windows.Forms.TextRenderer]::DrawText($g, $script:detail, $fontSmall,
      (New-Object System.Drawing.Rectangle(80, 48, 100, 18)),
      $grayText, [System.Windows.Forms.TextFormatFlags]::Left)
  }
})

$form.Add_FormClosed({
  $timer.Dispose()
  $tipTimer.Dispose()
  try { $tipForm.Close() } catch { }
  try { $mutex.ReleaseMutex() } catch { }
  $mutex.Dispose()
})

[System.Windows.Forms.Application]::Run($form)
