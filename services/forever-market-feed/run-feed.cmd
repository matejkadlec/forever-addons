@echo off
rem Runs feed.py with the first Python that works: py launcher, python, else WSL python3.
rem feed.py logs to feed.log itself; feed-run.log only catches what a crashing interpreter prints.
setlocal
cd /d "%~dp0"
py -3 -c "import sys" >nul 2>nul && (py -3 feed.py %* > feed-run.log 2>&1 & goto :eof)
python -c "import sys" >nul 2>nul && (python feed.py %* > feed-run.log 2>&1 & goto :eof)
wsl.exe -e python3 feed.py %* > feed-run.log 2>&1
