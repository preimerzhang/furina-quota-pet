@echo off
chcp 65001 >nul
cd /d "%~dp0"
where node >nul 2>nul
if %errorlevel%==0 (set "CARD_NODE=node") else (set "CARD_NODE=C:\Users\zhangshunli\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe")
start "" "http://127.0.0.1:4173"
"%CARD_NODE%" web\server.mjs
pause
