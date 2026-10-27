@echo off
chcp 936 >nul
title VPN 绕过
cd /d "%~dp0"

:menu
cls
echo.
echo   ============================================
echo     让指定网站 / 软件绕过 VPN（走直连）
echo   ============================================
echo.
echo     1. 放行一次      挂 VPN 前点一次就行
echo     2. 放行 + 守护   VPN 会重置路由时用，窗口留着
echo     3. 撤销          删掉所有规则
echo     4. 看会放行什么   只预览，不动系统
echo     0. 退出
echo.
set "ch="
set /p ch=请选择：
if "%ch%"=="" exit /b
if "%ch%"=="1" goto once
if "%ch%"=="2" goto watch
if "%ch%"=="3" goto undo
if "%ch%"=="4" goto dry
if "%ch%"=="0" exit /b
goto menu

:once
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-route.ps1" < nul
goto end

:watch
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-route.ps1" -Watch < nul
goto end

:undo
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-route.ps1" -Undo < nul
goto end

:dry
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0split-route.ps1" -DryRun < nul
goto end

:end
echo.
pause
goto menu
