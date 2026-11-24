@echo off
chcp 65001
title log viewer (UTF-8)
echo step1: connect phone by USB cable
echo step2: allow USB debugging on phone
echo.
echo checking device...
"E:\tools\platform-tools\adb.exe" devices
echo.
echo ====== log start, Ctrl+C to exit (Chinese OK) ======
"E:\tools\platform-tools\adb.exe" logcat -s flutter
pause
