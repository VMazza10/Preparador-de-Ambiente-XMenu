# =============================================================================
# FERRAMENTA DE PREPARAÇÃO DE AMBIENTE XMENU (GUI v12.0 - FIXED RESIZE)
# =============================================================================
# CORREÇÕES E RESTAURAÇÕES COMPLETAS:
# - Altura do cabeçalho e responsividade corrigidas
# - Acentuação e ortografia corrigidas
# - Ícones da Área de Trabalho (Computador, Rede, Lixeira, Usuário) GARANTIDOS
# - Limpeza de Toolbars da Barra de Tarefas restaurada
# - Desativação de Hibernação restaurada
# - Ajustes Visuais (MenuDelay, etc) restaurados
# - Limpeza de Arquivos Temporários restaurada
# - Limpeza de Cache de Ícones restaurada
# - Criação do Atalho "Suporte Xmenu" REFORÇADA (Igual versão 8.2)
# - CORREÇÃO DE ERRO: Tratamento de permissão na chave de Feeds (Notícias)
# =============================================================================

# --- VARIÁVEIS GLOBAIS ---
$RepoBase = "https://raw.githubusercontent.com/VMazza10/Preparador-de-Ambiente-XMenu/main" 
$Script:LogControl = $null 
$Script:HeaderPanel = $null
$Script:MainButton = $null
$Script:GrpLog = $null
$Script:GrpInstall = $null
$Script:ProgressBar = $null 

# --- CAMINHO DE DESTINO DOS DOWNLOADS (DESKTOP) ---
$DesktopPath = [System.Environment]::GetFolderPath('Desktop')
$Script:DownloadFolder = Join-Path -Path $DesktopPath -ChildPath "Arquivos Xmenu"

if (-not (Test-Path $Script:DownloadFolder)) {
    New-Item -Path $Script:DownloadFolder -ItemType Directory -Force | Out-Null
}

# --- VERIFICAÇÃO DE ADMINISTRADOR ---
$principal = [Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "ERRO CRÍTICO: Execute como Administrador."
    Start-Sleep -Seconds 5
    Exit 1
}

# --- IMPORTS ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net

# --- API Import (Wallpaper) ---
$code = @'
[DllImport("user32.dll", CharSet=CharSet.Auto)]
public static extern int SystemParametersInfo (UInt32 uiAction, UInt32 uiParam, string pvParam, UInt32 fWinIni);
'@
Add-Type -MemberDefinition $code -Name "WinAPI" -Namespace "Stuff"
$SPI_SETDESKWALLPAPER = 0x14
$SPIF_UPDATEINIFILE = 0x01
$SPIF_SENDCHANGE = 0x02

# --- CORES E ESTILOS ---
$ColorBg        = [System.Drawing.Color]::FromArgb(32, 33, 36)
$ColorHeader    = [System.Drawing.Color]::FromArgb(0, 120, 212)
$ColorSuccess   = [System.Drawing.Color]::SeaGreen
$ColorText      = [System.Drawing.Color]::WhiteSmoke
$ColorSubText   = [System.Drawing.Color]::FromArgb(180, 180, 180)
$ColorLogBg     = [System.Drawing.Color]::FromArgb(15, 15, 15)
$ColorLogText   = [System.Drawing.Color]::FromArgb(0, 255, 128)
$ColorError     = [System.Drawing.Color]::FromArgb(255, 80, 80)
$ColorBtnNormal = [System.Drawing.Color]::FromArgb(60, 60, 60)
$ColorBtnHover  = [System.Drawing.Color]::FromArgb(80, 80, 80)
$ColorBtnAction = [System.Drawing.Color]::FromArgb(0, 120, 212)

$FontTitle = New-Object System.Drawing.Font("Segoe UI", 20, [System.Drawing.FontStyle]::Bold)
$FontSub   = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Regular)
$FontBtn   = New-Object System.Drawing.Font("Segoe UI Semibold", 10)
$FontLog   = New-Object System.Drawing.Font("Consolas", 10)
$FontBigBtn = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)

# --- FORMULÁRIO PRINCIPAL ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Instalador XMenu v12.0"
$form.Size = New-Object System.Drawing.Size(850, 900) 
$form.WindowState = "Normal" 
$form.StartPosition = "CenterScreen"
$form.BackColor = $ColorBg
$form.ForeColor = $ColorText
$form.FormBorderStyle = "Sizable"

