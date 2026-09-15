@echo off
Title Testar o Preparador local (antes de subir)

:: =========================================================
:: Abre o programa usando os scripts DESTA PASTA (as alteracoes
:: que ainda nao foram para o GitHub). Os executaveis do Preparador
:: Web continuam baixando a versao publicada.
:: =========================================================

:: Pede administrador: sem ele o programa fecha na hora, sem aviso.
:: O fsutil so funciona elevado. O "whoami /groups" nao serve: o grupo
:: Administradores aparece nele mesmo sem elevar ("usado apenas para negar").
fsutil dirty query %SystemDrive% >nul 2>&1
if not errorlevel 1 goto ADMIN
if /i "%~1"=="elevado" (
    echo Nao foi possivel abrir como administrador.
    pause
    exit /b
)
echo Pedindo permissao de administrador...
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevado' -Verb RunAs"
exit /b

:ADMIN

:ESCOLHA
cls
echo =========================================================
echo  TESTAR O PREPARADOR LOCAL (antes de subir para o GitHub)
echo =========================================================
echo.
echo   1 - XMenu
echo   2 - Revenda
echo.
choice /c 12 /n /m "Qual versao abrir? (1 ou 2): "
if errorlevel 2 (
    set "SCRIPT=%~dp0..\Preparar Ambiente Revenda.ps1"
) else (
    set "SCRIPT=%~dp0..\Preparar Ambiente Xmenu.ps1"
)

if not exist "%SCRIPT%" (
    echo.
    echo Nao encontrei o arquivo:
    echo %SCRIPT%
    pause
    exit /b
)

echo.
echo Abrindo: %SCRIPT%
echo (feche a janela do programa para voltar aqui)
echo.
PowerShell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"

echo.
choice /c SN /n /m "Abrir de novo? (S/N): "
if errorlevel 2 exit /b
goto ESCOLHA
