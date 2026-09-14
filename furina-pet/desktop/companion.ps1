# Desktop interaction, persistence, settings and tray support.
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class FurinaDesktop {
    [StructLayout(LayoutKind.Sequential)] public struct Rect { public int Left,Top,Right,Bottom; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr window, StringBuilder value, int size);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr window, int id);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    public static bool IsFullscreen(IntPtr ownWindow) {
        IntPtr window=GetForegroundWindow();
        if(window==IntPtr.Zero || window==ownWindow) return false;
        var name=new StringBuilder(128); GetClassName(window,name,128);
        if(name.ToString()=="Progman" || name.ToString()=="WorkerW" || name.ToString()=="Shell_TrayWnd") return false;
        Rect rect; if(!GetWindowRect(window,out rect)) return false;
        var bounds=System.Windows.Forms.Screen.FromHandle(window).Bounds;
        return rect.Left<=bounds.Left && rect.Top<=bounds.Top && rect.Right>=bounds.Right && rect.Bottom>=bounds.Bottom;
    }
}
'@ -ReferencedAssemblies System.Windows.Forms,System.Drawing
$script:preferences=@{scale=100; left=$null; top=$null; gaze=$true; phrases=$true; interactionSeconds=0; hideFullscreen=$true}
if(Test-Path -LiteralPath $SettingsPath) {
    try {
        $stored=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach($key in @('gaze','phrases','hideFullscreen')) {
            if($stored.$key -is [bool]){$script:preferences[$key]=$stored.$key}
        }
        if($stored.scale -is [ValueType] -and -not [double]::IsNaN([double]$stored.scale) -and -not [double]::IsInfinity([double]$stored.scale)) {
            $script:preferences.scale=[Math]::Max(60,[Math]::Min(180,[double]$stored.scale))
        }
        if($stored.interactionSeconds -in @(0,60,120,300)){$script:preferences.interactionSeconds=[int]$stored.interactionSeconds}
        foreach($key in @('left','top')) {
            if($stored.$key -is [ValueType] -and -not [double]::IsNaN([double]$stored.$key) -and -not [double]::IsInfinity([double]$stored.$key)){$script:preferences[$key]=[double]$stored.$key}
        }
    } catch { Write-Warning '无法读取宠物配置，已使用默认设置。' }
}
$script:manuallyHidden=$false
$script:fullscreenHidden=$false
$script:lastInteraction=[DateTime]::UtcNow
$script:startupKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:startupName='FurinaQuotaPet'

