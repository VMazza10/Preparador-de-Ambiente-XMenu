@echo off
setlocal
:: XMenu - Automação de Git Push

:: Muda para o diretório onde o script está
cd /d "%~dp0"

echo.
echo ===========================================
echo   ENVIAR ALTERACOES PARA O GITHUB (XMenu)
echo ===========================================
echo.

:: Solicita a mensagem de commit
echo Digite o comentario para este commit:
set /p msg="> "

:: Se não digitar nada, usa uma mensagem padrão
if "%msg%"=="" (
    set msg="Atualizacao automatica - $(date /t)"
)

echo.
echo [+] Adicionando arquivos (git add .)...
git add .

echo [+] Criando commit com a mensagem: "%msg%"...
git commit -m "%msg%"

echo [+] Enviando para o GitHub (git push)...
git push -u origin main

echo.
echo [!] Processo concluido!
echo.
pause
