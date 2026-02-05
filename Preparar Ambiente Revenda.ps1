# =============================================================================
# XMENU SYSTEM MANAGER - VERSAO REVENDA
# Baseado na v17.47 (STABILITY FIX)
# Alteracoes Revenda:
#   - Wallpaper: fundo_revenda.png
#   - Removido: Atalhos de Suporte e Pasta Netcontroll
#   - Layout: Botoes de Links movidos para Menu no Header (Altura Corrigida)
# =============================================================================

# -----------------------------------------------------------------------------
# 1. CONFIGURACOES PRELIMINARES
# -----------------------------------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ErrorActionPreference = "SilentlyContinue"

# Define diretorios
$Script:DesktopPath = [Environment]::GetFolderPath("Desktop")
$Script:DownloadFolder = Join-Path $Script:DesktopPath "Arquivos Xmenu"
$Script:RepoBase = "https://raw.githubusercontent.com/VMazza10/Preparador-de-Ambiente-XMenu/main"

if (-not (Test-Path $Script:DownloadFolder)) { 
    New-Item -Path $Script:DownloadFolder -ItemType Directory -Force | Out-Null 
}

# Variaveis Globais UI
$Script:LogBox = $null
$Script:ProgressBar = $null
$Script:StatusLabel = $null
$Script:MainForm = $null
$Script:BtnCancel = $null
$Script:DownloadComplete = $false
$Script:DownloadError = $null
$Script:IsDownloading = $false
$Script:CurrentWebClient = $null 
$Script:CancelRequested = $false

# -----------------------------------------------------------------------------
# 2. VERIFICACAO DE PERMISSOES
# -----------------------------------------------------------------------------
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("ERRO CRITICO: Execute como Administrador.", "Permissao", "OK", "Error") | Out-Null
    Exit
}

# Carrega Graficos
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# API Wallpaper
$code = '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo (UInt32 uiAction, UInt32 uiParam, string pvParam, UInt32 fWinIni);'
Add-Type -MemberDefinition $code -Name "WinAPI" -Namespace "XMenuTools"

# -----------------------------------------------------------------------------
# 3. FUNCOES UTILITARIAS E LOGS
# -----------------------------------------------------------------------------

# Nova funcao de espera que NAO trava a tela
function Wait-UI {
    param($Seconds)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 10
    }
    $sw.Stop()
}

