@echo off
REM gapi.bat — Google API helper for Hermes on Windows
REM Usage: gapi gmail search "is:unread" --max 10
REM        gapi calendar list
REM        gapi drive search "report"

set PYTHONIOENCODING=utf-8
set VENV_PYTHON=C:\Users\DELL\AppData\Local\hermes\hermes-agent\venv\Scripts\python.exe
set SCRIPT=%HERMES_HOME%\skills\productivity\google-workspace\scripts\google_api.py

"%VENV_PYTHON%" "%SCRIPT%" %*
