# Quota alerts, focus timer and monitor placement.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FurinaPlacement {
 [StructLayout(LayoutKind.Sequential)] public struct Rect {public int Left,Top,Right,Bottom;}
 [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h,out Rect r);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
 [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
}
'@
$script:focusMode='idle'; $script:focusPaused=$false; $script:focusRemaining=0
$script:notificationCount=0; $script:quotaNotified=@{}
foreach($entry in @{quotaAlerts=$false; quotaThreshold=10; focusMinutes=25; breakMinutes=5; edgeSnap=$true; physicalX=$null; physicalY=$null}.GetEnumerator()) {
    $script:preferences[$entry.Key]=$entry.Value
}
if($stored) {
    foreach($key in @('quotaAlerts','edgeSnap')){if($stored.$key -is [bool]){$script:preferences[$key]=$stored.$key}}
    foreach($key in @('quotaThreshold','focusMinutes','breakMinutes')) {
        $maximum=if($key -eq 'quotaThreshold'){50}elseif($key -eq 'focusMinutes'){120}else{30}
        if($stored.$key -is [ValueType] -and $stored.$key -ge 1 -and $stored.$key -le $maximum){$script:preferences[$key]=[int]$stored.$key}
    }
    foreach($key in @('physicalX','physicalY')) {
        if($null -ne $stored.$key -and $stored.$key -is [ValueType] -and [Math]::Abs([double]$stored.$key) -lt 100000){$script:preferences[$key]=[int]$stored.$key}
    }
    if($stored.quotaNotified){foreach($property in $stored.quotaNotified.PSObject.Properties){$script:quotaNotified[$property.Name]=[long]$property.Value}}
}
function Get-NativeRect($Window) {
    $handle=(New-Object Windows.Interop.WindowInteropHelper($Window)).Handle
    if($handle -eq [IntPtr]::Zero){return $null}
    $rect=New-Object FurinaPlacement+Rect
    if([FurinaPlacement]::GetWindowRect($handle,[ref]$rect)){return $rect}
    return $null
}
function Set-NativePosition($Window,[int]$X,[int]$Y) {
    $handle=(New-Object Windows.Interop.WindowInteropHelper($Window)).Handle
    if($handle -ne [IntPtr]::Zero){[void][FurinaPlacement]::SetWindowPos($handle,[IntPtr]::Zero,$X,$Y,0,0,0x15)}
}
function Get-ClampedPlacement([int]$X,[int]$Y,[int]$Width,[int]$Height,$Area,[bool]$Snap) {
    $right=[Math]::Max($Area.Left,$Area.Right-$Width)
    $bottom=[Math]::Max($Area.Top,$Area.Bottom-$Height)
    $x=[Math]::Max($Area.Left,[Math]::Min($X,$right))
    $y=[Math]::Max($Area.Top,[Math]::Min($Y,$bottom))
    if($Snap) {
        if([Math]::Abs($x-$Area.Left) -le 20){$x=$Area.Left}elseif([Math]::Abs($x-$right) -le 20){$x=$right}
        if([Math]::Abs($y-$Area.Top) -le 20){$y=$Area.Top}elseif([Math]::Abs($y-$bottom) -le 20){$y=$bottom}
    }
    return @{x=[int]$x; y=[int]$y}
}
function Snap-PetEdges([bool]$Snap=$script:preferences.edgeSnap) {
    $rect=Get-NativeRect $script:pet
    if(-not $rect){return}
    $rectangle=New-Object Drawing.Rectangle($rect.Left,$rect.Top,($rect.Right-$rect.Left),($rect.Bottom-$rect.Top))
    $area=[Windows.Forms.Screen]::FromRectangle($rectangle).WorkingArea
    $position=Get-ClampedPlacement $rect.Left $rect.Top $rectangle.Width $rectangle.Height $area $Snap
    Set-NativePosition $script:pet $position.x $position.y
}
function Record-NativePosition {
    $rect=Get-NativeRect $script:pet
    if($rect){$script:preferences.physicalX=$rect.Left; $script:preferences.physicalY=$rect.Top}
    $script:preferences.quotaNotified=$script:quotaNotified
}
function Place-QuotaNative {
    $petRect=Get-NativeRect $script:pet; $panel=Get-NativeRect $script:popup
    if(-not $petRect -or -not $panel){return}
    $area=[Windows.Forms.Screen]::FromHandle((New-Object Windows.Interop.WindowInteropHelper($script:pet)).Handle).WorkingArea
    $width=$panel.Right-$panel.Left; $height=$panel.Bottom-$panel.Top
    $x=$petRect.Left-$width-12
    if($x -lt $area.Left){$x=$petRect.Right+12}
    $position=Get-ClampedPlacement $x ($petRect.Bottom-$height) $width $height $area $false
    Set-NativePosition $script:popup $position.x $position.y
}
function Notify-Companion([string]$Title,[string]$Message) {
    $script:notificationCount++
    $script:lastNotification=$Title+' · '+$Message
    if(-not $script:testMode){$script:tray.ShowBalloonTip(5000,$Title,$Message,[Windows.Forms.ToolTipIcon]::Info)}
}
function Check-QuotaAlerts($Data) {
    if(-not $script:preferences.quotaAlerts){return}
    $alerts=@()
    foreach($bucket in $Data.buckets) {foreach($window in $bucket.windows) {
        if($null -eq $window.remaining -or $window.remaining -ge $script:preferences.quotaThreshold){continue}
        $cycle=if($window.resetAt){[string]$window.resetAt}else{[DateTime]::Now.ToString('yyyy-MM-dd')}
        $key=$bucket.name+'|'+$window.kind+'|'+$window.minutes+'|'+$cycle
        if(-not $script:quotaNotified.ContainsKey($key)) {
            $script:quotaNotified[$key]=[DateTime]::UtcNow.Ticks
            $alerts+=((Get-WindowLabel $window)+'剩余 '+('{0:0.#}%' -f $window.remaining))
        }
    }}
    if($alerts.Count) {
        Notify-Companion '芙宁娜 · 额度提醒' ($alerts -join '；')
        while($script:quotaNotified.Count -gt 128){$oldest=$script:quotaNotified.GetEnumerator() | Sort-Object Value | Select-Object -First 1; $script:quotaNotified.Remove($oldest.Key)}
        try {Save-Preferences} catch {Write-Warning '额度提醒记录未能保存。'}
    }
}
function Get-RestState {
    if($script:focusMode -eq 'focus' -and -not $script:focusPaused){return 'waiting'}
    return 'idle'
}
function Set-FocusPhase([string]$Phase,[DateTime]$Now=[DateTime]::UtcNow) {
    $script:focusMode=$Phase; $script:focusPaused=$false
    $minutes=if($Phase -eq 'focus'){$script:preferences.focusMinutes}else{$script:preferences.breakMinutes}
    $script:focusRemaining=$minutes*60; $script:focusDeadline=$Now.AddSeconds($script:focusRemaining)
    $script:bubble.IsOpen=$false
    Set-PetState (Get-RestState); Update-Focus $Now
}
function Stop-Focus {
    $script:focusMode='idle'; $script:focusPaused=$false; $script:focusRemaining=0
    Set-PetState 'idle'; Update-Focus
}
function Toggle-FocusPause {
    if($script:focusMode -eq 'idle'){return}
    if($script:focusPaused){$script:focusDeadline=[DateTime]::UtcNow.AddSeconds($script:focusRemaining); $script:focusPaused=$false}
    else {$script:focusRemaining=[Math]::Max(0,($script:focusDeadline-[DateTime]::UtcNow).TotalSeconds); $script:focusPaused=$true}
    Set-PetState (Get-RestState); Update-Focus
}
function Update-Focus([DateTime]$Now=[DateTime]::UtcNow) {
    if($script:focusMode -ne 'idle' -and -not $script:focusPaused) {
        $script:focusRemaining=[Math]::Max(0,($script:focusDeadline-$Now).TotalSeconds)
        if($script:focusRemaining -le 0) {
            if($script:focusMode -eq 'focus') {
                Notify-Companion '专注完成' '做得不错！站起来活动一下，休息计时已开始。'
                Set-FocusPhase 'break' $Now
                if($script:pet.IsVisible){Set-PetState 'waving'}
            } else {
                $script:focusMode='idle'
                Notify-Companion '休息结束' '准备好时，再开启下一轮专注吧。'
                if($script:pet.IsVisible){Set-PetState 'waving'}
            }
        }
    }
    $label=if($script:focusMode -eq 'focus'){'专注'}elseif($script:focusMode -eq 'break'){'休息'}else{'尚未开始'}
    $time=[TimeSpan]::FromSeconds([Math]::Ceiling($script:focusRemaining))
    $script:focusStatus.Text=$label+' '+('{0:00}:{1:00}' -f [Math]::Floor($time.TotalMinutes),$time.Seconds)+$(if($script:focusPaused){' · 已暂停'}else{''})
    $script:pauseButton.Content=if($script:focusPaused){'继续'}else{'暂停'}
    $script:pauseButton.IsEnabled=$script:focusMode -ne 'idle'
    $script:tray.Text='芙宁娜 · '+$script:focusStatus.Text
}

