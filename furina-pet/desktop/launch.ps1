$ErrorActionPreference = 'Stop'
$hostExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$petScript = Join-Path $PSScriptRoot 'furina.ps1'
$arguments = '-NoProfile -STA -ExecutionPolicy Bypass -File "' + $petScript + '"'
Start-Process -FilePath $hostExe -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $PSScriptRoot -RedirectStandardError (Join-Path $PSScriptRoot 'error.log') | Out-Null
