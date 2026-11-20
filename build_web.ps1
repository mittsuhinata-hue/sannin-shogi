# Web版を docs フォルダに書き出す。
# ブラウザが古いゲーム本体を使い回さないよう、本体のファイル名に中身の目印を付ける。
#   使い方: powershell -ExecutionPolicy Bypass -File build_web.ps1
param(
    [string]$Godot = "C:\Users\ilove\Downloads\Godot\Godot_v4.7.2-stable_win64_console.exe"
)
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

& $Godot --headless --path . --export-release "Web" docs/index.html | Out-Null
if (-not (Test-Path docs\index.pck)) { throw "書き出しに失敗しました" }
Remove-Item docs\*.import -ErrorAction SilentlyContinue

# 本体（.pck）の名前を中身に合わせて変える
$hash = (Get-FileHash docs\index.pck -Algorithm SHA256).Hash.Substring(0, 10).ToLower()
$pck = "game-$hash.pck"
Get-ChildItem docs -Filter "game-*.pck" | Remove-Item
Move-Item docs\index.pck "docs\$pck"
$size = (Get-Item "docs\$pck").Length

# index.html の設定に、新しい本体の名前を書き込む
$enc = New-Object System.Text.UTF8Encoding($false)
$html = [IO.File]::ReadAllText("$PSScriptRoot\docs\index.html", $enc)
$html = $html -replace '"fileSizes":\{"index\.pck":\d+,', ('"mainPack":"' + $pck + '","fileSizes":{"' + $pck + '":' + $size + ',')
if ($html -notmatch [regex]::Escape($pck)) { throw "index.html の書き換えに失敗しました" }
# ページ自体もなるべく古いものを使わないようにする
$html = $html -replace '<head>', "<head>`n<meta http-equiv=`"Cache-Control`" content=`"no-cache`">"
[IO.File]::WriteAllText("$PSScriptRoot\docs\index.html", $html, $enc)
Write-Output "書き出し完了: $pck"
