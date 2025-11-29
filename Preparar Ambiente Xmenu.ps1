# =============================================================================
# FERRAMENTA DE PREPARACAO DE AMBIENTE XMENU (GUI v8.2 - CUSTOM DIALOG)
# =============================================================================
# - Visual Moderno (Flat Design)
# - Janela de Aviso Final Personalizada (Maior e mais legivel)
# - Limpeza TOTAL da Barra de Tarefas
# - Configura Windows (UAC, Energia, Visual, Data, Explorer)
# - Downloads e Instalacoes Automatizadas
# =============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net

# --- API Import para Desktop Wallpaper ---
# Define a funcao SystemParametersInfo (P/Invoke) para atualizar o papel de parede
$code = @'
[DllImport("user32.dll", CharSet=CharSet.Auto)]
public static extern int SystemParametersInfo (UInt32 uiAction, UInt32 uiParam, string pvParam, UInt32 fWinIni);
'@
Add-Type -MemberDefinition $code -Name "WinAPI" -Namespace "Stuff"

# Constantes para SystemParametersInfo
$SPI_SETDESKWALLPAPER = 0x14
$SPIF_UPDATEINIFILE = 0x01
$SPIF_SENDCHANGE = 0x02

# --- Verificacao e Auto-Elevacao de Administrador ---
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Se nao for administrador, reinicia o script com elevacao de privilegios (RunAs)
    $scriptPath = $MyInvocation.MyCommand.Path
    
    # Prepara os argumentos para o novo processo do PowerShell
    # '-NoProfile' para inicializacao mais rapida
    # '-ExecutionPolicy Bypass' para evitar problemas de politica de execucao
    # '-File' para especificar o caminho do script
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""
    
    # Inicia um novo processo PowerShell com o verbo RunAs (o que dispara o UAC)
    Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -Verb RunAs
    
    # Sai da sessao atual, nao elevada
    Exit
}
# O script continuara a partir daqui somente se ja estiver executando como Administrador.

# --- CORES E ESTILOS ---
$ColorDarkBg    = [System.Drawing.Color]::FromArgb(30, 30, 30)       # Fundo Principal
$ColorPanel     = [System.Drawing.Color]::FromArgb(45, 45, 48)       # Paineis
$ColorHeader    = [System.Drawing.Color]::FromArgb(0, 122, 204)      # Azul VS Code
$ColorText      = [System.Drawing.Color]::WhiteSmoke                # Texto
$ColorLog       = [System.Drawing.Color]::FromArgb(20, 20, 20)       # Fundo Log
$ColorLogText   = [System.Drawing.Color]::LimeGreen                 # Texto Log
$ColorBtnAction = [System.Drawing.Color]::FromArgb(0, 120, 215)      # Botao Principal
$ColorBtnDown   = [System.Drawing.Color]::FromArgb(60, 60, 60)       # Botoes Download

# --- JANELA PRINCIPAL ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Instalador XMenu v8.2"
# Ajustado o tamanho da janela principal para acomodar a nova linha de botoes
$form.Size = New-Object System.Drawing.Size(695, 1040) 
# $form.AutoSize = $true # Removido para evitar conflito
# $form.AutoSizeMode = "GrowAndShrink" # Removido para evitar conflito
$form.AutoScroll = $true # Adicionado para permitir rolagem se a janela for diminuída
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorDarkBg
$form.ForeColor = $ColorText
$form.FormBorderStyle = "Sizable" # Permite que o usuário redimensione
$form.MaximizeBox = $true # Permite maximizar

# --- CABECALHO ---
$pnlHeader = New-Object System.Windows.Forms.Panel
# Manter 700px de largura para preencher o espaço, ajustado para ser visível no Autosize
$pnlHeader.Size = New-Object System.Drawing.Size(685, 70) 
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.BackColor = $ColorHeader
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "PREPARADOR DE AMBIENTE XMENU"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true # CORREÇÃO: Utilizando $true para booleanos
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(20, 20)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Configuracao de Sistema e Softwares"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
$lblSub.AutoSize = $true # CORREÇÃO: Utilizando $true para booleanos
$lblSub.ForeColor = [System.Drawing.Color]::White
$lblSub.Location = New-Object System.Drawing.Point(420, 30)
$pnlHeader.Controls.Add($lblSub)

# --- AREA DE LOG ---
# Ajustar a localização dos elementos para acomodar o novo layout
$logYStart = 90

