@echo off
Title Configuracao de Ambiente - XMenu

:: =========================================================
:: ETAPA 1: AUTO-ELEVAÇÃO
:: Este bloco verifica se o script foi iniciado como Administrador.
:: Se nao for, ele se reinicia usando o comando 'runas' para forcar o UAC.
:: =========================================================
whoami /groups | find "S-1-5-32-544" > nul
if %errorlevel% neq 0 (
echo Elevando privilegios... Sera solicitado o UAC.
goto runas_admin
)
goto start_script

:runas_admin
:: Forca a reinicializacao do .bat com o verbo 'RunAs'.
powershell -Command "Start-Process -FilePath '%~dpnx0' -Verb RunAs"
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
PowerShell.exe -ExecutionPolicy Bypass -File "%~dp0Preparar Ambiente Xmenu.ps1"

:END
echo.
echo Processo concluido.
pause