[xml]$extraXaml=@'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="芙宁娜 · 提醒与专注" Width="400" SizeToContent="Height" ResizeMode="NoResize" WindowStartupLocation="CenterScreen" Topmost="True" Background="#192640" Foreground="#EDF5FF">
 <StackPanel Margin="24">
  <TextBlock Text="提醒与专注" FontSize="22" FontWeight="SemiBold" Margin="0,0,0,18"/>
  <CheckBox x:Name="AlertsCheck" Content="低额度提醒（每 5 分钟检查）" Foreground="#EDF5FF"/>
  <TextBlock x:Name="ThresholdLabel" Margin="0,10,0,4"/>
  <Slider x:Name="ThresholdSlider" Minimum="1" Maximum="50" TickFrequency="1" IsSnapToTickEnabled="True" Margin="0,0,0,14"/>
  <CheckBox x:Name="SnapCheck" Content="拖动结束时吸附屏幕边缘" Foreground="#EDF5FF" Margin="0,0,0,14"/>
  <TextBlock Text="移动到显示器" Margin="0,0,0,6"/>
  <ComboBox x:Name="MonitorBox" Margin="0,0,0,6"/>
  <Button x:Name="MoveMonitor" Content="移到所选屏幕" Padding="6" Margin="0,0,0,18"/>
  <TextBlock Text="专注时长（1–120 分钟）"/>
  <TextBox x:Name="FocusMinutes" Margin="0,6,0,12"/>
  <TextBlock Text="休息时长（1–30 分钟）"/>
  <TextBox x:Name="BreakMinutes" Margin="0,6,0,12"/>
  <TextBlock x:Name="FocusStatus" FontSize="22" Foreground="#85D8FF" Margin="0,0,0,12"/>
  <UniformGrid Columns="3"><Button x:Name="StartFocus" Content="开始专注" Padding="5"/><Button x:Name="PauseFocus" Content="暂停"/><Button x:Name="StopFocus" Content="结束"/></UniformGrid>
  <TextBlock Text="保存后生效。专注中暂停主动互动；休息结束不会自动开启下一轮。" TextWrapping="Wrap" FontSize="12" Foreground="#9CB8E1" Margin="0,14,0,12"/>
  <TextBlock x:Name="ExtraStatus" TextWrapping="Wrap" Foreground="#FFBBA8" Margin="0,0,0,10"/>
  <Button x:Name="SaveExtra" Content="保存提醒与计时设置" Padding="10" Background="#345A92" Foreground="White" BorderThickness="0"/>
 </StackPanel>
