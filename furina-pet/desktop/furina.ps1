param(
    [string]$PythonExe = '',
    [switch]$SmokeTest,
    [switch]$IntegrationTest,
    [switch]$DesktopTest,
    [string]$SettingsPath = ''
)
$ErrorActionPreference = 'Stop'
if(-not $PythonExe) {
    $bundledPython=Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'
    if(Test-Path -LiteralPath $bundledPython){$PythonExe=$bundledPython}
    else {
        $pythonCommand=Get-Command python.exe -ErrorAction SilentlyContinue
        if(-not $pythonCommand){throw '未找到 Python 3，请安装 Python 或用 -PythonExe 指定其路径。'}
        $PythonExe=$pythonCommand.Source
    }
}
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
Add-Type -AssemblyName System.Windows.Forms
$script:testMode = $SmokeTest -or $IntegrationTest -or $DesktopTest
$script:temporarySettings=$script:testMode -and -not $SettingsPath
if(-not $SettingsPath){$SettingsPath=if($script:testMode){Join-Path $PSScriptRoot ('test-settings-'+[Guid]::NewGuid().ToString()+'.json')}else{Join-Path $PSScriptRoot 'settings.json'}}
$script:instanceMutex = New-Object Threading.Mutex($false, 'Local\FurinaQuotaPet_v1')
if (-not $script:testMode) {
    try { $acquired=$script:instanceMutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
    if(-not $acquired){$script:instanceMutex.Dispose(); return}
}
$script:ownsMutex = -not $script:testMode
$script:queryProcess = $null
$script:press = $null
$script:dragging = $false
$script:state = 'idle'
$script:frame = 0
$script:lookIndex = $null
$script:animations = @{
    idle = @{row=0; durations=@(280,110,110,140,140,320)}
    'running-right' = @{row=1; durations=@(120,120,120,120,120,120,120,220)}
    'running-left' = @{row=2; durations=@(120,120,120,120,120,120,120,220)}
    waving = @{row=3; durations=@(140,140,140,280)}
    jumping = @{row=4; durations=@(140,140,140,140,280)}
    failed = @{row=5; durations=@(140,140,140,140,140,140,140,240)}
    waiting = @{row=6; durations=@(150,150,150,150,150,260)}
    running = @{row=7; durations=@(120,120,120,120,120,220)}
    review = @{row=8; durations=@(150,150,150,150,150,280)}
}

$script:atlas = New-Object Windows.Media.Imaging.BitmapImage
$script:atlas.BeginInit()
$script:atlas.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
$script:atlas.UriSource = New-Object Uri((Join-Path $PSScriptRoot 'assets\spritesheet.png'))
$script:atlas.EndInit()
$script:atlas.Freeze()
$script:cells = @{}
foreach ($stateName in $script:animations.Keys) {
    $animation = $script:animations[$stateName]
    $frames = @()
    for ($i=0; $i -lt $animation.durations.Count; $i++) {
        $rectangle = New-Object Windows.Int32Rect(($i*192),($animation.row*208),192,208)
        $cell = New-Object Windows.Media.Imaging.CroppedBitmap($script:atlas,$rectangle)
        $cell.Freeze()
        $frames += $cell
    }
    $script:cells[$stateName] = $frames
}
$script:lookCells = @()
foreach($rowIndex in @(9,10)) {
    for($i=0;$i -lt 8;$i++) {
        $rectangle=New-Object Windows.Int32Rect(($i*192),($rowIndex*208),192,208)
        $cell=New-Object Windows.Media.Imaging.CroppedBitmap($script:atlas,$rectangle)
        $cell.Freeze(); $script:lookCells += $cell
    }
}

$script:pet = New-Object Windows.Window
$script:pet.Title = '芙宁娜 · 点击查看额度'
$script:pet.Width=192; $script:pet.Height=208
$script:pet.WindowStyle='None'; $script:pet.ResizeMode='NoResize'
$script:pet.AllowsTransparency=$true; $script:pet.Background=[Windows.Media.Brushes]::Transparent
$script:pet.Topmost=$true; $script:pet.ShowInTaskbar=$false
$script:image = New-Object Windows.Controls.Image
$script:image.Stretch='Uniform'
$script:image.ToolTip='单击查看额度 · 双击互动 · 拖动移动 · 右键设置'
$script:pet.Content=$script:image
$workArea=[Windows.SystemParameters]::WorkArea
$script:pet.Left=$workArea.Right-220; $script:pet.Top=$workArea.Bottom-240
. (Join-Path $PSScriptRoot 'companion.ps1')

[xml]$popupXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="芙宁娜 · 当前额度"
        Width="340" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize"
        AllowsTransparency="True" Background="Transparent" Topmost="True" ShowInTaskbar="False">
 <Border Background="#F51A253D" CornerRadius="18" BorderBrush="#567BB7" BorderThickness="1" Padding="20">
  <StackPanel>
   <DockPanel Margin="0,0,0,16">
    <Button x:Name="CloseButton" DockPanel.Dock="Right" Content="×" Width="26" Height="26"
            Background="Transparent" BorderThickness="0" Foreground="#B9CFF3" FontSize="22" ToolTip="关闭额度面板"/>
    <StackPanel><TextBlock Text="当前额度" Foreground="#F1F5FF" FontSize="22" FontWeight="SemiBold"/>
     <TextBlock Text="芙宁娜为你查看" Foreground="#9CB8E1" FontSize="12" Margin="0,4,0,0"/></StackPanel>
   </DockPanel>
   <StackPanel x:Name="QuotaCards"/>
   <TextBlock x:Name="StatusText" Text="正在查看额度…" Foreground="#9CB8E1" FontSize="12"
              TextWrapping="Wrap" Margin="0,8,0,12"/>
   <Button x:Name="RefreshButton" Content="刷新额度" Padding="12,7" Background="#345A92"
           BorderThickness="0" Foreground="White" FontSize="13"/>
  </StackPanel>
 </Border>
</Window>
'@
$script:popup=[Windows.Markup.XamlReader]::Load((New-Object Xml.XmlNodeReader($popupXaml)))
$script:cards=$script:popup.FindName('QuotaCards')
$script:status=$script:popup.FindName('StatusText')
$script:refreshButton=$script:popup.FindName('RefreshButton')
$script:popup.FindName('CloseButton').Add_Click({ $script:popup.Hide(); if($script:state -eq 'review'){Set-PetState 'idle'} })
$script:popup.Add_PreviewKeyDown({ param($sender,$eventArgs) if ($eventArgs.Key -eq 'Escape') { $script:popup.Hide(); if($script:state -eq 'review'){Set-PetState 'idle'} } })

function Set-PetState([string]$NewState) {
    $script:state=$NewState; $script:frame=0; $script:lookIndex=$null
    $script:image.Source=$script:cells[$NewState][0]
    $script:animationTimer.Interval=[TimeSpan]::FromMilliseconds($script:animations[$NewState].durations[0])
}
function Position-Popup {
    $area=Get-PetWorkArea
    $height=if($script:popup.ActualHeight -gt 0){$script:popup.ActualHeight}else{350}
    $x=$script:pet.Left-352
    if($x -lt $area.Left){$x=$script:pet.Left+$script:pet.Width+12}
    $script:popup.Left=[Math]::Max($area.Left,[Math]::Min($x,$area.Right-340))
    $script:popup.Top=[Math]::Max($area.Top,[Math]::Min($script:pet.Top+$script:pet.Height-$height,$area.Bottom-$height))
}
function Get-WindowLabel($WindowData) {
    if($WindowData.minutes -eq 300){return '五小时额度'}
    if($WindowData.minutes -eq 10080){return '每周额度'}
    if($null -eq $WindowData.minutes){return '额度窗口'}
    if($WindowData.minutes -ge 1440){return ('{0:g} 天额度' -f ($WindowData.minutes/1440))}
    if($WindowData.minutes -ge 60){return ('{0:g} 小时额度' -f ($WindowData.minutes/60))}
    return ('{0} 分钟额度' -f $WindowData.minutes)
}
function Render-Quota($Data) {
    $script:cards.Children.Clear()
    foreach($bucket in $Data.buckets) {
        if($Data.buckets.Count -gt 1) {
            $heading=New-Object Windows.Controls.TextBlock
            $heading.Text=$bucket.name; $heading.Foreground=[Windows.Media.Brushes]::LightSteelBlue
            [void]$script:cards.Children.Add($heading)
        }
        foreach($windowData in $bucket.windows) {
            $box=New-Object Windows.Controls.StackPanel
            $box.Margin=New-Object Windows.Thickness(0,0,0,16)
            $row=New-Object Windows.Controls.DockPanel
            $percent=New-Object Windows.Controls.TextBlock
            $percent.Text=if($null -eq $windowData.remaining){'未知'}else{('{0:0.#}%' -f $windowData.remaining)}
            $percent.Foreground=[Windows.Media.Brushes]::White; $percent.FontSize=22
            [Windows.Controls.DockPanel]::SetDock($percent,'Right'); [void]$row.Children.Add($percent)
            $label=New-Object Windows.Controls.TextBlock
            $label.Text=(Get-WindowLabel $windowData)+' · 剩余'; $label.Foreground=[Windows.Media.Brushes]::LightSteelBlue
            $label.VerticalAlignment='Center'; [void]$row.Children.Add($label); [void]$box.Children.Add($row)
            $progress=New-Object Windows.Controls.ProgressBar
            $progress.Height=7; $progress.Margin=New-Object Windows.Thickness(0,8,0,8)
            $progress.Background=New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString('#304363'))
            $progress.Foreground=New-Object Windows.Media.SolidColorBrush([Windows.Media.ColorConverter]::ConvertFromString('#80BCF3'))
            if($null -ne $windowData.remaining){$progress.Value=[double]$windowData.remaining}
            if($null -ne $windowData.remaining -and $windowData.remaining -le 10){$progress.Foreground=[Windows.Media.Brushes]::Salmon}
            [void]$box.Children.Add($progress)
            $reset=New-Object Windows.Controls.TextBlock
            $reset.Text=if($windowData.resetLocal){'重置于 '+$windowData.resetLocal}else{'重置时间暂不可用'}
            $reset.Foreground=[Windows.Media.Brushes]::LightSlateGray; $reset.FontSize=12
            [void]$box.Children.Add($reset); [void]$script:cards.Children.Add($box)
        }
    }
    $script:status.Text='更新于 '+$Data.updatedLocal+' · 点击芙宁娜即可刷新'
    $script:popup.UpdateLayout(); Position-Popup
}
function Refresh-Quota {
    if($script:queryProcess -and -not $script:queryProcess.HasExited){return}
    $script:cards.Children.Clear(); $script:status.Text='正在查看额度…'; $script:refreshButton.IsEnabled=$false
    Set-PetState 'running'
    try {
        $info=New-Object Diagnostics.ProcessStartInfo
        $info.FileName=$PythonExe
        $info.Arguments='"'+(Join-Path $PSScriptRoot 'quota_client.py')+'"'
        $info.WorkingDirectory=$PSScriptRoot
        $info.UseShellExecute=$false; $info.CreateNoWindow=$true
        $info.RedirectStandardOutput=$true; $info.RedirectStandardError=$true
        $info.StandardOutputEncoding=[Text.Encoding]::UTF8; $info.StandardErrorEncoding=[Text.Encoding]::UTF8
        $script:queryProcess=[Diagnostics.Process]::Start($info)
        $script:queryStarted=[DateTime]::UtcNow
        $script:queryTimer.Start()
    } catch {
        $script:status.Text='无法启动额度查询，请检查 Python 运行环境。'
        $script:refreshButton.IsEnabled=$true; Set-PetState 'failed'
    }
}
function Show-Quota {
    $script:clickTimer.Stop()
    $script:bubble.IsOpen=$false
    Position-Popup; $script:popup.Show(); Refresh-Quota
}
$script:refreshButton.Add_Click({Refresh-Quota})
$script:queryTimer=New-Object Windows.Threading.DispatcherTimer
$script:queryTimer.Interval=[TimeSpan]::FromMilliseconds(100)
$script:queryTimer.Add_Tick({
    if(-not $script:queryProcess){return}
    if(-not $script:queryProcess.HasExited) {
        if(([DateTime]::UtcNow-$script:queryStarted).TotalSeconds -gt 26) {
            $script:queryProcess.Kill(); $script:queryProcess.Dispose(); $script:queryProcess=$null; $script:status.Text='查询超时，请检查网络后重试。'
            $script:queryTimer.Stop(); $script:refreshButton.IsEnabled=$true; Set-PetState 'failed'
        }
        return
    }
    $script:queryTimer.Stop()
    $data=$null
    try {
        $output=$script:queryProcess.StandardOutput.ReadToEnd()
        $data=$output | ConvertFrom-Json
        if(-not $data.ok){throw $data.error}
        Render-Quota $data; Set-PetState 'waving'
    } catch {
        $script:status.Text=if($data -and $data.error){$data.error}else{'额度查询失败，请确认 Codex 已登录并检查网络。'}
        Set-PetState 'failed'
    } finally {
        $script:queryProcess.Dispose(); $script:queryProcess=$null; $script:refreshButton.IsEnabled=$true
    }
})
$script:animationTimer=New-Object Windows.Threading.DispatcherTimer
$script:animationTimer.Add_Tick({
    $script:frame++
    if($script:frame -ge $script:cells[$script:state].Count) {
        if($script:state -in @('waving','failed','jumping')) {
            Set-PetState $(if($script:state -eq 'waving' -and $script:popup.IsVisible){'review'}else{'idle'})
            return
        }
        $script:frame=0
    }
    if($null -eq $script:lookIndex){$script:image.Source=$script:cells[$script:state][$script:frame]}
    $script:animationTimer.Interval=[TimeSpan]::FromMilliseconds($script:animations[$script:state].durations[$script:frame])
})
Set-PetState 'idle'
$script:gazeTimer=New-Object Windows.Threading.DispatcherTimer
$script:gazeTimer.Interval=[TimeSpan]::FromMilliseconds(80)
$script:gazeTimer.Add_Tick({
    if(-not $script:preferences.gaze -or $script:state -ne 'idle' -or $script:press -or -not $script:pet.IsVisible){return}
    $anchor=$script:pet.PointToScreen((New-Object Windows.Point(($script:pet.Width/2),($script:pet.Height*80/208))))
    $cursor=[Windows.Forms.Cursor]::Position
    $dx=$cursor.X-$anchor.X; $dy=$cursor.Y-$anchor.Y
    $distance=[Math]::Sqrt($dx*$dx+$dy*$dy)
    if($distance -lt 22 -or $distance -gt 350) {
        $script:lookIndex=$null; $script:image.Source=$script:cells['idle'][$script:frame]; return
    }
    $angle=([Math]::Atan2($dx,-$dy)*180/[Math]::PI+360)%360
    $script:lookIndex=([int][Math]::Floor(($angle+11.25)/22.5))%16
    $script:image.Source=$script:lookCells[$script:lookIndex]
})

