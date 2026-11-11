# ============================================================================
# DisplayTray.ps1 v5 - управление ТВ из трея Windows 11
#
#  * иконка в трее: зелёный экран = ТВ включён, серый = выключен
#  * левый клик по иконке - включить/выключить ТВ (мониторы всегда остаются включёнными)
#  * правый клик - меню: переключить, запомнить раскладку, автозапуск, выход
#  * автозапуск вместе с Windows (пункт меню "Автозапуск")
#
# Нужен MultiMonitorTool.exe (NirSoft) в этой же папке.
#
# ЗАПУСК:  powershell -NoProfile -ExecutionPolicy Bypass -STA -File DisplayTray.ps1
#
# ПЕРВАЯ НАСТРОЙКА (один раз, через меню в трее):
#   1) Включите все дисплеи (мониторы + ТВ), расставьте их, задайте частоты
#      (AOC 144 Гц, основной AOC)  ->  меню: "Запомнить раскладку: ТВ включён"
#   2) Отключите ТВ в Параметрах Windows ("Отключить этот дисплей"), проверьте мониторы
#      ->  меню: "Запомнить раскладку: ТВ выключен"
#   3) Поставьте галочку "Автозапуск"
# ============================================================================

$ErrorActionPreference = 'Stop'

# ------------------------- НАСТРОЙКИ ---------------------------------------
$MonitorIds = @('AOC2402', 'GSM5AB6')   # мониторы (Short Monitor ID), всегда включены
$TvId       = 'MTC0030'                 # ТВ

$Dir        = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$Tool       = Join-Path $Dir 'MultiMonitorTool.exe'
$CfgMonitors = Join-Path $Dir 'config_monitors.cfg'   # ТВ выключен
$CfgWithTv   = Join-Path $Dir 'config_with_tv.cfg'    # мониторы + ТВ
$LogFile    = Join-Path $Dir 'DisplayTray.log'
$RunKey     = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunName    = 'DisplayTvTray'
# ---------------------------------------------------------------------------

# Один экземпляр
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\DisplayTvTray')
if (-not $script:mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class Win
{
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]   public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    // ID всех мониторов, которые сейчас активны на рабочем столе (быстро, без внешних программ)
    public static string[] ActiveMonitorIds()
    {
        List<string> list = new List<string>();
        DISPLAY_DEVICE a = new DISPLAY_DEVICE();
        a.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        for (uint i = 0; EnumDisplayDevices(null, i, ref a, 0); i++)
        {
            if ((a.StateFlags & 0x1) == 0) continue;           // адаптер не на рабочем столе
            DISPLAY_DEVICE m = new DISPLAY_DEVICE();
            m.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
            for (uint j = 0; EnumDisplayDevices(a.DeviceName, j, ref m, 0); j++)
            {
                if ((m.StateFlags & 0x1) != 0) list.Add(m.DeviceID);
            }
        }
        return list.ToArray();
    }
}
'@

# Скрываем консольное окно
[void][Win]::ShowWindow([Win]::GetConsoleWindow(), 0)

# ------------------------- ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ -------------------------
function Log([string]$msg) {
    try { "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')  $msg" | Add-Content -Path $LogFile } catch {}
}

function Run-Tool([string]$toolArgs) {
    Log "tool: $toolArgs"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Tool
    $psi.Arguments = $toolArgs
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    [void]$p.WaitForExit(15000)
}

