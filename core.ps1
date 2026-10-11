$ErrorActionPreference = 'Stop'
function Get-PhoneInterfaces {
    return @(Get-PnpDevice -PresentOnly -ErrorAction Stop | Where-Object { $_.InstanceId -match '^USB\\VID_1782&PID_4D0[03]' })
}
function Get-DiagPort {
    $devices = @(Get-PhoneInterfaces | Where-Object { $_.InstanceId -match '^USB\\VID_1782&PID_4D03&MI_00\\' })
    if ($devices.Count -ne 1) { throw '需要恰好一台 4D03 诊断设备。请断开其他展讯手机。' }
    if ($devices[0].Status -ne 'OK' -or $devices[0].FriendlyName -notmatch '\((COM\d+)\)') { throw '诊断接口缺少驱动。请先点击「检查或安装驱动」。' }
    return $Matches[1]
}
function New-AtPacket([string]$Command) {
    $payload = [Text.Encoding]::ASCII.GetBytes($Command + "`r`n")
    $packet = New-Object byte[] ($payload.Length + 10)
    $packet[0] = 0x7e
    $length = $payload.Length + 8
    $packet[5] = [byte]($length -band 255)
    $packet[6] = [byte]($length -shr 8)
    $packet[7] = 0x68
    [Array]::Copy($payload, 0, $packet, 9, $payload.Length)
    $packet[$packet.Length - 1] = 0x7e
    return ,$packet
}
function Read-DiagResponse([byte[]]$Bytes) {
    # 实机返回的 7E 填充和多个响应帧；只接受完整 DIAG 帧中的 AT 正文。
    $payloads = [Collections.Generic.List[string]]::new()
    $frame = [Collections.Generic.List[byte]]::new()
    $escaped = $false
    foreach ($b in $Bytes) {
        if ($b -eq 0x7e) {
            if ($frame.Count -ge 8) {
                $f = $frame.ToArray()
                $declared = [int]$f[4] + ([int]$f[5] -shl 8)
                if ($declared -eq $f.Length -and $f[6] -eq 0x9c -and $f[7] -eq 0) {
                    $payloads.Add([Text.Encoding]::ASCII.GetString($f, 8, $f.Length - 8))
                }
            }
            $frame.Clear(); $escaped = $false
        } elseif ($escaped) { $frame.Add([byte]($b -bxor 0x20)); $escaped = $false
        } elseif ($b -eq 0x7d) { $escaped = $true
        } else { $frame.Add($b) }
    }
    $text = $payloads -join "`r`n"
    return [pscustomobject]@{ Text = $text; HasFrames = $payloads.Count -gt 0; Ok = $text -match '(?m)^\s*OK\s*$'; Error = $text -match '(?im)^\s*(ERROR|\+CME ERROR.*)\s*$' }
}
function Test-VerifiedFirmware([string]$Text) {
    return ($Text -match '(?m)^HW\s+Version:\s*UMS9117\s*$' -and $Text -match '(?m)^Software Version:\s*11\.00\.17\.00\s*$' -and $Text -match '(?m)^Platform Version:\s*MOCOR_20A_MP_W22\.04\.6_P5_Release\s*$')
}
function Open-DiagSerial {
    $portName = Get-DiagPort
    $port = [IO.Ports.SerialPort]::new($portName, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
    $port.Handshake = [IO.Ports.Handshake]::None; $port.DtrEnable = $true; $port.RtsEnable = $true
    $port.ReadTimeout = 300; $port.WriteTimeout = 2000
    try { $port.Open(); return $port } catch { $port.Dispose(); throw "无法打开 $portName。请关闭其他占用手机串口的工具。$($_.Exception.Message)" }
}
function Invoke-SerialPacket($Port, [byte[]]$Packet, [int]$WaitMs = 2600, [switch]$AllowDisconnect) {
    $Port.DiscardInBuffer(); $Port.Write($Packet, 0, $Packet.Length)
    $end = [DateTime]::UtcNow.AddMilliseconds($WaitMs)
    $bytes = [Collections.Generic.List[byte]]::new()
    while ([DateTime]::UtcNow -lt $end) {
        if (-not $AllowDisconnect) { Test-Cancel }
        try {
            $available = $Port.BytesToRead
            if ($available -gt 0) {
                $chunk = New-Object byte[] $available
                $n = $Port.Read($chunk, 0, $chunk.Length)
                for ($i = 0; $i -lt $n; $i++) { $bytes.Add($chunk[$i]) }
            }
        } catch { if ($AllowDisconnect) { break }; throw }
        Start-Sleep -Milliseconds 40
    }
    return ,$bytes.ToArray()
}
function Invoke-Verify {
    Write-State '正在通过 DIAG 查询手机版本，请保持连接。'
    $port = Open-DiagSerial
    try {
        $versionBytes = Invoke-SerialPacket $port (New-AtPacket 'AT+CGMR')
        $version = Read-DiagResponse $versionBytes
        [IO.File]::WriteAllBytes((Join-Path $JobDir 'version.bin'), $versionBytes)
        if (-not $version.HasFrames -or -not $version.Ok -or $version.Error) { throw '没有获得有效的 DIAG 版本回应。下载模式的 ACK 不算验证成功。' }
        Write-State $version.Text.Trim()
        if (-not (Test-VerifiedFirmware $version.Text)) { throw '手机平台或固件版本与本次成功记录不符。此工具不会对该版本执行重置。' }
        $atBytes = Invoke-SerialPacket $port (New-AtPacket 'AT')
        $at = Read-DiagResponse $atBytes
        if (-not $at.Ok -or $at.Error) { throw '普通 AT 查询未返回有效 OK，停止重置。' }
        return $version.Text.Trim()
    } finally { if ($port.IsOpen) { $port.Close() }; $port.Dispose() }
}
function Get-BootComPort {
    $connectedPorts = [IO.Ports.SerialPort]::GetPortNames()
    $usbRoot = 'HKLM:\SYSTEM\CurrentControlSet\Enum\USB'
    foreach ($device in @(Get-ChildItem $usbRoot -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^VID_1782&PID_4D00$' })) {
        foreach ($instance in @(Get-ChildItem $device.PSPath -ErrorAction SilentlyContinue)) {
            $name = (Get-ItemProperty ($instance.PSPath + '\Device Parameters') -Name PortName -ErrorAction SilentlyContinue).PortName
            if ($name -and $connectedPorts -contains $name) { return $name }
        }
    }
    return $null
}
function Initialize-UsbLibrary {
    if (-not ('DiagUsb' -as [type])) {
        $dll = (Join-Path $PSScriptRoot 'spd_dump64\libusb-1.0.dll').Replace('\', '\\')
        $source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'libusb-native.cs')).Replace('LIBUSB_PATH', $dll)
        Add-Type -TypeDefinition $source
    }
}
function Invoke-EnterDiag {
    $existing = @(Get-PhoneInterfaces)
    if (@($existing | Where-Object { $_.InstanceId -match 'PID_4D03' }).Count -gt 0) { return '手机已经出现 4D03 接口。继续检查驱动。' }
    if ($existing.Count -gt 0) { throw '请先拔线、取下电池等待 30 秒、装回并保持关机，再点击进入 DIAG。' }
    Initialize-UsbLibrary
    $context = [IntPtr]::Zero; $handle = [IntPtr]::Zero; $claimed = -1
    $modePacket = [byte[]](0x7e, 0, 0, 0, 0, 8, 0, 0xfe, 0x81, 0x7e)
    $sent = $false
    try {
        if ([DiagUsb]::libusb_init([ref]$context) -lt 0) { throw 'USB 通信库初始化失败。' }
        Write-State '监听已准备好。现在保持手机关机，不按任何键，直接插入 USB。等待最多 180 秒。'
        $deadline = [DateTime]::UtcNow.AddSeconds(180)
        while ([DateTime]::UtcNow -lt $deadline) {
            Test-Cancel
            $bootPort = Get-BootComPort
            if ($bootPort) {
                $serial = [IO.Ports.SerialPort]::new($bootPort, 115200, [IO.Ports.Parity]::None, 8, [IO.Ports.StopBits]::One)
                $serial.DtrEnable = $true; $serial.RtsEnable = $true; $serial.WriteTimeout = 1500
                try {
                    $serial.Open()
                    Write-State "发现 $bootPort，使用展讯串口驱动发送 DIAG 切换包。"
                    $response = Invoke-SerialPacket $serial $modePacket 1800 -AllowDisconnect
                    [IO.File]::WriteAllBytes((Join-Path $JobDir 'entry-response.bin'), $response)
                    $sent = $true; break
                } finally { if ($serial.IsOpen) { $serial.Close() }; $serial.Dispose() }
            }
            $handle = [DiagUsb]::libusb_open_device_with_vid_pid($context, 0x1782, 0x4d00)
            if ($handle -ne [IntPtr]::Zero) {
                $eps = [DiagUsb]::Endpoints($handle)
                $rc = [DiagUsb]::libusb_claim_interface($handle, $eps[0])
                if ($rc -lt 0) { throw "USB 接口被占用或驱动不可用，错误 $rc。" }
                $claimed = $eps[0]; $count = 0
                $rc = [DiagUsb]::libusb_bulk_transfer($handle, [byte]$eps[2], $modePacket, 10, [ref]$count, 1500)
                if ($rc -lt 0 -or $count -ne 10) { throw "DIAG 切换包发送失败，错误 $rc。" }
                Write-State '已通过 WinUSB 发送 DIAG 切换包，正在等待新的诊断接口。'
                $response = New-Object byte[] 4096; $received = 0
                [void][DiagUsb]::libusb_bulk_transfer($handle, [byte]$eps[1], $response, 4096, [ref]$received, 2500)
                if ($received -gt 0) { [IO.File]::WriteAllBytes((Join-Path $JobDir 'entry-response.bin'), [byte[]]$response[0..($received - 1)]) }
                $sent = $true; break
            }
            Start-Sleep -Milliseconds 120
        }
        if (-not $sent) { throw '等待连接超时。检查数据线、USB 插口及 4D00 驱动，彻底断电后重试。' }
    } finally {
        if ($handle -ne [IntPtr]::Zero) { if ($claimed -ge 0) { [void][DiagUsb]::libusb_release_interface($handle, $claimed) }; [DiagUsb]::libusb_close($handle) }
        if ($context -ne [IntPtr]::Zero) { [DiagUsb]::libusb_exit($context) }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(40)
    while ([DateTime]::UtcNow -lt $deadline) {
        Test-Cancel
        if (@(Get-PhoneInterfaces | Where-Object { $_.InstanceId -match 'PID_4D03' }).Count -gt 0) { return '发现 4D03。模式切换已完成；下一步检查串口驱动和 DIAG 通信。' }
        Start-Sleep -Milliseconds 400
    }
    throw '切换包已发送，但没有出现 4D03。请拔线、取下电池等待 30 秒后无按键重试。'
}
function Invoke-InstallDriver {
    $inf = Join-Path $PSScriptRoot 'unisoc-driver\Drivers\sprdvcom.inf'
    foreach ($signedFile in @('unisoc-driver\Drivers\sprdvcom.cat', 'unisoc-driver\Drivers\amd64\sprdvcom.sys')) {
        if ((Get-AuthenticodeSignature (Join-Path $PSScriptRoot $signedFile)).Status -ne 'Valid') { throw '驱动签名验证未通过，停止安装。' }
    }
    Write-State '正在安装匹配的 UNISOC 串口驱动。'
    $output = & "$env:WINDIR\System32\pnputil.exe" /add-driver $inf /install 2>&1
    $code = $LASTEXITCODE
    $output | Out-File (Join-Path $JobDir 'driver-install.log') -Encoding utf8
    if ($code -ne 0) { throw "驱动安装失败，退出码 $code。查看日志；安装需要管理员权限。" }
    Start-Sleep -Milliseconds 800
    if (@(Get-PhoneInterfaces | Where-Object { $_.InstanceId -match 'PID_4D03' }).Count -eq 0) { return '驱动已安装。请按准备步骤彻底断电，点击第 1 步后无按键插线。' }
    $port = Get-DiagPort
    return "驱动正常，诊断端口为 $port。继续点击验证通信。"
}
function Invoke-Reset {
    if ($Consent -cne 'ERASE_TA1617') { throw '未确认清除用户数据，未发送重置命令。' }
    # 每次重置前重新读取真实接口和固件，不依赖界面保存的旧结果。
    $verified = Invoke-Verify
    Write-State '固件和 DIAG 已重新验证。现在发送恢复出厂命令，请保持连接。'
    $port = Open-DiagSerial
    try {
        $bytes = Invoke-SerialPacket $port (New-AtPacket 'AT+SPDIAG="AT+ETSRESET"') 6000 -AllowDisconnect
        [IO.File]::WriteAllBytes((Join-Path $JobDir 'reset-response.bin'), $bytes)
        $response = Read-DiagResponse $bytes
        if (-not $response.Ok -or $response.Error) { throw '已发送命令，但未取得有效 OK。结果未确认，请检查手机屏幕；不要立即重复重置。' }
        return '手机接受了恢复出厂命令。请等约一分钟，检查是否正常开机且不再提示锁码；然后点击「确认手机已恢复」。'
    } finally { if ($port.IsOpen) { $port.Close() }; $port.Dispose() }
}