$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = "Log de Execucao:"
$lblLogTitle.Location = New-Object System.Drawing.Point(20, $logYStart)
$lblLogTitle.AutoSize = $true # CORREÇÃO: Utilizando $true para booleanos
$lblLogTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblLogTitle)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true # CORREÇÃO: Utilizando $true para booleanos
$txtLog.ScrollBars = "Vertical"
$txtLog.Size = New-Object System.Drawing.Size(645, 200)
$txtLog.Location = New-Object System.Drawing.Point(20, ($logYStart + 25)) # Corrigido: Envolvendo a soma entre parenteses
$txtLog.BackColor = $ColorLog
$txtLog.ForeColor = $ColorLogText
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$txtLog.ReadOnly = $true # CORREÇÃO: Utilizando $true para booleanos
$txtLog.BorderStyle = "FixedSingle"
$form.Controls.Add($txtLog)

function Log-Message {
    param($Msg)
    # Removendo acentos e caracteres especiais das mensagens de log
    $CleanMsg = $Msg -replace '[áàãâä]', 'a' `
                     -replace '[éèêë]', 'e' `
                     -replace '[íìîï]', 'i' `
                     -replace '[óòõôö]', 'o' `
                     -replace '[úùûü]', 'u' `
                     -replace '[ç]', 'c' `
                     -replace '[^a-zA-Z0-9\s:\[\]\-\/\.]', ''
    $txtLog.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $CleanMsg`r`n")
    $txtLog.ScrollToCaret()
    $form.Refresh() # Garantindo o redesenho imediato para evitar desalinhamento do log
}

