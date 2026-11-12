@echo off
chcp 65001 >nul
title 查看手机日志（Flutter）
set ADB=E:\tools\platform-tools\adb.exe

echo ============================================
echo   1. 请先用数据线把手机连到电脑
echo   2. 手机上要允许"USB调试"
echo   3. 看到设备序列号后再按任意键开始
echo ============================================
echo.
"%ADB%" devices
echo.
pause

echo.
echo ---------- 只显示 App 打印的日志（Ctrl+C 退出）----------
echo.
"%ADB%" logcat -s flutter:I
pause
