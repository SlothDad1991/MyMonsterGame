@echo off
title Monster Game - online address
echo.
echo  === Monster Game: share your world online ===
echo.
echo  1. In the game, click "Host on this computer" (keep the game open).
echo  2. Leave THIS window open while people play.
echo  3. Look below for a line ending in  .trycloudflare.com
echo     Send that address (without https://) to everyone.
echo     They open the game link on their phone, paste it, and press Join.
echo.

set "CF=cloudflared"
where cloudflared >nul 2>nul
if errorlevel 1 (
    if exist "%ProgramFiles(x86)%\cloudflared\cloudflared.exe" (
        set "CF=%ProgramFiles(x86)%\cloudflared\cloudflared.exe"
    ) else if exist "%ProgramFiles%\cloudflared\cloudflared.exe" (
        set "CF=%ProgramFiles%\cloudflared\cloudflared.exe"
    ) else (
        echo  Installing Cloudflare's free tunnel tool, one time only...
        winget install --id Cloudflare.cloudflared -e --accept-source-agreements --accept-package-agreements
        if exist "%ProgramFiles(x86)%\cloudflared\cloudflared.exe" set "CF=%ProgramFiles(x86)%\cloudflared\cloudflared.exe"
        if exist "%ProgramFiles%\cloudflared\cloudflared.exe" set "CF=%ProgramFiles%\cloudflared\cloudflared.exe"
    )
)

"%CF%" tunnel --no-autoupdate --url http://localhost:9080
echo.
echo  The tunnel stopped. Close this window, or press a key to exit.
pause >nul