function Log-Message {
    param($Tag, $Msg)
    if ($null -eq $Script:LogBox) { return }

    if ($Script:LogBox.InvokeRequired) {
        $Script:LogBox.Invoke({ Log-Message $Tag $Msg })
    } else {
        $timestamp = (Get-Date).ToString("HH:mm:ss")
        $Script:LogBox.SelectionStart = $Script:LogBox.TextLength
        $Script:LogBox.SelectionLength = 0
        
        $color = [System.Drawing.Color]::WhiteSmoke
        if ($Tag -eq "ERRO") { $color = [System.Drawing.Color]::Salmon }
        elseif ($Tag -eq "SUCESSO") { $color = [System.Drawing.Color]::LimeGreen }
        elseif ($Tag -eq "INFO") { $color = [System.Drawing.Color]::LightSkyBlue }
        elseif ($Tag -eq "ZIP") { $color = [System.Drawing.Color]::Gold }
        elseif ($Tag -eq "LOG") { $color = [System.Drawing.Color]::LightGray; $Tag = "" }
        elseif ($Tag -eq "CANCEL") { $color = [System.Drawing.Color]::Orange }
        
        $Script:LogBox.SelectionColor = [System.Drawing.Color]::Gray
        $Script:LogBox.AppendText("[$timestamp] ")
        $Script:LogBox.SelectionColor = $color
        
        if ($Tag -ne "") { $Script:LogBox.AppendText("${Tag}: ") }
        $Script:LogBox.AppendText("$Msg`r`n")
        $Script:LogBox.ScrollToCaret()
        
        $Script:MainForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Show-IPs {
    try {
        $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        if ($activeAdapters) {
            $ips = $activeAdapters | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
            
            $netConfig = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } | Select-Object -First 1
            $gateway = if ($netConfig) { $netConfig.IPv4DefaultGateway.NextHop } else { "Nao detectado" }
            $dnsServers = if ($netConfig) { $netConfig.DNSServer.ServerAddresses -join ", " } else { "Nao detectado" }
            
            $internetStatus = if (Test-Connection 8.8.8.8 -Count 1 -Quiet) { "Conectado (Online)" } else { "Sem Acesso (Offline)" }
            $pingAdm2 = if (Test-Connection "adm2.netcontroll.com.br" -Count 1 -Quiet) { "OK (Acessivel)" } else { "FALHA (Inacessivel)" }
            
            if ($ips) {
                if ($ips -is [string]) { $ips = @($ips) }
                $txtIPs = $ips -join ", "
                $txtClipboard = $ips -join "`r`n"
                
                Clear-DnsClientCache
                
                Log-Message "INFO" "Diagnostico de Rede Detalhado:"
                Log-Message "INFO" "   > Endereco IP.....: $txtIPs"
                Log-Message "INFO" "   > Gateway Padrao..: $gateway"
                Log-Message "INFO" "   > Servidores DNS..: $dnsServers"
                Log-Message "INFO" "   > Status Internet.: $internetStatus (Cache DNS Limpo)"
                Log-Message "INFO" "   > Ping ADM2.......: $pingAdm2"
                
                [System.Windows.Forms.Clipboard]::SetText($txtClipboard)
                
                $msgBody = "RELATORIO DE REDE:`n" +
                           "--------------------------------------------------`n" +
                           "Endereco IP.......: $txtIPs`n" +
                           "Gateway Padrao....: $gateway`n" +
                           "Servidores DNS....: $dnsServers`n" +
                           "Status Internet...: $internetStatus`n" +
                           "Ping ADM2 (Server): $pingAdm2`n" +
                           "--------------------------------------------------`n" +
                           "(Enderecos IP copiados para a Area de Transferencia!)"

                [System.Windows.Forms.MessageBox]::Show($msgBody, "Diagnostico de Rede", "OK", "Information") | Out-Null
            } else {
                [System.Windows.Forms.MessageBox]::Show("Nenhum IP valido encontrado.", "Rede", "OK", "Warning") | Out-Null
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Sem adaptadores de rede conectados.", "Rede", "OK", "Warning") | Out-Null
        }
    } catch { Log-Message "ERRO" "Falha ao ler IPs: $_" }
}

# -----------------------------------------------------------------------------
# 4. MOTOR DE DOWNLOAD E INSTALACAO
# -----------------------------------------------------------------------------

function Cancel-Download {
    if ($Script:CurrentWebClient -ne $null -and $Script:IsDownloading) {
        $Script:CancelRequested = $true
        try { $Script:CurrentWebClient.CancelAsync() } catch {}
        Log-Message "CANCEL" "Solicitacao de cancelamento enviada..."
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Start-Download {
    param($Url, $FileName, $Button)
    
    if ($Script:IsDownloading) { 
        [System.Windows.Forms.MessageBox]::Show("Ja existe um download em andamento. Cancele-o primeiro se desejar.", "Ocupado", "OK", "Warning") | Out-Null
        return 
    }
    
    if ($Button.Text -like "*Instalado" -or $Button.Text -like "*Aberto" -or $Button.Text -like "*Extraido") { return }

    $originalText = $Button.Text
    $Script:IsDownloading = $true
    $Script:CancelRequested = $false
    
    if ($Script:BtnCancel) { 
        $Script:BtnCancel.Visible = $true
        $Script:BtnCancel.Enabled = $true
        $Script:BtnCancel.BringToFront()
    }
    
    try {
        $Script:DownloadComplete = $false
        $Script:DownloadError = $null
        
        if ($Script:ProgressBar) { $Script:ProgressBar.Value = 0 }
        
        $Button.Text = "Conectando..."
        $Button.Enabled = $false 
        $Button.BackColor = [System.Drawing.Color]::FromArgb(200, 140, 0)
        
        $destPath = Join-Path $Script:DownloadFolder $FileName
        Log-Message "DOWN" "Iniciando download: $FileName"
        if ($Script:StatusLabel) { $Script:StatusLabel.Text = "Baixando $FileName... (Pressione Cancelar para parar)" }

        $maxRetries = 3
        $retryCount = 0
        $downloadSuccessful = $false
        $wc = $null

        while (-not $downloadSuccessful -and $retryCount -lt $maxRetries -and -not $Script:CancelRequested) {
            $retryCount++
            $Script:DownloadComplete = $false
            $Script:DownloadError = $null

            try {
                $wc = New-Object System.Net.WebClient
                $Script:CurrentWebClient = $wc
                
                if ($retryCount -gt 1) { 
                    Log-Message "INFO" "Tentativa $retryCount de $maxRetries..." 
                    $Button.Text = "Tentativa $retryCount..."
                }

                $wc.Add_DownloadProgressChanged({
                    param($s, $e)
                    # CORRECAO CRITICA: REMOVIDO DoEvents AQUI. Causa StackOverflow em downloads rapidos.
                    
                    if ($Script:ProgressBar) { $Script:ProgressBar.Value = $e.ProgressPercentage }
                    
                    # Atualiza texto apenas se mudar o valor para economizar UI
                    $mbRead = "{0:N1}" -f ($e.BytesReceived / 1MB)
                    $mbTotal = "{0:N1}" -f ($e.TotalBytesToReceive / 1MB)
                    
                    if ($Script:CancelRequested) {
                        try { $s.CancelAsync() } catch {}
                    } else {
                        $Button.Text = "$mbRead / $mbTotal MB"
                    }
                })

                $wc.Add_DownloadFileCompleted({
                    param($s, $e)
                    if ($e.Cancelled) {
                        $Script:CancelRequested = $true
                    } elseif ($e.Error) { 
                        $Script:DownloadError = $e.Error 
                    }
                    $Script:DownloadComplete = $true
                })

                $cleanUrl = $Url.Replace(" ", "%20")
                $wc.DownloadFileAsync((New-Object Uri($cleanUrl)), $destPath)

                while (-not $Script:DownloadComplete) {
                    # DoEvents aqui eh seguro pois tem delay
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 10 
                }
                
                if ($Script:CancelRequested) {
                    Log-Message "CANCEL" "Cancelado pelo usuario."
                    break 
                }

                if ($Script:DownloadError) { throw $Script:DownloadError }
                $downloadSuccessful = $true

            } catch {
                if ($Script:CancelRequested) { break }
                Log-Message "ERRO" "Falha na tentativa ${retryCount}: $($_.Exception.Message)"
                Wait-UI 2
            } finally {
                if ($wc) { $wc.Dispose(); $wc = $null }
                $Script:CurrentWebClient = $null
            }
        }

        if ($Script:CancelRequested) {
            $Button.BackColor = [System.Drawing.Color]::Salmon
            $Button.Text = "Cancelado"
            $Script:StatusLabel.Text = "Cancelado."
            if (Test-Path $destPath) { 
                Wait-UI 0.5 
                try { Remove-Item $destPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
            Wait-UI 1 
            $Button.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 45)
            $Button.Text = $originalText
            
        } elseif ($downloadSuccessful) {
            
            # Verificacao de integridade basica (arquivo > 50kb)
            $fileInfo = Get-Item $destPath
            if ($fileInfo.Length -lt 50000) {
                 Log-Message "ERRO" "Arquivo corrompido ou link invalido (Tamanho: $($fileInfo.Length) bytes)."
                 $Button.BackColor = [System.Drawing.Color]::Salmon
                 $Button.Text = "Erro (Arquivo Invalido)"
                 return
            }

            Log-Message "SUCESSO" "Download concluido."
            $Button.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113)
            $Button.Text = "Instalado"
            
            Unblock-File -Path $destPath -ErrorAction SilentlyContinue

            if ($FileName.EndsWith(".zip")) {
                Log-Message "ZIP" "Extraindo arquivo..."
                $Button.Text = "Extraindo..."
                [System.Windows.Forms.Application]::DoEvents()
                
                try {
                    $folderName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
                    $finalPath = Join-Path $Script:DownloadFolder $folderName
                    $tempPath = Join-Path $Script:DownloadFolder "temp_$folderName"
                    
                    if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force | Out-Null }
                    if (Test-Path $finalPath) { Remove-Item $finalPath -Recurse -Force | Out-Null }
                    
                    Expand-Archive -LiteralPath $destPath -DestinationPath $tempPath -Force
                    
                    $items = Get-ChildItem -Path $tempPath
                    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
                        Move-Item -Path $items[0].FullName -Destination $finalPath
                        Remove-Item $tempPath -Recurse -Force | Out-Null
                    } else {
                        Rename-Item -Path $tempPath -NewName $folderName
                    }
                    
                    Invoke-Item $finalPath
                    $Button.Text = "Pasta Aberta"
                    Log-Message "SUCESSO" "Extraido com sucesso para: $folderName"
                } catch {
                    Log-Message "ERRO" "Falha ao extrair ZIP."
                    $Button.Text = "Erro ZIP"
                    $Button.BackColor = [System.Drawing.Color]::Salmon
                }
                
            } elseif ($FileName.EndsWith(".rar")) {
                 $Button.Text = "Baixado (RAR)"
                 Invoke-Item $destPath
            } else {
                Log-Message "EXEC" "Executando instalador..."
                Start-Process $destPath
                $Button.Text = "Executado"
            }
        } else {
            if (-not $Script:CancelRequested) {
                Log-Message "ERRO" "Falha definitiva no download."
                $Button.BackColor = [System.Drawing.Color]::Salmon
                $Button.Text = "Erro"
                Wait-UI 2
                $Button.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 45)
                $Button.Text = $originalText
            }
        }

    } catch {
        Log-Message "ERRO" "Erro Fatal de Script: $($_.Exception.Message)"
        $Button.Text = "Erro Fatal"
        $Button.BackColor = [System.Drawing.Color]::Red
    } finally {
        $Script:IsDownloading = $false
        $Script:CurrentWebClient = $null
        $Script:CancelRequested = $false
        
        if ($Script:BtnCancel) { $Script:BtnCancel.Visible = $false }
        $Button.Enabled = $true
        
        if ($Script:ProgressBar) { $Script:ProgressBar.Value = 0 }
        if ($Script:StatusLabel) { $Script:StatusLabel.Text = "Pronto." }
    }
}

function Install-VSPE-Combined {
    param($Button)
    if ($Script:IsDownloading) { 
        [System.Windows.Forms.MessageBox]::Show("Aguarde o download atual!", "Ocupado", "OK", "Warning") | Out-Null
        return 
    }

    Start-Download "https://www.netcontroll.com.br/util/instaladores/VSPE/VSPE.zip" "VSPE.zip" $Button
    if ($Button.Text -eq "Erro" -or $Button.Text -eq "Erro Fatal" -or $Button.Text -eq "Cancelado") { return }
    if ($Script:CancelRequested) { return }

    $Button.Text = "Baixando Epson..."
    $Button.BackColor = [System.Drawing.Color]::FromArgb(200, 140, 0)
    [System.Windows.Forms.Application]::DoEvents()
    
    $epsonUrl = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/tmvirtualportdriver.zip"
    Start-Download $epsonUrl "tmvirtualportdriver.zip" $Button
    
    if ($Button.Text -ne "Erro" -and $Button.Text -ne "Erro Fatal" -and $Button.Text -ne "Cancelado") {
        $Button.Text = "VSPE + Epson (Pronto)"
        $Button.BackColor = [System.Drawing.Color]::LimeGreen
    }
}

function Install-SqlManual {
    param($Button)
    if ($Script:IsDownloading) { 
        [System.Windows.Forms.MessageBox]::Show("Aguarde o download atual!", "Ocupado", "OK", "Warning") | Out-Null
        return 
    }
    
    try {
        $Button.Enabled = $false
        Start-Download "https://download.microsoft.com/download/7/f/8/7f8a9c43-8c8a-4f7c-9f92-83c18d96b681/SQL2019-SSEI-Expr.exe" "SQL2019-SSEI-Expr.exe" $Button
        
        if ($Script:CancelRequested) { return }
        
        if ($Button.Text -ne "Erro" -and $Button.Text -ne "Erro Fatal" -and $Button.Text -ne "Cancelado") {
            Start-Download "https://aka.ms/ssms/22/release/vs_SSMS.exe" "vs_SSMS.exe" $Button
        }
        
        if ($Script:CancelRequested) { return }
        
        if ($Button.Text -ne "Erro" -and $Button.Text -ne "Erro Fatal" -and $Button.Text -ne "Cancelado") {
            $Button.Text = "SQL + SSMS (Baixados)"
            $Button.BackColor = [System.Drawing.Color]::LimeGreen
        }
    } finally {
        $Button.Enabled = $true
    }
}

function Open-Selector {
    param($Type, $Button)
    $height = if ($Type -eq "PDV" -or $Type -eq "LinkXMenu") { 320 } else { 220 }

    $fSel = New-Object System.Windows.Forms.Form
    $fSel.Text = "Versoes - $Type"; $fSel.Size = "400,$height"; $fSel.StartPosition = 'CenterParent'
    $fSel.BackColor = [System.Drawing.Color]::FromArgb(30,30,30); $fSel.ForeColor = 'White'
    $fSel.FormBorderStyle = 'FixedDialog'; $fSel.MaximizeBox = $false
    
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Selecione da Lista:"; $lbl.Location = '20,20'; $lbl.AutoSize = $true
    [void]$fSel.Controls.Add($lbl)

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = '20,45'; $cb.Width = 340; $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'
    $cb.BackColor = [System.Drawing.Color]::FromArgb(50,50,60); $cb.ForeColor = 'White'
    
    $versions = @()
    if ($Type -eq "PDV") {
        $versions += @{Name="NetPDV v1.3.63.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/63/0/NetPDV.zip"; File="NetPDV_1.3.63.0.zip"}
        $versions += @{Name="NetPDV v1.3.60.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/60/0/NetPDV.zip"; File="NetPDV_1.3.60.0.zip"}
        $versions += @{Name="NetPDV v1.3.59.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/59/0/NetPDV.zip"; File="NetPDV_1.3.59.0.zip"}
        $versions += @{Name="NetPDV v1.3.55.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.zip"; File="NetPDV_1.3.55.0.zip"}
        $versions += @{Name="NetPDV v1.3.46.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/46/0/NetPDV.zip"; File="NetPDV_1.3.46.0.zip"}
        $versions += @{Name="NetPDV v1.3.44.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/44/0/NetPDV.zip"; File="NetPDV_1.3.44.0.zip"}
        $versions += @{Name="NetPDV v1.3.40.0"; Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/40/0/NetPDV.zip"; File="NetPDV_1.3.40.0.zip"}
    } elseif ($Type -eq "LinkXMenu") {
        $versions += @{Name="Link XMenu v10.16"; Url="https://netcontroll.com.br/util/instaladores/LinkXMenu/10/16/LinkXMenu.zip"; File="LinkXMenu_10.16.zip"}
        $versions += @{Name="Link XMenu v10.12"; Url="http://netcontroll.com.br/util/instaladores/LinkXMenu/10/12/LinkXMenu.zip"; File="LinkXMenu_10.12.zip"}
    } else {
        $versions += @{Name="Concentrador v1.3.59.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.59.0.zip"; File="Concentrador.1.3.59.0.zip"}
        $versions += @{Name="Concentrador v1.3.55.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.55.0.zip"; File="Concentrador.1.3.55.0.zip"}
        $versions += @{Name="Concentrador v1.3.50.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.50.0.zip"; File="Concentrador.1.3.50.0.zip"}
        $versions += @{Name="Concentrador v1.3.46.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.46.0.zip"; File="Concentrador.1.3.46.0.zip"}
        $versions += @{Name="Concentrador v1.3.44.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.44.0.zip"; File="Concentrador.1.3.44.0.zip"}
        $versions += @{Name="Concentrador v1.3.40.0"; Url="https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.40.0.zip"; File="Concentrador.1.3.40.0.zip"}
    }

    foreach ($v in $versions) { [void]$cb.Items.Add($v.Name) }
    $cb.SelectedIndex = 0
    [void]$fSel.Controls.Add($cb)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "BAIXAR SELECIONADO"; $btn.Location = '20,80'; $btn.Size = '340,35'
    $btn.BackColor = [System.Drawing.Color]::FromArgb(0,120,215); $btn.ForeColor = 'White'; $btn.FlatStyle = 'Flat'
    $btn.Add_Click({
        $fSel.Tag = $versions[$cb.SelectedIndex]
        $fSel.DialogResult = 'OK'
        $fSel.Close()
    })
    [void]$fSel.Controls.Add($btn)

    if ($Type -eq "PDV" -or $Type -eq "LinkXMenu") {
        $sep = New-Object System.Windows.Forms.Label; $sep.Text = "__________________________________________________"
        $sep.Location = '20,125'; $sep.AutoSize = $true; $sep.ForeColor = 'Gray'
        [void]$fSel.Controls.Add($sep)

        $lblMan = New-Object System.Windows.Forms.Label; $lblMan.Text = "Ou digite a Versao Manual:"; $lblMan.Location = '20,155'; $lblMan.AutoSize = $true
        [void]$fSel.Controls.Add($lblMan)

        $lblPre = New-Object System.Windows.Forms.Label; $lblPre.Location = '20,183'; $lblPre.AutoSize = $true; $lblPre.Font = New-Object System.Drawing.Font("Consolas", 12)
        $lblPos = New-Object System.Windows.Forms.Label; $lblPos.Location = '130,183'; $lblPos.AutoSize = $true; $lblPos.Font = New-Object System.Drawing.Font("Consolas", 12)
        
        $txtMan = New-Object System.Windows.Forms.TextBox
        $txtMan.Location = '65,180'; $txtMan.Width = 60; $txtMan.Font = New-Object System.Drawing.Font("Consolas", 10)
        $txtMan.TextAlign = 'Center'

        if ($Type -eq "PDV") {
            $lblPre.Text = "1.3."; $lblPos.Text = ".0"
        } else {
            $lblPre.Text = "10."; $lblPos.Text = "" 
        }

        [void]$fSel.Controls.Add($lblPre); [void]$fSel.Controls.Add($txtMan); [void]$fSel.Controls.Add($lblPos)

        $btnMan = New-Object System.Windows.Forms.Button
        $btnMan.Text = "BAIXAR MANUAL"; $btnMan.Location = '180,178'; $btnMan.Size = '180,30'
        $btnMan.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113); $btnMan.ForeColor = 'White'; $btnMan.FlatStyle = 'Flat'
        
        $btnMan.Add_Click({
            $v = $txtMan.Text.Trim()
            if ($v -match '^\d+$') {
                if ($Type -eq "PDV") {
                    $fSel.Tag = @{ Url="https://netcontroll.com.br/util/instaladores/netpdv/1.3/$v/0/NetPDV.zip"; File="NetPDV_1.3.$v.0.zip" }
                } else {
                    $fSel.Tag = @{ Url="http://netcontroll.com.br/util/instaladores/LinkXMenu/10/$v/LinkXMenu.zip"; File="LinkXMenu_10.$v.zip" }
                }
                $fSel.DialogResult = 'OK'
                $fSel.Close()
            } else { [System.Windows.Forms.MessageBox]::Show("Digite apenas o numero da versao (Ex: 62 ou 16)", "Erro", "OK", "Warning") | Out-Null }
        })
        [void]$fSel.Controls.Add($btnMan)
    }

    [void]$fSel.ShowDialog()
    if ($fSel.DialogResult -eq 'OK' -and $fSel.Tag) { Start-Download $fSel.Tag.Url $fSel.Tag.File $Button }
}

# -----------------------------------------------------------------------------
# 5. CONFIGURACAO DO AMBIENTE (REGISTRY E OTIMIZACOES)
# -----------------------------------------------------------------------------
function Run-Config {
    param($Btn)
    $Btn.Enabled = $false; $Btn.Text = "AGUARDE... CONFIGURANDO"; $Btn.BackColor = [System.Drawing.Color]::Gray
    $Script:ProgressBar.Value = 0
    
    Log-Message "LOG" "--- INICIANDO CONFIGURACAO ---"
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "1. UAC (Seguranca):"
    Log-Message "LOG" "     Desativando EnableLUA e Prompts..."
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    $Script:ProgressBar.Value = 15
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "2. ENERGIA:"
    Log-Message "LOG" "     Definindo Plano de Alta Performance..."
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    powercfg /change monitor-timeout-ac 0 | Out-Null
    powercfg /change disk-timeout-ac 0 | Out-Null
    powercfg /change standby-timeout-ac 0 | Out-Null
    Log-Message "LOG" "     Desativando Hibernacao (FastStartup)..."
    powercfg /h off | Out-Null
    Start-Process "reg.exe" -ArgumentList "ADD ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    $Script:ProgressBar.Value = 30
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "3. AJUSTES VISUAIS E EXPLORER:"
    Log-Message "LOG" "     Data DD/MM/AAAA e Explorer..."
    Set-ItemProperty -Path "HKCU:\Control Panel\International" -Name "sShortDate" -Value "dd/MM/yyyy" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Otimizando efeitos visuais (Performance)..."
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "MenuShowDelay" -Value "0" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "FontSmoothing" -Value "2" -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" -Name "VisualFXSetting" -Value 3 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewAlphaSelect" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ListviewShadow" -Value 1 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Exibindo Icones Desktop..."
    $iconPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    if (!(Test-Path $iconPath)) { New-Item -Path $iconPath -Force | Out-Null }
    # Ativa Computer, RecycleBin, User, Network
    Set-ItemProperty -Path $iconPath -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" -Value 0 -Force -ErrorAction SilentlyContinue
    $Script:ProgressBar.Value = 45
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "4. REDE E SEGURANCA:"
    Log-Message "LOG" "     Liberando Firewall (Arquivos) e Senhas..."
    netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes | Out-Null
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v LimitBlankPasswordUse /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Control\Lsa /v everyoneincludesanonymous /t REG_DWORD /d 1 /f" -NoNewWindow -Wait
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters /v restrictnullsessaccess /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    
    # --- PERFORMANCE NETWORK ---
    Log-Message "LOG" "     Otimizando TCP/IP (Baixa Latencia)..."
    $tcpKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    Get-ChildItem $tcpKey | ForEach-Object {
        New-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $Script:ProgressBar.Value = 60
    
    Log-Message "LOG" "5. LIMPEZA E OTIMIZACAO:"
    # --- PERFORMANCE SERVICES ---
    Log-Message "LOG" "     Desativando SysMain (Superfetch) e Telemetria..."
    Stop-Service "SysMain" -ErrorAction SilentlyContinue
    Set-Service "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service "DiagTrack" -ErrorAction SilentlyContinue
    Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue

    Log-Message "LOG" "     Removendo Bloatware (Cortana, Feeds, Chat)..."
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $advKey -Name "ShowCortanaButton" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $advKey -Name "ShowTaskViewButton" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $advKey -Name "TaskbarMn" -Value 0 -Force -ErrorAction SilentlyContinue
    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value 0 -Force -ErrorAction SilentlyContinue
    $pplKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People"
    if (!(Test-Path $pplKey)) { New-Item -Path $pplKey -Force -ErrorAction SilentlyContinue | Out-Null }
    Set-ItemProperty -Path $pplKey -Name "PeopleBand" -Value 0 -Force -ErrorAction SilentlyContinue
    
    $feedsKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Feeds"
    if (!(Test-Path $feedsKey)) { New-Item -Path $feedsKey -Force | Out-Null }
    try { Set-ItemProperty -Path $feedsKey -Name "ShellFeedsTaskbarViewMode" -Value 2 -Force -ErrorAction Stop } catch {
        Start-Process "reg.exe" -ArgumentList "ADD HKCU\Software\Microsoft\Windows\CurrentVersion\Feeds /v ShellFeedsTaskbarViewMode /t REG_DWORD /d 2 /f" -NoNewWindow -Wait
    }
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds")) { New-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Force | Out-Null }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds" -Name "EnableFeeds" -Value 0 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Removendo App Installer e Widgets..."
    Get-AppxPackage -AllUsers *Microsoft.DesktopAppInstaller* | Remove-AppxPackage -ErrorAction SilentlyContinue
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh")) { New-Item "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Force -ErrorAction SilentlyContinue

    # --- LIMPEZA DE TOOLBARS E ICONES (RESTAURADA) ---
    Log-Message "LOG" "     Resetando Toolbars e Icones da Barra..."
    
    # 1. Remove Toolbars (Endereco, Links, etc)
    $toolbarStreamPaths = @(
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\TaskbarWinXP",
        "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Streams\Desktop\Taskband"
    )
    foreach ($p in $toolbarStreamPaths) {
        if (Test-Path $p) { Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue | Out-Null }
    }

    # 2. Ocultar icone "Reuniao Agora" (Meet Now)
    $policiesExplorer = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    if (!(Test-Path $policiesExplorer)) { New-Item -Path $policiesExplorer -Force | Out-Null }
    Set-ItemProperty -Path $policiesExplorer -Name "HideSCAMeetNow" -Value 1 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Limpando arquivos temporarios..."
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Get-ChildItem -Path "$env:windir\Temp" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    $Script:ProgressBar.Value = 80
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "6. PERSONALIZACAO REVENDA:"
    Log-Message "LOG" "     Baixando e Definindo Wallpaper..."
    $tempDir = Join-Path $env:TEMP "XmenuResources"
    if (!(Test-Path $tempDir)) { New-Item $tempDir -ItemType Directory -Force | Out-Null }
    
    # --- MODIFICACAO REVENDA: NOME DO ARQUIVO ALTERADO PARA 'fundo_revenda.png' ---
    $wallPath = Join-Path $tempDir "fundo_revenda.png"
    
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile("$Script:RepoBase/fundo_revenda.png", $wallPath)
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallPaper" -Value "0" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallPaper" -Value $wallPath -Force
        [XMenuTools.WinAPI]::SystemParametersInfo(0x0014, 0, $wallPath, 3) | Out-Null
    } catch { Log-Message "ERRO" "Falha no Wallpaper: $($_.Exception.Message)" }
    
    # --- MODIFICACAO REVENDA: BLOCO DE CRIACAO DE ATALHO SUPORTE REMOVIDO ---
    
    Log-Message "LOG" "7. FINALIZACAO:"
    Log-Message "LOG" "     Limpando cache e reiniciando Explorer..."
    Get-ChildItem "$env:LOCALAPPDATA\IconCache.db" -ErrorAction SilentlyContinue | Remove-Item -Force | Out-Null
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Wait-UI 2 # Espera nao travante
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    
    Log-Message "LOG" "--- PROCESSO CONCLUIDO ---"
    $Btn.Text = "SUCESSO! (CONFIRA AS 4 JANELAS)"
    $Btn.BackColor = [System.Drawing.Color]::LimeGreen
    $Btn.Enabled = $true
    $Script:ProgressBar.Value = 100
    
    # 2. JANELA PERMANECE VISIVEL E ATUALIZADA
    $Script:MainForm.Activate()
    
    $finalForm = New-Object System.Windows.Forms.Form
    $finalForm.Text = "Configuracao Concluida"
    $finalForm.Size = New-Object System.Drawing.Size(400, 200)
    $finalForm.StartPosition = "CenterScreen"
    $finalForm.BackColor = [System.Drawing.Color]::FromArgb(25,25,30); $finalForm.ForeColor = 'White'
    $finalForm.FormBorderStyle = 'FixedDialog'; $finalForm.MaximizeBox = $false
    $finalForm.TopMost = $true
    
    $lblFim = New-Object System.Windows.Forms.Label
    $lblFim.Text = "Configuracao Finalizada!`n`nSerao abertas as janelas:`n- Recursos do Windows`n- Rede`n- Regiao`n- Performance"
    $lblFim.AutoSize = $false; $lblFim.Size = New-Object System.Drawing.Size(360, 100); $lblFim.Location = '20,20'
    [void]$finalForm.Controls.Add($lblFim)
    
    $btnFim = New-Object System.Windows.Forms.Button
    $btnFim.Text = "ENTENDIDO"; $btnFim.Location = '100,120'; $btnFim.Size = '180,30'
    $btnFim.BackColor = [System.Drawing.Color]::LimeGreen; $btnFim.ForeColor = 'White'; $btnFim.FlatStyle = 'Flat'
    
    $btnFim.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$finalForm.Controls.Add($btnFim)
    $finalForm.AcceptButton = $btnFim

    if ($finalForm.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        Start-Process "OptionalFeatures.exe"
        Start-Process "control.exe" -ArgumentList "/name Microsoft.NetworkAndSharingCenter /page Advanced"
        Start-Process "intl.cpl"
        Start-Process "systempropertiesperformance.exe"
    }
}

# -----------------------------------------------------------------------------
# 6. UI WINDOWS FORMS
# -----------------------------------------------------------------------------
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth = if ($screen.Width -lt 1000) { 900 } else { 1000 }
$formHeight = if ($screen.Height -lt 800) { 700 } else { 800 }

$form = New-Object System.Windows.Forms.Form
$form.Text = "XMenu System Manager v17.47 - REVENDA"
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(25,25,30); $form.ForeColor = 'White'
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$Script:MainForm = $form

# === CONTEXT MENU PARA LINKS ÚTEIS (NOVO) ===
$linkMenu = New-Object System.Windows.Forms.ContextMenuStrip
$linkMenu.ShowImageMargin = $false
$linkMenu.Font = New-Object System.Drawing.Font("Segoe UI", 10)

function Add-CtxLink { param($Text, $Url)
    $item = $linkMenu.Items.Add($Text)
    $item.Tag = $Url
    $item.Add_Click({ Start-Process $this.Tag })
}

Add-CtxLink "Manual Técnico" "https://netcontroll.gitbook.io/xmenu-tecnico"
Add-CtxLink "Versões XMenu" "https://netcontroll.gitbook.io/xmenu-versoes"
Add-CtxLink "ADM Master" "https://netcontroll.com.br/adm/"
Add-CtxLink "Portal Xmenu" "https://portal.netcontroll.com.br/#/auth/login"
# ============================================

# HEADER
$head = New-Object System.Windows.Forms.Panel; $head.Dock = 'Top'; $head.Height = 160
$head.BackColor = [System.Drawing.Color]::FromArgb(0,120,215); $head.Padding = '20,20,20,0'
[void]$form.Controls.Add($head)

$hLeft = New-Object System.Windows.Forms.Panel; $hLeft.Dock = 'Fill'; $hLeft.BackColor = 'Transparent'
[void]$head.Controls.Add($hLeft)
$lT = New-Object System.Windows.Forms.Label; $lT.Text = "XMenu Manager"; $lT.AutoSize = $true
$lT.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold); $lT.Location = '0,10'
[void]$hLeft.Controls.Add($lT)
$lS = New-Object System.Windows.Forms.Label; $lS.Text = "Desenvolvido por Vinicius Mazaroski"; $lS.AutoSize = $true
$lS.ForeColor = [System.Drawing.Color]::FromArgb(200,230,255); $lS.Location = '5,60'
[void]$hLeft.Controls.Add($lS)

