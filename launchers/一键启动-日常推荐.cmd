@echo off
REM One-click start: DAILY profile (cpu-gb 4 / ctx 131072 / gen 8192 / budget 32768)
REM ASCII-only on purpose: cmd parses .cmd in the OEM codepage, non-ASCII text breaks the commands.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-engine.ps1" -Profile daily
