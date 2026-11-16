@echo off
rem Registers (or replaces) the Windows task ForeverMarketFeed: every 30 minutes, hidden, while you are logged in.
rem ForeverMarketFeed.task.xml is a template, __FEED_DIR__ becomes this folder. The result goes to register-task.log.
setlocal
set "FEED_DIR=%~dp0"
set "FEED_DIR=%FEED_DIR:~0,-1%"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$x = Get-Content -Raw -Encoding Unicode -LiteralPath (Join-Path $env:FEED_DIR 'ForeverMarketFeed.task.xml'); Set-Content -Encoding Unicode -LiteralPath (Join-Path $env:TEMP 'ForeverMarketFeed.task.xml') -Value $x.Replace('__FEED_DIR__', $env:FEED_DIR)" > "%FEED_DIR%\register-task.log" 2>&1
schtasks /Create /F /TN "ForeverMarketFeed" /XML "%TEMP%\ForeverMarketFeed.task.xml" >> "%FEED_DIR%\register-task.log" 2>&1
schtasks /Query /TN "ForeverMarketFeed" /V /FO LIST >> "%FEED_DIR%\register-task.log" 2>&1
del "%TEMP%\ForeverMarketFeed.task.xml" >nul 2>nul