# --- FUNCAO DOWNLOAD SIMPLES (USADA PARA DOWNLOADS EM SEQUENCIA) ---
function Download-Only {
    param($Url, $FileName)
    
    $destPath = "$env:TEMP\$FileName"

    try {
        Log-Message "Iniciando download: $FileName"
        
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $destPath)
        
        Log-Message "Executando/Abrindo arquivo: $FileName"
        
        Start-Process $destPath
        
        Log-Message "Arquivo iniciado com sucesso."
        return $true
    } catch {
        # CORRECAO: Usando ${FileName} para delimitar a variavel corretamente antes dos ':'
        Log-Message "ERRO no download de ${FileName}: $_" 
        [System.Windows.Forms.MessageBox]::Show("Erro no download de $FileName. Verifique a internet.", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

# --- FUNCAO DOWNLOAD (USADA PARA BOTOES INDIVIDUAIS) ---
function Download-And-Run {
    param($Url, $FileName, $ButtonObj)
    
    $originalText = $ButtonObj.Text
    $ButtonObj.Enabled = $false
    $ButtonObj.Text = "Baixando..."
    $ButtonObj.BackColor = [System.Drawing.Color]::Orange
    $form.Refresh()

    $destPath = "$env:TEMP\$FileName"

    try {
        Log-Message "Iniciando download: $FileName"
        
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($Url, $destPath)
        
        Log-Message "Executando/Abrindo arquivo..."
        $ButtonObj.Text = "Abrindo..."
        $form.Refresh()

        Start-Process $destPath
        
        Log-Message "Arquivo iniciado com sucesso."
        $ButtonObj.BackColor = [System.Drawing.Color]::SeaGreen
        $ButtonObj.Text = "Sucesso"
    } catch {
        Log-Message "ERRO: $_"
        [System.Windows.Forms.MessageBox]::Show("Erro no download. Verifique a internet.", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        $ButtonObj.BackColor = [System.Drawing.Color]::DarkRed
        $ButtonObj.Text = "Erro"
    }

    $ButtonObj.Enabled = $true
    Start-Sleep -Seconds 2
    if ($ButtonObj.Text -eq "Erro") { $ButtonObj.Text = $originalText }
}

# --- PAINEL DE ACOES ---
$grpActionsYStart = $logYStart + 25 + 200 + 15 # Abaixo do Log

$grpActions = New-Object System.Windows.Forms.GroupBox
$grpActions.Text = " Preparacao do Windows " # Removido o acento
$grpActions.ForeColor = $ColorText
$grpActions.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$grpActions.Size = New-Object System.Drawing.Size(645, 120)
$grpActions.Location = New-Object System.Drawing.Point(20, $grpActionsYStart)
$form.Controls.Add($grpActions)

$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Text = "CONFIGURAR AMBIENTE WINDOWS`n(UAC, Energia, Visual, Limpeza)"
$btnConfig.Size = New-Object System.Drawing.Size(605, 70)
$btnConfig.Location = New-Object System.Drawing.Point(20, 30)
$btnConfig.BackColor = $ColorBtnAction
$btnConfig.FlatStyle = "Flat"
$btnConfig.FlatAppearance.BorderSize = 0
$btnConfig.ForeColor = [System.Drawing.Color]::White
$btnConfig.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$btnConfig.Cursor = [System.Windows.Forms.Cursors]::Hand
$grpActions.Controls.Add($btnConfig)

# --- PAINEL DE DOWNLOADS ---
$grpDownloadsYStart = $grpActionsYStart + 120 + 15 # Abaixo das Ações

$grpDownloads = New-Object System.Windows.Forms.GroupBox
$grpDownloads.Text = " Instalacao de Softwares " # Removido o acento
$grpDownloads.ForeColor = $ColorText
$grpDownloads.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
# O tamanho do grupo permanece 460 para 6 linhas completas
$grpDownloads.Size = New-Object System.Drawing.Size(645, 460) 
$grpDownloads.Location = New-Object System.Drawing.Point(20, $grpDownloadsYStart)
$form.Controls.Add($grpDownloads)

# Estilo padrao botoes download
$btnStyle = {
    param($btn)
    $btn.Size = New-Object System.Drawing.Size(290, 50)
    $btn.BackColor = $ColorBtnDown
    $btn.FlatStyle = "Flat"
    $btn.FlatAppearance.BorderSize = 0
    $btn.ForeColor = [System.Drawing.Color]::White
    $btn.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $btn.Cursor = [System.Windows.Forms.Cursors]::Hand
}

# LINHA 1 (SQL Server 2008 e SQL 2019 Netcontroll)
# Botao SQL 2008
$btnSQL = New-Object System.Windows.Forms.Button
$btnSQL.Text = "SQL Server 2008 (Automatico)"
$btnSQL.Location = New-Object System.Drawing.Point(20, 40)
& $btnStyle $btnSQL
$grpDownloads.Controls.Add($btnSQL)

# Botao SQL 2019 (Link Netcontroll - Automático)
$btnSQL19 = New-Object System.Windows.Forms.Button
$btnSQL19.Text = "SQL Server 2019 (Automatico)"
$btnSQL19.Location = New-Object System.Drawing.Point(330, 40)
& $btnStyle $btnSQL19
$grpDownloads.Controls.Add($btnSQL19)

# LINHA 2 (Concentrador e NetPDV)
# Botao Concentrador (Movido para a posição 2)
$btnConc = New-Object System.Windows.Forms.Button
$btnConc.Text = "Concentrador"
$btnConc.Location = New-Object System.Drawing.Point(20, 110)
& $btnStyle $btnConc
$grpDownloads.Controls.Add($btnConc)

# Botao NetPDV (Movido para a posição 2)
$btnNetPDV = New-Object System.Windows.Forms.Button
$btnNetPDV.Text = "NetPDV"
$btnNetPDV.Location = New-Object System.Drawing.Point(330, 110)
& $btnStyle $btnNetPDV
$grpDownloads.Controls.Add($btnNetPDV)

# LINHA 3 (LinkXMenu e Xbot)
# Botao LinkXMenu
$btnLink = New-Object System.Windows.Forms.Button
$btnLink.Text = "Link XMenu"
$btnLink.Location = New-Object System.Drawing.Point(20, 180)
& $btnStyle $btnLink
$grpDownloads.Controls.Add($btnLink)

# Botao Xbot
$btnXbot = New-Object System.Windows.Forms.Button
$btnXbot.Text = "XBot"
$btnXbot.Location = New-Object System.Drawing.Point(330, 180)
& $btnStyle $btnXbot
$grpDownloads.Controls.Add($btnXbot)

# LINHA 4 (Xtag e VSPE)
# Botao Xtag
$btnXtag = New-Object System.Windows.Forms.Button
$btnXtag.Text = "XTag Client 2.0"
$btnXtag.Location = New-Object System.Drawing.Point(20, 250)
& $btnStyle $btnXtag
$grpDownloads.Controls.Add($btnXtag)

# Botao VSPE
$btnVSPE = New-Object System.Windows.Forms.Button
$btnVSPE.Text = "VSPE (Virtual Serial Port)"
$btnVSPE.Location = New-Object System.Drawing.Point(330, 250)
& $btnStyle $btnVSPE
$grpDownloads.Controls.Add($btnVSPE)

# LINHA 5 (ZIP Versoes PDV e ZIP Versoes Concentrador) - Botões ZIP lado a lado
# Botao ZIP Versoes PDV
$btnZipPdv = New-Object System.Windows.Forms.Button
$btnZipPdv.Text = "ZIP Versoes PDV"
$btnZipPdv.Location = New-Object System.Drawing.Point(20, 320) # POSIÇÃO ESQUERDA
& $btnStyle $btnZipPdv
$grpDownloads.Controls.Add($btnZipPdv)

# Botao ZIP Versoes Concentrador
$btnZipConc = New-Object System.Windows.Forms.Button
$btnZipConc.Text = "ZIP Versoes Concentrador"
$btnZipConc.Location = New-Object System.Drawing.Point(330, 320) # POSIÇÃO DIREITA
& $btnStyle $btnZipConc
$grpDownloads.Controls.Add($btnZipConc)

# LINHA 6 (TecnoSpeed e SQL + SSMS MANUAL) - SQL Manual é o último
# Botao NFCe (TecnoSpeed)
$btnNFCe = New-Object System.Windows.Forms.Button
$btnNFCe.Text = "TecnoSpeed"
$btnNFCe.Location = New-Object System.Drawing.Point(20, 390) # POSIÇÃO ESQUERDA
& $btnStyle $btnNFCe
$grpDownloads.Controls.Add($btnNFCe)

# Botao SQL + SSMS MANUAL (AGORA É O ÚLTIMO)
$btnSQLSSMSManual = New-Object System.Windows.Forms.Button
$btnSQLSSMSManual.Text = "SQL 2019 + SSMS MANUAL"
$btnSQLSSMSManual.Location = New-Object System.Drawing.Point(330, 390) # ÚLTIMA POSIÇÃO
& $btnStyle $btnSQLSSMSManual
$grpDownloads.Controls.Add($btnSQLSSMSManual)


# --- PROGRESSO (Mover para baixo, após o último grupo) ---
$progressBarYStart = $grpDownloadsYStart + 460 + 5 # Ajustado o YStart

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Size = New-Object System.Drawing.Size(685, 10)
$progressBar.Location = New-Object System.Drawing.Point(0, $progressBarYStart)
$progressBar.Style = "Continuous"
$form.Controls.Add($progressBar)


# --- EVENTOS ---
$btnSQL.Add_Click({ Download-And-Run "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2008x64.exe" "SQL2008x64.exe" $btnSQL })
# Link SQL 2019 (Netcontroll)
$btnSQL19.Add_Click({ Download-And-Run "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2019.exe" "SQL2019.exe" $btnSQL19 }) 

# NOVO Link SQL 2019 Manual + SSMS 2022 (UNIFICADO)
$btnConc.Add_Click({ Download-And-Run "https://www.netcontroll.com.br/util/instaladores/netpdv/InstaladorConcentrador.exe" "Concentrador.exe" $btnConc })
$btnNetPDV.Add_Click({ Download-And-Run "https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.exe" "NetPDV.exe" $btnNetPDV })
$btnLink.Add_Click({ Download-And-Run "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/11/LinkXMenu.exe" "LinkXMenu.exe" $btnLink })
$btnXbot.Add_Click({ Download-And-Run "https://aws.netcontroll.com.br/XBotClient/setup.exe" "XBotSetup.exe" $btnXbot })
$btnXtag.Add_Click({ Download-And-Run "https://aws.netcontroll.com.br/XTagClient2.0/setup.exe" "XTagSetup.exe" $btnXtag })
$btnVSPE.Add_Click({ Download-And-Run "https://www.netcontroll.com.br/util/instaladores/VSPE/VSPE.zip" "VSPE.zip" $btnVSPE })

# Evento para ZIP Versões PDV (placeholder)
$btnZipPdv.Add_Click({ 
    # Insira o link de download do ZIP Versões PDV aqui
    Download-And-Run "http://link.para.zip.versoes.pdv/VERSOESPDV.zip" "VERSOESPDV.zip" $btnZipPdv 
})

# Evento para ZIP Versões Concentrador (placeholder)
$btnZipConc.Add_Click({ 
    # Insira o link de download do ZIP Versões Concentrador aqui
    Download-And-Run "http://link.para.zip.versoes.concentrador/VERSOESCONC.zip" "VERSOESCONC.zip" $btnZipConc 
})

# BOTÃO SQL MANUAL (AGORA É O PENÚLTIMO EVENTO)
$btnSQLSSMSManual.Add_Click({ 
    $originalText = $btnSQLSSMSManual.Text
    $btnSQLSSMSManual.Enabled = $false
    $btnSQLSSMSManual.Text = "Baixando SQL 2019..."
    $btnSQLSSMSManual.BackColor = [System.Drawing.Color]::Orange
    $form.Refresh()
    Log-Message "Iniciando download SQL 2019 MANUAL e SSMS..."
    
    # Download SQL 2019 Manual
    $sqlSuccess = Download-Only "https://download.microsoft.com/download/7/f/8/7f8a9c43-8c8a-4f7c-9f92-83c18d96b681/SQL2019-SSEI-Expr.exe" "SQL2019-SSEI-Expr.exe"
    
    if ($sqlSuccess) {
        $btnSQLSSMSManual.Text = "Baixando SSMS 2022..."
        $btnSQLSSMSManual.BackColor = [System.Drawing.Color]::Orange
        $form.Refresh()
        
        # Download SSMS 2022
        $ssmsSuccess = Download-Only "https://aka.ms/ssms/22/release/vs_SSMS.exe" "vs_SSMS.exe"
    }
    
    # Se os dois downloads falharem, o estado do botao deve ser 'Erro'.
    if (-not $sqlSuccess -or -not $ssmsSuccess) {
        $btnSQLSSMSManual.Text = "Erro em um dos downloads"
        $btnSQLSSMSManual.BackColor = [System.Drawing.Color]::DarkRed
    } else {
        $btnSQLSSMSManual.Text = "Downloads Manuais Iniciados"
        $btnSQLSSMSManual.BackColor = [System.Drawing.Color]::SeaGreen
    }
    
    $btnSQLSSMSManual.Enabled = $true
    Start-Sleep -Seconds 2
    if ($btnSQLSSMSManual.Text -eq "Erro em um dos downloads") { $btnSQLSSMSManual.Text = $originalText }
})

# Evento NFCe (TecnoSpeed) - AGORA É O ÚLTIMO EVENTO
$btnNFCe.Add_Click({ Download-And-Run "https://www.netcontroll.com.br/util/instaladores/NFCE/10.1.83.68/InstaladorNFCe.exe" "InstaladorNFCe.exe" $btnNFCe })

# --- LOGICA DE CONFIGURACAO ---
$btnConfig.Add_Click({
    # CORREÇÃO: Usando $false para a sintaxe correta do booleano no PowerShell
    $btnConfig.Enabled = $false
    $btnConfig.Text = "Processando... Por favor, aguarde."
    $btnConfig.BackColor = [System.Drawing.Color]::Gray
    $progressBar.Value = 0

    # 1. UAC
    Log-Message "ETAPA 1: Configurando UAC e Politicas..."
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f" -Wait -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f" -Wait -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f" -Wait -NoNewWindow
    $progressBar.Value = 20

    # 2. ENERGIA
    Log-Message "ETAPA 2: Otimizando Energia..."
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    # Botoes
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 7648efa3-dd9c-4e3e-b566-50f929386280 0
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 96996bc0-ad50-47ec-923b-6f41874dd9eb 0
    powercfg /setacvalueindex SCHEME_CURRENT 4f971e89-eebd-4455-a8de-9e59040e7347 5ca83367-6e45-459f-a27b-476b1d01c936 0
    powercfg /setactive SCHEME_CURRENT
    # Fast Boot
    Start-Process "reg.exe" -ArgumentList "ADD ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f" -Wait -NoNewWindow
    $progressBar.Value = 40

    # 3. DATA
    Log-Message "ETAPA 3: Ajustando Data..."
    Set-ItemProperty -Path "HKCU:\Control Panel\International" -Name "sShortDate" -Value "dd/MM/yyyy" -Force
    
    # 4. EXPLORER & ICONES
    Log-Message "ETAPA 4: Configurando Explorador e Icones..."
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1 -Force
    $iconPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    if (!(Test-Path $iconPath)) { New-Item -Path $iconPath -Force | Out-Null }
    Set-ItemProperty -Path $iconPath -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Force # PC
    Set-ItemProperty -Path $iconPath -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 0 -Force # Lixeira
    Set-ItemProperty -Path $iconPath -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0 -Force # User
    Set-ItemProperty -Path $iconPath -Name "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" -Value 0 -Force # Rede
    $progressBar.Value = 60

    # 5. REDE & COMPARTILHAMENTO
    Log-Message "ETAPA 5: Liberando Rede..."
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f" -Wait -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v everyoneincludesanonymous /t REG_DWORD /d 1 /f" -Wait -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters /v restrictnullsessaccess /t REG_DWORD /d 0 /f" -Wait -NoNewWindow

    # 6. LIMPEZA TOTAL DA BARRA DE TAREFAS
    Log-Message "ETAPA 6: Limpando Barra de Tarefas e Toolbars (Remocao de Streams)..."
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    
    # Remove icones padrao da barra
    Set-ItemProperty -Path $advKey -Name "ShowCortanaButton" -Value 0 -Force
    Set-ItemProperty -Path $advKey -Name "ShowTaskViewButton" -Value 0 -Force
    
    # Adiciona verificacao para a chave 'People' (que pode nao existir no W11)
    $peopleKeyPath = "$advKey\People"
    if (!(Test-Path $peopleKeyPath)) { 
        New-Item -Path $advKey -Name "People" -Force | Out-Null 
    }
    Set-ItemProperty -Path $peopleKeyPath -Name "PeopleBand" -Value 0 -Force
    
    # NOVO: Remove botao 'Reunir Agora' (Meet Now)
    Set-ItemProperty -Path $advKey -Name "TaskbarMn" -Value 0 -Force
    
    # Pesquisa Oculta
    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value 0 -Force
    
    # Noticias (Weather)
    Start-Process "reg.exe" -ArgumentList "ADD ""HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds"" /v ShellFeedsTaskbarViewMode /t REG_DWORD /d 2 /f" -Wait -NoNewWindow
    
    # NOVO: Desativa Widgets (News and Interests) no Windows 11 (HKLM Policy)
    Log-Message "Desativando Widgets (News and Interests) via politica HKLM..."
    $dshPolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    if (!(Test-Path $dshPolicyPath)) { 
        New-Item -Path $dshPolicyPath -Force | Out-Null
        Log-Message "Chave de Politica DSH criada."
    }
    Set-ItemProperty -Path $dshPolicyPath -Name "AllowNewsAndInterests" -Type DWord -Value 0 -Force
    
    # NOVO E MAIS ROBUSTO: Remove as chaves de Stream/Desktop que armazenam a configuracao das toolbars
    # Isso força o Explorer a resetar o estado da barra de tarefas, removendo Endereço, Links e Área de Trabalho.
    Log-Message "Resetando configuracao das Toolbars da Barra de Tarefas (Streams)..."
    $toolbarStreamPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\TaskbarWinXP",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\Taskband"
    )

    foreach ($p in $toolbarStreamPaths) {
        if (Test-Path $p) {
            # Remove a chave e todo o seu conteudo recursivamente
            # Redirecionando a saída de erros (2) para o nulo ($null) para suprimir mensagens de erro de permissão/acesso negado.
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue 2>$null 
            Log-Message "Removida chave: $p"
        }
    }
    
    $progressBar.Value = 80

    # 7. VISUAL, LIMPEZA, WALLPAPER & ATALHO DE SUPORTE
    Log-Message "ETAPA 7: Visual, Limpeza de Temp e Wallpaper..."
    
    # Config visual
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Force
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 3 -Force
    Set-ItemProperty -Path $advKey -Name "ListviewAlphaSelect" -Value 1 -Force
    Set-ItemProperty -Path $advKey -Name "ListviewShadow" -Value 1 -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothing" -Value "2" -Force
    
    # Limpeza - CORREÇÃO: Usando Out-Null para suprimir a saída de erros de "Acesso negado" e "Objeto não encontrado"
    Log-Message "Limpando arquivos temporarios..." # Removido o acento
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path "$env:windir\Temp\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    
    # 7.5. WALLPAPER & ATALHO DE SUPORTE
    $scriptRoot = $PSScriptRoot 

    # Define Wallpaper
    Log-Message "Configurando Papel de Parede..."
    $wallpaperPath = Join-Path -Path $scriptRoot -ChildPath "fundo.png"

    if (Test-Path $wallpaperPath) {
        # Define o estilo do Wallpaper: 10 = Fill (Preencher), 0 = Nao ladrilhar
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10" -Type String -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallPaper" -Value "0" -Type String -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallPaper" -Value $wallpaperPath -Type String -Force
        
        # Atualiza o Desktop
        [Stuff.WinAPI]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE) | Out-Null
        Log-Message "Papel de parede definido para '$wallpaperPath'."
    } else {
        Log-Message "AVISO: Imagem 'fundo.png' nao encontrada no diretorio do script. Wallpaper nao alterado."
    }

    # Copia Atalho de Suporte e Icone
    $targetBaseDir = "C:\Netcontroll\SuporteXmenuChat"
    $targetConfigDir = Join-Path -Path $targetBaseDir -ChildPath "Config"
    
    # Nomes dos arquivos de recurso
    $iconFileName = "iconeatalho.ico"
    $faviconFileName = "faviconxmenu.ico" # NOVO: Nome do favicon
    $headerIconFileName = "iconheaderxmenu.png"
    $pdfFileName = "SuporteXmenuDicas.pdf"
    $htmlFileName = "Suporte Xmenu.html" 
    
    # Caminhos para o atalho
    # CORREÇÃO: Usa o Desktop Público para que o atalho apareça para todos os usuários
    $desktopPath = [System.IO.Path]::Combine($env:PUBLIC, "Desktop") 
    $shortcutName = "Suporte Xmenu"
    $shortcutPath = [System.IO.Path]::Combine($desktopPath, "$shortcutName.lnk")
    
    Log-Message "Criando estrutura de pastas: $targetConfigDir"
    if (-not (Test-Path $targetConfigDir)) {
        New-Item -Path $targetConfigDir -ItemType Directory -Force | Out-Null
    }

    # 1. Copia Arquivo HTML e Recursos para a subpasta Config
    Log-Message "Copiando arquivos de suporte e icones para C:\Config"
    try {
        # Lista de arquivos para copiar (todos para $targetConfigDir)
        # Assume que todos os arquivos (HTML, ICO, PNG, PDF) estao dentro da subpasta 'config' do script.
        $filesToCopy = @(
            "config\$htmlFileName",
            "config\$iconFileName",
            "config\$faviconFileName", # NOVO: Adicionado o favicon à lista de cópia
            "config\$headerIconFileName",
            "config\$pdfFileName"
        )
        
        foreach ($file in $filesToCopy) {
            $source = Join-Path -Path $scriptRoot -ChildPath $file
            $destFileName = Split-Path -Leaf $file
            $destination = Join-Path -Path $targetConfigDir -ChildPath $destFileName
            
            if (Test-Path $source) {
                Copy-Item -Path $source -Destination $destination -Force
                Log-Message "Arquivo copiado: $destFileName"
            } else {
                Log-Message "AVISO: Recurso '$file' nao encontrado. Ignorando."
            }
        }
        
        # O caminho final do HTML
        $finalHtmlPath = Join-Path -Path $targetConfigDir -ChildPath $htmlFileName
        
    } catch {
        Log-Message "ERRO ao copiar arquivos para C:\Netcontroll: $_"
    }

    # 2. Criar NOVO atalho na Area de Trabalho que aponta para o HTML na pasta Config e usa o icone em C:\Config
    Log-Message "Criando atalho na Area de Trabalho com icone customizado..."
    try {
        $WshShell = New-Object -ComObject WScript.Shell
        $Shortcut = $WshShell.CreateShortcut($shortcutPath)
        
        # O atalho aponta para o executável CMD
        $Shortcut.TargetPath = "cmd.exe"
        
        # CORREÇÃO DA SINTAXE: Usando o operador -f para formatação segura, evitando erro de parser.
        # Arguments: /c start "" "caminho_completo_do_html"
        $Shortcut.Arguments = '/c start "" "{0}"' -f $finalHtmlPath
        
        # Define o ícone customizado, apontando para o ICO copiado em C:\Config
        $Shortcut.IconLocation = Join-Path -Path $targetConfigDir -ChildPath $iconFileName
        $Shortcut.Save()
        
        Log-Message "Atalho '$shortcutName' criado com sucesso na Area de Trabalho com icone e metodo de abertura robusto."
    } catch {
        Log-Message "ERRO ao criar atalho com WScript.Shell: $_"
    }
    
    # 3. CORREÇÃO DE ÍCONE: Limpar o cache de ícones
    Log-Message "Limpando o cache de icones para forcar a atualizacao do atalho..."
    try {
        # CORREÇÃO: Forçar o fechamento de mais processos para garantir que IconCache.db possa ser removido.
        Stop-Process -Name Explorer -Force -ErrorAction SilentlyContinue
        Stop-Process -Name imageres -Force -ErrorAction SilentlyContinue
        
        # Limpa o cache de ícones (localizado em diferentes caminhos dependendo do Windows)
        $iconCacheFiles = @(
            "$env:LOCALAPPDATA\IconCache.db",
            "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db"
        )

        foreach ($file in $iconCacheFiles) {
            Get-ChildItem -Path $file -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }

    } catch {
        Log-Message "AVISO: Nao foi possivel limpar o cache de icones: $_"
    }


    # 8. REINICIAR INTERFACE
    Log-Message "Reiniciando Interface..."
    # Garante que o explorer seja iniciado novamente após a limpeza do cache (se tiver sido parado)
    $explorerProc = Get-Process explorer -ErrorAction SilentlyContinue
    if (-not $explorerProc) {
        Start-Process explorer.exe
    }
    Start-Sleep -Seconds 2 # Dá um tempo para o explorer carregar
    
    $progressBar.Value = 100
    Log-Message "CONFIGURACAO CONCLUIDA."
    
    # --- JANELA FINAL PERSONALIZADA (CUSTOM FORM) ---
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = "Finalizacao Necessaria"
    $finalForm.Size = New-Object System.Drawing.Size(550, 400) # Aumentada
    $finalForm.StartPosition = "CenterScreen"
    $finalForm.BackColor = $ColorDarkBg
    $finalForm.ForeColor = $ColorText
    $finalForm.FormBorderStyle = "FixedDialog"
    $finalForm.MaximizeBox = $false
    $finalForm.MinimizeBox = $false

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = "CONFIGURACAO AUTOMATICA CONCLUIDA!"
    $lblHead.Location = New-Object System.Drawing.Point(25, 25)
    $lblHead.Size = New-Object System.Drawing.Size(500, 30)
    $lblHead.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblHead.ForeColor = [System.Drawing.Color]::LimeGreen
    $finalForm.Controls.Add($lblHead)

    $lblBody = New-Object System.Windows.Forms.Label
    $lblBody.Text = "JANELAS SERAO ABERTAS AGORA PARA AJUSTE MANUAL:`n`n1. Recursos do Windows:`n   - Marque '.NET 3.5' e 'IIS'.`n`n2. Compartilhamento (Todas as Redes):`n   - Marque 'Desativar compartilhamento protegido por senha'.`n`n3. Regiao:`n   - Verifique se a data esta dd/MM/aaaa.`n`n4. Opcoes de Desempenho (Visuais):`n   - Configure os efeitos visuais conforme preferencia."
    $lblBody.Location = New-Object System.Drawing.Point(25, 70)
    $lblBody.Size = New-Object System.Drawing.Size(480, 200)
    $lblBody.Font = New-Object System.Drawing.Font("Segoe UI", 11)
    $finalForm.Controls.Add($lblBody)

    $btnOk = New-Object System.Windows.Forms.Button
    $btnOk.Text = "ENTENDIDO, ABRIR JANELAS"
    $btnOk.Location = New-Object System.Drawing.Point(125, 280)
    $btnOk.Size = New-Object System.Drawing.Size(280, 50)
    $btnOk.BackColor = $ColorBtnAction
    $btnOk.ForeColor = [System.Drawing.Color]::White
    $btnOk.FlatStyle = "Flat"
    $btnOk.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnOk.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnOk.Add_Click({ $finalForm.Close() })
    $finalForm.Controls.Add($btnOk)

    # Exibe a janela customizada
    $finalForm.ShowDialog()
    
    # Abre janelas para acao manual apos fechar o aviso
    Start-Process "OptionalFeatures.exe"
    Start-Process "control.exe" -ArgumentList "/name Microsoft.NetworkAndSharingCenter /page Advanced"
    Start-Process "intl.cpl"
    Start-Process "systempropertiesperformance.exe"
    
    $btnConfig.Text = "Configuracao Concluida"
    $btnConfig.BackColor = [System.Drawing.Color]::SeaGreen
    $btnConfig.Enabled = $true
})

$form.ShowDialog()