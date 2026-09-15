@echo off
Title Configuracao de Ambiente - XMenu

:: =========================================================
:: ETAPA 1: AUTO-ELEVAÇÃO
:: Este bloco verifica se o script foi iniciado como Administrador.
:: Se nao for, ele se reinicia usando o comando 'runas' para forcar o UAC.
:: =========================================================
:: O fsutil so funciona elevado. O "whoami /groups" nao serve: o grupo
:: Administradores aparece nele mesmo sem elevar ("usado apenas para negar").
fsutil dirty query %SystemDrive% >nul 2>&1
if not errorlevel 1 goto start_script
if /i "%~1"=="elevado" (
echo Nao foi possivel abrir como administrador.
pause
exit /b
)
echo Elevando privilegios... Sera solicitado o UAC.
goto runas_admin

:runas_admin
:: Forca a reinicializacao do .bat com o verbo 'RunAs'.
powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList 'elevado' -Verb RunAs"
exit /b

:start_script
echo.
echo =========================================================
echo  INICIADOR DE CONFIGURACAO XMENU
echo =========================================================
echo.

:RUN_PS1
echo 1/1. Iniciando script Preparar Ambiente Xmenu.ps1...
echo (A Politica de Execucao sera ignorada para este processo)
echo.

:: CORRECAO CRITICA: Usando %~dp0 (diretorio do BAT) para garantir que o Powershell
:: encontre o script PS1, resolvendo o erro "arquivo nao existe".
:: O BAT fica em Ferramentas\ e o script na raiz do projeto (..\).
PowerShell.exe -ExecutionPolicy Bypass -File "%~dp0..\Preparar Ambiente Xmenu.ps1"

:END
echo.
echo Processo concluido.
pause