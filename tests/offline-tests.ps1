$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot) 'core.ps1')
$script:checks=0
function Assert-Check($Condition,[string]$Name) { if(-not $Condition) { throw "FAILED: $Name" }; $script:checks++; Write-Output "PASS: $Name" }
$data=Join-Path $PSScriptRoot 'data'
$version=Read-DiagResponse ([IO.File]::ReadAllBytes((Join-Path $data 'version.bin')))
Assert-Check ($version.HasFrames -and $version.Ok -and -not $version.Error) '实际成功版本回应可以解析'
Assert-Check (Test-VerifiedFirmware $version.Text) '实际固件通过匹配'
Assert-Check (-not (Test-VerifiedFirmware ($version.Text.Replace('11.00.17.00','99.00.00.00')))) '其他固件被拒绝'
Assert-Check (-not (Test-VerifiedFirmware ($version.Text.Replace('UMS9117','SC6531')))) '其他平台被拒绝'
Assert-Check (-not (Test-VerifiedFirmware 'OK')) '只有 OK 不能验证固件'
$reset=Read-DiagResponse ([IO.File]::ReadAllBytes((Join-Path $data 'reset.bin')))
Assert-Check ($reset.Ok -and -not $reset.Error) '实际重置回应可以解析'
$ack=Read-DiagResponse ([byte[]](0x7e,0,0x80,0,0,0x3b,0x5a,0x7e))
Assert-Check (-not $ack.HasFrames -and -not $ack.Ok) '下载协议 ACK 不被误认为 DIAG 成功'
$expected='7E-00-00-00-00-21-00-68-00-41-54-2B-53-50-44-49-41-47-3D-22-41-54-2B-45-54-53-52-45-53-45-54-22-0D-0A-7E'
Assert-Check ([BitConverter]::ToString((New-AtPacket 'AT+SPDIAG="AT+ETSRESET"')) -ceq $expected) '恢复出厂报文逐字节匹配成功记录'
$truncated=Read-DiagResponse ([byte[]](0x7e,0,0,0,0,14,0,0x9c,0,13,10,0x4f,0x4b,13,10))
Assert-Check (-not $truncated.Ok) '不完整响应不算 OK'
$badLength=Read-DiagResponse ([byte[]](0x7e,0,0,0,0,99,0,0x9c,0,13,10,0x4f,0x4b,13,10,0x7e))
Assert-Check (-not $badLength.Ok) '错误长度响应不算 OK'
$Consent=''; $blocked=$false
try { Invoke-Reset } catch { $blocked=$_.Exception.Message -match '未确认' }
Assert-Check $blocked '缺少确认时在读取设备及发送命令前阻止重置'
Initialize-UsbLibrary
Assert-Check ([bool]('DiagUsb' -as [type])) '64 位 USB 通信声明成功编译且未调用设备'
Write-Output "OFFLINE_TESTS_OK $script:checks checks. No device commands sent."