</Window>
'@
$script:extraWindow=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($extraXaml)))
$script:focusStatus=$script:extraWindow.FindName('FocusStatus'); $script:pauseButton=$script:extraWindow.FindName('PauseFocus')
$script:extraWindow.Add_Closing({param($sender,$eventArgs) if(-not $script:exiting){$eventArgs.Cancel=$true; $script:extraWindow.Hide()}})
$script:extraWindow.FindName('ThresholdSlider').Add_ValueChanged({$script:extraWindow.FindName('ThresholdLabel').Text='剩余低于 '+[int]$script:extraWindow.FindName('ThresholdSlider').Value+'% 时提醒一次'})
function Show-Extras {
    $script:extraWindow.FindName('AlertsCheck').IsChecked=$script:preferences.quotaAlerts
    $script:extraWindow.FindName('SnapCheck').IsChecked=$script:preferences.edgeSnap
    $script:extraWindow.FindName('ThresholdSlider').Value=$script:preferences.quotaThreshold
    $script:extraWindow.FindName('FocusMinutes').Text=[string]$script:preferences.focusMinutes
    $script:extraWindow.FindName('BreakMinutes').Text=[string]$script:preferences.breakMinutes
    $box=$script:extraWindow.FindName('MonitorBox'); $box.Items.Clear()
    foreach($screen in [Windows.Forms.Screen]::AllScreens) {
        $item=New-Object Windows.Controls.ComboBoxItem
        $item.Content=$screen.DeviceName+' · '+$screen.Bounds.Width+'×'+$screen.Bounds.Height
        $item.Tag=$screen; [void]$box.Items.Add($item)
    }
    $box.SelectedIndex=0; $script:extraWindow.FindName('ExtraStatus').Text=''
    Update-Focus; $script:extraWindow.Show(); [void]$script:extraWindow.Activate()
}
function Save-Extras {
    $focus=0; $rest=0
    if(-not [int]::TryParse($script:extraWindow.FindName('FocusMinutes').Text,[ref]$focus) -or $focus -lt 1 -or $focus -gt 120 -or -not [int]::TryParse($script:extraWindow.FindName('BreakMinutes').Text,[ref]$rest) -or $rest -lt 1 -or $rest -gt 30){throw '请输入有效的专注和休息分钟数。'}
    $script:preferences.focusMinutes=$focus; $script:preferences.breakMinutes=$rest
    $script:preferences.quotaAlerts=[bool]$script:extraWindow.FindName('AlertsCheck').IsChecked
    $threshold=[int]$script:extraWindow.FindName('ThresholdSlider').Value
    if($threshold -ne $script:preferences.quotaThreshold){$script:quotaNotified=@{}}
    $script:preferences.quotaThreshold=$threshold
    $script:preferences.edgeSnap=[bool]$script:extraWindow.FindName('SnapCheck').IsChecked
    Save-Preferences
    $script:extraWindow.FindName('ExtraStatus').Text='已保存；时长设置用于下一次计时。'
    $script:nextQuotaPoll=[DateTime]::UtcNow
}
$script:extraWindow.FindName('SaveExtra').Add_Click({try {Save-Extras} catch {$script:extraWindow.FindName('ExtraStatus').Text=$_.Exception.Message}})
$script:extraWindow.FindName('StartFocus').Add_Click({try {Save-Extras; Set-FocusPhase 'focus'} catch {$script:extraWindow.FindName('ExtraStatus').Text=$_.Exception.Message}})
$script:pauseButton.Add_Click({Toggle-FocusPause})
$script:extraWindow.FindName('StopFocus').Add_Click({Stop-Focus})
$script:extraWindow.FindName('MoveMonitor').Add_Click({
    $screen=$script:extraWindow.FindName('MonitorBox').SelectedItem.Tag
    if($screen){Show-Pet; Set-NativePosition $script:pet ($screen.WorkingArea.Right-220) ($screen.WorkingArea.Bottom-240); Snap-PetEdges $false; Save-Preferences}
})
$extraButton=New-Object Windows.Controls.Button; $extraButton.Content='提醒、番茄钟与显示器'; $extraButton.Padding=New-Object Windows.Thickness(8)
$extraButton.Margin=New-Object Windows.Thickness(0,0,0,12); $extraButton.Add_Click({Show-Extras})
$settingsPanel=$script:settingsWindow.Content
$settingsPanel.Children.Insert($settingsPanel.Children.Count-1,$extraButton)
$extraEntry=$trayMenu.Items.Insert(3,(New-Object Windows.Forms.ToolStripMenuItem('提醒与专注')))
$trayMenu.Items[3].Add_Click({Show-Extras})
$script:focusTimer=New-Object Windows.Threading.DispatcherTimer
$script:focusTimer.Interval=[TimeSpan]::FromSeconds(1)
$script:nextQuotaPoll=[DateTime]::UtcNow.AddSeconds(5)
$script:displaySignature=([Windows.Forms.Screen]::AllScreens | ForEach-Object {$_.DeviceName+$_.Bounds.ToString()}) -join ';'
$script:focusTimer.Add_Tick({
    Update-Focus
    if(-not $script:testMode -and $script:preferences.quotaAlerts -and [DateTime]::UtcNow -ge $script:nextQuotaPoll) {
        $script:nextQuotaPoll=[DateTime]::UtcNow.AddMinutes(5)
        Refresh-Quota -Background
    }
    $signature=([Windows.Forms.Screen]::AllScreens | ForEach-Object {$_.DeviceName+$_.Bounds.ToString()}) -join ';'
    if($signature -ne $script:displaySignature){$script:displaySignature=$signature; Snap-PetEdges $false; Save-Preferences}
})
Update-Focus

