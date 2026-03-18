<#
.SYNOPSIS
    WinNetx Optimizer
.DESCRIPTION
    A background tool to disable and stop heavy Windows services.
.AUTHOR
    webhubx
#>
param(
    [switch]$Silent
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ConfigPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"

# تحميل أو إنشاء الإعدادات
function Get-Config {
    if (Test-Path $ConfigPath) {
        $Config = Get-Content $ConfigPath | ConvertFrom-Json
        
        # توافق مع الإعدادات القديمة التي لا تحتوي على وقت الفحص
        if (-not (Get-Member -InputObject $Config -Name "ScheduleIntervalMinutes" -MemberType Properties)) {
            $Config | Add-Member -MemberType NoteProperty -Name "ScheduleIntervalMinutes" -Value 30
        }
        
        return $Config
    } else {
        $DefaultConfig = @{
            Services = @("wuauserv", "BITS", "DoSvc")
            LogFile = "WinNetx.log"
            MaxLogSizeMB = 5
            ScheduleIntervalMinutes = 30
        }
        $DefaultConfig | ConvertTo-Json | Set-Content $ConfigPath
        return (Get-Content $ConfigPath | ConvertFrom-Json)
    }
}

function Log-Message {
    param([string]$Message, $Config)
    
    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath $Config.LogFile
    $MaxLogSizeMB = $Config.MaxLogSizeMB
    
    if (Test-Path $LogPath) {
        $LogFileInfo = Get-Item $LogPath
        if ($LogFileInfo.Length -gt ($MaxLogSizeMB * 1024 * 1024)) {
            $BackupPath = "$LogPath.old"
            if (Test-Path $BackupPath) { Remove-Item -Path $BackupPath -Force }
            Rename-Item -Path $LogPath -NewName $($Config.LogFile + ".old") -Force
        }
    }

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "[$Timestamp] $Message"
    Add-Content -Path $LogPath -Value $LogEntry
}

function Show-Notification {
    param([string]$Title, [string]$Text)
    $NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
    $NotifyIcon.Icon = [System.Drawing.SystemIcons]::Shield
    $NotifyIcon.BalloonTipTitle = $Title
    $NotifyIcon.BalloonTipText = $Text
    $NotifyIcon.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $NotifyIcon.Visible = $true
    $NotifyIcon.ShowBalloonTip(5000)
    
    # انتظار حتى يعرض الإشعار
    Start-Sleep -Seconds 5
    $NotifyIcon.Visible = $false
    $NotifyIcon.Dispose()
}

function Run-Silent {
    # 1. منع تشغيل أكثر من نسخة باستخدام Mutex
    $MutexName = "Global\WinNetxSilentMutex"
    $MutexCreated = $false
    $Mutex = New-Object System.Threading.Mutex($true, $MutexName, [ref]$MutexCreated)

    if (-not $MutexCreated) {
        exit
    }

    $Config = Get-Config
    $ServicesStopped = @()

    try {
        Log-Message "بدء فحص الخدمات (بدون واجهة)..." $Config
        foreach ($ServiceName in $Config.Services) {
            $Service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
            
            if ($Service) {
                if ($Service.Status -eq 'Running') {
                    try {
                        Stop-Service -Name $ServiceName -Force -ErrorAction Stop
                        $ServicesStopped += $ServiceName
                        Log-Message "تم إيقاف الخدمة بنجاح: $ServiceName" $Config
                    } catch {
                        Log-Message "فشل في إيقاف الخدمة: $ServiceName. الخطأ: $_" $Config
                    }
                }
                
                if ($Service.StartType -ne 'Disabled') {
                    try {
                        Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop
                        Log-Message "تم تعطيل تشغيل الخدمة بنجاح (Disabled): $ServiceName" $Config
                    } catch {
                        Log-Message "فشل في تعطيل تشغيل الخدمة: $ServiceName. الخطأ: $_" $Config
                    }
                }
            }
        }

        # عرض إشعار Tray في حال إيقاف خدمات
        if ($ServicesStopped.Count -gt 0) {
            $ServiceNames = $ServicesStopped -join ", "
            Show-Notification -Title "تم إيقاف خدمات ويندوز" -Text ("تم إيقاف وتعطيل الخدمات التالية: " + $ServiceNames)
        }
    } finally {
        if ($MutexCreated) {
            $Mutex.ReleaseMutex()
            $Mutex.Dispose()
        }
    }
}

function Show-UI {
    $Config = Get-Config

    $Form = New-Object System.Windows.Forms.Form
    $Form.Text = "WinNetx Optimizer - إعدادات البرنامج"
    $Form.Size = New-Object System.Drawing.Size(400, 300)
    $Form.StartPosition = "CenterScreen"
    $Form.FormBorderStyle = "FixedDialog"
    $Form.MaximizeBox = $false

    $Label = New-Object System.Windows.Forms.Label
    $Label.Text = "الخدمات التي سيتم إيقافها (خدمة واحدة في كل سطر):"
    $Label.Location = New-Object System.Drawing.Point(10, 10)
    $Label.AutoSize = $true
    $Form.Controls.Add($Label)

    $TextBox = New-Object System.Windows.Forms.TextBox
    $TextBox.Location = New-Object System.Drawing.Point(10, 35)
    $TextBox.Size = New-Object System.Drawing.Size(360, 120)
    $TextBox.Multiline = $true
    $TextBox.ScrollBars = "Vertical"
    $TextBox.Text = ($Config.Services -join "`r`n")
    $Form.Controls.Add($TextBox)

    $IntervalLabel = New-Object System.Windows.Forms.Label
    $IntervalLabel.Text = "وقت الفحص المجدول (بالدقائق):"
    $IntervalLabel.Location = New-Object System.Drawing.Point(10, 165)
    $IntervalLabel.AutoSize = $true
    $Form.Controls.Add($IntervalLabel)

    $IntervalTextBox = New-Object System.Windows.Forms.TextBox
    $IntervalTextBox.Location = New-Object System.Drawing.Point(200, 162)
    $IntervalTextBox.Size = New-Object System.Drawing.Size(60, 20)
    if ($null -eq $Config.ScheduleIntervalMinutes) { $Config.ScheduleIntervalMinutes = 30 }
    $IntervalTextBox.Text = $Config.ScheduleIntervalMinutes.ToString()
    $Form.Controls.Add($IntervalTextBox)

    $SaveButton = New-Object System.Windows.Forms.Button
    $SaveButton.Location = New-Object System.Drawing.Point(10, 200)
    $SaveButton.Size = New-Object System.Drawing.Size(100, 30)
    $SaveButton.Text = "حفظ الإعدادات"
    $SaveButton.Add_Click({
        $Config.Services = $TextBox.Text -split "`r`n" | Where-Object { $_.Trim() -ne "" }
        $validInterval = 30
        if ([int]::TryParse($IntervalTextBox.Text, [ref]$validInterval) -and $validInterval -gt 0) {
            $Config.ScheduleIntervalMinutes = $validInterval
        } else {
            [System.Windows.Forms.MessageBox]::Show("الرجاء إدخال رقم صحيح لوقت الفحص. تم تعيين القيمة الافتراضية 30", "تنبيه", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            $Config.ScheduleIntervalMinutes = 30
            $IntervalTextBox.Text = "30"
        }
        $Config | ConvertTo-Json | Set-Content $ConfigPath
        [System.Windows.Forms.MessageBox]::Show("تم حفظ الإعدادات بنجاح.", "نجاح", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    })
    $Form.Controls.Add($SaveButton)

    $ScheduleButton = New-Object System.Windows.Forms.Button
    $ScheduleButton.Location = New-Object System.Drawing.Point(120, 200)
    $ScheduleButton.Size = New-Object System.Drawing.Size(150, 30)
    $ScheduleButton.Text = "إنشاء مهمة (Task)"
    $ScheduleButton.Add_Click({
        try {
            $Minutes = $Config.ScheduleIntervalMinutes
            if ($null -eq $Minutes -or $Minutes -le 0) { $Minutes = 30 }
            
            # إعداد المهمة للعمل كل المدة المحددة
            $TaskName = "WinNetxTask"
            $Action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Silent"
            
            # الجدولة بناء على المتغير (على شكل Trigger يتكرر)
            $Trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $Minutes)
            
            # لضمان ظهور الإشعارات للمستخدم، يتم تشغيلها بـ HighestPrivileges وللمستخدم الحالي
            Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -RunLevel Highest -Force | Out-Null
            
            [System.Windows.Forms.MessageBox]::Show("تم إنشاء المهمة المجدولة لتشغيل السكريبت كل $Minutes دقيقة.", "نجاح", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("حدث خطأ أثناء إنشاء المهمة المجدولة. تأكد من تشغيل البرنامج كمسؤول (Run as Administrator). `nالخطأ: $_", "خطأ", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    })
    $Form.Controls.Add($ScheduleButton)

    $RunNowButton = New-Object System.Windows.Forms.Button
    $RunNowButton.Location = New-Object System.Drawing.Point(280, 200)
    $RunNowButton.Size = New-Object System.Drawing.Size(90, 30)
    $RunNowButton.Text = "فحص الآن"
    $RunNowButton.Add_Click({
        Run-Silent
    })
    $Form.Controls.Add($RunNowButton)

    $Form.ShowDialog() | Out-Null
}

if ($Silent) {
    Run-Silent
} else {
    # التأكد من تشغيل السكريبت كمسؤول لعرض الواجهة وإنشاء المهام
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        # إعادة تشغيل السكريبت كمسؤول تلقائياً
        try {
            Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
            exit
        } catch {
            $Title = "تحذير الصلاحيات"
            $Msg = "يجب تشغيل السكريبت كمسؤول (Run as Administrator) لتتمكن من إنشاء المهام المجدولة والتحكم بالخدمات."
            [System.Windows.Forms.MessageBox]::Show($Msg, $Title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            exit
        }
    }
    Show-UI
}