# --- CABEÇALHO ---
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Height = 140
$pnlHeader.Dock = "Top"
$pnlHeader.BackColor = $ColorHeader
$pnlHeader.Padding = New-Object System.Windows.Forms.Padding(20)
$form.Controls.Add($pnlHeader)
$Script:HeaderPanel = $pnlHeader

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "ASSISTENTE DE CONFIGURAÇÃO XMENU"
$lblTitle.Font = $FontTitle
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(20, 15)
$lblTitle.AutoSize = $false
$lblTitle.Size = New-Object System.Drawing.Size(($pnlHeader.Width - 180), 80) 
$lblTitle.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Automação de Ambiente Windows e Softwares Netcontroll"
$lblSub.Font = $FontSub
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
$lblSub.Location = New-Object System.Drawing.Point(25, 95) 
$lblSub.AutoSize = $false
$lblSub.Size = New-Object System.Drawing.Size(($pnlHeader.Width - 180), 30)
$lblSub.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblSub.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$pnlHeader.Controls.Add($lblSub)

# --- BOTÃO COPIAR IP ---
$btnCopyIP = New-Object System.Windows.Forms.Button
$btnCopyIP.Text = "Copiar IP local"
$btnCopyIP.Size = New-Object System.Drawing.Size(120, 30)
$btnCopyIP.Location = New-Object System.Drawing.Point(($pnlHeader.Width - 150), 25) 
$btnCopyIP.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$btnCopyIP.BackColor = [System.Drawing.Color]::White
$btnCopyIP.ForeColor = $ColorHeader
$btnCopyIP.FlatStyle = "Flat"
$btnCopyIP.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$btnCopyIP.Cursor = [System.Windows.Forms.Cursors]::Hand
$pnlHeader.Controls.Add($btnCopyIP)

# --- PAINEL DE CONTEÚDO ---
$pnlContent = New-Object System.Windows.Forms.Panel
$pnlContent.Dock = "Fill"
$pnlContent.AutoScroll = $true
$pnlContent.Padding = New-Object System.Windows.Forms.Padding(30) 
$form.Controls.Add($pnlContent)
$pnlContent.BringToFront() 

# --- TABLE LAYOUT PRINCIPAL ---
$tlpMain = New-Object System.Windows.Forms.TableLayoutPanel
$tlpMain.Dock = "Top"
$tlpMain.AutoSize = $true
$tlpMain.ColumnCount = 1
$tlpMain.RowCount = 5
$tlpMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 250))) | Out-Null
$tlpMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20))) | Out-Null
$tlpMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 80))) | Out-Null
$tlpMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 20))) | Out-Null
$tlpMain.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) | Out-Null
$pnlContent.Controls.Add($tlpMain)

# --- 1. LOGS ---
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = "Log de Operações Detalhado"
$grpLog.ForeColor = $ColorSubText
$grpLog.Font = $FontSub
$grpLog.Dock = "Fill"
$tlpMain.Controls.Add($grpLog, 0, 0)
$Script:GrpLog = $grpLog

$txtLog = New-Object System.Windows.Forms.RichTextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.Dock = "Fill"
$txtLog.BackColor = $ColorLogBg
$txtLog.ForeColor = $ColorLogText
$txtLog.Font = $FontLog
$txtLog.ReadOnly = $true
$txtLog.BorderStyle = "None"
$grpLog.Controls.Add($txtLog)
$Script:LogControl = $txtLog

# --- 2. BOTÃO PRINCIPAL ---
$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Text = "PREPARAR AMBIENTE"
$btnConfig.Dock = "Fill"
$btnConfig.BackColor = $ColorBtnAction
$btnConfig.ForeColor = [System.Drawing.Color]::White
$btnConfig.FlatStyle = "Flat"
$btnConfig.FlatAppearance.BorderSize = 0
$btnConfig.Font = $FontBigBtn
$btnConfig.Cursor = [System.Windows.Forms.Cursors]::Hand
$tlpMain.Controls.Add($btnConfig, 0, 2)
$Script:MainButton = $btnConfig