$hRight = New-Object System.Windows.Forms.FlowLayoutPanel; $hRight.Dock = 'Right'; $hRight.Width = 250
$hRight.FlowDirection = 'TopDown'; $hRight.BackColor = 'Transparent'; $hRight.WrapContents = $false
[void]$head.Controls.Add($hRight)

$sysInfo = New-Object System.Windows.Forms.Label
$sysInfo.Text = "$env:COMPUTERNAME`n$env:USERNAME`nWindows $((Get-WmiObject Win32_OperatingSystem).Version)"
$sysInfo.AutoSize = $true; $sysInfo.Font = New-Object System.Drawing.Font("Consolas", 9)
$sysInfo.TextAlign = 'TopRight'; $sysInfo.Anchor = 'Right'
[void]$hRight.Controls.Add($sysInfo)

$btnIP = New-Object System.Windows.Forms.Button; $btnIP.Text = "DIAG. REDE"; $btnIP.Size = '120,30'
$btnIP.BackColor = 'White'; $btnIP.ForeColor = [System.Drawing.Color]::FromArgb(0,120,215)
$btnIP.FlatStyle = 'Flat'; $btnIP.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnIP.Margin = '0,10,0,0'; $btnIP.Anchor = 'Right'
$btnIP.Add_Click({ Show-IPs })
[void]$hRight.Controls.Add($btnIP)

