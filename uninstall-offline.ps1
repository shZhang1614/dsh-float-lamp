# dsh-float-lamp 离线卸载脚本
$ErrorActionPreference = 'Stop'
$name = 'dsh-float-lamp'
$dest = Join-Path $env:USERPROFILE "dsh-plugins\$name"

# 杀掉正在显示的灯进程（只匹配灯脚本，不误伤其它 powershell）
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match '-File .*lamp\.ps1' } |
  ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 移除 profile 里的 dependency 与 bundles 条目
$profiles = Get-ChildItem (Join-Path $env:USERPROFILE ".dsh\profiles\*\package.json") -ErrorAction SilentlyContinue
foreach ($p in $profiles) {
  $pkg = Get-Content $p.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
  $changed = $false
  if ($pkg.dependencies -and $pkg.dependencies.PSObject.Properties[$name]) {
    $pkg.dependencies.PSObject.Properties.Remove($name); $changed = $true
  }
  if ($pkg.dsh -and $pkg.dsh.profile -and $pkg.dsh.profile.bundles -and ($pkg.dsh.profile.bundles -contains $name)) {
    $pkg.dsh.profile.bundles = @($pkg.dsh.profile.bundles | Where-Object { $_ -ne $name }); $changed = $true
  }
  if ($changed) {
    [System.IO.File]::WriteAllText($p.FullName, ($pkg | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Write-Host "已从 profile [$($p.Directory.Name)] 移除配置"
  }
  $nm = Join-Path $p.Directory.FullName "node_modules\$name"
  if (Test-Path $nm) {
    $item = Get-Item $nm -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { cmd /c rmdir "`"$nm`"" | Out-Null }
    else { Remove-Item $nm -Recurse -Force }
    Write-Host "已移除 node_modules 链接"
  }
}

if (Test-Path $dest) { Remove-Item $dest -Recurse -Force; Write-Host "已删除 $dest" }
Write-Host ""
Write-Host "✅ 卸载完成。重启 DeepSeek Harness 后彻底生效。"
