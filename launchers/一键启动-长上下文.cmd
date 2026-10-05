@echo off
REM One-click start: LONG-CONTEXT profile (cpu-gb 6 / ctx 262144 / gen 8192 / budget 32768)
REM ASCII-only on purpose.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-engine.ps1" -Profile longctx
