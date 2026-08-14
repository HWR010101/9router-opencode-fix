@echo off
rem ============================================================
rem  fix-9router.bat - one-click fix for 9Router's
rem  "Free usage exceeded" on opencode free models.
rem  Runs fix-9router.ps1 (same folder); no admin needed
rem  (9Router lives under npm global, not Program Files).
rem ============================================================
setlocal
cd /d "%~dp0"

if not exist "%~dp0fix-9router.ps1" (
    echo ERROR: fix-9router.ps1 not found next to this .bat file.
    echo Make sure both files are in the same folder.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix-9router.ps1"

echo.
pause
