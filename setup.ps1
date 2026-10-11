param([string]$CacheDirectory = (Join-Path $PSScriptRoot '.downloads'), [switch]$PrepareOnly)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
function Assert-Hash([string]$Path, [string]$Expected) {
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $Expected) { throw "文件校验失败：$Path。请删除该下载文件后重试。" }
}
function Get-Component([string]$Name, [string]$Url, [string]$Hash) {
    $path = Join-Path $CacheDirectory $Name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Host "正在下载：$Name"
        $partial = $path + '.partial'
        Invoke-WebRequest -Uri $Url -OutFile $partial -UseBasicParsing
        Assert-Hash $partial $Hash
        Move-Item -LiteralPath $partial -Destination $path -Force
    }
    Assert-Hash $path $Hash
    return $path
}
function Assert-DriverSignatures {
    foreach ($relativePath in @('sprdvcom.cat', 'amd64\sprdvcom.sys')) {
        $file = Join-Path $PSScriptRoot ('unisoc-driver\Drivers\' + $relativePath)
        $signature = Get-AuthenticodeSignature -LiteralPath $file
        if ($signature.Status -ne 'Valid') { throw "驱动签名验证失败：$relativePath" }
        if ($signature.SignerCertificate.Subject -notmatch 'Microsoft|Unisoc|Spreadtrum') { throw "驱动发布者不匹配：$relativePath" }
    }
}
try {
    if (-not [Environment]::Is64BitProcess) { throw '请使用 64 位 Windows PowerShell 启动工具。' }
    New-Item -ItemType Directory -Path $CacheDirectory -Force | Out-Null
    $usbHash = '76055314E4E69641FB889E88B858BCC14B50AFF06F197E5F8D5A112BA2E13ED7'
    $usbFile = Join-Path $PSScriptRoot 'spd_dump64\libusb-1.0.dll'
    if (-not (Test-Path -LiteralPath $usbFile)) {
        $usbZip = Get-Component 'spd_dump64.zip' 'https://github.com/ilyakurdyukov/spreadtrum_flash/releases/download/1.20260403/spd_dump64.zip' '402CE5B3B06681947655F804FA009990922D2905302B65B9905C00F2FFDA056B'
        $usbExtract = Join-Path $CacheDirectory 'usb-extract'
        Expand-Archive -LiteralPath $usbZip -DestinationPath $usbExtract -Force
        $dlls = @(Get-ChildItem -LiteralPath $usbExtract -Filter 'libusb-1.0.dll' -Recurse -File)
        if ($dlls.Count -ne 1) { throw '下载包中的 USB 组件数量不匹配。' }
        Assert-Hash $dlls[0].FullName $usbHash
        New-Item -ItemType Directory -Path (Split-Path $usbFile) -Force | Out-Null
        Copy-Item -LiteralPath $dlls[0].FullName -Destination $usbFile -Force
    }
    Assert-Hash $usbFile $usbHash
    $driverInf = Join-Path $PSScriptRoot 'unisoc-driver\Drivers\sprdvcom.inf'
    if (-not (Test-Path -LiteralPath $driverInf)) {
        $sevenZip = Get-Component '7zr.exe' 'https://github.com/ip7z/7zip/releases/download/26.04/7zr.exe' '256FECA8E274E5DA655E2A284FABAFD9F554365EB164862089DACD4E8276D282'
        $driverArchive = Get-Component 'SPRD_UNISOC_v4.21.39.134.7z' 'https://dl1.infinity-box.com/00/pub/?dir=/soc-drivers/SPD-Unisoc/&uid=20738&file=SPRD_UNISOC_v4.21.39.134_pass_1111.7z' 'C35232F5A5D7B08A3B93E764AE8B0E4491CFB059FB0BE44819462593E653165D'
        $driverExtract = Join-Path $CacheDirectory 'driver-extract'
        Write-Host '正在解压并核对驱动。此步骤不会安装驱动或操作手机。'
        & $sevenZip x '-p1111' ('-o' + $driverExtract) '-y' $driverArchive | Out-Null
        if ($LASTEXITCODE -ne 0) { throw '驱动解压失败。' }
        $found = @(Get-ChildItem -LiteralPath $driverExtract -Filter 'sprdvcom.inf' -Recurse -File)
        if ($found.Count -ne 1) { throw '下载包中的驱动目录不匹配。' }
        New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'unisoc-driver') -Force | Out-Null
        Copy-Item -LiteralPath $found[0].Directory.FullName -Destination (Join-Path $PSScriptRoot 'unisoc-driver\Drivers') -Recurse -Force
    }
    Assert-DriverSignatures
    Write-Host '组件已准备好。驱动安装和手机操作需要在中文界面中逐步点击。'
    if (-not $PrepareOnly) { & (Join-Path $PSScriptRoot 'gui.ps1') }
} catch {
    Write-Host ('启动失败：' + $_.Exception.Message) -ForegroundColor Red
    if (-not $PrepareOnly) { [void](Read-Host '按回车关闭；可保留错误信息后重试') }
    exit 1
}
