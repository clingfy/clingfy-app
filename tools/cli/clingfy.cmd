@echo off
rem clingfy — thin cmd shim so the launcher works from cmd.exe AND PowerShell
rem once this file's directory is on PATH. All logic lives in clingfy.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clingfy.ps1" %*
