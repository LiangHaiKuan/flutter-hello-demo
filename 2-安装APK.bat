@echo off
title install apk
if "%~1"=="" (
  echo drag an APK file onto this bat icon
  pause
  exit /b
)
echo installing: %~nx1
"E:\tools\platform-tools\adb.exe" install -r "%~1"
echo ====== install done, open app on phone, then run 1-查看日志.bat ======
pause
