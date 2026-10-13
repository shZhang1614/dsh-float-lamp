# dsh-float-lamp widget — 独立置顶悬浮表情状态灯。
# 轮询 ~/.dsh/float-lamp/state.json，渲染带表情的圆形灯：
#   绿 running：笑脸 + 上下弹性伸缩（squash & stretch，底部锚定）+ 眼球左右扫视 + 眨眼
#   橙 approval：担忧脸（八字眉+波浪嘴+汗滴）+ 左右紧张抖动
#   蓝 question：好奇脸（单侧挑眉+歪嘴+头顶 ? 气泡）+ 上下漂浮
#   灰 idle：困倦脸（闭眼弧线+小 o 嘴+Zzz），静止
#   暗灰 offline：X 眼 + 平嘴，静止；离线持续 60 秒自动退出
# 动画 50ms/帧（20fps），仅在 running/approval/question 时运行，静止状态不耗 CPU。
# 左键拖动移动（位置记忆），右键菜单：置顶开关 / 退出。单实例（互斥锁）。
# 鼠标悬停：显示当前任务信息（每会话一行：状态 + 最近用户消息 + 正在执行的工具）。

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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
$script:blinkNext = 0
$script:blinkUntil = 0

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

# ---- 状态轮询 ----
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
  # 动画开关：只有 running/approval/question 需要逐帧动画
  if ($script:state -in @('running', 'approval', 'question')) {
    if (-not $animTimer.Enabled) { $animTimer.Start() }
  } else {
    if ($animTimer.Enabled) { $animTimer.Stop() }
    # 静止状态：只在显示内容变化时重绘（避免每 tick 重绘导致闪烁）
    $key = "$($script:state)|$($script:detail)"
    if ($key -ne $script:lastRender) {
      $script:lastRender = $key
      $form.Invalidate()
    }
  }
})
$timer.Start()

# ---- 动画时钟（20fps，仅动画状态运行） ----
$animTimer = New-Object System.Windows.Forms.Timer
$animTimer.Interval = 50
$animTimer.Add_Tick({
  $script:phase += 0.28
  $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
  if ($now -gt $script:blinkNext) {
    $script:blinkUntil = $now + 130
    $script:blinkNext = $now + 2400 + (Get-Random -Maximum 2600)
  }
  $form.Invalidate()
})

# ---- 绘制 ----
$fontTitle = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$fontSmall = New-Object System.Drawing.Font('Microsoft YaHei UI', 8)
$fontBubble = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$fontZzz = New-Object System.Drawing.Font('Segoe UI', 8, [System.Drawing.FontStyle]::Italic)
$grayText = [System.Drawing.Color]::FromArgb(156, 163, 175)
$faceDark = [System.Drawing.Color]::FromArgb(23, 28, 38)