function Test-IdActive($list, [string]$id) {
    foreach ($x in $list) { if ($x -like ('*\' + $id + '\*')) { return $true } }
    return $false
}

# Tv = ТВ активен; Mon = все мониторы активны
function Get-State {
    $l = [Win]::ActiveMonitorIds()
    $missing = @($MonitorIds | Where-Object { -not (Test-IdActive $l $_) })
    return @{ Tv = (Test-IdActive $l $TvId); Mon = ($missing.Count -eq 0) }
}

function Notify([string]$title, [string]$text) {
    $script:tray.ShowBalloonTip(2500, $title, $text, [System.Windows.Forms.ToolTipIcon]::Info)
}

# ------------------------- ПЕРЕКЛЮЧЕНИЕ ТВ ---------------------------------
function Set-Tv([bool]$on) {
    if ($script:busy) { return }
    $script:busy = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $cfg = if ($on) { $CfgWithTv } else { $CfgMonitors }
        if (-not (Test-Path $cfg) -or -not (Test-Path $Tool)) {
            Notify 'Нет данных' 'Не найден MultiMonitorTool.exe или сохранённая раскладка. Сначала сохраните обе раскладки через меню.'
            return
        }
        Log "=== TV -> $(if ($on) {'ON'} else {'OFF'})"
        $ok = $false
        for ($try = 1; ($try -le 3) -and (-not $ok); $try++) {
            if ($try -ge 2) {
                # запасной вариант: принудительно включить пропавшие мониторы / выключить ТВ
                $s = Get-State
                if (-not $s.Mon) { foreach ($id in $MonitorIds) { Run-Tool "/enable $id" } }
                if ((-not $on) -and $s.Tv) { Run-Tool "/disable $TvId" }
            }
            Run-Tool "/LoadConfig `"$cfg`""
            $deadline = (Get-Date).AddSeconds(4)
            do {
                $s = Get-State
                if ($s.Mon -and ($s.Tv -eq $on)) { $ok = $true; break }
                Start-Sleep -Milliseconds 100
            } while ((Get-Date) -lt $deadline)
        }
        Log ("{0} in {1} ms" -f $(if ($ok) {'OK'} else {'FAILED'}), $sw.ElapsedMilliseconds)
        if (-not $ok) { Notify 'Не удалось переключить' 'Подробности в DisplayTray.log' }
    }
    finally {
        $script:busy = $false
        Update-Ui
    }
}

function Save-Layout([bool]$tvOn) {
    $s = Get-State
    if (-not $s.Mon -or ($s.Tv -ne $tvOn)) {
        $need = if ($tvOn) { 'все мониторы и ТВ должны быть включены' } else { 'мониторы включены, ТВ выключен' }
        Notify 'Раскладка не сохранена' "Сейчас нужно состояние: $need."
        return
    }
    $cfg = if ($tvOn) { $CfgWithTv } else { $CfgMonitors }
    Run-Tool "/SaveConfig `"$cfg`""
    Log "Saved layout, tvOn=$tvOn"
    Notify 'Готово' 'Раскладка сохранена.'
}

# ------------------------- АВТОЗАПУСК --------------------------------------
function Get-Autostart {
    try { return ($null -ne (Get-ItemProperty -Path $RunKey -Name $RunName -ErrorAction Stop).$RunName) }
    catch { return $false }
}

function Set-Autostart([bool]$on) {
    if ($on) {
        # VBS-обёртка запускает PowerShell полностью скрыто, без мелькающего окна
        $vbs  = Join-Path $Dir 'DisplayTray-start.vbs'
        $line = 'CreateObject("WScript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ""' + $PSCommandPath + '""", 0, False'
        Set-Content -Path $vbs -Value $line -Encoding Default
        Set-ItemProperty -Path $RunKey -Name $RunName -Value ('wscript.exe "' + $vbs + '"')
        Log "Autostart ON"
    } else {
        Remove-ItemProperty -Path $RunKey -Name $RunName -ErrorAction SilentlyContinue
        Log "Autostart OFF"
    }
}

# ------------------------- ИКОНКИ ------------------------------------------
function New-TvIcon([System.Drawing.Color]$fill) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $pen   = [System.Drawing.Pen]::new([System.Drawing.Color]::White, 2.5)
    $brush = [System.Drawing.SolidBrush]::new($fill)
    $g.FillRectangle($brush, 3, 5, 26, 17)
    $g.DrawRectangle($pen, 3, 5, 26, 17)
    $g.DrawLine($pen, 16, 22, 16, 27)
    $g.DrawLine($pen, 9, 28, 23, 28)
    $g.Dispose(); $pen.Dispose(); $brush.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

$iconOn  = New-TvIcon ([System.Drawing.Color]::FromArgb(46, 160, 67))
$iconOff = New-TvIcon ([System.Drawing.Color]::FromArgb(110, 110, 110))

# ------------------------- ТРЕЙ И МЕНЮ -------------------------------------
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:busy   = $false
$script:lastTv = $null

$script:tray = New-Object System.Windows.Forms.NotifyIcon
$menu = New-Object System.Windows.Forms.ContextMenuStrip

$miToggle = $menu.Items.Add('Включить ТВ')
$miToggle.Font = New-Object System.Drawing.Font($miToggle.Font, [System.Drawing.FontStyle]::Bold)
[void]$menu.Items.Add('-')
$miSaveOn  = $menu.Items.Add('Запомнить раскладку: ТВ включён')
$miSaveOff = $menu.Items.Add('Запомнить раскладку: ТВ выключен')
[void]$menu.Items.Add('-')
$miAuto = $menu.Items.Add('Автозапуск')
$miAuto.CheckOnClick = $true
$miAuto.Checked = Get-Autostart
$miLog  = $menu.Items.Add('Открыть лог')
[void]$menu.Items.Add('-')
$miExit = $menu.Items.Add('Выход')

function Update-Ui {
    $tv = (Get-State).Tv
    $script:lastTv = $tv
    $script:tray.Icon = if ($tv) { $iconOn } else { $iconOff }
    $script:tray.Text = if ($tv) { 'ТВ: включён' } else { 'ТВ: выключен' }
    $miToggle.Text    = if ($tv) { 'Выключить ТВ' } else { 'Включить ТВ' }
}

$miToggle.Add_Click({ Set-Tv (-not (Get-State).Tv) })
$miSaveOn.Add_Click({ Save-Layout $true })
$miSaveOff.Add_Click({ Save-Layout $false })
$miAuto.Add_Click({ Set-Autostart $miAuto.Checked })
$miLog.Add_Click({ if (Test-Path $LogFile) { Start-Process notepad.exe $LogFile } })
$miExit.Add_Click({
    $script:timer.Stop()
    $script:tray.Visible = $false
    $script:tray.Dispose()
    [System.Windows.Forms.Application]::Exit()
})

$script:tray.ContextMenuStrip = $menu
$script:tray.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Set-Tv (-not (Get-State).Tv) }
})

# Следим за внешними изменениями (например, Win+P): обновляем иконку раз в 2 секунды
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 2000
$script:timer.Add_Tick({
    if (-not $script:busy) {
        if ((Get-State).Tv -ne $script:lastTv) { Update-Ui }
    }
})

Update-Ui
$script:tray.Visible = $true
$script:timer.Start()

if (-not (Test-Path $CfgMonitors) -or -not (Test-Path $CfgWithTv)) {
    Notify 'Первая настройка' 'Сохраните обе раскладки через правый клик по иконке.'
}
Log "Started"

[System.Windows.Forms.Application]::Run()
