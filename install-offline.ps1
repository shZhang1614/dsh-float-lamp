# dsh-float-lamp 离线安装脚本（朋友拿到 zip 后运行这一个文件即可）
# 用法：右键“使用 PowerShell 运行”，或 powershell -NoProfile -ExecutionPolicy Bypass -File install-offline.ps1
$ErrorActionPreference = 'Stop'
$src  = $PSScriptRoot
$name = 'dsh-float-lamp'
$dest = Join-Path $env:USERPROFILE "dsh-plugins\$name"

Write-Host "[1/4] 复制插件到 $dest"
if (Test-Path $dest) {
  Write-Host "  目标已存在，覆盖更新"
}
robocopy $src $dest /MIR /XD .git node_modules screenshots-tmp /NFL /NDL /NJH /NJS | Out-Null
if ($LASTEXITCODE -gt 7) { throw "复制失败 (robocopy exit $LASTEXITCODE)" }
$global:LASTEXITCODE = 0

Write-Host "[2/4] 定位 DeepSeek Harness profile"
$profiles = Get-ChildItem (Join-Path $env:USERPROFILE ".dsh\profiles\*\package.json") -ErrorAction SilentlyContinue
if (-not $profiles) { throw "未找到 ~/.dsh/profiles/*/package.json —— 朋友机器上要先安装并启动过 DeepSeek Harness。" }
$profilePkg = $profiles | Where-Object { $_.Directory.Name -eq 'desktop' } | Select-Object -First 1
if (-not $profilePkg) { $profilePkg = $profiles | Select-Object -First 1 }
$profileDir = $profilePkg.Directory.FullName
Write-Host "  使用 profile: $($profilePkg.Directory.Name)"

Write-Host "[3/4] 写入 profile 配置（dependency + bundles）"
$pkg = Get-Content $profilePkg.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
if (-not $pkg.dependencies) { $pkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) }
$link = $dest.Replace('\','/')
$pkg.dependencies | Add-Member -NotePropertyName $name -NotePropertyValue "link:$link" -Force
if (-not $pkg.dsh) { $pkg | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{profile=[pscustomobject]@{bundles=@()}}) }
if (-not $pkg.dsh.profile) { $pkg.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{bundles=@()}) }
if (-not $pkg.dsh.profile.bundles) { $pkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue @() }
if ($pkg.dsh.profile.bundles -notcontains $name) {
  $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles) + $name
}
$json = $pkg | ConvertTo-Json -Depth 10
[System.IO.File]::WriteAllText($profilePkg.FullName, $json, (New-Object System.Text.UTF8Encoding $false))

Write-Host "[4/4] 创建 node_modules 链接（junction）"
$nm = Join-Path $profileDir "node_modules\$name"
if (Test-Path $nm) {
  $item = Get-Item $nm -Force
  if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
    cmd /c rmdir "`"$nm`"" | Out-Null
  } else {
    Remove-Item $nm -Recurse -Force
  }
}
$nmParent = Join-Path $profileDir 'node_modules'
if (-not (Test-Path $nmParent)) { New-Item -ItemType Directory -Path $nmParent | Out-Null }
cmd /c mklink /J "`"$nm`"" "`"$dest`"" | Out-Null
if (-not (Test-Path $nm)) { throw "junction 创建失败" }

Write-Host ""
Write-Host "✅ 安装完成。请【完全退出并重新打开 DeepSeek Harness】（托盘图标右键退出，不是窗口内重启）。"
Write-Host "   重启后灯窗会自动出现在屏幕右上角：绿=运行中 橙=待授权 蓝=待交互 灰=空闲。"
Write-Host "   卸载：运行同目录 uninstall-offline.ps1，或在 dshmarket 里关闭本插件。"
