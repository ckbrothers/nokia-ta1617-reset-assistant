param([ValidateSet('Enter','Driver','Probe','Reset')][string]$Action, [string]$JobDir, [string]$Consent = '')
$ErrorActionPreference = 'Stop'
function Write-State([string]$Message, [bool]$Done = $false, [bool]$Success = $false) {
    $state = @{ message=$Message; done=$Done; success=$Success; action=$Action; time=[DateTime]::Now.ToString('HH:mm:ss.fff') }
    $path = Join-Path $JobDir 'state.json'
    $state | ConvertTo-Json -Compress | Set-Content ($path + '.tmp') -Encoding utf8
    Move-Item -LiteralPath ($path + '.tmp') -Destination $path -Force
    ('[' + $state.time + '] ' + $Message) | Add-Content (Join-Path $JobDir '操作日志.txt') -Encoding utf8
}
function Test-Cancel { if (Test-Path (Join-Path $JobDir 'cancel')) { throw '操作已取消。没有继续发送重置命令。' } }
try {
    . (Join-Path $PSScriptRoot 'core.ps1')
    if ([IntPtr]::Size -ne 8) { throw '请使用 64 位 Windows 和随附的启动文件。' }
    switch ($Action) {
        'Enter' { $message = Invoke-EnterDiag }
        'Driver' { $message = Invoke-InstallDriver }
        'Probe' { $message = "DIAG 验证通过。`r`n" + (Invoke-Verify) }
        'Reset' { $message = Invoke-Reset }
    }
    Write-State $message $true $true
} catch { Write-State $_.Exception.Message $true $false; exit 1 }