# --- 3. DOWNLOADS ---
$grpInstall = New-Object System.Windows.Forms.GroupBox
$grpInstall.Text = "Instalação de Softwares"
$grpInstall.ForeColor = $ColorSubText
$grpInstall.Font = $FontSub
$grpInstall.AutoSize = $true
$grpInstall.Dock = "Top"
$grpInstall.Padding = New-Object System.Windows.Forms.Padding(10, 25, 10, 10)
$tlpMain.Controls.Add($grpInstall, 0, 4)

$tblButtons = New-Object System.Windows.Forms.TableLayoutPanel
$tblButtons.Dock = "Top"
$tblButtons.AutoSize = $true
$tblButtons.ColumnCount = 2
$tblButtons.RowCount = 7
$tblButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$tblButtons.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50))) | Out-Null
$grpInstall.Controls.Add($tblButtons)

# --- BARRA DE PROGRESSO ---
$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Size = New-Object System.Drawing.Size(720, 5)
$progressBar.Dock = "Bottom"
$progressBar.Style = "Continuous"
$form.Controls.Add($progressBar)
$Script:ProgressBar = $progressBar

# --- FUNÇÕES AUXILIARES ---

function Log-Message {
    param($Msg)
    $t = $Script:LogControl
    $clean = $Msg -replace '[^a-zA-Z0-9\s:\[\]\-\/\.\(\)]', ''
    $t.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] $clean`r`n")
    $t.ScrollToCaret()
    $form.Refresh()
}

function Log-Error {
    param($Msg)
    $t = $Script:LogControl
    $t.SelectionStart = $t.TextLength
    $t.SelectionLength = 0
    $t.SelectionColor = $ColorError
    $t.AppendText("[$((Get-Date).ToString('HH:mm:ss'))] ERRO: $Msg`r`n")
    $t.SelectionColor = $ColorLogText
    $t.ScrollToCaret()
    $form.Refresh()
}

function Get-LocalIP {
    try {
        $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        if (-not $activeAdapters) { Log-Error "Sem rede conectada."; return }

        $ips = $activeAdapters | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
               Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } |
               Select-Object -ExpandProperty IPAddress -Unique
        
        if ($ips) {
            if ($ips -is [string]) { $ips = @($ips) }
            $ipString = $ips -join "`n"
            $ipString | Set-Clipboard
            
            if ($ips.Count -eq 1) { Log-Message "IP copiado: $($ips[0])" }
            else { Log-Message "IPs copiados: $($ips -join ', ')" }
        } else { Log-Error "Nenhum IP válido encontrado." }
    } catch { Log-Error "Erro IP: $_" }
}
$btnCopyIP.Add_Click({ Get-LocalIP })

function Download-Core {
    param($Url, $FileName, $Unblock)
    if ($null -eq $Unblock) { $Unblock = $true }

    $destPath = Join-Path -Path $Script:DownloadFolder -ChildPath $FileName
    
    try {
        $SafeUrl = $Url.Replace(" ", "%20")
        Log-Message "Iniciando download de: $FileName"
        Log-Message "Salvando em: $destPath"
        
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($SafeUrl, $destPath)
        Log-Message "Download OK."
        
        if ($Unblock) { 
            Log-Message "Desbloqueando arquivo de seguranca..."
            Unblock-File -Path $destPath -ErrorAction SilentlyContinue 
        }
        
        Log-Message "Executando instalador..."
        Start-Process $destPath
        Log-Message "Instalação iniciada: $FileName"
        return $true
    } catch {
        $errMsg = "Falha no download de $FileName : $_"
        Log-Error $errMsg
        return $false
    }
}

function Download-Btn-Action {
    param($Url, $FileName, $Btn)
    $originalText = $Btn.Text
    
    if ($originalText -like "*Instalado") { return }

    $Btn.Enabled = $false; $Btn.Text = "Baixando..."; $Btn.BackColor = [System.Drawing.Color]::Orange; $form.Refresh()
    
    $result = Download-Core $Url $FileName $true
    
    $Btn.BackColor = [System.Drawing.Color]::SeaGreen
    $Btn.Text = "$originalText Instalado" 
    
    $Btn.Enabled = $true
}

