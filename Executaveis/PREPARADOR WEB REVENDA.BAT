@echo off
:: ==========================================
:: VERIFICACAO DE ADMINISTRADOR (SILENCIOSA)
:: ==========================================
NET SESSION >nul 2>&1
if %errorLevel% neq 0 (
    powershell -Command "Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('Por favor, execute este programa como Administrador (Botao direito > Executar como admin).', 'Permissao Necessaria', 'OK', 'Error')"
    exit
)

:: ==========================================
:: CONFIGURACAO E EXECUCAO
:: ==========================================
:: Define a URL (Link RAW corrigido para o script de Revenda)
set "SCRIPT_URL=https://raw.githubusercontent.com/VMazza10/Preparador-de-Ambiente-XMenu/main/Preparar%%20Ambiente%%20Revenda.ps1"

:: Define o comando PowerShell:
:: 1. Define TLS 1.2 (Seguranca)
:: 2. Define caminho temporario
:: 3. Baixa o arquivo (OutFile)
:: 4. Executa o arquivo baixado
set "PS_CMD=[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; $f = Join-Path $env:TEMP 'XMenu_Revenda.ps1'; Invoke-WebRequest -Uri '%SCRIPT_URL%' -OutFile $f -UseBasicParsing; & $f"

:: Executa o comando em modo OCULTO (-WindowStyle Hidden)
PowerShell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -Command "%PS_CMD%"