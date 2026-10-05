@echo off
REM One-click stop (works for either profile)
REM ASCII-only on purpose.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0stop-engine.ps1"