# --- NOVO BOTAO LINKS NO HEADER ---
$btnLinks = New-Object System.Windows.Forms.Button; $btnLinks.Text = "LINKS ÚTEIS ▼"; $btnLinks.Size = '120,30'
$btnLinks.BackColor = 'White'; $btnLinks.ForeColor = [System.Drawing.Color]::FromArgb(0,120,215)
$btnLinks.FlatStyle = 'Flat'; $btnLinks.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnLinks.Margin = '0,5,0,0'; $btnLinks.Anchor = 'Right'
$btnLinks.Add_Click({ 
    $linkMenu.Show($btnLinks, 0, $btnLinks.Height) 
})
[void]$hRight.Controls.Add($btnLinks)
# ----------------------------------

# FOOTER
$foot = New-Object System.Windows.Forms.Panel; $foot.Dock = 'Bottom'; $foot.Height = 30
$foot.BackColor = [System.Drawing.Color]::FromArgb(40,40,45)
[void]$form.Controls.Add($foot)
$prog = New-Object System.Windows.Forms.ProgressBar; $prog.Dock = 'Top'; $prog.Height = 5
[void]$foot.Controls.Add($prog); $Script:ProgressBar = $prog
$stat = New-Object System.Windows.Forms.Label; $stat.Text = "Pronto."; $stat.Dock = 'Fill'
$stat.TextAlign = 'MiddleLeft'; $stat.Padding = '10,0,0,0'; $stat.ForeColor = 'Gray'
[void]$foot.Controls.Add($stat); $Script:StatusLabel = $stat

