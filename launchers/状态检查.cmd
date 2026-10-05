@echo off
REM Status check: running? which profile? VRAM/RAM? ready? real inference working?
REM ASCII-only on purpose.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0status.ps1"
