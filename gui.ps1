param([switch]$UiCheck, [string]$PreviewPath = '')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$script:busy = $false; $script:verified = $false; $script:resetAttempted = $false
$script:awaitingPhone = $false; $script:job = $null; $script:lastState = ''; $script:action = ''
$script:logRoot = Join-Path $PSScriptRoot '运行日志'
$form = [Windows.Forms.Form]::new()
$form.Text = '诺基亚 TA-1617 锁码重置助手'
$form.ClientSize = [Drawing.Size]::new(920, 690)
$form.MinimumSize = [Drawing.Size]::new(936, 729)
$form.StartPosition = 'CenterScreen'; $form.BackColor = [Drawing.Color]::FromArgb(245,247,250)
$form.Font = [Drawing.Font]::new('Microsoft YaHei UI',10)
function Add-Label($Text,$X,$Y,$W,$H,$Size=10) {
    $label = [Windows.Forms.Label]::new(); $label.Text=$Text
    $label.Location=[Drawing.Point]::new($X,$Y); $label.Size=[Drawing.Size]::new($W,$H)
    $label.Font=[Drawing.Font]::new('Microsoft YaHei UI',$Size); $form.Controls.Add($label); return $label
}
function Add-Button($Text,$X,$Y,$W,$H) {
    $button = [Windows.Forms.Button]::new(); $button.Text=$Text
    $button.Location=[Drawing.Point]::new($X,$Y); $button.Size=[Drawing.Size]::new($W,$H)
    $button.FlatStyle='Flat'; $button.BackColor=[Drawing.Color]::White; $form.Controls.Add($button); return $button
}
$title = Add-Label 'TA-1617 锁码重置助手' 28 23 850 38 20
$title.ForeColor=[Drawing.Color]::FromArgb(25,54,85)
$subtitle=Add-Label '适用记录：中国版 16QN3B17CN00 · UMS9117 · 固件 11.00.17.00' 30 70 855 27
$prep=Add-Label "准备：拔掉 USB，取下电池等 30 秒，再装回。保持关机，暂时不插线。`r`n点击第 1 步，看到「监听已准备好」后，不按任何键插线。" 30 109 855 60 11
$entry=Add-Button '1 进入 DIAG' 30 187 200 48
$driver=Add-Button '2 检查或安装驱动' 250 187 200 48
$probe=Add-Button '3 验证通信' 470 187 200 48
$reset=Add-Button '4 重置锁码' 690 187 200 48
$reset.BackColor=[Drawing.Color]::FromArgb(255,238,229); $reset.Enabled=$false
$modelCheck=[Windows.Forms.CheckBox]::new(); $modelCheck.Text='我已核对电池仓标签：手机型号是 TA-1617，产品代码是 16QN3B17CN00。'
$modelCheck.Location=[Drawing.Point]::new(30,251); $modelCheck.Size=[Drawing.Size]::new(860,30)
$form.Controls.Add($modelCheck)
$status=Add-Label '尚未操作。已在 DIAG 模式的手机，可从第 2 步开始。' 30 295 860 49 11
$status.ForeColor=[Drawing.Color]::FromArgb(30,78,118)
$progress=[Windows.Forms.ProgressBar]::new(); $progress.Location=[Drawing.Point]::new(30,347)
$progress.Size=[Drawing.Size]::new(860,5); $progress.Style='Blocks'; $form.Controls.Add($progress)
$log=[Windows.Forms.RichTextBox]::new(); $log.Location=[Drawing.Point]::new(30,366)
$log.Size=[Drawing.Size]::new(860,212); $log.ReadOnly=$true; $log.BackColor=[Drawing.Color]::White
$log.Font=[Drawing.Font]::new('Microsoft YaHei UI',10); $log.Anchor='Top,Bottom,Left,Right'; $form.Controls.Add($log)
$cancel=Add-Button '取消等待' 30 594 115 37; $cancel.Enabled=$false
$logs=Add-Button '打开日志' 161 594 115 37
$manual=Add-Button '使用说明' 292 594 115 37
$confirm=Add-Button '确认手机已恢复' 669 594 221 37; $confirm.Enabled=$false
$footer=Add-Label '重置会清除用户数据。只有你确认手机正常使用、不再提示锁码，才记录为成功。' 30 649 860 25 9
function Append-Log([string]$Text) { $log.AppendText('['+[DateTime]::Now.ToString('HH:mm:ss')+'] '+$Text+"`r`n"); $log.ScrollToCaret() }
function Update-Controls {
    foreach($b in @($entry,$driver,$probe)) { $b.Enabled = -not $script:busy -and -not $script:awaitingPhone }
    $reset.Enabled = -not $script:busy -and $script:verified -and $modelCheck.Checked -and -not $script:resetAttempted
    $cancel.Enabled = $script:busy -and $script:action -ne 'Reset' -and $script:action -ne 'Driver'
    $confirm.Enabled = -not $script:busy -and $script:awaitingPhone
    if($script:busy) { $progress.Style='Marquee' } else { $progress.Style='Blocks' }
}
function Start-Task([string]$Action, [string]$Consent='') {
    if($script:busy) { return }
    if($Action -eq 'Reset' -and (-not $script:verified -or -not $modelCheck.Checked -or $script:resetAttempted -or $Consent -cne 'ERASE_TA1617')) { return }
    if($Action -ne 'Reset') { $script:verified=$false }
    $script:busy=$true; $script:action=$Action; $script:lastState=''
    if($Action -eq 'Reset') { $script:resetAttempted=$true }
    try {
        New-Item -ItemType Directory -Path $script:logRoot -Force | Out-Null
        $script:job=Join-Path $script:logRoot ([DateTime]::Now.ToString('yyyyMMdd-HHmmss-fff')+'-'+$Action)
        New-Item -ItemType Directory -Path $script:job -Force | Out-Null
        $exe="$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        if(-not [Environment]::Is64BitProcess) { $exe="$env:WINDIR\Sysnative\WindowsPowerShell\v1.0\powershell.exe" }
        $worker=Join-Path $PSScriptRoot 'worker.ps1'
        $workerArguments='-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'" -Action '+$Action+' -JobDir "'+$script:job+'"'
        if($Consent) { $workerArguments+=' -Consent '+$Consent }
        $status.Text='正在启动，请稍候。'; Append-Log ('开始步骤：'+$Action)
        if($Action -eq 'Driver') {
            $status.Text='安装驱动可能弹出 Windows 权限提示，请选择「是」。'
            $script:process=Start-Process -FilePath $exe -ArgumentList $workerArguments -Verb RunAs -WindowStyle Hidden -PassThru
        } else { $script:process=Start-Process -FilePath $exe -ArgumentList $workerArguments -WindowStyle Hidden -PassThru }
    } catch {
        $script:busy=$false; $status.Text='未能启动：'+$_.Exception.Message; Append-Log $status.Text
        if($Action -eq 'Reset') { $script:resetAttempted=$false }
    }
    Update-Controls
}
$timer=[Windows.Forms.Timer]::new(); $timer.Interval=400
$timer.Add_Tick({
    if(-not $script:busy) { return }
    $statePath=Join-Path $script:job 'state.json'
    if(Test-Path $statePath) {
        try {
            $state=Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if($state.time -ne $script:lastState) {
                $script:lastState=$state.time; Append-Log $state.message
                $status.Text=($state.message -split '[\r\n]+')[0]
                if($state.done) {
                    $script:busy=$false
                    if($script:action -eq 'Probe') { $script:verified=[bool]$state.success }
                    if($script:action -eq 'Reset') {
                        $script:awaitingPhone=$true
                        if(-not $state.success) { $status.Text='重置结果未确认。请先检查手机屏幕，避免重复发送。' }
                    }
                    Update-Controls
                }
            }
        } catch { }
    }
    if($script:busy -and $script:process.HasExited) {
        $script:busy=$false; $script:verified=$false
        $status.Text='进程已结束。请检查日志；若刚取消了权限提示，可重新点击安装驱动。'
        if($script:action -eq 'Reset') { $script:awaitingPhone=$true; $status.Text='进程结束，结果未确认。请检查手机屏幕，不要立即重复重置。' }
        Append-Log $status.Text; Update-Controls
    }
})
$entry.Add_Click({ Start-Task 'Enter' })
$driver.Add_Click({ Start-Task 'Driver' })
$probe.Add_Click({ Start-Task 'Probe' })
$modelCheck.Add_CheckedChanged({ Update-Controls })
$reset.Add_Click({
    if(-not $script:verified -or -not $modelCheck.Checked -or $script:resetAttempted) { return }
    $choice=[Windows.Forms.MessageBox]::Show($form,"即将恢复出厂并清除手机用户数据。`r`n手机：TA-1617，中国版；已通过 DIAG 固件验证。`r`n`r`n确定要继续清除并重置锁码吗？",'确认清除用户数据',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Warning,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if($choice -eq [Windows.Forms.DialogResult]::Yes) { Start-Task 'Reset' 'ERASE_TA1617' }
})
$cancel.Add_Click({ if($script:busy -and $script:action -ne 'Reset' -and $script:action -ne 'Driver') { New-Item -ItemType File -Path (Join-Path $script:job 'cancel') -Force | Out-Null; $cancel.Enabled=$false; $status.Text='正在取消等待并关闭连接。' } })
$logs.Add_Click({ if(Test-Path $script:logRoot) { Start-Process explorer.exe -ArgumentList ('"'+$script:logRoot+'"') } else { [void][Windows.Forms.MessageBox]::Show('还没有操作日志。') } })
$manual.Add_Click({ Start-Process notepad.exe -ArgumentList ('"'+(Join-Path $PSScriptRoot '使用说明.txt')+'"') })
$confirm.Add_Click({
    $choice=[Windows.Forms.MessageBox]::Show($form,'手机现在能正常使用，并且不再提示原锁码吗？','确认手机结果',[Windows.Forms.MessageBoxButtons]::YesNo,[Windows.Forms.MessageBoxIcon]::Question,[Windows.Forms.MessageBoxDefaultButton]::Button2)
    if($choice -eq [Windows.Forms.DialogResult]::Yes) {
        '机主确认：正常使用，不再提示锁码。' | Set-Content (Join-Path $script:job '手机结果确认.txt') -Encoding utf8
        $script:awaitingPhone=$false; $script:verified=$false
        $status.Text='重置成功：你已确认手机恢复使用。可以拔掉 USB。'
        Append-Log $status.Text; Update-Controls; $confirm.Enabled=$false
    } else { Append-Log '机主尚未确认恢复。请检查手机并保留日志。'; $status.Text='尚未确认恢复。请先检查手机，保留日志后再排查。' }
})
$form.Add_FormClosing({
    if($script:busy) {
        if($script:action -eq 'Reset' -or $script:action -eq 'Driver') { $_.Cancel=$true; [void][Windows.Forms.MessageBox]::Show('请等待当前安装或重置步骤结束后再关闭。'); return }
        New-Item -ItemType File -Path (Join-Path $script:job 'cancel') -Force | Out-Null
    }
})
Append-Log '工具不会自动清除手机。先验证通信，再确认数据清除。'
Append-Log 'WinUSB 入口和重置命令已在本机成功；展讯串口入口沿用同一切换包，尚未重新实机验证。'
if($UiCheck) {
    $uiChecks=0
    if($reset.Enabled) { throw '重置按钮初始状态错误' }; $uiChecks++
    $modelCheck.Checked=$true; Update-Controls
    if($reset.Enabled) { throw '未验证时重置按钮不应启用' }; $uiChecks++
    $script:verified=$true; Update-Controls
    if(-not $reset.Enabled) { throw '验证和型号确认后按钮应启用' }; $uiChecks++
    $script:busy=$true; Update-Controls
    if($reset.Enabled) { throw '忙碌时不能重复重置' }; $uiChecks++
    $script:busy=$false; $script:resetAttempted=$true; Update-Controls
    if($reset.Enabled) { throw '重置尝试后不能自动重发' }; $uiChecks++
    $script:resetAttempted=$false; $script:verified=$false; $modelCheck.Checked=$false; Update-Controls
    $form.StartPosition='Manual'; $form.Location=[Drawing.Point]::new(-30000,-30000)
    $form.Show(); [Windows.Forms.Application]::DoEvents()
    $form.PerformLayout()
    if($PreviewPath) { $bitmap=[Drawing.Bitmap]::new($form.Width,$form.Height); $form.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$form.Width,$form.Height)); $bitmap.Save($PreviewPath,[Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose() }
    [pscustomobject]@{Controls=$form.Controls.Count;ResetInitiallyEnabled=$reset.Enabled;ModelInitiallyChecked=$modelCheck.Checked;Busy=$script:busy;UiChecks=$uiChecks;LogChars=$log.Text.Length;Preview=$PreviewPath} | ConvertTo-Json
    $form.Dispose(); exit
}
$timer.Start()
try { [void]$form.ShowDialog() } finally { $timer.Stop(); $timer.Dispose(); $form.Dispose() }