# BOTAO CANCELAR (NOVO)
$btnCancel = New-Object System.Windows.Forms.Button
$btnCancel.Text = "X"
$btnCancel.Size = New-Object System.Drawing.Size(30, 25)
$btnCancel.Dock = 'Right'
$btnCancel.BackColor = [System.Drawing.Color]::Salmon
$btnCancel.ForeColor = 'White'
$btnCancel.FlatStyle = 'Flat'
$btnCancel.Visible = $false # Oculto por padrao
$btnCancel.Add_Click({ Cancel-Download })
[void]$foot.Controls.Add($btnCancel)
$Script:BtnCancel = $btnCancel


# MAIN LAYOUT
$layout = New-Object System.Windows.Forms.TableLayoutPanel; $layout.Dock = 'Fill'; $layout.ColumnCount = 1
$layout.Padding = '20'; $layout.RowCount = 3
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 25)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 75)))
[void]$form.Controls.Add($layout); $layout.BringToFront()

$gLog = New-Object System.Windows.Forms.GroupBox; $gLog.Text = "Log"; $gLog.ForeColor = 'Gray'; $gLog.Dock = 'Fill'
[void]$layout.Controls.Add($gLog, 0, 0)
$tLog = New-Object System.Windows.Forms.RichTextBox; $tLog.Dock = 'Fill'; $tLog.BackColor = [System.Drawing.Color]::FromArgb(20,20,20)
$tLog.ForeColor = 'White'; $tLog.BorderStyle = 'None'; $tLog.ReadOnly = $true; $tLog.Font = New-Object System.Drawing.Font("Consolas", 9)
[void]$gLog.Controls.Add($tLog); $Script:LogBox = $tLog