function Add-Btn {
    param($Txt, $Url, $File, $Row, $Col)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Txt
    $b.Tag = "$Url|$File"
    $b.Dock = "Fill" 
    $b.Height = 45
    $b.Margin = New-Object System.Windows.Forms.Padding(5)
    $b.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
    $b.ForeColor = [System.Drawing.Color]::White
    $b.FlatStyle = "Flat"
    $b.FlatAppearance.BorderSize = 0
    $b.Font = $FontBtn
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    
    $b.Add_MouseEnter({ 
        if ($this.Text -notlike "*Instalado") { $this.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80) }
    })
    $b.Add_MouseLeave({ 
        if ($this.Text -like "*Instalado") { 
            $this.BackColor = [System.Drawing.Color]::SeaGreen 
        } else {
            $this.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60) 
        }
    })
    
    $b.Add_Click({ 
        $u = $this.Tag.Split('|')[0]
        $f = $this.Tag.Split('|')[1]
        Download-Btn-Action $u $f $this 
    })
    
    $tblButtons.Controls.Add($b, $Col, $Row)
    return $b
}

# --- LISTA BOTÕES ---
Add-Btn "SQL Server 2008 (Automático)" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2008x64.exe" "SQL2008x64.exe" 0 0 | Out-Null
Add-Btn "SQL Server 2019 (Automático)" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2019.exe" "SQL2019.exe" 0 1 | Out-Null
Add-Btn "Concentrador" "https://www.netcontroll.com.br/util/instaladores/netpdv/InstaladorConcentrador.exe" "Concentrador.exe" 1 0 | Out-Null
Add-Btn "NetPDV" "https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.exe" "NetPDV.exe" 1 1 | Out-Null
Add-Btn "Link XMenu" "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/11/LinkXMenu.exe" "LinkXMenu.exe" 2 0 | Out-Null
Add-Btn "XBot" "https://aws.netcontroll.com.br/XBotClient/setup.exe" "XBotSetup.exe" 2 1 | Out-Null
Add-Btn "XTag Client 2.0" "https://aws.netcontroll.com.br/XTagClient2.0/setup.exe" "XTagSetup.exe" 3 0 | Out-Null
Add-Btn "VSPE (Serial Port)" "https://www.netcontroll.com.br/util/instaladores/VSPE/VSPE.zip" "VSPE.zip" 3 1 | Out-Null
Add-Btn "ZIP Versões PDV" "http://link.para.zip.versoes.pdv/VERSOESPDV.zip" "VERSOESPDV.zip" 4 0 | Out-Null
Add-Btn "ZIP Versões Concentrador" "http://link.para.zip.versoes.concentrador/VERSOESCONC.zip" "VERSOESCONC.zip" 4 1 | Out-Null
Add-Btn "TecnoSpeed" "https://www.netcontroll.com.br/util/instaladores/NFCE/10.1.83.68/InstaladorNFCe.exe" "InstaladorNFCe.exe" 5 0 | Out-Null

# SQL Manual Custom
$btnMan = New-Object System.Windows.Forms.Button
$btnMan.Text = "SQL 2019 + SSMS (MANUAL)"
$btnMan.Dock = "Fill"; $btnMan.Margin = New-Object System.Windows.Forms.Padding(5); $btnMan.Height = 45
$btnMan.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60); $btnMan.ForeColor = [System.Drawing.Color]::White
$btnMan.FlatStyle = "Flat"; $btnMan.FlatAppearance.BorderSize = 0; $btnMan.Font = $FontBtn; $btnMan.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnMan.Add_MouseEnter({ 
    if ($this.Text -notlike "*Instalado") { $this.BackColor = [System.Drawing.Color]::FromArgb(80, 80, 80) }
})
$btnMan.Add_MouseLeave({ 
    if ($this.Text -like "*Instalado") { $this.BackColor = [System.Drawing.Color]::SeaGreen } 
    else { $this.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 60) } 
})
$tblButtons.Controls.Add($btnMan, 1, 5)
$btnMan.Add_Click({
    if ($this.Text -like "*Instalado") { return }
    $this.Text = "Baixando..."; $this.BackColor = [System.Drawing.Color]::Orange; $form.Refresh()
    Download-Core "https://download.microsoft.com/download/7/f/8/7f8a9c43-8c8a-4f7c-9f92-83c18d96b681/SQL2019-SSEI-Expr.exe" "SQL2019-SSEI-Expr.exe" $true
    Download-Core "https://aka.ms/ssms/22/release/vs_SSMS.exe" "vs_SSMS.exe" $true
    $this.Text = "SQL Manual Instalado"; $this.BackColor = [System.Drawing.Color]::SeaGreen
})