function Get-StartupCommand {
    $hostExe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    return ('"'+$hostExe+'" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "'+(Join-Path $PSScriptRoot 'launch.ps1')+'"')
}
function Get-StartupEnabled {
    return ($null -ne (Get-ItemProperty -LiteralPath $script:startupKey -Name $script:startupName -ErrorAction SilentlyContinue))
}
function Set-StartupEnabled([bool]$Enabled) {
    if($script:testMode){$script:testStartupCommand=if($Enabled){Get-StartupCommand}else{$null}; return}
    if($Enabled) {
        if(-not (Test-Path -LiteralPath $script:startupKey)){New-Item -Path $script:startupKey -Force | Out-Null}
        New-ItemProperty -LiteralPath $script:startupKey -Name $script:startupName -Value (Get-StartupCommand) -PropertyType String -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $script:startupKey -Name $script:startupName -ErrorAction SilentlyContinue
    }
}
function Save-Preferences {
    Record-NativePosition
    $script:preferences.left=$script:pet.Left; $script:preferences.top=$script:pet.Top
    $temporary=$SettingsPath+'.tmp'
    $script:preferences | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $SettingsPath -Force
}
function Get-PetWorkArea {
    $source=[Windows.PresentationSource]::FromVisual($script:pet)
    if(-not $source){return [Windows.SystemParameters]::WorkArea}
    $screen=[Windows.Forms.Screen]::FromHandle((New-Object Windows.Interop.WindowInteropHelper($script:pet)).Handle)
    $bounds=$screen.WorkingArea
    $matrix=$source.CompositionTarget.TransformFromDevice
    $origin=$matrix.Transform((New-Object Windows.Point($bounds.Left,$bounds.Top)))
    $size=$matrix.Transform((New-Object Windows.Vector($bounds.Width,$bounds.Height)))
    return (New-Object Windows.Rect($origin.X,$origin.Y,$size.X,$size.Y))
}
function Apply-PetSize {
    $script:pet.Width=192*$script:preferences.scale/100
    $script:pet.Height=208*$script:preferences.scale/100
}
function Restore-PetPosition {
    Apply-PetSize
    if($null -ne $script:preferences.physicalX -and $null -ne $script:preferences.physicalY) {
        Set-NativePosition $script:pet $script:preferences.physicalX $script:preferences.physicalY
        Snap-PetEdges $false
        return
    }
    if($null -ne $script:preferences.left -and $null -ne $script:preferences.top) {
        $script:pet.Left=$script:preferences.left; $script:pet.Top=$script:preferences.top
    }
    # Keep a reachable window even after a display is disconnected.
    $area=Get-PetWorkArea
    $script:pet.Left=[Math]::Max($area.Left,[Math]::Min($script:pet.Left,$area.Right-$script:pet.Width))
    $script:pet.Top=[Math]::Max($area.Top,[Math]::Min($script:pet.Top,$area.Bottom-$script:pet.Height))
}
$script:hotkeyRegistered=$false
$script:hotkeyHook=[Windows.Interop.HwndSourceHook]{
    param($hwnd,$message,$wParam,$lParam,[ref]$handled)
    if($message -eq 0x312 -and $wParam.ToInt32() -eq 7821) {
        if($script:pet.IsVisible){Hide-Pet}else{Show-Pet}
        $handled.Value=$true
    }
    return [IntPtr]::Zero
}
$script:pet.Add_SourceInitialized({
    Restore-PetPosition
    if(-not $script:testMode -or $DesktopTest) {
        $script:windowSource=[Windows.PresentationSource]::FromVisual($script:pet)
        $script:windowSource.AddHook($script:hotkeyHook)
        $script:hotkeyHandle=$script:windowSource.Handle
        $script:hotkeyRegistered=[FurinaDesktop]::RegisterHotKey($script:hotkeyHandle,7821,0x4003,0x79)
        if(-not $script:hotkeyRegistered){Write-Warning 'Ctrl+Alt+F10 已被占用，请使用托盘显示或隐藏。'}
    }
})
Apply-PetSize
if($null -ne $script:preferences.left){$script:pet.Left=$script:preferences.left}
if($null -ne $script:preferences.top){$script:pet.Top=$script:preferences.top}

$script:bubble=New-Object Windows.Controls.Primitives.Popup
$script:bubble.PlacementTarget=$script:image; $script:bubble.Placement='Top'
$script:bubble.AllowsTransparency=$true; $script:bubble.StaysOpen=$true
$bubbleBorder=New-Object Windows.Controls.Border
$bubbleBorder.Background=[Windows.Media.Brushes]::MidnightBlue
$bubbleBorder.CornerRadius=New-Object Windows.CornerRadius(12)
$bubbleBorder.Padding=New-Object Windows.Thickness(14,10,14,10)
$script:bubbleText=New-Object Windows.Controls.TextBlock
$script:bubbleText.Foreground=[Windows.Media.Brushes]::White
$script:bubbleText.FontSize=14; $script:bubbleText.MaxWidth=230; $script:bubbleText.TextWrapping='Wrap'
$bubbleBorder.Child=$script:bubbleText; $script:bubble.Child=$bubbleBorder
$script:bubbleTimer=New-Object Windows.Threading.DispatcherTimer
$script:bubbleTimer.Interval=[TimeSpan]::FromSeconds(3)
$script:bubbleTimer.Add_Tick({$script:bubble.IsOpen=$false; $script:bubbleTimer.Stop()})
function Play-Interaction {
    if(($script:focusMode -eq 'focus' -and -not $script:focusPaused) -or $script:queryTimer.IsEnabled -or -not $script:pet.IsVisible){return}
    Set-PetState (@('waving','jumping') | Get-Random)
    $script:lastInteraction=[DateTime]::UtcNow
    if($script:preferences.phrases) {
        $script:bubbleText.Text=@('今天的舞台，也有你的座位。','休息一下，精彩还在后面呢。','哼哼，轮到我登场啦！','工作辛苦啦，给你一个小小的掌声。') | Get-Random
        $script:bubble.IsOpen=$true; $script:bubbleTimer.Stop(); $script:bubbleTimer.Start()
    }
}
$script:clickTimer=New-Object Windows.Threading.DispatcherTimer
$script:clickTimer.Interval=[TimeSpan]::FromMilliseconds([Windows.Forms.SystemInformation]::DoubleClickTime+20)
$script:clickTimer.Add_Tick({$script:clickTimer.Stop(); Show-Quota})
function Hide-Pet {
    $script:manuallyHidden=$true; $script:clickTimer.Stop()
    $script:popup.Hide(); $script:bubble.IsOpen=$false; $script:pet.Hide()
    $script:animationTimer.Stop(); $script:gazeTimer.Stop()
}
function Show-Pet {
    $script:manuallyHidden=$false
    $script:fullscreenHidden=$false
    $script:pet.Show(); Restore-PetPosition
    $script:animationTimer.Start(); $script:gazeTimer.Start()
}