function Test-Extras {
    Show-Extras
    $script:extraWindow.FindName('FocusMinutes').Text='abc'
    $rejected=$false
    try {Save-Extras} catch {$rejected=$true}
    if(-not $rejected){throw 'Invalid focus duration accepted'}
    $script:extraWindow.FindName('FocusMinutes').Text='25'
    $script:extraWindow.FindName('BreakMinutes').Text='5'
    Save-Extras
    $now=[DateTime]::UtcNow
    Set-FocusPhase 'focus' $now
    $before=$script:state; Play-Interaction
    if($script:state -ne $before -or $script:focusRemaining -ne 1500){throw 'Focus quiet mode failed'}
    Toggle-FocusPause; $remaining=$script:focusRemaining
    Update-Focus $now.AddDays(1)
    if($script:focusRemaining -ne $remaining -or -not $script:focusPaused){throw 'Paused timer advanced'}
    Toggle-FocusPause
    $count=$script:notificationCount
    $script:focusDeadline=$now; Update-Focus $now
    if($script:focusMode -ne 'break' -or $script:focusRemaining -ne 300 -or $script:notificationCount -ne $count+1){throw 'Focus completion failed'}
    Update-Focus $now
    if($script:notificationCount -ne $count+1){throw 'Focus reminder repeated'}
    $script:focusDeadline=$now; Update-Focus $now
    if($script:focusMode -ne 'idle' -or $script:notificationCount -ne $count+2){throw 'Break completion failed'}
    Stop-Focus
    $script:preferences.quotaAlerts=$true; $script:preferences.quotaThreshold=10; $script:quotaNotified=@{}
    $quota='{"buckets":[{"name":"codex","windows":[{"kind":"primary","minutes":300,"remaining":9,"resetAt":123},{"kind":"secondary","minutes":10080,"remaining":null}]}]}' | ConvertFrom-Json
    $count=$script:notificationCount
    Check-QuotaAlerts $quota; Check-QuotaAlerts $quota
    if($script:notificationCount -ne $count+1){throw 'Quota deduplication failed'}
    $record=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if(-not $record.quotaNotified){throw 'Quota reminder ledger not saved'}
    $quota.buckets[0].windows[0].resetAt=124; Check-QuotaAlerts $quota
    if($script:notificationCount -ne $count+2){throw 'New quota reset did not rearm reminder'}
    $quota.buckets[0].windows[0].resetAt=125; $quota.buckets[0].windows[0].remaining=10; Check-QuotaAlerts $quota
    if($script:notificationCount -ne $count+2){throw 'Threshold boundary reminder incorrect'}
    $script:preferences.quotaAlerts=$false; $quota.buckets[0].windows[0].remaining=0; Check-QuotaAlerts $quota
    if($script:notificationCount -ne $count+2){throw 'Disabled quota reminder fired'}
    foreach($area in @((New-Object Drawing.Rectangle(-1920,0,1920,1080)),(New-Object Drawing.Rectangle(1920,-1440,2560,1440)))) {
        $p=Get-ClampedPlacement ($area.Left+12) ($area.Top+9) 192 208 $area $true
        if($p.x -ne $area.Left -or $p.y -ne $area.Top){throw 'Negative-coordinate edge snap failed'}
        $p=Get-ClampedPlacement 99999 99999 288 312 $area $false
        if($p.x -ne $area.Right-288 -or $p.y -ne $area.Bottom-312){throw 'Monitor clamp failed'}
    }
    $rect=Get-NativeRect $script:pet
    Set-NativePosition $script:pet $rect.Left $rect.Top; Record-NativePosition
    if($script:preferences.physicalX -ne $rect.Left){throw 'Native position persistence failed'}
    $script:extraWindow.Hide()
    Write-Output 'Extras passed: focus pause/quiet/completion; quota disable, unknown, boundary, reset-cycle dedup and persistence; multi-monitor coordinates and edge clamp.'
}
