@echo off
Title Git Push Rapido (XMenu)
echo.

:: =================================================================
:: ETAPA 1: CONFIGURACAO E VARIAVEIS
:: =================================================================

:: Captura a data e hora atuais para a mensagem de commit
for /f "tokens=1-4 delims=/ " %%a in ('date /t') do set current_date=%%a-%%b-%%c
for /f "tokens=1-2 delims=: " %%a in ('time /t') do set current_time=%%a%%b

set commit_message="Feito pelo BAT [%current_date% %current_time%]"

:: Navega para o diretorio do script (onde o .git esta)
cd /d "%~dp0"
echo Diretorio atual: %cd%

echo.
echo =========================================================
echo  INICIANDO PROCESSO GIT
echo =========================================================
echo.

:: =================================================================
:: ETAPA 2: ADD, COMMIT e PUSH
:: =================================================================

echo 1. Adicionando todos os arquivos novos e alterados...
git add .
if %errorlevel% neq 0 (
    echo ERRO: Falha ao adicionar arquivos. Certifique-se que o Git esta instalado.
    goto :FAIL
)

echo 2. Criando commit com a mensagem: %commit_message%
git commit -m %commit_message%
if %errorlevel% neq 0 (
    echo AVISO: Nada para commitar (ou falha no commit). Tentando push...
)

echo 3. Enviando (push) para o GitHub...
:: O 'git push' pedira autenticacao se o seu token tiver expirado.
git push -u origin main
if %errorlevel% neq 0 (
    echo ERRO: Falha ao enviar (push) para o GitHub. Verifique sua conexao ou autenticacao.
    goto :FAIL
)

echo.
echo =========================================================
echo  SUCESSO! O codigo esta no GitHub.
echo =========================================================
goto :END

:FAIL
echo.
echo =========================================================
echo  FALHA NO PROCESSO DE ENVIO.
echo =========================================================
pause

:END
echo.
pause