$form.Add_Paint({
  $g = $args[1].Graphics
  $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

  # 边框
  $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(90, 120, 130, 145), 1)
  $g.DrawPath($pen, $script:path)
  $pen.Dispose()

  $st = $script:state
  $base = $colors[$st]
  $alpha = 255
  if ($st -eq 'idle') { $alpha = 175 }
  if ($st -eq 'offline') { $alpha = 120 }

  # ---- 动画参数（按状态） ----
  $p = $script:phase
  $sx = 1.0; $sy = 1.0; $bobX = 0.0; $bobY = 0.0
  switch ($st) {
    'running' {
      # 上下弹性伸缩：竖向拉伸 + 横向挤压（保体积），底部锚定像弹跳的小球
      $s = [Math]::Sin($p)
      $sy = 1 + 0.16 * $s
      $sx = 1.0 / $sy
      $bobY = -2.5 * [Math]::Max(0, $s)
    }
    'approval' {
      # 紧张抖动：左右小幅晃动 + 轻微压扁
      $s = [Math]::Sin($p * 1.7)
      $sy = 1 + 0.07 * $s
      $sx = 1.0 / $sy
      $bobX = 2.4 * $s
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

  # 光晕（随灯同步伸缩）
  for ($i = 3; $i -ge 1; $i--) {
    $grx = $rx + 6 * $i; $gry = $ry + 6 * $i
    $ga = [int](14 * $i * ($alpha / 255.0))
    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($ga, $base.R, $base.G, $base.B))
    $g.FillEllipse($b, ($cx2 - $grx), ($cyc - $gry), ($grx * 2), ($gry * 2))
    $b.Dispose()
  }
  # 灯芯（表情脸底色）
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($alpha, $base.R, $base.G, $base.B))
  $g.FillEllipse($b, ($cx2 - $rx), ($cyc - $ry), ($rx * 2), ($ry * 2))
  $b.Dispose()
  # 高光
  $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int](70 * ($alpha / 255.0)), 255, 255, 255))
  $g.FillEllipse($b, ($cx2 - 0.48 * $rx), ($cyc - 0.66 * $ry), (0.62 * $rx), (0.46 * $ry))
  $b.Dispose()

  # ---- 表情 ----
  $penFace = New-Object System.Drawing.Pen($faceDark, 2)
  $penFace.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $penFace.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $eyeDX = 0.42 * $rx
  $eyeY = $cyc - 0.30 * $ry
  $ew = 0.34 * $rx; $eh = 0.40 * $ry
  $blinking = ($st -in @('running', 'approval', 'question')) -and
              ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() -lt $script:blinkUntil)

  if ($st -eq 'offline') {
    # X X 眼
    foreach ($side in -1, 1) {
      $ex = $cx2 + $side * $eyeDX
      $g.DrawLine($penFace, ($ex - 3.5), ($eyeY - 3.5), ($ex + 3.5), ($eyeY + 3.5))
      $g.DrawLine($penFace, ($ex - 3.5), ($eyeY + 3.5), ($ex + 3.5), ($eyeY - 3.5))
    }
    # 平嘴
    $g.DrawLine($penFace, ($cx2 - 6), ($cyc + 0.42 * $ry), ($cx2 + 6), ($cyc + 0.42 * $ry))
  } elseif ($st -eq 'idle') {
    # 闭眼（下弯弧线）+ 小 o 嘴 + Zzz
    foreach ($side in -1, 1) {
      $ex = $cx2 + $side * $eyeDX
      $g.DrawArc($penFace, ($ex - $ew / 2), ($eyeY - $eh / 2), $ew, $eh, 200, 140)
    }
    $b = New-Object System.Drawing.SolidBrush($faceDark)
    $g.FillEllipse($b, ($cx2 - 2.5), ($cyc + 0.34 * $ry), 5, 5)
    $b.Dispose()
    $bTxt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 200, 210, 225))
    $g.DrawString('z', $fontZzz, $bTxt, [single]($cx2 + $rx + 1), [single]($cyc - $ry - 4))
    $g.DrawString('Z', $fontZzz, $bTxt, [single]($cx2 + $rx + 7), [single]($cyc - $ry - 12))
    $bTxt.Dispose()
  } elseif ($blinking) {
    # 眨眼：两条横线眼 + 当前状态嘴
    foreach ($side in -1, 1) {
      $ex = $cx2 + $side * $eyeDX
      $g.DrawLine($penFace, ($ex - $ew / 2), $eyeY, ($ex + $ew / 2), $eyeY)
    }
    $g.DrawArc($penFace, ($cx2 - 0.34 * $rx), ($cyc + 0.16 * $ry), (0.68 * $rx), (0.42 * $ry), 20, 140)
  } else {
    # 睁眼：白眼球 + 瞳孔（瞳孔位置按状态：running 扫视 / question 上看 / approval 瞪大）
    $gx = 0.0; $gy = 0.0
    $pupilR = 0.16 * $rx
    if ($st -eq 'running') { $gx = 0.14 * $rx * [Math]::Sin($p * 0.5) }
    if ($st -eq 'question') { $gy = -0.16 * $ry; $pupilR = 0.14 * $rx }
    if ($st -eq 'approval') { $pupilR = 0.19 * $rx }
    foreach ($side in -1, 1) {
      $ex = $cx2 + $side * $eyeDX
      $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
      $g.FillEllipse($b, ($ex - $ew / 2), ($eyeY - $eh / 2), $ew, $eh)
      $b.Dispose()
      $b = New-Object System.Drawing.SolidBrush($faceDark)
      $g.FillEllipse($b, ($ex + $gx - $pupilR), ($eyeY + $gy - $pupilR), ($pupilR * 2), ($pupilR * 2))
      $b.Dispose()
    }
    # 嘴（按状态）
    switch ($st) {
      'running' {
        # 微笑：下半弧
        $g.DrawArc($penFace, ($cx2 - 0.36 * $rx), ($cyc + 0.14 * $ry), (0.72 * $rx), (0.44 * $ry), 20, 140)
      }
      'approval' {
        # 波浪嘴（紧张）
        $my = $cyc + 0.36 * $ry
        $mw = 0.62 * $rx
        $pts = @(
          (New-Object System.Drawing.PointF([single]($cx2 - $mw / 2), [single]$my)),
          (New-Object System.Drawing.PointF([single]($cx2 - $mw / 6), [single]($my - 2.4))),
          (New-Object System.Drawing.PointF([single]($cx2 + $mw / 6), [single]($my + 2.4))),
          (New-Object System.Drawing.PointF([single]($cx2 + $mw / 2), [single]$my))
        )
        $g.DrawLines($penFace, $pts)
        # 八字眉（内端上挑 = 担忧）
        foreach ($side in -1, 1) {
          $ex = $cx2 + $side * $eyeDX
          $inner = $ex - $side * ($ew / 2)
          $outer = $ex + $side * ($ew / 2)
          $g.DrawLine($penFace, [single]$outer, [single]($eyeY - $eh / 2 - 1.5), [single]$inner, [single]($eyeY - $eh / 2 - 4.5))
        }
        # 汗滴
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(210, 150, 205, 250))
        $g.FillEllipse($b, [single]($cx2 + $rx * 0.72), [single]($cyc - $ry * 0.95), [single]4.5, [single]6.5)
        $b.Dispose()
      }
      'question' {
        # 歪嘴微笑（偏右）+ 左侧挑眉
        $g.DrawArc($penFace, ($cx2 - 0.10 * $rx), ($cyc + 0.18 * $ry), (0.52 * $rx), (0.36 * $ry), 20, 140)
        $exL = $cx2 - $eyeDX
        $g.DrawLine($penFace, [single]($exL - $ew / 2), [single]($eyeY - $eh / 2 - 5), [single]($exL + $ew / 2), [single]($eyeY - $eh / 2 - 7))
        # 头顶 ? 气泡（随漂浮上下动）
        $bx = $cx2 + $rx * 0.85; $by = $cyc - $ry * 1.35
        $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(230, $base.R, $base.G, $base.B))
        $g.FillEllipse($b, [single]($bx - 7), [single]($by - 7), [single]14, [single]14)
        $b.Dispose()
        $bTxt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
        $g.DrawString('?', $fontBubble, $bTxt, [single]($bx - 4), [single]($by - 8))
        $bTxt.Dispose()
      }
    }
  }
  $penFace.Dispose()

  # 文字
  $label = $labels[$st]
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
  $animTimer.Dispose()
  $tipTimer.Dispose()
  try { $tipForm.Close() } catch { }
  try { $mutex.ReleaseMutex() } catch { }
  try { $mutex.Dispose() } catch { }
})

[System.Windows.Forms.Application]::Run($form)
