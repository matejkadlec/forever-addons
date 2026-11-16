@echo off
rem Registers (or replaces) the Windows task ForeverMarketFeed from ForeverMarketFeed.task.xml: every 30 minutes, hidden, while you are logged in.
rem The result goes to register-task.log.
schtasks /Create /F /TN "ForeverMarketFeed" /XML "%~dp0ForeverMarketFeed.task.xml" > "%~dp0register-task.log" 2>&1
schtasks /Query /TN "ForeverMarketFeed" /V /FO LIST >> "%~dp0register-task.log" 2>&1