# --- AÇÃO CONFIGURAR ---
$btnConfig.Add_Click({
    $this.Enabled = $false
    $this.Text = "PROCESSANDO..."
    $this.BackColor = [System.Drawing.Color]::Gray
    $Script:ProgressBar.Value = 0 
    
    # 1. UAC
    Log-Message "--- INICIANDO CONFIGURAÇÃO ---"
    Log-Message "1. UAC (Segurança):"
    Log-Message "   > Desativando EnableLUA..."
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f" -NoNewWindow
    Log-Message "   > Desativando Prompt Admin..."
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f" -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f" -NoNewWindow
    $Script:ProgressBar.Value = 20

    # 2. Energia
    Log-Message "2. ENERGIA:"
    Log-Message "   > Definindo Plano de Alta Performance..."
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    Log-Message "   > Desativando Tempo Limite de Monitor/Disco..."
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    
    # --- RESTAURADO: Desativaçao de Hibernacao/FastStartup ---
    Log-Message "   > Desativando Hibernação (FastStartup)..."
    Start-Process "reg.exe" -ArgumentList "ADD ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f" -NoNewWindow
    
    $Script:ProgressBar.Value = 40

    # 3. Data e Explorer
    Log-Message "3. AJUSTES VISUAIS E EXPLORER:"
    Log-Message "   > Data DD/MM/AAAA..."
    Set-ItemProperty -Path "HKCU:\Control Panel\International" -Name "sShortDate" -Value "dd/MM/yyyy" -Force
    Log-Message "   > Explorer: Abrir em 'Meu Computador'..."
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1 -Force
    
    # --- RESTAURADO: Ajustes Visuais (Delay e Suavização) ---
    Log-Message "   > Otimizando efeitos visuais (MenuDelay, Fontes)..."
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Force
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 3 -Force
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewAlphaSelect" -Value 1 -Force
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewShadow" -Value 1 -Force
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothing" -Value "2" -Force

    # --- RESTAURADO: Icones Desktop (Computador, Lixeira, Rede, Usuário) ---
    Log-Message "   > Exibindo Ícones Desktop (Computador, Lixeira, Rede, Usuário)..."
    $iconPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    if (!(Test-Path $iconPath)) { New-Item -Path $iconPath -Force | Out-Null }
    # Computador
    Set-ItemProperty -Path $iconPath -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Force
    # Lixeira
    Set-ItemProperty -Path $iconPath -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 0 -Force
    # Arquivos do Usuário
    Set-ItemProperty -Path $iconPath -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0 -Force
    # Rede
    Set-ItemProperty -Path $iconPath -Name "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" -Value 0 -Force

    # 4. Rede
    Log-Message "4. REDE:"
    Log-Message "   > Liberando Firewall (Arquivos)..."
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
    Log-Message "   > Permitindo senhas"
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f" -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v everyoneincludesanonymous /t REG_DWORD /d 1 /f" -NoNewWindow
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters /v restrictnullsessaccess /t REG_DWORD /d 0 /f" -NoNewWindow

    # 5. Barra, Winget e Widgets
    Log-Message "5. LIMPEZA E BARRA DE TAREFAS:"
    Log-Message "   > Removendo Cortana e Visao de Tarefas..."
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $advKey -Name "ShowCortanaButton" -Value 0 -Force
    Set-ItemProperty -Path $advKey -Name "ShowTaskViewButton" -Value 0 -Force
    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value 0 -Force
    
    # --- RESTAURADO: Remocao do botao Pessoas e Feeds ---
    Log-Message "   > Removendo botao Pessoas..."
    $peopleKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People"
    if (!(Test-Path $peopleKeyPath)) { New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "People" -Force | Out-Null }
    Set-ItemProperty -Path $peopleKeyPath -Name "PeopleBand" -Value 0 -Force
    
    Log-Message "   > Desativando Feeds (Noticias e Interesses) na Barra..."
    # 1. Configuracao do Usuario (HKCU) - Modo de Visualização (0=Show, 1=IconOnly, 2=Hidden)
    # CORREÇÃO: Tratamento de erro caso a chave esteja bloqueada/permissão negada
    $feedsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"
    if (!(Test-Path $feedsKey)) { New-Item -Path $feedsKey -Force | Out-Null }
    
    try {
        # Tenta modo nativo do PowerShell
        Set-ItemProperty -Path $feedsKey -Name "ShellFeedsTaskbarViewMode" -Type DWord -Value 2 -Force -ErrorAction Stop
    } catch {
        # Se falhar (acesso negado), tenta via CMD/Reg.exe de forma silenciosa e força via Policy HKLM abaixo
        Log-Message "   > Aviso: Permissao negada no HKCU. Tentando forçar via HKLM Policy..."
        Start-Process "reg.exe" -ArgumentList "ADD ""HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds"" /v ShellFeedsTaskbarViewMode /t REG_DWORD /d 2 /f" -NoNewWindow -ErrorAction SilentlyContinue
    }

    # --- REMOÇÃO DO WINGET (APP INSTALLER) ---
    Log-Message "   > Removendo App Installer (Winget)..."
    Get-AppxPackage -AllUsers *Microsoft.DesktopAppInstaller* | Remove-AppxPackage -ErrorAction SilentlyContinue

    # --- REMOÇÃO DE WIDGETS (NEWS AND INTERESTS) VIA POLÍTICA ---
    Log-Message "   > Bloqueando Widgets via Politica (DSH)..."
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Type DWord -Value 0 -Force
    # Forçar também EnableFeeds para 0
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds")) { New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Force | Out-Null }
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Name "EnableFeeds" -Type DWord -Value 0 -Force


    # --- RESTAURADO: REMOÇAO DE TOOLBARS (Endereço, Links, Area de Trabalho) ---
    Log-Message "   > Resetando Toolbars da Barra de Tarefas..."
    $toolbarStreamPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\TaskbarWinXP",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\Taskband"
    )
    foreach ($p in $toolbarStreamPaths) {
        if (Test-Path $p) {
            Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
        }
    }
    
    # --- RESTAURADO: LIMPEZA DE TEMP ---
    Log-Message "   > Limpando arquivos temporarios..."
    Remove-Item -Path "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem -Path "$env:windir\Temp" -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | Remove-Item -Force -ErrorAction SilentlyContinue | Out-Null

    $Script:ProgressBar.Value = 80

    # 6. PERSONALIZAÇÃO
    Log-Message "6. PERSONALIZAÇAO (ATALHO SUPORTE):"
    $tempDir = "$env:TEMP\XmenuResources"
    if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }
    $wallpaperPath = "$tempDir\fundo.png"
    
    try {
        Log-Message "   > Baixando Wallpaper..."
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile("$RepoBase/fundo.png".Replace(" ", "%20"), $wallpaperPath)
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallPaper" -Value "0" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallPaper" -Value $wallpaperPath -Force
        [Stuff.WinAPI]::SystemParametersInfo($SPI_SETDESKWALLPAPER, 0, $wallpaperPath, $SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE) | Out-Null
    } catch { Log-Error "Erro no Wallpaper." }

    $targetConfigDir = "C:\Netcontroll\SuporteXmenuChat\Config"
    if (-not (Test-Path $targetConfigDir)) { New-Item -Path $targetConfigDir -ItemType Directory -Force | Out-Null }
    
    # Lista atualizada de arquivos de suporte
    $files = @("Suporte Xmenu.html", "iconeatalho.ico", "faviconxmenu.ico", "iconheaderxmenu.png", "SuporteXmenuDicas.pdf")
    foreach ($f in $files) {
        $u = "$RepoBase/Config/$f".Replace(" ", "%20")
        $d = Join-Path $targetConfigDir $f
        try { (New-Object System.Net.WebClient).DownloadFile($u, $d) } catch { Log-Error "Erro ao baixar $f" }
    }

    $finalHtmlPath = Join-Path $targetConfigDir "Suporte Xmenu.html"
    $iconPath = Join-Path $targetConfigDir "iconeatalho.ico"
    
    # --- RESTAURADO: Criação do Atalho com Lógica da v8.2 ---
    if (Test-Path $finalHtmlPath) {
        try {
            Log-Message "   > Criando atalho 'Suporte Xmenu' no Desktop Público..."
            $WshShell = New-Object -ComObject WScript.Shell
            
            # Atalho no Desktop Público (Visível para todos os usuários)
            $shortcutPath = [System.IO.Path]::Combine($env:PUBLIC, "Desktop", "Suporte Xmenu.lnk")
            $Shortcut = $WshShell.CreateShortcut($shortcutPath)
            
            $Shortcut.TargetPath = $finalHtmlPath
            $Shortcut.Arguments = "" # Importante para compatibilidade
            $Shortcut.IconLocation = $iconPath
            $Shortcut.Save()
            
            Log-Message "   > Atalho criado com sucesso!"
        } catch {
            Log-Error "Falha ao criar atalho: $_"
        }
    } else {
        Log-Error "Arquivo HTML base não encontrado. Atalho não criado."
    }

    # 7. FIM
    Log-Message "7. FINALIZAÇÃO:"
    
    # --- RESTAURADO: Limpeza de Cache de Icones ---
    Log-Message "   > Limpando cache de ícones..."
    Get-ChildItem -Path "$env:LOCALAPPDATA\IconCache.db" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\Windows\Explorer\iconcache_*.db" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

    Log-Message "   > Reiniciando Explorer para aplicar..."
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    
    Log-Message "--- PROCESSO CONCLUIDO ---"
    
    $Script:HeaderPanel.BackColor = $ColorSuccess
    $Script:MainButton.BackColor = $ColorSuccess
    $Script:MainButton.Text = "CONFIGURAÇÃO CONCLUÍDA"
    $Script:MainButton.Enabled = $true
    $Script:GrpLog.ForeColor = $ColorSuccess 
    
    # JANELA FINAL (PAUSA AQUI ATÉ CLICAR EM OK)
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = "Configuração Concluída"
    $finalForm.Size = New-Object System.Drawing.Size(400, 250)
    $finalForm.StartPosition = "CenterScreen"
    $finalForm.BackColor = $ColorBg
    $finalForm.ForeColor = $ColorText
    $finalForm.FormBorderStyle = "FixedDialog"
    $finalForm.MaximizeBox = $false
    $finalForm.TopMost = $true 

    $lblHead = New-Object System.Windows.Forms.Label
    $lblHead.Text = "CONFIGURAÇÃO FINALIZADA!"
    $lblHead.Location = New-Object System.Drawing.Point(30, 30)
    $lblHead.AutoSize = $true
    $lblHead.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
    $lblHead.ForeColor = [System.Drawing.Color]::LimeGreen
    $finalForm.Controls.Add($lblHead)

    $lblInfo = New-Object System.Windows.Forms.Label
    $lblInfo.Text = "Ao clicar em ENTENDIDO, as janelas de ajustes manuais (Rede, Recursos, etc.) serão abertas."
    $lblInfo.Location = New-Object System.Drawing.Point(30, 70)
    $lblInfo.Size = New-Object System.Drawing.Size(340, 80)
    $lblInfo.Font = $FontSub
    $finalForm.Controls.Add($lblInfo)
    
    $btnFim = New-Object System.Windows.Forms.Button
    $btnFim.Text = "ENTENDIDO, ABRIR JANELAS"
    $btnFim.Location = New-Object System.Drawing.Point(100, 150)
    $btnFim.Size = New-Object System.Drawing.Size(200, 40)
    $btnFim.BackColor = $ColorBtnAction
    $btnFim.ForeColor = [System.Drawing.Color]::White
    $btnFim.FlatStyle = "Flat"
    
    # AQUI: AS FERRAMENTAS ABREM QUANDO CLICAR NO BOTÃO
    $btnFim.Add_Click({ 
        $finalForm.Close()
        
        Start-Process "OptionalFeatures.exe"
        Start-Process "control.exe" -ArgumentList "/name Microsoft.NetworkAndSharingCenter /page Advanced"
        Start-Process "intl.cpl"
        Start-Process "systempropertiesperformance.exe"
    })
    $finalForm.Controls.Add($btnFim)
    
    $finalForm.ShowDialog()
})

$form.ShowDialog()