[xml]$settingsXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
 Title="芙宁娜 · 设置" Width="390" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Background="#192640" Foreground="#EDF5FF" Topmost="True">
 <StackPanel Margin="24">
  <TextBlock Text="陪伴，由你决定" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,20"/>
  <TextBlock x:Name="SizeLabel" Text="宠物大小"/>
  <Slider x:Name="SizeSlider" Minimum="60" Maximum="180" TickFrequency="10" IsSnapToTickEnabled="True" Margin="0,10,0,16"/>
  <CheckBox x:Name="GazeCheck" Content="鼠标靠近时转动视线" Foreground="#EDF5FF" Margin="0,0,0,14"/>
  <CheckBox x:Name="PhrasesCheck" Content="双击互动时显示角色风格短语" Foreground="#EDF5FF" Margin="0,0,0,14"/>
  <TextBlock Text="主动互动频率" Margin="0,0,0,6"/>
  <ComboBox x:Name="FrequencyBox" Margin="0,0,0,16"/>
  <CheckBox x:Name="FullscreenCheck" Content="全屏应用前台时自动隐藏" Foreground="#EDF5FF" Margin="0,0,0,14"/>
  <CheckBox x:Name="StartupCheck" Content="登录 Windows 后自动启动（默认关闭）" Foreground="#EDF5FF" Margin="0,0,0,8"/>
  <TextBlock Text="位置在拖动后自动保存；单击查看额度，双击互动。" TextWrapping="Wrap" FontSize="12" Foreground="#9CB8E1" Margin="0,8,0,12"/>
  <TextBlock x:Name="SettingsStatus" TextWrapping="Wrap" Foreground="#FFBBA8" FontSize="12" Margin="0,0,0,12"/>
  <Button x:Name="SaveSettings" Content="保存设置" Padding="10" Background="#345A92" Foreground="White" BorderThickness="0"/>
 </StackPanel>
</Window>
'@
$script:settingsWindow=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($settingsXaml)))
$script:sizeSlider=$script:settingsWindow.FindName('SizeSlider')
$script:frequencyBox=$script:settingsWindow.FindName('FrequencyBox')
foreach($seconds in @(0,60,120,300)) {
    $choice=New-Object Windows.Controls.ComboBoxItem
    $choice.Content=if($seconds -eq 0){'仅双击互动'}else{'每 '+($seconds/60)+' 分钟'}
    $choice.Tag=$seconds; [void]$script:frequencyBox.Items.Add($choice)
}
$script:sizeSlider.Add_ValueChanged({$script:settingsWindow.FindName('SizeLabel').Text='宠物大小 · '+[int]$script:sizeSlider.Value+'%'})
$script:settingsWindow.Add_Closing({param($sender,$eventArgs) if(-not $script:exiting){$eventArgs.Cancel=$true; $script:settingsWindow.Hide()}})
function Show-Settings {
    $script:clickTimer.Stop()
    $script:sizeSlider.Value=$script:preferences.scale
    $script:settingsWindow.FindName('GazeCheck').IsChecked=$script:preferences.gaze
    $script:settingsWindow.FindName('PhrasesCheck').IsChecked=$script:preferences.phrases
    $script:settingsWindow.FindName('FullscreenCheck').IsChecked=$script:preferences.hideFullscreen
    $script:settingsWindow.FindName('StartupCheck').IsChecked=(Get-StartupEnabled)
    foreach($choice in $script:frequencyBox.Items){if($choice.Tag -eq $script:preferences.interactionSeconds){$script:frequencyBox.SelectedItem=$choice}}
    $script:settingsWindow.FindName('SettingsStatus').Text=''
    $script:settingsWindow.Show(); [void]$script:settingsWindow.Activate()
}
function Save-SettingsFromControls {
    $enableStartup=[bool]$script:settingsWindow.FindName('StartupCheck').IsChecked
    if($enableStartup -ne (Get-StartupEnabled)){Set-StartupEnabled $enableStartup}
    $script:preferences.scale=[int]$script:sizeSlider.Value
    $script:preferences.gaze=[bool]$script:settingsWindow.FindName('GazeCheck').IsChecked
    $script:preferences.phrases=[bool]$script:settingsWindow.FindName('PhrasesCheck').IsChecked
    $script:preferences.hideFullscreen=[bool]$script:settingsWindow.FindName('FullscreenCheck').IsChecked
    $script:preferences.interactionSeconds=[int]$script:frequencyBox.SelectedItem.Tag
    Restore-PetPosition; Save-Preferences
    $script:lastInteraction=[DateTime]::UtcNow
    $script:lookIndex=$null
    if(-not $script:preferences.phrases){$script:bubble.IsOpen=$false}
    $script:settingsWindow.Hide()
}
$script:settingsWindow.FindName('SaveSettings').Add_Click({
    try {Save-SettingsFromControls} catch {$script:settingsWindow.FindName('SettingsStatus').Text='保存失败，请检查目录权限后重试。'}
})