$script:image.Add_MouseLeftButtonDown({
    param($sender,$eventArgs)
    $script:clickTimer.Stop()
    $script:doubleClick=$eventArgs.ClickCount -eq 2
    if($script:doubleClick){Play-Interaction}
    $script:press=$script:pet.PointToScreen($eventArgs.GetPosition($script:pet))
    $script:startLeft=$script:pet.Left; $script:startTop=$script:pet.Top
    $script:dragging=$false; [void]$script:image.CaptureMouse()
})
$script:image.Add_MouseMove({
    param($sender,$eventArgs)
    if(-not $script:press -or $eventArgs.LeftButton -ne 'Pressed'){return}
    $point=$script:pet.PointToScreen($eventArgs.GetPosition($script:pet))
    $source=[Windows.PresentationSource]::FromVisual($script:pet)
    $delta=$source.CompositionTarget.TransformFromDevice.Transform((New-Object Windows.Vector(($point.X-$script:press.X),($point.Y-$script:press.Y))))
    if([Math]::Abs($delta.X)+[Math]::Abs($delta.Y) -gt 6) {
        if(-not $script:dragging) { $script:dragging=$true; $script:popup.Hide(); $script:bubble.IsOpen=$false; Set-PetState $(if($delta.X -ge 0){'running-right'}else{'running-left'}) }
        $script:pet.Left=$script:startLeft+$delta.X; $script:pet.Top=$script:startTop+$delta.Y
    }
})
$script:image.Add_MouseLeftButtonUp({
    if(-not $script:press){return}
    $wasDragging=$script:dragging; $script:press=$null; $script:dragging=$false
    $script:image.ReleaseMouseCapture()
    if($wasDragging){Set-PetState 'idle'; try {Save-Preferences} catch {Write-Warning '位置未能保存。'}}
    elseif(-not $script:doubleClick){$script:clickTimer.Start()}
})
$script:image.Add_LostMouseCapture({$script:press=$null; if($script:dragging){$script:dragging=$false; Set-PetState 'idle'}})
$menu=New-Object Windows.Controls.ContextMenu
foreach($itemText in @('查看 / 刷新额度','互动一下','设置','隐藏到托盘','关闭额度面板','退出芙宁娜')) {
    $item=New-Object Windows.Controls.MenuItem; $item.Header=$itemText
    switch($itemText) {
        '查看 / 刷新额度' {$item.Add_Click({Show-Quota})}
        '互动一下' {$item.Add_Click({Play-Interaction})}
        '设置' {$item.Add_Click({Show-Settings})}
        '隐藏到托盘' {$item.Add_Click({Hide-Pet})}
        '关闭额度面板' {$item.Add_Click({$script:popup.Hide(); if($script:state -eq 'review'){Set-PetState 'idle'}})}
        '退出芙宁娜' {$item.Add_Click({$script:pet.Close()})}
    }
    [void]$menu.Items.Add($item)
}
$script:image.ContextMenu=$menu
$script:pet.Add_Closed({
    Close-Companion
    $script:animationTimer.Stop(); $script:queryTimer.Stop(); $script:gazeTimer.Stop(); $script:popup.Close()
    if($script:queryProcess){if(-not $script:queryProcess.HasExited){$script:queryProcess.Kill()}; $script:queryProcess.Dispose()}
    if($script:ownsMutex){$script:instanceMutex.ReleaseMutex()}
    $script:instanceMutex.Dispose()
    if([Windows.Application]::Current){[Windows.Application]::Current.Shutdown()}
})
if($DesktopTest) {
    $application=New-Object Windows.Application
    $application.ShutdownMode='OnExplicitShutdown'
    $script:desktopTestPhase=0; $script:desktopTestResult=$null
    $script:lifecycleTimer=New-Object Windows.Threading.DispatcherTimer
    $script:lifecycleTimer.Interval=[TimeSpan]::FromMilliseconds(400)
    $script:lifecycleTimer.Add_Tick({
        try {
            switch($script:desktopTestPhase) {
                0 {
                    if(-not $script:hotkeyRegistered -or -not $script:tray.Visible){throw 'Hotkey or tray unavailable'}
                    [void][FurinaDesktop]::PostMessage($script:hotkeyHandle,0x312,[IntPtr]7821,[IntPtr]::Zero)
                }
                1 {
                    if($script:pet.IsVisible){throw 'Native hotkey did not hide pet'}
                    [void][FurinaDesktop]::PostMessage($script:hotkeyHandle,0x312,[IntPtr]7821,[IntPtr]::Zero)
                }
                2 {
                    if(-not $script:pet.IsVisible){throw 'Hidden application did not restore'}
                    Show-Settings; $script:settingsWindow.UpdateLayout()
                    $preview=New-Object Windows.Media.Imaging.RenderTargetBitmap([int]$script:settingsWindow.ActualWidth,[int]$script:settingsWindow.ActualHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
                    $preview.Render($script:settingsWindow)
                    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
                    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($preview))
                    $stream=[IO.File]::Create((Join-Path $PSScriptRoot '..\..\.tools\settings-preview.png'))
                    try {$encoder.Save($stream)} finally {$stream.Dispose()}
                }
                3 {
                    $script:settingsWindow.Close()
                    if($script:settingsWindow.IsVisible){throw 'Settings did not hide on close'}
                    Show-Settings
                    if(-not $script:settingsWindow.IsVisible){throw 'Settings cannot reopen'}
                    $script:desktopTestResult='Desktop lifecycle passed: native hotkey, tray, hidden message loop, settings reopen and shutdown.'
                    $script:lifecycleTimer.Stop(); $script:pet.Close()
                }
            }
            $script:desktopTestPhase++
        } catch {
            $script:desktopTestResult='Desktop lifecycle failed: '+$_.Exception.Message
            $script:lifecycleTimer.Stop(); $script:pet.Close()
        }
    })
    $script:animationTimer.Start(); $script:gazeTimer.Start(); $script:lifecycleTimer.Start()
    [void]$application.Run($script:pet)
    if(-not $script:desktopTestResult -or -not $script:desktopTestResult.StartsWith('Desktop lifecycle passed')){throw $script:desktopTestResult}
    Write-Output $script:desktopTestResult
} elseif($IntegrationTest) {
    $script:pet.Show(); $script:pet.UpdateLayout()
    $down=New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left)
    $down.RoutedEvent=[Windows.Controls.Image]::MouseLeftButtonDownEvent
    $script:image.RaiseEvent($down)
    $script:dragging=$true
    $up=New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left)
    $up.RoutedEvent=[Windows.Controls.Image]::MouseLeftButtonUpEvent
    $script:image.RaiseEvent($up)
    if($script:queryProcess -or $script:popup.IsVisible){throw 'Dragging incorrectly triggered quota'}
    $script:image.RaiseEvent($down); $script:image.RaiseEvent($up)
    if(-not $script:clickTimer.IsEnabled){throw 'Click failed to schedule quota query'}
    $doubleDown=New-Object Windows.Input.MouseButtonEventArgs([Windows.Input.Mouse]::PrimaryDevice,[Environment]::TickCount,[Windows.Input.MouseButton]::Left)
    $doubleDown.RoutedEvent=[Windows.Controls.Image]::MouseLeftButtonDownEvent
    [void][Windows.Input.MouseButtonEventArgs].GetProperty('ClickCount').GetSetMethod($true).Invoke($doubleDown,@(2))
    $script:image.RaiseEvent($doubleDown); $script:image.RaiseEvent($up)
    if($script:clickTimer.IsEnabled -or $script:queryProcess -or $script:state -notin @('waving','jumping')){throw 'Double click triggered quota or failed interaction'}
    $script:image.RaiseEvent($down); $script:image.RaiseEvent($up)
    $script:testOutcome=$null
    $script:testStarted=[DateTime]::UtcNow
    $script:testTimer=New-Object Windows.Threading.DispatcherTimer
    $script:testTimer.Interval=[TimeSpan]::FromMilliseconds(100)
    $script:testTimer.Add_Tick({
        if($script:status.Text.StartsWith('更新于')) {
            if($script:cards.Children.Count -lt 1){throw 'Live quota cards empty'}
            $script:testOutcome='Integration passed: drag and double click skip quota; single click displays live quota; '+$script:status.Text
            $script:testTimer.Stop(); $script:pet.Close()
        } elseif((-not $script:queryTimer.IsEnabled -and -not $script:clickTimer.IsEnabled) -or ([DateTime]::UtcNow-$script:testStarted).TotalSeconds -gt 30) {
            $script:testOutcome='Click integration failed: '+$script:status.Text
            $script:testTimer.Stop(); $script:pet.Close()
        }
    })
    $script:testTimer.Start(); $script:animationTimer.Start()
    $application=New-Object Windows.Application
    [void]$application.Run($script:pet)
    if(-not $script:testOutcome -or -not $script:testOutcome.StartsWith('Integration passed')){throw ('Integration did not pass: '+$script:testOutcome)}
    Write-Output $script:testOutcome
    if($script:temporarySettings -and (Test-Path -LiteralPath $SettingsPath)){Remove-Item -LiteralPath $SettingsPath}
} elseif($SmokeTest) {
    $script:pet.Show(); $script:pet.UpdateLayout()
    $initialScale=$script:preferences.scale
    if([Math]::Abs($script:pet.Width-192*$initialScale/100) -gt .1){throw 'Loaded scale not applied'}
    Show-Settings
    $script:sizeSlider.Value=150
    $script:settingsWindow.FindName('GazeCheck').IsChecked=$false
    $script:settingsWindow.FindName('PhrasesCheck').IsChecked=$false
    $script:frequencyBox.SelectedIndex=2
    $script:pet.Left=120; $script:pet.Top=80
    Save-SettingsFromControls
    $saved=Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if($saved.scale -ne 150 -or $saved.gaze -ne $false -or $saved.phrases -ne $false -or $saved.interactionSeconds -ne 120 -or $script:pet.Width -ne 288){throw 'Settings persistence failed'}
    Update-DesktopVisibility $true
    if($script:pet.IsVisible -or -not $script:fullscreenHidden){throw 'Fullscreen hide failed'}
    Update-DesktopVisibility $false
    if(-not $script:pet.IsVisible){throw 'Fullscreen restore failed'}
    Hide-Pet; Update-DesktopVisibility $false
    if($script:pet.IsVisible){throw 'Manual hide unexpectedly restored'}
    Show-Pet
    if(-not $script:pet.IsVisible -or $script:manuallyHidden){throw 'Tray restore failed'}
    Play-Interaction
    if($script:state -notin @('waving','jumping') -or $script:bubble.IsOpen){throw 'Interaction preference failed'}
    $script:preferences.phrases=$true; Play-Interaction
    if(-not $script:bubble.IsOpen -or -not $script:bubbleText.Text){throw 'Interaction phrase failed'}
    Set-StartupEnabled $true
    if($script:testStartupCommand -notlike '*-WindowStyle Hidden*-File "*launch.ps1"'){throw 'Startup command quoting failed'}
    Set-StartupEnabled $false
    if($script:testStartupCommand){throw 'Startup disable failed'}
    $script:pet.Hide()
    $testData='{"ok":true,"buckets":[{"name":"codex","windows":[{"kind":"primary","minutes":300,"remaining":42,"resetLocal":"09-13 23:43"},{"kind":"secondary","minutes":10080,"remaining":null,"resetLocal":null}]}],"updatedLocal":"12:00:00"}' | ConvertFrom-Json
    Render-Quota $testData
    if($script:cards.Children.Count -ne 2){throw 'Quota cards smoke test failed'}
    if($script:cells['idle'].Count -ne 6 -or $script:cells['running-left'].Count -ne 8 -or $script:lookCells.Count -ne 16){throw 'Animation frame count failed'}
    Set-PetState 'running'; Set-PetState 'waving'; Set-PetState 'idle'
    $script:pet.Close()
    if($script:temporarySettings -and (Test-Path -LiteralPath $SettingsPath)){Remove-Item -LiteralPath $SettingsPath}
    Write-Output ('WPF smoke passed: loaded scale '+$initialScale+'%; saved size/position/preferences; interaction; hide/restore; startup command; quota cards.')
} else {
    $script:animationTimer.Start()
    $script:gazeTimer.Start()
    $script:desktopTimer.Start()
    $application=New-Object Windows.Application
    $application.ShutdownMode='OnExplicitShutdown'
    [void]$application.Run($script:pet)
}