$bCfg = New-Object System.Windows.Forms.Button; $bCfg.Text = "⚡ PREPARAR AMBIENTE WINDOWS"
$bCfg.Dock = 'Fill'; $bCfg.BackColor = [System.Drawing.Color]::FromArgb(0,120,215); $bCfg.ForeColor = 'White'
$bCfg.FlatStyle = 'Flat'; $bCfg.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$bCfg.Margin = '0,10,0,10'; $bCfg.Cursor = 'Hand'
$bCfg.Add_Click({ Run-Config $this })
[void]$layout.Controls.Add($bCfg, 0, 1)

$pScroll = New-Object System.Windows.Forms.Panel; $pScroll.Dock = 'Fill'; $pScroll.AutoScroll = $true
[void]$layout.Controls.Add($pScroll, 0, 2)
$tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = 'Top'; $tbl.AutoSize = $true
$tbl.ColumnCount = 2; [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pScroll.Controls.Add($tbl)

function Add-Title { param($T) 
    $l = New-Object System.Windows.Forms.Label; $l.Text = $T; $l.AutoSize = $true
    $l.ForeColor = [System.Drawing.Color]::FromArgb(0,120,215); $l.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $l.Margin = '5,15,0,5'; [void]$tbl.Controls.Add($l, 0, -1); $tbl.SetColumnSpan($l, 2)
    # Correct usage of Out-Null to prevent ghost output
    $null = $l
}

function Add-Btn { param($T, $D, $U, $F, $Sel=$false, $Type="") 
    $b = New-Object System.Windows.Forms.Button; $b.Height = 60; $b.Dock = 'Top'
    $b.BackColor = [System.Drawing.Color]::FromArgb(40,40,45); $b.ForeColor = 'WhiteSmoke'
    $b.FlatStyle = 'Flat'; $b.TextAlign = 'MiddleLeft'; $b.Padding = '10,0,0,0'; $b.Margin = '5'
    $b.Text = $T; $b.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    if ($Sel) { 
        $b.BackColor = [System.Drawing.Color]::FromArgb(50,50,60); $b.Text += "  ▼"
        $b.Tag = $Type; $b.Add_Click({ Open-Selector $this.Tag $this })
    } else {
        $b.Tag = "$U|$F"; $b.Add_Click({ $d=$this.Tag.Split('|'); Start-Download $d[0] $d[1] $this })
    }
    [void]$tbl.Controls.Add($b)
    # Correct usage of Out-Null to prevent ghost output
    $null = $b
}

Add-Title "BANCO DE DADOS"
Add-Btn "SQL Server 2008 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2008x64_DESCONTINUADO.exe" "SQL2008x64.exe"
Add-Btn "SQL Server 2019 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2019.exe" "SQL2019.exe"

$bSqlMan = New-Object System.Windows.Forms.Button; $bSqlMan.Height = 60; $bSqlMan.Dock = 'Top'
$bSqlMan.BackColor = [System.Drawing.Color]::FromArgb(40,40,45); $bSqlMan.ForeColor = 'WhiteSmoke'
$bSqlMan.FlatStyle = 'Flat'; $bSqlMan.TextAlign = 'MiddleLeft'; $bSqlMan.Padding = '10,0,0,0'; $bSqlMan.Margin = '5'
$bSqlMan.Text = "SQL 2019 + SSMS (Manual)"; $bSqlMan.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSqlMan.Cursor = 'Hand'
$bSqlMan.Add_Click({ Install-SqlManual $this })
[void]$tbl.Controls.Add($bSqlMan)

Add-Title "PROGRAMAS NETCONTROLL"
Add-Btn "Concentrador (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/InstaladorConcentrador.exe" "Concentrador.exe"
Add-Btn "Concentrador (ZIP)" "" "" "" $true "Concentrador"
Add-Btn "NetPDV (Instalador)" "" "https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.exe" "NetPDV.exe"
Add-Btn "NetPDV (ZIP)" "" "" "" $true "PDV"
Add-Btn "Link XMenu (Instalador)" "" "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/11/LinkXMenu.exe" "LinkXMenu.exe"
Add-Btn "Link XMenu (ZIP)" "" "" "" $true "LinkXMenu"
Add-Btn "XBot" "" "https://aws.netcontroll.com.br/XBotClient/setup.exe" "XBotSetup.exe"
Add-Btn "XTag Client 2.0" "" "https://aws.netcontroll.com.br/XTagClient2.0/setup.exe" "XTagSetup.exe"

Add-Title "EXTERNOS"
Add-Btn "TecnoSpeed NFCe (11.1.7.27)" "" "https://netcontroll.com.br/util/instaladores/NFCE/11.1.7.27/InstaladorNFCe.exe" "InstaladorNFCe.exe"

$bVspe = New-Object System.Windows.Forms.Button; $bVspe.Height = 60; $bVspe.Dock = 'Top'
$bVspe.BackColor = [System.Drawing.Color]::FromArgb(40,40,45); $bVspe.ForeColor = 'WhiteSmoke'
$bVspe.FlatStyle = 'Flat'; $bVspe.TextAlign = 'MiddleLeft'; $bVspe.Padding = '10,0,0,0'; $bVspe.Margin = '5'
$bVspe.Text = "VSPE + Epson Virtual Port"; $bVspe.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bVspe.Cursor = 'Hand'
$bVspe.Add_Click({ Install-VSPE-Combined $this })
[void]$tbl.Controls.Add($bVspe)

Add-Btn "TeamViewer Full" "" "https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe" "Teamviewer.exe"
Add-Btn "Google Chrome" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/ChromeSetup.exe" "ChromeSetup.exe"

Log-Message "SISTEMA" "Dashboard Carregado. Pronto."
[void]$form.ShowDialog()