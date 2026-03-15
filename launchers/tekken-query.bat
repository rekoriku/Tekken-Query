@echo off
REM Launch Tekken Query in interactive mode.
REM Place this script in the same directory as tekken-cli.exe and tekken_query.exe.
set "SCRIPT_DIR=%~dp0"
"%SCRIPT_DIR%tekken-cli.exe" -d "%SCRIPT_DIR%data" interactive %*
