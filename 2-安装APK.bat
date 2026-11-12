@echo off
chcp 65001 >nul
title 安装 APK 到手机
set ADB=E:\tools\platform-tools\adb.exe

if "%~1"=="" (
    echo 用法：把 apk 文件拖到这个 bat 文件上即可安装
    echo.
    echo 当前连接的设备：
    "%ADB%" devices
    pause
    exit /b
)

echo 正在安装：%~1
"%ADB%" install -r "%~1"
echo.
echo 安装结束，请到手机上打开「你好Demo」
pause