$script:tray=New-Object Windows.Forms.NotifyIcon
$script:trayIcon=New-Object Drawing.Icon((Join-Path $PSScriptRoot 'assets\furina.ico'))
$script:tray.Icon=$script:trayIcon
$script:tray.Text='芙宁娜 · 双击托盘显示宠物'
$trayMenu=New-Object Windows.Forms.ContextMenuStrip
foreach($label in @('显示宠物','隐藏宠物','查看额度','设置','退出')) {
    $entry=$trayMenu.Items.Add($label)
    switch($label) {
        '显示宠物' {$entry.Add_Click({Show-Pet})}
        '隐藏宠物' {$entry.Add_Click({Hide-Pet})}
        '查看额度' {$entry.Add_Click({Show-Pet; Show-Quota})}
        '设置' {$entry.Add_Click({Show-Settings})}
        '退出' {$entry.Add_Click({$script:pet.Close()})}
    }
}
$script:tray.ContextMenuStrip=$trayMenu
$script:tray.Add_DoubleClick({Show-Pet})
$script:tray.Visible=(-not $script:testMode -or $DesktopTest)
$script:desktopTimer=New-Object Windows.Threading.DispatcherTimer
$script:desktopTimer.Interval=[TimeSpan]::FromMilliseconds(700)
function Update-DesktopVisibility([bool]$Fullscreen) {
    if($script:manuallyHidden){return}
    $shouldHide=$script:preferences.hideFullscreen -and $Fullscreen -and -not $script:settingsWindow.IsVisible -and -not $script:extraWindow.IsVisible
    if($shouldHide -and -not $script:fullscreenHidden) {
        $script:fullscreenHidden=$true; $script:clickTimer.Stop(); $script:popup.Hide(); $script:bubble.IsOpen=$false
        $script:pet.Hide(); $script:animationTimer.Stop(); $script:gazeTimer.Stop()
    } elseif(-not $shouldHide -and $script:fullscreenHidden) {Show-Pet}
}
$script:desktopTimer.Add_Tick({
    $handle=(New-Object Windows.Interop.WindowInteropHelper($script:pet)).Handle
    Update-DesktopVisibility ([FurinaDesktop]::IsFullscreen($handle))
    if($script:preferences.interactionSeconds -gt 0 -and $script:state -eq 'idle' -and -not $script:press -and -not $script:popup.IsVisible -and -not $script:settingsWindow.IsVisible -and ([DateTime]::UtcNow-$script:lastInteraction).TotalSeconds -ge $script:preferences.interactionSeconds){Play-Interaction}
})
function Close-Companion {
    $script:exiting=$true
    $script:focusTimer.Stop(); $script:extraWindow.Close()
    $script:clickTimer.Stop(); $script:bubbleTimer.Stop(); $script:desktopTimer.Stop()
    $script:bubble.IsOpen=$false; $script:settingsWindow.Close()
    if($script:hotkeyRegistered){[void][FurinaDesktop]::UnregisterHotKey($script:hotkeyHandle,7821)}
    if($script:windowSource -and -not $script:windowSource.IsDisposed){$script:windowSource.RemoveHook($script:hotkeyHook)}
    $script:tray.Visible=$false; $script:tray.Dispose(); $script:trayIcon.Dispose(); $trayMenu.Dispose()
    if(-not $script:testMode){try {Save-Preferences} catch {Write-Warning '配置未能保存。'}}
}
