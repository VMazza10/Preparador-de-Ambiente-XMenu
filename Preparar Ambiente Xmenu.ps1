# =============================================================================
# XMENU SYSTEM MANAGER v17.59
# Visual: Dashboard Moderno
# Correcoes:
#   - CRITICO: Removido DoEvents do loop de evento de download (causava crash).
#   - Link do Chrome atualizado para Mirror GitHub (Versao Estavel).
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

# Exclui a pasta de downloads do Windows Defender.
# Evita falsos positivos que bloqueiam instaladores de driver legitimos
# (comum em auto-extraiveis WinRAR SFX e drivers antigos).
# ATENCAO: essa pasta deixa de ser escaneada pelo antivirus.
try {
    if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
        Add-MpPreference -ExclusionPath $Script:DownloadFolder -ErrorAction SilentlyContinue
    }
}
catch {}

# Variaveis Globais UI
$Script:LogBox = $null
$Script:ProgressBar = $null
$Script:StatusLabel = $null
$Script:MainForm = $null
$Script:CancelOverlay = $null
$Script:CancelOverlayTarget = $null
$Script:CancelOverlayActive = $false
$Script:CancelOverlayTimer = $null
$Script:CancelOverlayLabel = "✕  CANCELAR"
$Script:CancelOverlayState = 'normal'
$Script:CancelOverlayFont = $null
$Script:ScrollPanel = $null
$Script:ProgressButton = $null
$Script:ProgressPercent = 0
$Script:ProgressHooked = $null
$Script:CancelOverlayDX = 0
$Script:CancelOverlayDY = 0
$Script:DoneMap = $null
$Script:DoneFont = $null
$Script:DownloadComplete = $false
$Script:DownloadError = $null
$Script:IsDownloading = $false
$Script:CurrentWebClient = $null 
$Script:CancelRequested = $false
$Script:ToolTip = $null
$Script:DeployMode = $false

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
    }
    else {
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
        elseif ($Tag -eq "CMD") { $color = [System.Drawing.Color]::SpringGreen }
        
        $Script:LogBox.SelectionColor = [System.Drawing.Color]::Gray
        $Script:LogBox.AppendText("[$timestamp] ")
        $Script:LogBox.SelectionColor = $color
        
        if ($Tag -ne "") { $Script:LogBox.AppendText("${Tag}: ") }
        $Script:LogBox.AppendText("$Msg`r`n")
        $Script:LogBox.ScrollToCaret()

        # Gravação em arquivo de log
        try {
            $logPath = "C:\Arquivos Xmenu\Logs"
            if (!(Test-Path $logPath)) { New-Item -ItemType Directory -Path $logPath -Force | Out-Null }
            $logFile = Join-Path $logPath "log_preparar_ambiente_$((Get-Date).ToString('yyyy-MM-dd')).txt"
            "[$((Get-Date).ToString('HH:mm:ss'))] [$Tag] $Msg" | Out-File -FilePath $logFile -Append -Encoding UTF8
        }
        catch {}
        
        $Script:MainForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}

# Checagem leve de integridade: tamanho minimo + assinatura binaria (MZ/PK).
# Pega download vazio, truncado ou pagina de erro (html) salva com extensao errada.
function Test-DownloadIntegrity {
    param($Path, $MinBytes = 10240)
    if (-not (Test-Path $Path)) { return $false }
    if ((Get-Item $Path).Length -lt $MinBytes) { return $false }

    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    if ($ext -eq '.exe' -or $ext -eq '.zip') {
        $expected = if ($ext -eq '.exe') { [byte[]](0x4D, 0x5A) } else { [byte[]](0x50, 0x4B) }
        $buffer = New-Object byte[] 2
        $fs = [System.IO.File]::OpenRead($Path)
        try { [void]$fs.Read($buffer, 0, 2) } finally { $fs.Close() }
        if ($buffer[0] -ne $expected[0] -or $buffer[1] -ne $expected[1]) { return $false }
    }
    return $true
}

function ConvertTo-Mascara {
    param([int]$Prefixo)
    try {
        $bits = ('1' * $Prefixo).PadRight(32, '0')
        return ((0..3) | ForEach-Object { [Convert]::ToInt32($bits.Substring($_ * 8, 8), 2) }) -join '.'
    }
    catch { return "-" }
}

function Show-IPs {
    try {
        if ($null -ne $Script:RedeForm -and -not $Script:RedeForm.IsDisposed) {
            $Script:RedeForm.Activate(); return
        }

        $f = New-ToolForm "Diagnostico de Rede" 780 700
        $Script:RedeForm = $f

        New-ToolLabel $f "DIAGNOSTICO DE REDE" 20 14 12 -Negrito | Out-Null
        $lblAdaptador = New-ToolLabel $f "Lendo configuracao..." 20 40 8.5 -Cor $Script:UiSuave

        # Faixa de veredito
        $pnlVeredito = New-Object System.Windows.Forms.Panel
        $pnlVeredito.Location = New-Object System.Drawing.Point(20, 66)
        $pnlVeredito.Size = New-Object System.Drawing.Size(725, 54)
        $pnlVeredito.Anchor = 'Top,Left,Right'
        $pnlVeredito.BackColor = $Script:UiFundo
        $pnlVeredito.Tag = @{ Cor = $Script:UiCinza; Texto = "Executando testes..." }
        $pnlVeredito.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.Clear($s.Parent.BackColor)
                $d = $s.Tag
                $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
                $caminho = New-RoundedRectPath -X 0 -Y 0 -W $s.Width -H $s.Height -R 8
                $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Get-UiTom $d.Cor 18), (Get-UiTom $d.Cor -28), [float]0)
                $g.FillPath($br, $caminho)
                $fw = New-Object System.Drawing.Font("Segoe UI", 11.5, [System.Drawing.FontStyle]::Bold)
                [System.Windows.Forms.TextRenderer]::DrawText($g, $d.Texto, $fw, $rect, [System.Drawing.Color]::White,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordBreak))
                $fw.Dispose(); $br.Dispose(); $caminho.Dispose()
            })
        [void]$f.Controls.Add($pnlVeredito)

        # Cartoes da cadeia de conexao
        $gRede = New-Gauge $f "REDE LOCAL" 20 132 234 88 $Script:UiAzul
        $gNet = New-Gauge $f "INTERNET" 265 132 234 88 $Script:UiAzul
        $gServidor = New-Gauge $f "SERVIDOR NETCONTROLL" 511 132 234 88 $Script:UiAzul

        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(20, 232)
        $lv.Size = New-Object System.Drawing.Size(725, 366)
        $lv.Anchor = 'Top,Left,Right,Bottom'
        Format-ToolListView $lv
        [void]$lv.Columns.Add("Item", 210)
        [void]$lv.Columns.Add("Resultado", 400)
        [void]$lv.Columns.Add("Status", 95)
        [void]$f.Controls.Add($lv)

        $Script:RedeRelatorio = ""

        $addLinha = {
            param([string]$Item, [string]$Valor, $Estado)
            $it = New-Object System.Windows.Forms.ListViewItem($Item)
            [void]$it.SubItems.Add($Valor)
            if ($null -eq $Estado) { [void]$it.SubItems.Add("-"); $it.ForeColor = $Script:UiTexto }
            elseif ($Estado) { [void]$it.SubItems.Add("OK"); $it.ForeColor = $Script:UiVerde }
            else { [void]$it.SubItems.Add("FALHA"); $it.ForeColor = $Script:UiVermelho }
            [void]$lv.Items.Add($it)
        }

        $diagnosticar = {
            $lv.Items.Clear()
            $pnlVeredito.Tag.Cor = $Script:UiCinza
            $pnlVeredito.Tag.Texto = "Executando testes..."
            $pnlVeredito.Invalidate()
            Update-Gauge $gRede 0 "..." "testando" $Script:UiCinza
            Update-Gauge $gNet 0 "..." "testando" $Script:UiCinza
            Update-Gauge $gServidor 0 "..." "testando" $Script:UiCinza
            [System.Windows.Forms.Application]::DoEvents()

            $ping = New-Object System.Net.NetworkInformation.Ping
            $linhas = @()

            # --- configuracao do adaptador ---
            $cfg = $null
            $ad = $null
            try {
                $cfg = Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $null -ne $_.IPv4DefaultGateway } | Select-Object -First 1
                if ($cfg) { $ad = Get-NetAdapter -InterfaceIndex $cfg.InterfaceIndex -ErrorAction SilentlyContinue }
            }
            catch {}

            $ipv4 = "-"; $mascara = "-"; $gw = ""; $dns = @()
            if ($cfg) {
                if ($cfg.IPv4Address) {
                    $ipv4 = $cfg.IPv4Address[0].IPAddress
                    $mascara = ConvertTo-Mascara $cfg.IPv4Address[0].PrefixLength
                }
                if ($cfg.IPv4DefaultGateway) { $gw = $cfg.IPv4DefaultGateway.NextHop }
                if ($cfg.DNSServer) { $dns = @($cfg.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses }) }
            }
            if ($dns.Count -eq 0 -and $cfg -and $cfg.DNSServer) { $dns = @($cfg.DNSServer.ServerAddresses) }

            $semIP = ($ipv4 -eq "-" -or $ipv4 -like "169.254.*")
            & $addLinha "Endereco IP" $(if ($ipv4 -like "169.254.*") { "$ipv4  (APIPA - o DHCP nao respondeu)" } else { $ipv4 }) (-not $semIP)
            & $addLinha "Mascara de sub-rede" $mascara $null
            & $addLinha "Gateway padrao" $(if ($gw) { $gw } else { "Nao detectado" }) ([bool]$gw)
            & $addLinha "Servidores DNS" $(if ($dns.Count -gt 0) { $dns -join ", " } else { "Nao detectado" }) ($dns.Count -gt 0)

            if ($ad) {
                $lblAdaptador.Text = "$($ad.InterfaceDescription)   |   $($ad.LinkSpeed)   |   MAC $($ad.MacAddress)"
                & $addLinha "Placa de rede" "$($ad.Name) - $($ad.InterfaceDescription)" $null
                & $addLinha "Velocidade do link" "$($ad.LinkSpeed)" $null
                & $addLinha "Endereco MAC" "$($ad.MacAddress)" $null

                $tipo = "Cabo (Ethernet)"
                if ($ad.PhysicalMediaType -match '802.11|Wireless|Native') { $tipo = "Wi-Fi (sem fio)" }
                & $addLinha "Tipo de conexao" $tipo $null

                # Qualidade do sinal quando for Wi-Fi: sinal fraco derruba PDV
                if ($tipo -like "Wi-Fi*") {
                    try {
                        $wlan = netsh wlan show interfaces 2>$null
                        $sinal = ($wlan | Select-String -Pattern 'Sinal|Signal' | Select-Object -First 1)
                        $ssid = ($wlan | Select-String -Pattern '^\s+SSID\s+:' | Select-Object -First 1)
                        if ($sinal) {
                            $pctSinal = 0
                            if ("$sinal" -match '(\d+)\s*%') { $pctSinal = [int]$matches[1] }
                            $nomeRede = if ($ssid) { ("$ssid" -split ':', 2)[1].Trim() } else { "-" }
                            & $addLinha "Sinal do Wi-Fi" "$pctSinal%  (rede: $nomeRede)" ($pctSinal -ge 60)
                        }
                    }
                    catch {}
                }
            }

            try {
                $dhcp = Get-NetIPInterface -InterfaceIndex $cfg.InterfaceIndex -AddressFamily IPv4 -ErrorAction Stop
                & $addLinha "Obtencao do IP" $(if ($dhcp.Dhcp -eq 'Enabled') { "Automatico (DHCP)" } else { "Fixo (manual)" }) $null
            }
            catch {}

            # Proxy configurado costuma travar acesso ao servidor
            try {
                $prx = Get-ItemProperty "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings" -ErrorAction Stop
                if ($prx.ProxyEnable -eq 1) {
                    & $addLinha "Proxy do Windows" "ATIVO: $($prx.ProxyServer)" $false
                }
                else { & $addLinha "Proxy do Windows" "Desativado (normal)" $true }
            }
            catch {}

            # --- testes de conectividade ---
            $okGw = $false; $msGw = 0
            if ($gw) {
                try {
                    $r = $ping.Send($gw, 1500)
                    if ($r.Status -eq 'Success') { $okGw = $true; $msGw = $r.RoundtripTime }
                }
                catch {}
                & $addLinha "Ping no gateway" $(if ($okGw) { "$gw respondeu em $msGw ms" } else { "$gw nao respondeu" }) $okGw
            }
            [System.Windows.Forms.Application]::DoEvents()

            $okNet = $false; $msNet = 0
            try {
                $r = $ping.Send("8.8.8.8", 2000)
                if ($r.Status -eq 'Success') { $okNet = $true; $msNet = $r.RoundtripTime }
            }
            catch {}
            & $addLinha "Internet (8.8.8.8)" $(if ($okNet) { "respondeu em $msNet ms" } else { "sem resposta" }) $okNet
            [System.Windows.Forms.Application]::DoEvents()

            $okDns = $false
            $tempoDns = 0
            try {
                $cron = [System.Diagnostics.Stopwatch]::StartNew()
                $res = [System.Net.Dns]::GetHostAddresses("google.com")
                $cron.Stop()
                if ($res.Count -gt 0) { $okDns = $true; $tempoDns = [int]$cron.ElapsedMilliseconds }
            }
            catch {}
            & $addLinha "Resolucao de nomes (DNS)" $(if ($okDns) { "google.com resolvido em $tempoDns ms" } else { "falhou ao resolver google.com" }) $okDns
            [System.Windows.Forms.Application]::DoEvents()

            $okAdm = $false; $msAdm = 0
            try {
                $r = $ping.Send("adm2.netcontroll.com.br", 2500)
                if ($r.Status -eq 'Success') { $okAdm = $true; $msAdm = $r.RoundtripTime }
            }
            catch {}
            & $addLinha "Servidor NetControll" $(if ($okAdm) { "adm2 respondeu em $msAdm ms" } else { "adm2 nao respondeu ao ping" }) $okAdm
            [System.Windows.Forms.Application]::DoEvents()

            $portasAdm = @()
            if ($okNet) {
                try { $portasAdm = Test-PortasRapido -IP ([System.Net.Dns]::GetHostAddresses("adm2.netcontroll.com.br")[0].IPAddressToString) -Portas @(80, 443) -TimeoutMs 900 } catch {}
                & $addLinha "Portas do servidor" $(if ($portasAdm.Count -gt 0) { "abertas: $($portasAdm -join ', ')" } else { "80 e 443 fechadas ou bloqueadas" }) ($portasAdm.Count -gt 0)
            }
            [System.Windows.Forms.Application]::DoEvents()

            # --- cartoes ---
            if ($okGw) {
                Update-Gauge $gRede ([Math]::Min(100, $msGw * 4)) "OK" "gateway em $msGw ms" $Script:UiVerde
            }
            else {
                Update-Gauge $gRede 100 "FALHA" $(if ($gw) { "gateway nao responde" } else { "sem gateway" }) $Script:UiVermelho
            }
            if ($okNet) {
                $corNet = if ($msNet -ge 150) { $Script:UiAmarelo } else { $Script:UiVerde }
                Update-Gauge $gNet ([Math]::Min(100, $msNet / 3)) "ONLINE" "$msNet ms ate 8.8.8.8" $corNet
            }
            else {
                Update-Gauge $gNet 100 "OFFLINE" "sem acesso a internet" $Script:UiVermelho
            }
            if ($okAdm) {
                $corAdm = if ($msAdm -ge 200) { $Script:UiAmarelo } else { $Script:UiVerde }
                Update-Gauge $gServidor ([Math]::Min(100, $msAdm / 4)) "ACESSIVEL" "$msAdm ms ate o adm2" $corAdm
            }
            else {
                Update-Gauge $gServidor 100 "SEM RESPOSTA" "adm2 inacessivel" $Script:UiVermelho
            }

            # --- veredito: aponta ONDE a corrente quebrou ---
            if ($semIP) {
                $pnlVeredito.Tag.Cor = $Script:UiVermelho
                $pnlVeredito.Tag.Texto = "SEM IP VALIDO - cabo solto ou roteador sem DHCP"
            }
            elseif (-not $okGw -and $gw) {
                $pnlVeredito.Tag.Cor = $Script:UiVermelho
                $pnlVeredito.Tag.Texto = "PROBLEMA NA REDE LOCAL - o roteador ($gw) nao responde"
            }
            elseif (-not $okNet) {
                $pnlVeredito.Tag.Cor = $Script:UiVermelho
                $pnlVeredito.Tag.Texto = "REDE LOCAL OK, MAS SEM INTERNET - verifique o link do provedor"
            }
            elseif (-not $okDns) {
                $pnlVeredito.Tag.Cor = $Script:UiAmarelo
                $pnlVeredito.Tag.Texto = "INTERNET OK, MAS O DNS FALHOU - tente limpar o cache DNS"
            }
            elseif (-not $okAdm) {
                $pnlVeredito.Tag.Cor = $Script:UiAmarelo
                $pnlVeredito.Tag.Texto = "INTERNET OK, MAS O SERVIDOR NETCONTROLL NAO RESPONDE"
            }
            else {
                $pnlVeredito.Tag.Cor = $Script:UiVerde
                $pnlVeredito.Tag.Texto = "REDE FUNCIONANDO - internet e servidor acessiveis"
            }
            $pnlVeredito.Invalidate()

            # --- relatorio em texto ---
            $Script:RedeRelatorio = @"
=== DIAGNOSTICO DE REDE - $env:COMPUTERNAME ===
Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm')

Endereco IP:   $ipv4
Mascara:       $mascara
Gateway:       $(if ($gw) { $gw } else { '-' })
DNS:           $(if ($dns.Count -gt 0) { $dns -join ', ' } else { '-' })
Placa:         $(if ($ad) { "$($ad.InterfaceDescription) ($($ad.LinkSpeed))" } else { '-' })
MAC:           $(if ($ad) { $ad.MacAddress } else { '-' })

Gateway:       $(if ($okGw) { "OK - $msGw ms" } else { 'FALHA' })
Internet:      $(if ($okNet) { "OK - $msNet ms" } else { 'FALHA' })
DNS:           $(if ($okDns) { "OK - $tempoDns ms" } else { 'FALHA' })
Servidor adm2: $(if ($okAdm) { "OK - $msAdm ms" } else { 'FALHA' })

Resultado: $($pnlVeredito.Tag.Texto)
"@

            Log-Message "INFO" "Diagnostico de Rede:"
            Log-Message "INFO" "   > IP: $ipv4  |  Gateway: $gw"
            Log-Message "INFO" "   > DNS: $(if ($dns.Count -gt 0) { $dns -join ', ' } else { '-' })"
            Log-Message "INFO" "   > Internet: $(if ($okNet) { "OK ($msNet ms)" } else { 'FALHA' })  |  adm2: $(if ($okAdm) { "OK ($msAdm ms)" } else { 'FALHA' })"

            # Mantem o comportamento antigo: o IP ja fica na area de transferencia
            try { [System.Windows.Forms.Clipboard]::SetText($ipv4) } catch {}
        }

        New-ToolButton $f "REEXECUTAR TESTES" 20 614 190 36 $Script:UiAzul $diagnosticar "Roda o diagnostico de novo" | Out-Null

        New-ToolButton $f "LIMPAR CACHE DNS" 220 614 180 36 $Script:UiCinza {
            try {
                Clear-DnsClientCache
                Log-Message "SUCESSO" "Cache DNS limpo."
                & $diagnosticar
            }
            catch { Log-Message "ERRO" "Falha ao limpar cache DNS: $_" }
        } "Resolve boa parte dos problemas de nome/DNS" | Out-Null

        New-ToolButton $f "RENOVAR IP" 410 614 140 36 $Script:UiCinza {
            $r = [System.Windows.Forms.MessageBox]::Show("Vou liberar e pedir um IP novo ao roteador.`n`nA conexao cai por alguns segundos. Continuar?",
                "Renovar IP", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                try {
                    Log-Message "INFO" "Renovando IP (ipconfig /release + /renew)..."
                    Start-Process "ipconfig" "/release" -Wait -WindowStyle Hidden
                    Start-Process "ipconfig" "/renew" -Wait -WindowStyle Hidden
                    Log-Message "SUCESSO" "IP renovado."
                    & $diagnosticar
                }
                catch { Log-Message "ERRO" "Falha ao renovar IP: $_" }
            }
        } "Pede um endereco novo ao roteador (ipconfig /renew)" | Out-Null

        New-ToolButton $f "COPIAR RELATORIO" 560 614 185 36 $Script:UiCinza {
            Set-Clipboard -Value $Script:RedeRelatorio
            [System.Windows.Forms.MessageBox]::Show("Relatorio copiado. Pode colar no chamado com Ctrl+V.", "Copiado", "OK", "Information") | Out-Null
        } "Copia o diagnostico completo em texto" | Out-Null

        $f.Add_FormClosing({ $Script:RedeForm = $null })
        $f.Add_Shown({ & $diagnosticar })
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch {
        Log-Message "ERRO" "Falha no diagnostico de rede: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha no diagnostico: $($_.Exception.Message)", "Rede", "OK", "Error") | Out-Null
    }
}


# -----------------------------------------------------------------------------
# ENERGIA DO USB: impressora termica USB que "some" depois de um tempo
# geralmente e a porta sendo suspensa pelo Windows.
# -----------------------------------------------------------------------------
function Invoke-UsbPowerFix {
    # -Silencioso: usado pelo PREPARAR AMBIENTE, so registra no log
    param([switch]$Silencioso)
    Log-Message "INFO" "Desligando economia de energia das portas USB..."
    $feitos = @()
    $falhas = @()

    # 1) Suspensao seletiva de USB no plano de energia atual (tomada e bateria)
    #    Subgrupo "Configuracoes USB" / "Configuracao de suspensao seletiva USB"
    $subUsb = "2a737441-1930-4402-8d77-b2bebba308a3"
    $cfgUsb = "48e6b7a6-50f5-4782-a5d4-53bb8f07e226"
    try {
        Start-Process "powercfg" "/setacvalueindex SCHEME_CURRENT $subUsb $cfgUsb 0" -Wait -WindowStyle Hidden
        Start-Process "powercfg" "/setdcvalueindex SCHEME_CURRENT $subUsb $cfgUsb 0" -Wait -WindowStyle Hidden
        Start-Process "powercfg" "/setactive SCHEME_CURRENT" -Wait -WindowStyle Hidden
        $feitos += "Suspensao seletiva de USB desativada"
        Log-Message "SUCESSO" "   > Suspensao seletiva de USB: desativada."
    }
    catch {
        $falhas += "Suspensao seletiva de USB"
        Log-Message "ERRO" "   > Falha na suspensao seletiva de USB: $($_.Exception.Message)"
    }

    # 2) Disco e suspensao do computador na tomada: PDV nao pode dormir
    try {
        Start-Process "powercfg" "/change disk-timeout-ac 0" -Wait -WindowStyle Hidden
        Start-Process "powercfg" "/change standby-timeout-ac 0" -Wait -WindowStyle Hidden
        Start-Process "powercfg" "/change hibernate-timeout-ac 0" -Wait -WindowStyle Hidden
        $feitos += "Suspensao do computador e do disco desligadas (na tomada)"
        Log-Message "SUCESSO" "   > Suspensao de disco/computador na tomada: desligada."
    }
    catch {
        $falhas += "Timeouts de energia"
        Log-Message "ERRO" "   > Falha nos timeouts de energia: $($_.Exception.Message)"
    }

    # 3) Aquele checkbox do Gerenciador de Dispositivos:
    #    "Permitir que o computador desligue este dispositivo para economizar energia"
    $ajustados = 0
    $negados = 0
    $jaOk = 0
    try {
        $dispositivos = @(Get-CimInstance -Namespace root\wmi -ClassName MSPower_DeviceEnable -ErrorAction Stop)
        foreach ($d in $dispositivos) {
            # So mexe em portas e hubs USB, nao em placa de rede
            if ($d.InstanceName -notmatch 'USB\\(ROOT_HUB|VID_)') { continue }
            if (-not $d.Enable) { $jaOk++; continue }
            try {
                Set-CimInstance -InputObject $d -Property @{ Enable = $false } -ErrorAction Stop
                $ajustados++
            }
            catch { $negados++ }
        }
        if ($ajustados -gt 0) {
            $feitos += "$ajustados porta(s)/hub(s) USB sem desligamento automatico"
            Log-Message "SUCESSO" "   > $ajustados dispositivo(s) USB com economia de energia desativada."
        }
        if ($negados -gt 0) {
            # Sem privilegio o WMI recusa a escrita: precisa avisar, nao dizer que deu certo
            $falhas += "$negados porta(s) USB recusaram o ajuste (execute como administrador)"
            Log-Message "ERRO" "   > $negados dispositivo(s) USB recusaram a alteracao (acesso negado)."
        }
        if ($ajustados -eq 0 -and $negados -eq 0) {
            $feitos += "Portas USB ja estavam sem desligamento automatico ($jaOk)"
            Log-Message "INFO" "   > Nenhum hub USB precisava de ajuste."
        }
    }
    catch {
        Log-Message "INFO" "   > Ajuste por dispositivo indisponivel nesta maquina (WMI de energia)."
    }

    $texto = "AJUSTE DE ENERGIA DAS PORTAS USB`r`n`r`n"
    if ($feitos.Count -gt 0) {
        $texto += "Aplicado:`r`n"
        foreach ($x in $feitos) { $texto += "  - $x`r`n" }
    }
    if ($falhas.Count -gt 0) {
        $texto += "`r`nNao foi possivel aplicar:`r`n"
        foreach ($x in $falhas) { $texto += "  - $x`r`n" }
    }
    $texto += "`r`nIsso evita que a impressora termica USB pare de responder`r`ndepois de um tempo parada. Se ela ja estiver travada,`r`ndesconecte e reconecte o cabo uma vez."

    if ($Silencioso) { return }

    [System.Windows.Forms.MessageBox]::Show($texto, "Energia das portas USB", "OK",
        $(if ($falhas.Count -gt 0) { "Warning" } else { "Information" })) | Out-Null
}

# -----------------------------------------------------------------------------
# PAINEL DE SERVICOS (SQL SERVER, SPOOLER E SISTEMA NETCONTROLL)
# -----------------------------------------------------------------------------
function Get-ServicosRelevantes {
    $lista = @()
    try {
        $todos = @(Get-Service -ErrorAction SilentlyContinue)
        foreach ($s in $todos) {
            $grupo = $null
            if ($s.Name -like 'MSSQL$*' -or $s.Name -eq 'MSSQLSERVER') { $grupo = "SQL Server (banco)" }
            elseif ($s.Name -eq 'SQLBrowser') { $grupo = "SQL Browser (localiza instancias)" }
            elseif ($s.Name -eq 'SQLWriter') { $grupo = "SQL Writer (backup)" }
            elseif ($s.Name -like 'SQLAgent$*' -or $s.Name -eq 'SQLSERVERAGENT') { $grupo = "SQL Agent (tarefas)" }
            elseif ($s.Name -eq 'Spooler') { $grupo = "Spooler de impressao" }
            elseif ($s.Name -match 'netcontroll|concentrador|xmenu|netpdv|xbot' -or
                $s.DisplayName -match 'NetControll|Concentrador|XMenu|NetPDV|XBot') { $grupo = "Sistema NetControll" }

            if ($grupo) {
                $inicio = "-"
                try { $inicio = (Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction Stop).StartMode } catch {}
                $lista += [PSCustomObject]@{
                    Nome    = $s.Name
                    Titulo  = $s.DisplayName
                    Grupo   = $grupo
                    Estado  = [string]$s.Status
                    Inicio  = $inicio
                }
            }
        }
    }
    catch {}
    return ($lista | Sort-Object Grupo, Nome)
}

function Show-ServiceManager {
    try {
        if ($null -ne $Script:SrvForm -and -not $Script:SrvForm.IsDisposed) {
            $Script:SrvForm.Activate(); return
        }

        $f = New-ToolForm "Servicos do Sistema (SQL / Impressao)" 820 660
        $Script:SrvForm = $f

        New-ToolLabel $f "SERVICOS DO SQL SERVER E DO SISTEMA" 20 14 12 -Negrito | Out-Null
        $lblInst = New-ToolLabel $f "" 20 40 8.5 -Cor $Script:UiSuave

        $pnlAviso = New-Object System.Windows.Forms.Panel
        $pnlAviso.Location = New-Object System.Drawing.Point(20, 66)
        $pnlAviso.Size = New-Object System.Drawing.Size(765, 50)
        $pnlAviso.Anchor = 'Top,Left,Right'
        $pnlAviso.BackColor = $Script:UiFundo
        $pnlAviso.Tag = @{ Cor = $Script:UiCinza; Texto = "Lendo servicos..." }
        $pnlAviso.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.Clear($s.Parent.BackColor)
                $d = $s.Tag
                $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
                $caminho = New-RoundedRectPath -X 0 -Y 0 -W $s.Width -H $s.Height -R 8
                $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Get-UiTom $d.Cor 18), (Get-UiTom $d.Cor -28), [float]0)
                $g.FillPath($br, $caminho)
                $fw = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
                [System.Windows.Forms.TextRenderer]::DrawText($g, $d.Texto, $fw, $rect, [System.Drawing.Color]::White,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::WordBreak))
                $fw.Dispose(); $br.Dispose(); $caminho.Dispose()
            })
        [void]$f.Controls.Add($pnlAviso)

        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(20, 128)
        $lv.Size = New-Object System.Drawing.Size(765, 330)
        $lv.Anchor = 'Top,Left,Right,Bottom'
        Format-ToolListView $lv
        [void]$lv.Columns.Add("Servico", 250)
        [void]$lv.Columns.Add("Funcao", 230)
        [void]$lv.Columns.Add("Estado", 110)
        [void]$lv.Columns.Add("Inicializacao", 155)
        [void]$f.Controls.Add($lv)

        $Script:SrvSelecionado = ""

        $carregar = {
            $sel = ""
            if ($lv.SelectedItems.Count -gt 0) { $sel = $lv.SelectedItems[0].Text }
            $lv.BeginUpdate()
            $lv.Items.Clear()
            $servicos = @(Get-ServicosRelevantes)
            foreach ($s in $servicos) {
                $it = New-Object System.Windows.Forms.ListViewItem($s.Nome)
                [void]$it.SubItems.Add($s.Grupo)
                [void]$it.SubItems.Add($s.Estado)
                [void]$it.SubItems.Add($s.Inicio)
                if ($s.Estado -eq 'Running') { $it.ForeColor = $Script:UiVerde }
                elseif ($s.Inicio -eq 'Disabled') { $it.ForeColor = $Script:UiVermelho }
                else { $it.ForeColor = $Script:UiAmarelo }
                if ($s.Nome -eq $sel) { $it.Selected = $true }
                [void]$lv.Items.Add($it)
            }
            $lv.EndUpdate()

            # Instancias instaladas (registro) - mostra mesmo se o servico estiver parado
            $instancias = @()
            try { $instancias = @((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server' -Name InstalledInstances -ErrorAction Stop).InstalledInstances) } catch {}
            $lblInst.Text = "Instancias SQL instaladas: $(if ($instancias.Count -gt 0) { $instancias -join ', ' } else { 'nenhuma encontrada' })   |   $env:COMPUTERNAME"

            # Veredito
            $sqlBanco = @($servicos | Where-Object { $_.Grupo -eq "SQL Server (banco)" })
            $sqlRodando = @($sqlBanco | Where-Object { $_.Estado -eq 'Running' })
            if ($sqlBanco.Count -eq 0) {
                $pnlAviso.Tag.Cor = $Script:UiCinza
                $pnlAviso.Tag.Texto = "SQL SERVER NAO INSTALADO NESTA MAQUINA"
            }
            elseif ($sqlRodando.Count -eq 0) {
                $pnlAviso.Tag.Cor = $Script:UiVermelho
                $pnlAviso.Tag.Texto = "SQL SERVER PARADO - o sistema nao vai conectar. Selecione e clique em INICIAR."
            }
            else {
                $manual = @($sqlBanco | Where-Object { $_.Inicio -eq 'Manual' -or $_.Inicio -eq 'Disabled' })
                if ($manual.Count -gt 0) {
                    $pnlAviso.Tag.Cor = $Script:UiAmarelo
                    $pnlAviso.Tag.Texto = "SQL RODANDO, MAS SEM INICIO AUTOMATICO - vai parar no proximo boot"
                }
                else {
                    $pnlAviso.Tag.Cor = $Script:UiVerde
                    $pnlAviso.Tag.Texto = "SQL SERVER RODANDO E CONFIGURADO PARA INICIAR COM O WINDOWS"
                }
            }
            $pnlAviso.Invalidate()
        }

        $servicoSelecionado = {
            if ($lv.SelectedItems.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Selecione um servico na lista primeiro.", "Servicos", "OK", "Information") | Out-Null
                return ""
            }
            return $lv.SelectedItems[0].Text
        }

        New-ToolButton $f "INICIAR" 20 470 120 34 $Script:UiVerde {
            $n = & $servicoSelecionado
            if (-not $n) { return }
            try {
                Start-Service -Name $n -ErrorAction Stop
                Log-Message "SUCESSO" "Servico iniciado: $n"
            }
            catch { Log-Message "ERRO" "Falha ao iniciar ${n}: $($_.Exception.Message)" }
            & $carregar
        } "Inicia o servico selecionado" | Out-Null

        New-ToolButton $f "PARAR" 148 470 120 34 $Script:UiVermelho {
            $n = & $servicoSelecionado
            if (-not $n) { return }
            $r = [System.Windows.Forms.MessageBox]::Show("Parar o servico '$n'?`n`nSe for o SQL Server, o sistema fica sem banco ate iniciar de novo.",
                "Confirmar", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            try {
                Stop-Service -Name $n -Force -ErrorAction Stop
                Log-Message "INFO" "Servico parado: $n"
            }
            catch { Log-Message "ERRO" "Falha ao parar ${n}: $($_.Exception.Message)" }
            & $carregar
        } "Para o servico selecionado" | Out-Null

        New-ToolButton $f "REINICIAR" 276 470 130 34 $Script:UiAzul {
            $n = & $servicoSelecionado
            if (-not $n) { return }
            try {
                Restart-Service -Name $n -Force -ErrorAction Stop
                Log-Message "SUCESSO" "Servico reiniciado: $n"
            }
            catch { Log-Message "ERRO" "Falha ao reiniciar ${n}: $($_.Exception.Message)" }
            & $carregar
        } "Para e inicia o servico de novo" | Out-Null

        New-ToolButton $f "INICIO AUTOMATICO" 414 470 200 34 $Script:UiCinza {
            $n = & $servicoSelecionado
            if (-not $n) { return }
            try {
                Set-Service -Name $n -StartupType Automatic -ErrorAction Stop
                Log-Message "SUCESSO" "Servico $n configurado para iniciar com o Windows."
            }
            catch { Log-Message "ERRO" "Falha ao configurar ${n}: $($_.Exception.Message)" }
            & $carregar
        } "Faz o servico subir junto com o Windows" | Out-Null

        New-ToolButton $f "ATUALIZAR" 622 470 163 34 $Script:UiCinza $carregar "Le os servicos de novo" | Out-Null

        # --- teste de conexao com o servidor de banco ---
        New-ToolLabel $f "Testar acesso ao banco em:" 20 520 9 -Cor $Script:UiSuave | Out-Null
        $txtSrv = New-Object System.Windows.Forms.TextBox
        $txtSrv.Location = New-Object System.Drawing.Point(196, 517)
        $txtSrv.Size = New-Object System.Drawing.Size(210, 24)
        $txtSrv.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
        $txtSrv.ForeColor = $Script:UiTexto
        $txtSrv.BorderStyle = 'FixedSingle'
        $txtSrv.Text = "127.0.0.1"
        [void]$f.Controls.Add($txtSrv)
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($txtSrv, "IP ou nome do servidor onde fica o SQL Server") }

        $lblTeste = New-ToolLabel $f "" 20 556 9 -Cor $Script:UiSuave -W 760

        New-ToolButton $f "TESTAR PORTA 1433" 414 516 200 34 $Script:UiAzul {
            $alvo = $txtSrv.Text.Trim()
            if (-not $alvo) { return }
            $lblTeste.Text = "Testando $alvo..."
            $lblTeste.ForeColor = $Script:UiSuave
            [System.Windows.Forms.Application]::DoEvents()
            try {
                $ip = $alvo
                if ($alvo -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
                    $ip = [System.Net.Dns]::GetHostAddresses($alvo)[0].IPAddressToString
                }
                $abertas = Test-PortasRapido -IP $ip -Portas @(1433) -TimeoutMs 900
                if ($abertas -contains 1433) {
                    $lblTeste.Text = "OK: a porta 1433 de $alvo ($ip) esta acessivel - o PDV consegue chegar no banco."
                    $lblTeste.ForeColor = $Script:UiVerde
                    Log-Message "SUCESSO" "Porta 1433 acessivel em $alvo."
                }
                else {
                    $lblTeste.Text = "FALHA: a porta 1433 de $alvo ($ip) nao respondeu - veja servico parado, firewall ou TCP/IP desabilitado no SQL."
                    $lblTeste.ForeColor = $Script:UiVermelho
                    Log-Message "ERRO" "Porta 1433 inacessivel em $alvo."
                }
            }
            catch {
                $lblTeste.Text = "Nao consegui resolver '$alvo': $($_.Exception.Message)"
                $lblTeste.ForeColor = $Script:UiVermelho
            }
        } "Verifica se o PDV consegue alcancar o banco de dados" | Out-Null

        New-ToolButton $f "SERVICOS DO WINDOWS" 622 516 163 34 $Script:UiCinza {
            Start-Process "services.msc"
        } "Abre o painel completo de servicos do Windows" | Out-Null

        $f.Add_FormClosing({ $Script:SrvForm = $null })
        & $carregar
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch {
        Log-Message "ERRO" "Falha no painel de servicos: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir o painel: $($_.Exception.Message)", "Servicos", "OK", "Error") | Out-Null
    }
}

# -----------------------------------------------------------------------------
# RELOGIO DO WINDOWS
# Relogio errado faz a SEFAZ rejeitar NFC-e/SAT e quebra validacao de
# certificado. Em maquina de PDV o servico de horario costuma vir desligado.
# -----------------------------------------------------------------------------
function Get-DesvioRelogio {
    # Le a diferenca entre o relogio local e o servidor de hora, sem alterar nada
    try {
        $saida = & w32tm /stripchart /computer:pool.ntp.br /samples:2 /dataonly 2>&1
        foreach ($linha in $saida) {
            if ("$linha" -match ',\s*([+-]?\d+\.\d+)s') { $ultimo = [double]$matches[1] }
        }
        if ($null -ne $ultimo) { return $ultimo }
    }
    catch {}
    return $null
}

function Invoke-ClockSync {
    # -Silencioso: usado pelo PREPARAR AMBIENTE. Pula a medicao de desvio
    # (que leva alguns segundos) e nao abre janela, so registra no log.
    param([switch]$Silencioso)
    Log-Message "INFO" "Sincronizando o relogio do Windows..."
    $passos = @()
    $problemas = @()

    $antes = $null
    if (-not $Silencioso) {
        $antes = Get-DesvioRelogio
        if ($null -ne $antes) {
            Log-Message "INFO" "   > Desvio antes: $([Math]::Round($antes, 3))s"
        }
    }

    # 1) O servico de horario precisa estar automatico e rodando
    try {
        Set-Service -Name w32time -StartupType Automatic -ErrorAction Stop
        $passos += "Servico de horario em inicio automatico"
    }
    catch { $problemas += "Nao consegui deixar o servico de horario em automatico" }

    try {
        $sv = Get-Service -Name w32time -ErrorAction Stop
        if ($sv.Status -ne 'Running') {
            Start-Service -Name w32time -ErrorAction Stop
            $passos += "Servico de horario iniciado"
        }
    }
    catch { $problemas += "Nao consegui iniciar o servico de horario" }

    # 2) Usa o pool.ntp.br (hora legal brasileira) em vez do padrao da
    #    Microsoft, que costuma estar bloqueado ou lento nas lojas
    try {
        $null = & w32tm /config /manualpeerlist:"pool.ntp.br,0x9" /syncfromflags:manual /update 2>&1
        $passos += "Fonte de hora apontada para o pool.ntp.br"
    }
    catch { $problemas += "Nao consegui configurar a fonte de hora" }

    # 3) Sincroniza (a primeira tentativa falha quando o servico acabou de subir)
    $sincronizou = $false
    foreach ($tentativa in 1..2) {
        try {
            $res = & w32tm /resync /force 2>&1
            if ("$res" -notmatch 'erro|error|falha|failed') { $sincronizou = $true; break }
        }
        catch {}
        Start-Sleep -Seconds 2
    }
    if ($sincronizou) { $passos += "Relogio sincronizado com o servidor de hora" }
    else { $problemas += "A sincronizacao nao respondeu (verifique se a porta UDP 123 esta liberada)" }

    $depois = $null
    if (-not $Silencioso) { $depois = Get-DesvioRelogio }

    $texto = "SINCRONIZACAO DO RELOGIO`r`n`r`n"
    $texto += "Hora do computador agora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')`r`n"
    if ($null -ne $antes) {
        $texto += "Diferenca antes:  $([Math]::Round($antes, 2)) segundos`r`n"
    }
    if ($null -ne $depois) {
        $texto += "Diferenca agora:  $([Math]::Round($depois, 2)) segundos`r`n"
        if ([Math]::Abs($depois) -gt 5) {
            $texto += "`r`nATENCAO: ainda ha mais de 5 segundos de diferenca.`r`nIsso e suficiente para a SEFAZ rejeitar NFC-e.`r`n"
        }
    }
    if ($passos.Count -gt 0) {
        $texto += "`r`nAplicado:`r`n"
        foreach ($p in $passos) { $texto += "  - $p`r`n" }
    }
    if ($problemas.Count -gt 0) {
        $texto += "`r`nNao deu certo:`r`n"
        foreach ($p in $problemas) { $texto += "  - $p`r`n" }
    }

    Log-Message $(if ($problemas.Count -gt 0) { "ERRO" } else { "SUCESSO" }) "Relogio: $(if ($sincronizou) { 'sincronizado' } else { 'falhou' })$(if ($null -ne $depois) { " (desvio $([Math]::Round($depois,2))s)" })"

    if ($Silencioso) { return }

    [System.Windows.Forms.MessageBox]::Show($texto, "Relogio do Windows", "OK",
        $(if ($problemas.Count -gt 0) { "Warning" } else { "Information" })) | Out-Null
}

# -----------------------------------------------------------------------------
# TEF HUB DA ELGIN - RESOLVE A VERSAO MAIS RECENTE SOZINHO
# A Elgin publica os instaladores nesta pasta do GitHub e troca a versao sem
# aviso. Em vez de deixar o link fixo (que envelhece), a gente pergunta a API
# qual e o arquivo x86 atual na hora do clique.
#
# Detalhe importante: o repositorio usa Git LFS. O link "raw.githubusercontent"
# devolve so um ponteiro de texto de ~130 bytes, nao o instalador. O binario de
# verdade sai por "media.githubusercontent.com/media/".
# -----------------------------------------------------------------------------
$Script:TefHubReserva = "https://media.githubusercontent.com/media/ElginDeveloperCommunity/ElginTEFHUB/master/ELGIN%20TEF%20HUB/Instaladores%20Windows/86Elgin%20TEFHUB-v05.09.00.exe"
$Script:TefHubPagina = "https://github.com/ElginDeveloperCommunity/ElginTEFHUB/tree/master/ELGIN%20TEF%20HUB/Instaladores%20Windows"

function Get-TefHubUltimaVersao {
    $api = "https://api.github.com/repos/ElginDeveloperCommunity/ElginTEFHUB/contents/ELGIN%20TEF%20HUB/Instaladores%20Windows"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $itens = Invoke-RestMethod -Uri $api -Headers @{ "User-Agent" = "XMenu-Preparador" } -TimeoutSec 25

        # "86..." = 32 bits (x86), que e a versao que usamos. "64..." e x64.
        $x86 = @($itens | Where-Object { $_.type -eq 'file' -and $_.name -match '^86Elgin.*\.exe$' })
        if ($x86.Count -eq 0) { return $null }

        $maisNovo = $x86 | Sort-Object {
            if ($_.name -match 'v(\d+)\.(\d+)\.(\d+)') { [version]"$($matches[1]).$($matches[2]).$($matches[3])" }
            else { [version]"0.0.0" }
        } -Descending | Select-Object -First 1

        $versao = if ($maisNovo.name -match 'v([\d\.]+)\.exe$') { $matches[1] } else { "desconhecida" }
        $caminho = (($maisNovo.path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'

        return [PSCustomObject]@{
            Versao  = $versao
            Nome    = $maisNovo.name
            Url     = "https://media.githubusercontent.com/media/ElginDeveloperCommunity/ElginTEFHUB/master/$caminho"
            Arquivo = "Elgin_TEFHUB_x86_v$versao.exe"
        }
    }
    catch {
        Log-Message "ERRO" "Nao consegui consultar o GitHub da Elgin: $($_.Exception.Message)"
        return $null
    }
}

function Install-TefHub {
    param($Button)

    $textoOriginal = $Button.Text
    $Button.Text = "Verificando versao mais recente..."
    $Button.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    $info = Get-TefHubUltimaVersao

    $Button.Enabled = $true
    $Button.Text = $textoOriginal

    if ($null -eq $info) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            "Nao consegui verificar a versao mais recente no GitHub da Elgin.`n`n" +
            "Pode ser falta de internet ou limite de consultas do GitHub.`n`n" +
            "SIM  = baixar a versao de reserva (05.09.00)`n" +
            "NAO  = abrir a pasta da Elgin no navegador",
            "TEF HUB", [System.Windows.Forms.MessageBoxButtons]::YesNoCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($r -eq [System.Windows.Forms.DialogResult]::No) {
            Log-Message "INFO" "Abrindo a pasta oficial da Elgin para download manual."
            Start-Process $Script:TefHubPagina
            return
        }
        if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Start-Download $Script:TefHubReserva "Elgin_TEFHUB_x86_v05.09.00.exe" $Button
        $nomeAlvo = "86Elgin TEFHUB-v05.09.00.exe"
    }
    else {
        Log-Message "INFO" "TEF HUB x86 no GitHub da Elgin: versao $($info.Versao)  ($($info.Nome))"
        Start-Download $info.Url $info.Arquivo $Button
        $nomeAlvo = $info.Nome
    }

    # O motor de download ja tenta 3 vezes sozinho. Se mesmo assim nao veio
    # (e o usuario nao cancelou), abre a pasta da Elgin para baixar na mao -
    # o arquivo tem mais de 300 MB e costuma ser rede instavel.
    if (-not $Script:UltimoDownloadOk -and -not $Script:UltimoDownloadCancelado) {
        Log-Message "ERRO" "TEF HUB falhou nas 3 tentativas. Abrindo a pasta oficial da Elgin."
        [System.Windows.Forms.MessageBox]::Show(
            "Nao consegui baixar o TEF HUB depois de 3 tentativas.`n`n" +
            "Vou abrir a pasta oficial da Elgin no navegador.`n" +
            "Baixe o arquivo:`n`n    $nomeAlvo`n`n" +
            "(o que comeca com 86 e a versao x86, que e a que usamos)",
            "TEF HUB", "OK", "Warning") | Out-Null
        Start-Process $Script:TefHubPagina
    }
}

function Invoke-SFC {
    Log-Message "INFO" "Iniciando SFC /Scannow (Reparo de Arquivos)..."
    Log-Message "CMD" "COMANDO: sfc /scannow"
    Log-Message "INFO" "Uma nova janela de comando foi aberta para o processo."
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "Write-Host 'Iniciando SFC /Scannow...'; sfc /scannow; Write-Host 'Concluido. Pressione qualquer tecla para sair.'; [void][Console]::ReadKey()" -Verb RunAs
}

function Invoke-SpoolerReset {
    Log-Message "INFO" "Resetando Spooler de Impressão..."
    try {
        Log-Message "CMD" "COMANDO: Stop-Service Spooler -Force"
        Stop-Service Spooler -Force -ErrorAction SilentlyContinue
        $path = "C:\Windows\System32\spool\PRINTERS\*"
        if (Test-Path $path) { 
            Log-Message "CMD" "COMANDO: Remove-Item $path -Recurse -Force"
            Remove-Item $path -Recurse -Force -ErrorAction SilentlyContinue
            Log-Message "INFO" "Fila de impressão limpa."
        }
        Log-Message "CMD" "COMANDO: Start-Service Spooler"
        Start-Service Spooler
        Log-Message "SUCESSO" "Spooler reiniciado com sucesso."
    }
    catch {
        Log-Message "ERRO" "Falha ao resetar spooler: $_"
    }
}

function Invoke-NetworkReset {
    Log-Message "INFO" "Iniciando Reset de Rede e DNS..."
    try {
        Log-Message "CMD" "COMANDO: ipconfig /flushdns"
        ipconfig /flushdns | Out-Null
        Log-Message "CMD" "COMANDO: ipconfig /registerdns"
        ipconfig /registerdns | Out-Null
        Log-Message "CMD" "COMANDO: netsh winsock reset"
        netsh winsock reset | Out-Null
        Log-Message "CMD" "COMANDO: netsh int ip reset"
        netsh int ip reset | Out-Null

        # Renovacao de IP (resolve problemas de rota)
        Log-Message "INFO" "========================================================="
        Log-Message "INFO" "ATENCAO: O IP DA MAQUINA SERA ALTERADO/RENOVADO!"
        Log-Message "INFO" "Os comandos a seguir liberam e renovam o endereco IP."
        Log-Message "INFO" "Isso corrige problemas de rota e conectividade."
        Log-Message "INFO" "========================================================="
        [System.Windows.Forms.Application]::DoEvents()

        Log-Message "CMD" "COMANDO: ipconfig /release (Liberando IP atual...)"
        ipconfig /release | Out-Null
        Log-Message "INFO" "IP liberado com sucesso. Obtendo novo endereco..."
        [System.Windows.Forms.Application]::DoEvents()

        Log-Message "CMD" "COMANDO: ipconfig /renew (Renovando IP...)"
        ipconfig /renew | Out-Null
        Log-Message "INFO" "Novo IP obtido com sucesso!"

        # Exibe o novo IP no log para conferencia
        try {
            $novoIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.PrefixOrigin -ne 'WellKnown' } | Select-Object -First 1).IPAddress
            if ($novoIP) {
                Log-Message "INFO" ">>> NOVO IP DA MAQUINA: $novoIP <<<"
            }
        }
        catch {}

        Log-Message "SUCESSO" "DNS e Stack de rede resetados + IP renovado! (Recomendado reiniciar)"
    }
    catch {
        Log-Message "ERRO" "Erro no reset de rede: $_"
    }
}

function Invoke-WindowsUpdateReset {
    Log-Message "INFO" "Iniciando Reparo do Windows Update..."
    try {
        Log-Message "LOG" "Parando serviços do Windows Update..."
        Log-Message "CMD" "COMANDO: Stop-Service wuauserv, bits, cryptsvc, msiserver -Force"
        Stop-Service wuauserv, bits, cryptsvc, msiserver -Force -ErrorAction SilentlyContinue
        
        Log-Message "LOG" "Limpando cache (SoftwareDistribution e Catroot2)..."
        $date = Get-Date -Format "yyyyMMddHHmm"
        if (Test-Path "C:\Windows\SoftwareDistribution") {
            Log-Message "CMD" "COMANDO: Move-Item C:\Windows\SoftwareDistribution ..."
            Move-Item "C:\Windows\SoftwareDistribution" "C:\Windows\SoftwareDistribution.$date.old" -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path "C:\Windows\System32\catroot2") {
            Log-Message "CMD" "COMANDO: Move-Item C:\Windows\System32\catroot2 ..."
            Move-Item "C:\Windows\System32\catroot2" "C:\Windows\System32\catroot2.$date.old" -Force -ErrorAction SilentlyContinue
        }

        Log-Message "LOG" "Reiniciando serviços do Windows..."
        Log-Message "CMD" "COMANDO: Start-Service wuauserv, bits, cryptsvc, msiserver"
        Start-Service wuauserv, bits, cryptsvc, msiserver -ErrorAction SilentlyContinue
        
        Log-Message "SUCESSO" "Windows Update Resetado! Recomenda-se reiniciar o PC."
    }
    catch {
        Log-Message "ERRO" "Falha ao resetar Windows Update: $_"
    }
}

function Invoke-DISM {
    Log-Message "INFO" "Iniciando DISM /RestoreHealth (Reparo de Imagem)..."
    Log-Message "CMD" "COMANDO: dism /online /cleanup-image /restorehealth"
    Log-Message "INFO" "Uma nova janela de comando foi aberta para o processo."
    Start-Process powershell -ArgumentList "-NoExit", "-Command", "Write-Host 'Iniciando DISM /RestoreHealth...'; dism /online /cleanup-image /restorehealth; Write-Host 'Concluido. Pressione qualquer tecla para sair.'; [void][Console]::ReadKey()" -Verb RunAs
}

function Invoke-DeepClean {
    Log-Message "INFO" "Iniciando Limpeza de Disco Profunda..."
    try {
        $paths = @("$env:windir\Logs\*", "$env:windir\Prefetch\*", "$env:TEMP\*", "$env:windir\Temp\*")
        foreach ($p in $paths) {
            if (Test-Path $p) {
                Log-Message "CMD" "COMANDO: Remove-Item $p -Recurse -Force"
                Remove-Item $p -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                Log-Message "LOG" "Limpando cache: $p"
            }
        }
        Log-Message "CMD" "COMANDO: cleanmgr.exe /sagerun:1"
        Start-Process "cleanmgr.exe" -ArgumentList "/sagerun:1" -ErrorAction SilentlyContinue
        Log-Message "SUCESSO" "Limpeza profunda enviada ao sistema!"
    }
    catch { Log-Message "ERRO" "Falha na limpeza: $_" }
}

# -----------------------------------------------------------------------------
# KIT VISUAL DAS FERRAMENTAS DE SUPORTE
# Paleta e controles compartilhados pelo monitor, avaliacao, scanner e ping,
# para as quatro janelas terem a mesma cara.
# -----------------------------------------------------------------------------
$Script:UiFundo = [System.Drawing.Color]::FromArgb(24, 28, 38)
$Script:UiCartao = [System.Drawing.Color]::FromArgb(33, 40, 54)
$Script:UiBorda = [System.Drawing.Color]::FromArgb(52, 62, 82)
$Script:UiTexto = [System.Drawing.Color]::FromArgb(234, 240, 250)
$Script:UiSuave = [System.Drawing.Color]::FromArgb(146, 160, 184)
$Script:UiAzul = [System.Drawing.Color]::FromArgb(14, 88, 62)
$Script:UiVerde = [System.Drawing.Color]::FromArgb(0, 194, 146)
$Script:UiAmarelo = [System.Drawing.Color]::FromArgb(226, 168, 40)
$Script:UiVermelho = [System.Drawing.Color]::FromArgb(222, 70, 70)
$Script:UiCinza = [System.Drawing.Color]::FromArgb(62, 72, 92)

function Get-UiTom {
    param($Cor, [int]$Delta)
    $r = [Math]::Max(0, [Math]::Min(255, [int]$Cor.R + $Delta))
    $g = [Math]::Max(0, [Math]::Min(255, [int]$Cor.G + $Delta))
    $b = [Math]::Max(0, [Math]::Min(255, [int]$Cor.B + $Delta))
    return [System.Drawing.Color]::FromArgb($r, $g, $b)
}

function New-ToolForm {
    param([string]$Titulo, [int]$Largura, [int]$Altura)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Titulo
    $f.Size = New-Object System.Drawing.Size($Largura, $Altura)
    $f.StartPosition = 'CenterParent'
    $f.BackColor = $Script:UiFundo
    $f.ForeColor = $Script:UiTexto
    $f.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
    $f.FormBorderStyle = 'Sizable'
    $f.MinimizeBox = $true
    $f.MaximizeBox = $true
    return $f
}

# Botao chapado moderno: cantos arredondados, gradiente sutil e hover/clique
$Script:ModernBtnPaint = {
    param($s, $e)
    $w = $s.Width; $h = $s.Height
    if ($w -le 4 -or $h -le 4) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $fundo = if ($s.Parent) { $s.Parent.BackColor } else { $Script:UiFundo }
    $g.Clear($fundo)

    $base = $s.BackColor
    $estado = [string]$s.Tag
    if (-not $s.Enabled) { $base = $Script:UiCinza }
    elseif ($estado -eq 'hover') { $base = Get-UiTom $base 26 }
    elseif ($estado -eq 'down') { $base = Get-UiTom $base -26 }

    $rect = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $caminho = New-RoundedRectPath -X 0 -Y 0 -W $w -H $h -R 6
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Get-UiTom $base 14), (Get-UiTom $base -14), [float]90)
    $g.FillPath($br, $caminho)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 255, 255, 255), 1)
    $g.DrawPath($pen, $caminho)

    $cor = if ($s.Enabled) { [System.Drawing.Color]::White } else { $Script:UiSuave }
    $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
        [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
        [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    [System.Windows.Forms.TextRenderer]::DrawText($g, $s.Text, $s.Font, $rect, $cor, $flags)

    $pen.Dispose(); $br.Dispose(); $caminho.Dispose()
}

function New-ToolButton {
    param($Pai, [string]$Texto, [int]$X, [int]$Y, [int]$W, [int]$H = 32, $Cor = $null, $AoClicar = $null, [string]$Dica = "")
    if ($null -eq $Cor) { $Cor = $Script:UiAzul }
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Texto
    $b.Location = New-Object System.Drawing.Point($X, $Y)
    $b.Size = New-Object System.Drawing.Size($W, $H)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $Cor
    $b.ForeColor = 'White'
    $b.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.Tag = 'normal'
    $b.Add_MouseEnter({ $this.Tag = 'hover'; $this.Invalidate() })
    $b.Add_MouseLeave({ $this.Tag = 'normal'; $this.Invalidate() })
    $b.Add_MouseDown({ $this.Tag = 'down'; $this.Invalidate() })
    $b.Add_MouseUp({ $this.Tag = 'hover'; $this.Invalidate() })
    $b.Add_EnabledChanged({ $this.Invalidate() })
    $b.Add_Paint($Script:ModernBtnPaint)
    if ($AoClicar) { $b.Add_Click($AoClicar) }
    if ($Dica -and $Script:ToolTip) { $Script:ToolTip.SetToolTip($b, $Dica) }
    if ($Pai) { [void]$Pai.Controls.Add($b) }
    return $b
}

function New-ToolLabel {
    param($Pai, [string]$Texto, [int]$X, [int]$Y, [int]$Tamanho = 9, [switch]$Negrito, $Cor = $null, [int]$W = 0)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Texto
    $l.Location = New-Object System.Drawing.Point($X, $Y)
    if ($W -gt 0) { $l.Width = $W; $l.AutoSize = $false } else { $l.AutoSize = $true }
    $estilo = if ($Negrito) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $l.Font = New-Object System.Drawing.Font("Segoe UI", $Tamanho, $estilo)
    $l.ForeColor = if ($Cor) { $Cor } else { $Script:UiTexto }
    $l.BackColor = [System.Drawing.Color]::Transparent
    if ($Pai) { [void]$Pai.Controls.Add($l) }
    return $l
}

# Medidor (CPU / RAM / disco): titulo, valor grande e barra arredondada
$Script:GaugePaint = {
    param($s, $e)
    $w = $s.Width; $h = $s.Height
    if ($w -le 10 -or $h -le 10) { return }
    $d = $s.Tag
    if ($null -eq $d) { return }
    $g = $e.Graphics
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    $cartao = New-RoundedRectPath -X 0 -Y 0 -W $w -H $h -R 8
    $bCartao = New-Object System.Drawing.SolidBrush($Script:UiCartao)
    $g.Clear($s.Parent.BackColor)
    $g.FillPath($bCartao, $cartao)
    $bCartao.Dispose()

    $rTitulo = New-Object System.Drawing.Rectangle(14, 10, ($w - 28), 18)
    $fTitulo = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $d.Titulo, $fTitulo, $rTitulo, $Script:UiSuave,
        ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))

    $rValor = New-Object System.Drawing.Rectangle(14, 26, ($w - 28), 30)
    $fValor = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
    [System.Windows.Forms.TextRenderer]::DrawText($g, $d.Texto, $fValor, $rValor, $Script:UiTexto,
        ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))

    # Barra
    $bx = 14; $bw = $w - 28; $bh = 8; $by = $h - 26
    if ($bw -gt 10) {
        $trilho = New-RoundedRectPath -X $bx -Y $by -W $bw -H $bh -R 4
        $bTrilho = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 24, 34))
        $g.FillPath($bTrilho, $trilho)
        $pct = [Math]::Max(0, [Math]::Min(100, [double]$d.Valor))
        $fw = [int]($bw * $pct / 100)
        if ($fw -gt 3) {
            $cor = $d.Cor
            $rFill = New-Object System.Drawing.Rectangle($bx, $by, $fw, $bh)
            $preenche = New-RoundedRectPath -X $bx -Y $by -W $fw -H $bh -R 4
            $bFill = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rFill, (Get-UiTom $cor 30), $cor, [float]0)
            $g.FillPath($bFill, $preenche)
            $bFill.Dispose(); $preenche.Dispose()
        }
        $bTrilho.Dispose(); $trilho.Dispose()
    }

    # Legenda embaixo
    if ($d.Legenda) {
        $rLeg = New-Object System.Drawing.Rectangle(14, ($h - 16), ($w - 28), 14)
        $fLeg = New-Object System.Drawing.Font("Segoe UI", 8)
        [System.Windows.Forms.TextRenderer]::DrawText($g, $d.Legenda, $fLeg, $rLeg, $Script:UiSuave,
            ([System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
        $fLeg.Dispose()
    }
    $fTitulo.Dispose(); $fValor.Dispose(); $cartao.Dispose()
}

function New-Gauge {
    param($Pai, [string]$Titulo, [int]$X, [int]$Y, [int]$W = 180, [int]$H = 92, $Cor = $null)
    $p = New-Object System.Windows.Forms.Panel
    $p.Location = New-Object System.Drawing.Point($X, $Y)
    $p.Size = New-Object System.Drawing.Size($W, $H)
    $p.BackColor = $Script:UiFundo
    $p.Tag = @{ Titulo = $Titulo; Texto = "--"; Valor = 0; Legenda = ""; Cor = $(if ($Cor) { $Cor } else { $Script:UiAzul }) }
    $p.Add_Paint($Script:GaugePaint)
    if ($Pai) { [void]$Pai.Controls.Add($p) }
    return $p
}

function Update-Gauge {
    param($Gauge, [double]$Valor, [string]$Texto, [string]$Legenda = "", $Cor = $null)
    if ($null -eq $Gauge -or $Gauge.IsDisposed) { return }
    $d = $Gauge.Tag
    $d.Valor = $Valor
    $d.Texto = $Texto
    $d.Legenda = $Legenda
    if ($Cor) { $d.Cor = $Cor }
    $Gauge.Invalidate()
}

function Get-CorPorUso {
    param([double]$Pct)
    if ($Pct -ge 90) { return $Script:UiVermelho }
    if ($Pct -ge 70) { return $Script:UiAmarelo }
    return $Script:UiVerde
}

function Format-ToolListView {
    param($LV)
    $LV.View = 'Details'
    $LV.FullRowSelect = $true
    $LV.GridLines = $false
    $LV.HideSelection = $false
    $LV.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
    $LV.ForeColor = $Script:UiTexto
    $LV.BorderStyle = 'None'
    $LV.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
}

# -----------------------------------------------------------------------------
# MONITOR DE CPU E MEMORIA
# -----------------------------------------------------------------------------
function Show-ResourceMonitor {
    try {
        if ($null -ne $Script:MonForm -and -not $Script:MonForm.IsDisposed) {
            $Script:MonForm.Activate(); return
        }

        $Script:MonAnterior = @{}
        $Script:MonUltimaHora = $null
        $Script:MonNucleos = [Math]::Max(1, [int]$env:NUMBER_OF_PROCESSORS)

        $f = New-ToolForm "Monitor de Recursos" 760 620
        $Script:MonForm = $f

        New-ToolLabel $f "USO DO SISTEMA EM TEMPO REAL" 20 16 12 -Negrito | Out-Null
        $lblUptime = New-ToolLabel $f "" 20 40 8.5 -Cor $Script:UiSuave

        $gCpu = New-Gauge $f "CPU" 20 66 225 92 $Script:UiAzul
        $gRam = New-Gauge $f "MEMORIA RAM" 257 66 225 92 $Script:UiVerde
        $gDisco = New-Gauge $f "DISCO C:" 494 66 225 92 $Script:UiAmarelo

        New-ToolLabel $f "PROCESSOS QUE MAIS CONSOMEM" 20 174 10 -Negrito | Out-Null
        $lblStat = New-ToolLabel $f "" 300 176 8.5 -Cor $Script:UiSuave

        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(20, 200)
        $lv.Size = New-Object System.Drawing.Size(699, 320)
        $lv.Anchor = 'Top,Left,Right,Bottom'
        Format-ToolListView $lv
        [void]$lv.Columns.Add("Processo", 215)
        [void]$lv.Columns.Add("CPU %", 70)
        [void]$lv.Columns.Add("Memoria", 100)
        [void]$lv.Columns.Add("PID", 65)
        [void]$lv.Columns.Add("Descricao", 178)
        [void]$f.Controls.Add($lv)

        $Script:MonPausado = $false

        $atualizar = {
            try {
                $agora = Get-Date
                $procs = Get-Process -ErrorAction SilentlyContinue
                $atual = @{}
                $linhas = @()
                $somaCpu = 0.0

                $dt = 0
                if ($null -ne $Script:MonUltimaHora) { $dt = ($agora - $Script:MonUltimaHora).TotalSeconds }

                foreach ($p in $procs) {
                    $seg = 0.0
                    try { $seg = $p.TotalProcessorTime.TotalSeconds } catch { continue }
                    $atual[$p.Id] = $seg

                    $pct = 0.0
                    if ($dt -gt 0.2 -and $Script:MonAnterior.ContainsKey($p.Id)) {
                        $delta = $seg - $Script:MonAnterior[$p.Id]
                        if ($delta -gt 0) { $pct = ($delta / $dt) / $Script:MonNucleos * 100 }
                    }
                    $somaCpu += $pct

                    $desc = ""
                    try { if ($p.Description) { $desc = $p.Description } } catch {}
                    $linhas += [PSCustomObject]@{
                        Nome = $p.ProcessName
                        Cpu  = $pct
                        Ram  = $p.WorkingSet64
                        Pid  = $p.Id
                        Desc = $desc
                    }
                }
                $Script:MonAnterior = $atual
                $Script:MonUltimaHora = $agora

                # Ordena por CPU e, em empate, por memoria
                $top = $linhas | Sort-Object -Property @{Expression = 'Cpu'; Descending = $true }, @{Expression = 'Ram'; Descending = $true } | Select-Object -First 18

                $selecionado = if ($lv.SelectedItems.Count -gt 0) { $lv.SelectedItems[0].SubItems[3].Text } else { "" }
                $lv.BeginUpdate()
                $lv.Items.Clear()
                foreach ($l in $top) {
                    $item = New-Object System.Windows.Forms.ListViewItem($l.Nome)
                    [void]$item.SubItems.Add(("{0:N1}" -f $l.Cpu))
                    [void]$item.SubItems.Add(("{0:N1} MB" -f ($l.Ram / 1MB)))
                    [void]$item.SubItems.Add([string]$l.Pid)
                    [void]$item.SubItems.Add($l.Desc)
                    if ($l.Cpu -ge 25) { $item.ForeColor = $Script:UiVermelho }
                    elseif ($l.Cpu -ge 10) { $item.ForeColor = $Script:UiAmarelo }
                    elseif ($l.Ram -ge 800MB) { $item.ForeColor = $Script:UiAmarelo }
                    if ([string]$l.Pid -eq $selecionado) { $item.Selected = $true }
                    [void]$lv.Items.Add($item)
                }
                $lv.EndUpdate()

                # Medidores. Na primeira leitura ainda nao ha base de comparacao
                # para calcular o uso de CPU (precisa de duas amostras).
                if ($dt -le 0.2) {
                    Update-Gauge $gCpu 0 "medindo..." "$($Script:MonNucleos) nucleos logicos" $Script:UiAzul
                }
                else {
                    $cpuPct = [Math]::Min(100, $somaCpu)
                    Update-Gauge $gCpu $cpuPct ("{0:N0} %" -f $cpuPct) "$($Script:MonNucleos) nucleos logicos" (Get-CorPorUso $cpuPct)
                }

                $osi = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
                if ($osi) {
                    $ramTotal = $osi.TotalVisibleMemorySize / 1MB
                    $ramLivre = $osi.FreePhysicalMemory / 1MB
                    $ramUso = $ramTotal - $ramLivre
                    $ramPct = if ($ramTotal -gt 0) { $ramUso / $ramTotal * 100 } else { 0 }
                    Update-Gauge $gRam $ramPct ("{0:N0} %" -f $ramPct) ("{0:N1} de {1:N1} GB em uso" -f $ramUso, $ramTotal) (Get-CorPorUso $ramPct)

                    try {
                        $up = $agora - $osi.LastBootUpTime
                        $lblUptime.Text = "Ligado ha $([int]$up.TotalDays)d $($up.Hours)h $($up.Minutes)min   |   $env:COMPUTERNAME"
                    }
                    catch {}
                }

                $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
                if ($disco -and $disco.Size -gt 0) {
                    $usado = ($disco.Size - $disco.FreeSpace) / 1GB
                    $totalD = $disco.Size / 1GB
                    $dPct = $usado / $totalD * 100
                    Update-Gauge $gDisco $dPct ("{0:N0} %" -f $dPct) ("{0:N0} GB livres de {1:N0} GB" -f ($disco.FreeSpace / 1GB), $totalD) (Get-CorPorUso $dPct)
                }

                $lblStat.Text = "$($procs.Count) processos  -  atualizado $(Get-Date -Format 'HH:mm:ss')"
            }
            catch {
                $lblStat.Text = "Falha ao ler: $($_.Exception.Message)"
            }
        }

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 2000
        $timer.Add_Tick($atualizar)

        $btnPausar = New-ToolButton $f "PAUSAR" 20 536 130 34 $Script:UiCinza $null "Congela a atualizacao automatica"
        $btnPausar.Anchor = 'Bottom,Left'
        $btnPausar.Add_Click({
                if ($timer.Enabled) { $timer.Stop(); $btnPausar.Text = "CONTINUAR"; $btnPausar.BackColor = $Script:UiVerde }
                else { $timer.Start(); $btnPausar.Text = "PAUSAR"; $btnPausar.BackColor = $Script:UiCinza }
                $btnPausar.Invalidate()
            })

        $btnAgora = New-ToolButton $f "ATUALIZAR AGORA" 160 536 170 34 $Script:UiAzul $atualizar
        $btnAgora.Anchor = 'Bottom,Left'

        $btnMatar = New-ToolButton $f "ENCERRAR PROCESSO" 340 536 190 34 $Script:UiVermelho $null "Finaliza o processo selecionado na lista"
        $btnMatar.Anchor = 'Bottom,Left'
        $btnMatar.Add_Click({
                if ($lv.SelectedItems.Count -eq 0) {
                    [System.Windows.Forms.MessageBox]::Show("Selecione um processo na lista primeiro.", "Encerrar processo", "OK", "Information") | Out-Null
                    return
                }
                $nome = $lv.SelectedItems[0].Text
                $procId = [int]$lv.SelectedItems[0].SubItems[3].Text
                $r = [System.Windows.Forms.MessageBox]::Show("Encerrar '$nome' (PID $procId)?`n`nTrabalhos nao salvos desse programa serao perdidos.",
                    "Confirmar", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Stop-Process -Id $procId -Force -ErrorAction Stop
                        Log-Message "INFO" "Processo encerrado: $nome (PID $procId)"
                        & $atualizar
                    }
                    catch {
                        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel encerrar: $($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
                    }
                }
            })

        $btnTarefas = New-ToolButton $f "GERENCIADOR DE TAREFAS" 540 536 179 34 $Script:UiCinza { Start-Process taskmgr.exe }
        $btnTarefas.Anchor = 'Bottom,Right'

        $f.Add_FormClosing({
                try { $timer.Stop(); $timer.Dispose() } catch {}
                $Script:MonForm = $null
            })

        & $atualizar
        $timer.Start()
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch { Log-Message "ERRO" "Monitor falhou: $_" }
}

# -----------------------------------------------------------------------------
# AVALIACAO DE HARDWARE
# -----------------------------------------------------------------------------
function Show-SystemInfo {
    Log-Message "INFO" "Iniciando Avaliacao de Hardware..."
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
        $drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
        $video = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Select-Object -First 1

        $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $diskGB = [Math]::Round($drive.Size / 1GB, 1)
        $freeGB = [Math]::Round($drive.FreeSpace / 1GB, 1)
        $cpuName = $cpu.Name.Trim()
        $nucleos = "$($cpu.NumberOfCores) nucleos / $($cpu.NumberOfLogicalProcessors) threads"

        # Tipo de disco onde fica o C: (SSD x HD mecanico)
        $tipoDisco = "Nao identificado"
        try {
            $fisico = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.MediaType -and $_.MediaType -ne 'Unspecified' } | Select-Object -First 1
            if ($fisico) { $tipoDisco = [string]$fisico.MediaType }
        }
        catch {}
        $ehSSD = ($tipoDisco -match 'SSD')

        # Memoria: velocidade e pentes usados
        $pentes = @()
        try { $pentes = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) } catch {}
        $ramDetalhe = "$ramGB GB"
        if ($pentes.Count -gt 0) {
            $vel = ($pentes | Where-Object { $_.Speed } | Select-Object -First 1).Speed
            $ramDetalhe = "$ramGB GB  -  $($pentes.Count) pente(s)"
            if ($vel) { $ramDetalhe += " a $vel MHz" }
        }

        # Rede: adaptador ativo e velocidade do link
        $redeInfo = "Sem conexao identificada"
        try {
            $ad = Get-CimInstance Win32_NetworkAdapter -Filter "NetEnabled=True" -ErrorAction Stop |
                Where-Object { $_.PhysicalAdapter -and $_.Speed } | Sort-Object Speed -Descending | Select-Object -First 1
            if ($ad) { $redeInfo = "$($ad.Name)  -  $([Math]::Round($ad.Speed / 1MB)) Mbps" }
        }
        catch {}

        # Antivirus ativo (util para saber quem pode estar bloqueando instalacao)
        $antivirus = "Nao identificado"
        try {
            $avs = @(Get-CimInstance -Namespace "root\SecurityCenter2" -ClassName AntiVirusProduct -ErrorAction Stop)
            if ($avs.Count -gt 0) { $antivirus = ($avs | ForEach-Object { $_.displayName }) -join ", " }
        }
        catch {}

        $benchTable = @{
            "AMD Ryzen 3 3200GE"  = 7309
            "AMD Ryzen 3 3200G"   = 7131
            "Intel Core i5-8500"  = 9548
            "Intel Core i5-8400"  = 9205
            "Intel Core i3-10100" = 8645
        }
        $score = "Nao catalogado"
        foreach ($key in $benchTable.Keys) {
            if ($cpuName -match [regex]::Escape($key)) { $score = $benchTable[$key]; break }
        }

        $passRAM = $ramGB -ge 15.5
        $passDisk = $diskGB -ge 210
        $passLivre = $freeGB -ge 20
        $passOS = $os.Caption -match "Windows 10|Windows 11"
        $passBench = if ($score -is [int]) { $score -ge 3500 } else { $true }

        $cleanCpu = $cpuName -replace '\s+', '+'
        $benchUrl = "https://www.cpubenchmark.net/cpu.php?cpu=$cleanCpu"

        $f = New-ToolForm "Avaliacao de Hardware" 700 720
        $f.MaximizeBox = $false

        New-ToolLabel $f "RELATORIO DE COMPATIBILIDADE" 22 16 13 -Negrito | Out-Null
        New-ToolLabel $f "$($cs.Manufacturer) $($cs.Model)   |   Serie: $(if ($bios) { $bios.SerialNumber } else { '-' })" 22 42 8.5 -Cor $Script:UiSuave | Out-Null

        # Resumo geral no topo
        $reprovados = @()
        if (-not $passRAM) { $reprovados += "RAM" }
        if (-not $passDisk) { $reprovados += "tamanho do disco" }
        if (-not $passLivre) { $reprovados += "espaco livre" }
        if (-not $passOS) { $reprovados += "versao do Windows" }
        if (-not $passBench) { $reprovados += "desempenho da CPU" }
        if (-not $ehSSD -and $tipoDisco -ne "Nao identificado") { $reprovados += "disco nao e SSD" }

        $resumoOk = ($reprovados.Count -eq 0)
        $pnlResumo = New-Object System.Windows.Forms.Panel
        $pnlResumo.Location = New-Object System.Drawing.Point(20, 66)
        $pnlResumo.Size = New-Object System.Drawing.Size(645, 56)
        $pnlResumo.BackColor = $Script:UiFundo
        $pnlResumo.Tag = @{
            Ok    = $resumoOk
            Texto = $(if ($resumoOk) { "MAQUINA APROVADA PARA O SISTEMA" } else { "ATENCAO: " + (($reprovados) -join ", ") })
        }
        $pnlResumo.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.Clear($s.Parent.BackColor)
                $d = $s.Tag
                $c1 = if ($d.Ok) { $Script:UiVerde } else { $Script:UiVermelho }
                $rect = New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)
                $caminho = New-RoundedRectPath -X 0 -Y 0 -W $s.Width -H $s.Height -R 8
                $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, (Get-UiTom $c1 18), (Get-UiTom $c1 -28), [float]0)
                $g.FillPath($br, $caminho)
                $fw = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
                $icone = if ($d.Ok) { [string][char]0x2714 } else { "!" }
                [System.Windows.Forms.TextRenderer]::DrawText($g, "$icone  $($d.Texto)", $fw, $rect, [System.Drawing.Color]::White,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::EndEllipsis))
                $fw.Dispose(); $br.Dispose(); $caminho.Dispose()
            })
        [void]$f.Controls.Add($pnlResumo)

        # Lista de itens avaliados
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(20, 136)
        $lv.Size = New-Object System.Drawing.Size(645, 430)
        Format-ToolListView $lv
        [void]$lv.Columns.Add("Item", 170)
        [void]$lv.Columns.Add("Valor encontrado", 390)
        [void]$lv.Columns.Add("Status", 80)
        [void]$f.Controls.Add($lv)

        $addItem = {
            param([string]$Item, [string]$Valor, $Pass)
            $it = New-Object System.Windows.Forms.ListViewItem($Item)
            [void]$it.SubItems.Add($Valor)
            if ($null -eq $Pass) {
                [void]$it.SubItems.Add("-")
                $it.ForeColor = $Script:UiTexto
            }
            elseif ($Pass) {
                [void]$it.SubItems.Add("OK")
                $it.ForeColor = $Script:UiVerde
            }
            else {
                [void]$it.SubItems.Add("ATENCAO")
                $it.ForeColor = $Script:UiVermelho
            }
            [void]$lv.Items.Add($it)
        }

        & $addItem "Sistema Operacional" "$($os.Caption) (build $($os.BuildNumber))" $passOS
        & $addItem "Arquitetura" "$($os.OSArchitecture)" $null
        & $addItem "Processador" $cpuName $passBench
        & $addItem "Nucleos" $nucleos $null
        & $addItem "Benchmark estimado" $(if ($score -is [int]) { "$score  (minimo recomendado: 3500)" } else { "$score  -  use o botao BENCHMARK ONLINE para consultar" }) $(if ($score -is [int]) { $passBench } else { $null })
        & $addItem "Memoria RAM" $ramDetalhe $passRAM
        & $addItem "Disco C: capacidade" "$diskGB GB" $passDisk
        & $addItem "Disco C: espaco livre" "$freeGB GB" $passLivre
        & $addItem "Tipo de disco" $tipoDisco $(if ($tipoDisco -eq "Nao identificado") { $null } else { $ehSSD })
        & $addItem "Placa de video" $(if ($video) { $video.Name } else { "-" }) $null
        & $addItem "Rede" $redeInfo $null
        & $addItem "Antivirus" $antivirus $null
        & $addItem "Fabricante / Modelo" "$($cs.Manufacturer) $($cs.Model)" $null
        & $addItem "Numero de serie" $(if ($bios) { $bios.SerialNumber } else { "-" }) $null
        & $addItem "Usuario / Maquina" "$env:USERNAME @ $env:COMPUTERNAME" $null

        $marca = { param($ok) if ($ok) { [string][char]0x2714 } else { "X" } }
        $relatorio = @"
=== AVALIACAO DE HARDWARE - $env:COMPUTERNAME ===
Data: $(Get-Date -Format 'dd/MM/yyyy HH:mm')

Sistema:      $($os.Caption) (build $($os.BuildNumber)) $(& $marca $passOS)
Processador:  $cpuName $(& $marca $passBench)
              $nucleos
Benchmark:    $score  (minimo 3500) $(& $marca $passBench)
Memoria RAM:  $ramDetalhe $(& $marca $passRAM)
Disco C:      $diskGB GB, $freeGB GB livres $(& $marca $passDisk)
Tipo:         $tipoDisco $(& $marca $ehSSD)
Video:        $(if ($video) { $video.Name } else { '-' })
Rede:         $redeInfo
Antivirus:    $antivirus
Maquina:      $($cs.Manufacturer) $($cs.Model)  -  Serie: $(if ($bios) { $bios.SerialNumber } else { '-' })

Resultado: $(if ($resumoOk) { 'APROVADA' } else { 'ATENCAO - ' + ($reprovados -join ', ') })
Benchmark online: $benchUrl
"@
        Set-Clipboard -Value $relatorio

        $lblCopia = New-ToolLabel $f "Relatorio ja copiado para a area de transferencia." 22 578 8.5 -Cor $Script:UiSuave

        New-ToolButton $f "COPIAR RELATORIO" 20 604 200 38 $Script:UiAzul {
            Set-Clipboard -Value $relatorio
            $lblCopia.Text = "Copiado! Pode colar no chamado (Ctrl+V)."
            $lblCopia.ForeColor = $Script:UiVerde
        } "Copia o relatorio completo em texto" | Out-Null

        New-ToolButton $f "SALVAR EM TXT" 230 604 190 38 $Script:UiCinza {
            try {
                $caminho = Join-Path $Script:DesktopPath "Avaliacao_$($env:COMPUTERNAME)_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
                $relatorio | Out-File $caminho -Encoding utf8
                $lblCopia.Text = "Salvo em: $caminho"
                $lblCopia.ForeColor = $Script:UiVerde
                Log-Message "SUCESSO" "Relatorio salvo: $caminho"
            }
            catch {
                $lblCopia.Text = "Falha ao salvar: $($_.Exception.Message)"
                $lblCopia.ForeColor = $Script:UiVermelho
            }
        } "Grava o relatorio na Area de Trabalho" | Out-Null

        New-ToolButton $f "BENCHMARK ONLINE" 430 604 235 38 $Script:UiCinza {
            Start-Process $benchUrl
        } "Abre a pontuacao desta CPU no cpubenchmark.net" | Out-Null

        [void]$f.ShowDialog($Script:MainForm)
        Log-Message "SUCESSO" "Avaliacao concluida e copiada."
    }
    catch {
        Log-Message "ERRO" "Falha na avaliacao: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha ao avaliar o hardware: $($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}

function Get-MacDeIP {
    param($IP, $ArpTable)
    try {
        $tabela = if ($null -ne $ArpTable) { $ArpTable } else { arp -a }
        foreach ($linha in $tabela) {
            if ($linha -match "^\s+$([regex]::Escape($IP))\s+([0-9a-fA-F-]{11,17})") {
                return $matches[1].Replace('-', ':').ToUpper()
            }
        }
    }
    catch {}
    return ""
}

function Get-VendorName {
    param($IP, $ArpTable, $Mac = $null)
    try {
        $macAddr = if ($Mac) { $Mac } else { Get-MacDeIP $IP $ArpTable }
        if ($macAddr -match '([0-9a-fA-F:]{17})') {
            $oui = $macAddr.Substring(0, 8)
            $vendors = @{
                "00:26:AB" = "EPSON"; "00:00:48" = "EPSON"; "FC:BA:B1" = "EPSON"
                "64:EB:8C" = "EPSON"; "A4:EE:57" = "EPSON"
                "00:0B:AB" = "ELGIN"; "00:00:5E" = "ELGIN"; "00:0B:E0" = "DIEXA"
                "00:13:21" = "BEMATECH"; "00:21:40" = "BEMATECH"; "00:1A:C5" = "BEMATECH"
                "00:1C:18" = "DARUMA"; "00:1E:E3" = "TANCA"; "00:0E:8F" = "SWEDA"
                "00:50:C2" = "CONTROL ID"; "FC:1A:11" = "CONTROL ID"; "00:1F:54" = "GERTEC"
                "00:07:4D" = "ZEBRA"; "00:05:9A" = "ZEBRA"; "8C:11:CB" = "ZEBRA"; "00:15:70" = "ZEBRA"
                "00:80:92" = "STAR"; "00:11:62" = "STAR"
                "00:11:0A" = "HP"; "00:1E:0B" = "HP"; "30:8D:99" = "HP"; "3C:D9:2B" = "HP"
                "00:15:99" = "SAMSUNG"; "00:00:F0" = "SAMSUNG"; "00:00:85" = "CANON"; "00:1E:8F" = "CANON"
                "00:00:74" = "RICOH"; "00:26:73" = "RICOH"; "00:20:00" = "LEXMARK"; "00:04:00" = "LEXMARK"
                "00:80:77" = "BROTHER"; "00:1B:A9" = "BROTHER"; "00:0B:78" = "XPRINTER"
                "00:21:29" = "TP-LINK"; "B0:4E:26" = "TP-LINK"; "50:C7:BF" = "TP-LINK"; "00:1D:AA" = "D-LINK"
                "00:22:3F" = "NETGEAR"; "C8:3A:35" = "TENDA"; "E0:43:DB" = "VIVO"; "00:1A:3F" = "INTELBRAS"
                "E8:94:F6" = "INTELBRAS"; "00:16:6C" = "SAMSUNG"; "00:1D:7E" = "CISCO"; "00:0C:29" = "VMWARE"
                "08:00:27" = "VIRTUALBOX"; "00:15:5D" = "HYPER-V"; "00:50:56" = "VMWARE"
                "3C:2A:F4" = "BROTHER"; "9C:5A:44" = "MULTILASER"; "00:1F:3B" = "INTEL"
                "DC:A6:32" = "RASPBERRY PI"; "B8:27:EB" = "RASPBERRY PI"
            }
            if ($vendors.ContainsKey($oui)) { return $vendors[$oui] }
        }
        return "Desconhecido"
    }
    catch { return "Desconhecido" }
}

# Testa varias portas ao mesmo tempo (bem mais rapido que uma de cada vez)
function Test-PortasRapido {
    param([string]$IP, [int[]]$Portas, [int]$TimeoutMs = 260)
    $abertas = @()
    $conexoes = @()
    try {
        $end = [System.Net.IPAddress]::Parse($IP)
        foreach ($p in $Portas) {
            $cli = New-Object System.Net.Sockets.TcpClient
            try { $conexoes += [PSCustomObject]@{ Porta = $p; Cliente = $cli; Async = $cli.BeginConnect($end, $p, $null, $null) } }
            catch { try { $cli.Close() } catch {} }
        }
        Start-Sleep -Milliseconds $TimeoutMs
        foreach ($c in $conexoes) {
            try {
                if ($c.Async.IsCompleted -and $c.Cliente.Connected) { $abertas += $c.Porta }
            }
            catch {}
            try { $c.Cliente.Close() } catch {}
        }
    }
    catch {}
    return ($abertas | Sort-Object)
}

function Get-NomePorta {
    param([int]$Porta)
    switch ($Porta) {
        9100 { "RAW/JetDirect" }
        515 { "LPR" }
        631 { "IPP" }
        80 { "HTTP" }
        443 { "HTTPS" }
        445 { "SMB" }
        135 { "RPC" }
        139 { "NetBIOS" }
        3389 { "RDP" }
        22 { "SSH" }
        1433 { "SQL Server" }
        default { "$Porta" }
    }
}

function Show-PrinterScanner {
    try {
        if ($null -ne $Script:ScannerForm -and -not $Script:ScannerForm.IsDisposed) {
            $Script:ScannerForm.Activate(); return
        }

        $f = New-ToolForm "Scanner de Rede" 940 660
        $Script:ScannerForm = $f
        $Script:ScannerTodos = @()
        $Script:ScannerParar = $false

        New-ToolLabel $f "DISPOSITIVOS NA REDE LOCAL" 20 14 12 -Negrito | Out-Null
        $lblRede = New-ToolLabel $f "" 20 38 8.5 -Cor $Script:UiSuave

        $btnScan = New-ToolButton $f "INICIAR SCAN" 20 64 150 34 $Script:UiAzul $null "Procura todos os equipamentos ligados na rede"
        $btnParar = New-ToolButton $f "PARAR" 178 64 90 34 $Script:UiVermelho $null "Interrompe a busca"
        $btnParar.Enabled = $false

        $lblFiltro = New-ToolLabel $f "Filtrar:" 286 72 9 -Cor $Script:UiSuave
        $txtFiltro = New-Object System.Windows.Forms.TextBox
        $txtFiltro.Location = New-Object System.Drawing.Point(336, 69)
        $txtFiltro.Size = New-Object System.Drawing.Size(180, 24)
        $txtFiltro.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
        $txtFiltro.ForeColor = $Script:UiTexto
        $txtFiltro.BorderStyle = 'FixedSingle'
        [void]$f.Controls.Add($txtFiltro)
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($txtFiltro, "Digite IP, fabricante, nome ou tipo para filtrar a lista") }

        $chkSoImp = New-Object System.Windows.Forms.CheckBox
        $chkSoImp.Text = "Somente impressoras"
        $chkSoImp.Location = New-Object System.Drawing.Point(528, 70)
        $chkSoImp.AutoSize = $true
        $chkSoImp.ForeColor = $Script:UiTexto
        [void]$f.Controls.Add($chkSoImp)

        $lblStat = New-ToolLabel $f "Pronto para escanear." 700 72 9 -Cor $Script:UiSuave

        $barra = New-Object System.Windows.Forms.Panel
        $barra.Location = New-Object System.Drawing.Point(20, 106)
        $barra.Size = New-Object System.Drawing.Size(880, 8)
        $barra.Anchor = 'Top,Left,Right'
        $barra.BackColor = $Script:UiFundo
        $barra.Tag = @{ Valor = 0 }
        $barra.Add_Paint({
                param($s, $e)
                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                $g.Clear($s.Parent.BackColor)
                $trilho = New-RoundedRectPath -X 0 -Y 0 -W $s.Width -H $s.Height -R 4
                $bt = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(20, 24, 34))
                $g.FillPath($bt, $trilho)
                $pct = [double]$s.Tag.Valor
                $fw = [int]($s.Width * $pct / 100)
                if ($fw -gt 3) {
                    $r = New-Object System.Drawing.Rectangle(0, 0, $fw, $s.Height)
                    $p = New-RoundedRectPath -X 0 -Y 0 -W $fw -H $s.Height -R 4
                    $b = New-Object System.Drawing.Drawing2D.LinearGradientBrush($r, [System.Drawing.Color]::FromArgb(28, 116, 232), [System.Drawing.Color]::FromArgb(0, 208, 158), [float]0)
                    $g.FillPath($b, $p)
                    $b.Dispose(); $p.Dispose()
                }
                $bt.Dispose(); $trilho.Dispose()
            })
        [void]$f.Controls.Add($barra)

        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(20, 124)
        $lv.Size = New-Object System.Drawing.Size(880, 430)
        $lv.Anchor = 'Top,Left,Right,Bottom'
        Format-ToolListView $lv
        [void]$lv.Columns.Add("IP", 120)
        [void]$lv.Columns.Add("Tipo", 150)
        [void]$lv.Columns.Add("Fabricante", 120)
        [void]$lv.Columns.Add("Nome / Host", 180)
        [void]$lv.Columns.Add("MAC", 140)
        [void]$lv.Columns.Add("Servicos", 160)
        [void]$f.Controls.Add($lv)

        # --- menu do botao direito ---
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $menu.BackColor = $Script:UiCartao
        $menu.ForeColor = $Script:UiTexto
        $ipSelecionado = {
            if ($lv.SelectedItems.Count -gt 0) { return $lv.SelectedItems[0].Text }
            return ""
        }
        [void]$menu.Items.Add("Testar ping continuo", $null, {
                $ip = & $ipSelecionado
                if ($ip) { Show-PingTester -InitialIP $ip }
            })
        [void]$menu.Items.Add("Abrir no navegador (http)", $null, {
                $ip = & $ipSelecionado
                if ($ip) { Start-Process "http://$ip" }
            })
        [void]$menu.Items.Add("Abrir compartilhamentos", $null, {
                $ip = & $ipSelecionado
                if ($ip) { Start-Process "explorer.exe" "\\$ip" }
            })
        [void]$menu.Items.Add("Copiar IP", $null, {
                $ip = & $ipSelecionado
                if ($ip) { Set-Clipboard -Value $ip }
            })
        [void]$menu.Items.Add("Copiar linha inteira", $null, {
                if ($lv.SelectedItems.Count -gt 0) {
                    $it = $lv.SelectedItems[0]
                    $partes = @()
                    foreach ($si in $it.SubItems) { $partes += $si.Text }
                    Set-Clipboard -Value ($partes -join "  |  ")
                }
            })
        [void]$menu.Items.Add("Adicionar impressora de rede (Windows)", $null, {
                Start-Process "rundll32.exe" "printui.dll,PrintUIEntry /il"
            })
        $lv.ContextMenuStrip = $menu

        # --- filtro e ordenacao ---
        $aplicarFiltro = {
            $termo = $txtFiltro.Text.Trim().ToLower()
            $soImp = $chkSoImp.Checked
            $lv.BeginUpdate()
            $lv.Items.Clear()
            foreach ($d in $Script:ScannerTodos) {
                if ($soImp -and $d.Tipo -ne "IMPRESSORA") { continue }
                if ($termo) {
                    $alvo = "$($d.IP) $($d.Tipo) $($d.Fabricante) $($d.Host) $($d.Mac) $($d.Servicos)".ToLower()
                    if ($alvo -notlike "*$termo*") { continue }
                }
                $it = New-Object System.Windows.Forms.ListViewItem($d.IP)
                [void]$it.SubItems.Add($d.Tipo)
                [void]$it.SubItems.Add($d.Fabricante)
                [void]$it.SubItems.Add($d.Host)
                [void]$it.SubItems.Add($d.Mac)
                [void]$it.SubItems.Add($d.Servicos)
                switch ($d.Tipo) {
                    "MAQUINA ATUAL" { $it.ForeColor = [System.Drawing.Color]::Gold }
                    "IMPRESSORA" { $it.ForeColor = $Script:UiVerde }
                    "ROTEADOR (GATEWAY)" { $it.ForeColor = [System.Drawing.Color]::LightSkyBlue }
                    "ROTEADOR/DISP. WEB" { $it.ForeColor = [System.Drawing.Color]::LightSkyBlue }
                    "COMPUTADOR" { $it.ForeColor = [System.Drawing.Color]::Wheat }
                    default { $it.ForeColor = $Script:UiTexto }
                }
                [void]$lv.Items.Add($it)
            }
            $lv.EndUpdate()
            $imp = @($Script:ScannerTodos | Where-Object { $_.Tipo -eq "IMPRESSORA" }).Count
            $lblStat.Text = "$($lv.Items.Count) de $($Script:ScannerTodos.Count) exibidos  -  $imp impressora(s)"
        }
        $txtFiltro.Add_TextChanged($aplicarFiltro)
        $chkSoImp.Add_CheckedChanged($aplicarFiltro)
        $lv.Add_DoubleClick({
                $ip = & $ipSelecionado
                if ($ip) { Show-PingTester -InitialIP $ip }
            })

        # --- o scan em si ---
        $btnScan.Add_Click({
                $btnScan.Enabled = $false; $btnScan.Text = "ESCANEANDO..."
                $btnParar.Enabled = $true
                $Script:ScannerParar = $false
                $Script:ScannerTodos = @()
                $lv.Items.Clear()
                $barra.Tag.Valor = 0; $barra.Invalidate()
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    $meusIps = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
                    $localIP = $meusIps[0]

                    $gwIP = $null
                    try {
                        $cfg = Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway } | Select-Object -First 1
                        if ($cfg) { $gwIP = $cfg.IPv4DefaultGateway.NextHop }
                    }
                    catch {}

                    if ($localIP -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.') {
                        $subnet = $matches[1]
                        $lblRede.Text = "Rede $subnet.0/24   |   Este PC: $localIP   |   Gateway: $(if ($gwIP) { $gwIP } else { '-' })"
                        $lblStat.Text = "Acordando a rede..."
                        [System.Windows.Forms.Application]::DoEvents()

                        # Dispara pings em massa para popular a tabela ARP
                        $ping = New-Object System.Net.NetworkInformation.Ping
                        foreach ($i in 1..254) {
                            try { [void]$ping.SendAsync("$subnet.$i", 90, $null) } catch {}
                            if ($i % 16 -eq 0) {
                                $barra.Tag.Valor = ($i / 254) * 35
                                $barra.Invalidate()
                                [System.Windows.Forms.Application]::DoEvents()
                                if ($Script:ScannerParar) { break }
                            }
                        }
                        Start-Sleep -Milliseconds 1800
                    }

                    $arp = arp -a
                    $ips = @()
                    foreach ($linha in $arp) {
                        if ($linha -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F-]{11,17})') {
                            $fIP = $matches[1]
                            if ($fIP -notlike "224.*" -and $fIP -notlike "239.*" -and $fIP -ne "255.255.255.255" -and $fIP -ne "0.0.0.0" -and $fIP -notlike "*.255") {
                                $ips += $fIP
                            }
                        }
                    }
                    foreach ($meu in $meusIps) { if ($ips -notcontains $meu) { $ips += $meu } }
                    $ips = @($ips | Select-Object -Unique | Sort-Object { [version]$_ })

                    if ($ips.Count -eq 0) {
                        $lblStat.Text = "Nenhum equipamento respondeu. Verifique o cabo/Wi-Fi."
                    }
                    else {
                        $portas = @(9100, 515, 631, 80, 443, 445, 135, 3389, 22, 1433)
                        $n = 0
                        foreach ($ip in $ips) {
                            if ($Script:ScannerParar) { break }
                            $n++
                            $lblStat.Text = "Identificando $ip  ($n de $($ips.Count))..."
                            $barra.Tag.Valor = 35 + (($n / $ips.Count) * 65)
                            $barra.Invalidate()
                            [System.Windows.Forms.Application]::DoEvents()

                            $host_ = ""
                            try { $host_ = [System.Net.Dns]::GetHostEntry($ip).HostName } catch { $host_ = "-" }
                            $mac = Get-MacDeIP $ip $arp
                            $fab = Get-VendorName $ip $arp $mac
                            $abertas = Test-PortasRapido -IP $ip -Portas $portas

                            $ehLocal = ($ip -in $meusIps)
                            $ehGw = ($null -ne $gwIP -and $ip -eq $gwIP)
                            $ehImp = ($abertas -contains 9100 -or $abertas -contains 515 -or $abertas -contains 631 -or
                                $fab -in @("EPSON", "ELGIN", "BEMATECH", "DARUMA", "TANCA", "ZEBRA", "STAR", "SWEDA", "GERTEC", "BROTHER", "XPRINTER", "LEXMARK", "RICOH", "CANON"))
                            $ehPC = ($abertas -contains 445 -or $abertas -contains 135 -or $abertas -contains 3389 -or $host_ -match "pc|note|desktop|laptop|workstation|server|caixa|pdv")
                            $ehWeb = ($abertas -contains 80 -or $abertas -contains 443)

                            $tipo = "Dispositivo"
                            if ($ehLocal) { $tipo = "MAQUINA ATUAL" }
                            elseif ($ehGw) { $tipo = "ROTEADOR (GATEWAY)" }
                            elseif ($ehImp) { $tipo = "IMPRESSORA" }
                            elseif ($ehPC) { $tipo = "COMPUTADOR" }
                            elseif ($ehWeb) { $tipo = "ROTEADOR/DISP. WEB" }

                            $servicos = (($abertas | ForEach-Object { Get-NomePorta $_ }) -join ", ")

                            $Script:ScannerTodos += [PSCustomObject]@{
                                IP         = $ip
                                Tipo       = $tipo
                                Fabricante = $fab
                                Host       = $host_
                                Mac        = $(if ($mac) { $mac } else { "-" })
                                Servicos   = $(if ($servicos) { $servicos } else { "-" })
                            }
                            & $aplicarFiltro
                        }
                        $barra.Tag.Valor = 100; $barra.Invalidate()
                        & $aplicarFiltro
                        $imp = @($Script:ScannerTodos | Where-Object { $_.Tipo -eq "IMPRESSORA" }).Count
                        Log-Message "INFO" "Scan de rede: $($Script:ScannerTodos.Count) equipamentos, $imp impressora(s)."
                    }
                }
                catch { $lblStat.Text = "Erro: $($_.Exception.Message)" }
                finally {
                    $btnScan.Enabled = $true; $btnScan.Text = "INICIAR SCAN"
                    $btnParar.Enabled = $false
                    $btnScan.Invalidate(); $btnParar.Invalidate()
                }
            })

        $btnParar.Add_Click({
                $Script:ScannerParar = $true
                $lblStat.Text = "Interrompendo..."
            })

        New-ToolButton $f "PING NO SELECIONADO" 20 566 200 34 $Script:UiCinza {
            if ($lv.SelectedItems.Count -gt 0) { Show-PingTester -InitialIP $lv.SelectedItems[0].Text }
            else { [System.Windows.Forms.MessageBox]::Show("Selecione um equipamento na lista.", "Ping", "OK", "Information") | Out-Null }
        } "Abre o teste de ping no equipamento selecionado" | Out-Null

        New-ToolButton $f "ABRIR NO NAVEGADOR" 230 566 190 34 $Script:UiCinza {
            if ($lv.SelectedItems.Count -gt 0) { Start-Process "http://$($lv.SelectedItems[0].Text)" }
        } "Abre a pagina de configuracao do equipamento" | Out-Null

        New-ToolButton $f "EXPORTAR CSV" 430 566 160 34 $Script:UiCinza {
            if ($Script:ScannerTodos.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Faca um scan antes de exportar.", "Exportar", "OK", "Information") | Out-Null
                return
            }
            try {
                $caminho = Join-Path $Script:DesktopPath "ScanRede_$(Get-Date -Format 'yyyyMMdd_HHmm').csv"
                $Script:ScannerTodos | Export-Csv -Path $caminho -NoTypeInformation -Encoding UTF8
                Log-Message "SUCESSO" "Scan exportado: $caminho"
                [System.Windows.Forms.MessageBox]::Show("Salvo em:`n$caminho", "Exportado", "OK", "Information") | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Falha ao exportar: $($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
            }
        } "Salva a lista em planilha na Area de Trabalho" | Out-Null

        New-ToolButton $f "GERENCIAR IMPRESSORAS" 600 566 220 34 $Script:UiAzul {
            Show-PrinterManager
        } "Abre o gerenciador de impressoras e drivers" | Out-Null

        $f.Add_FormClosing({ $Script:ScannerParar = $true; $Script:ScannerForm = $null })
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Erro ao abrir Scanner: $_", "XMenu") | Out-Null
    }
}

function Show-PrinterManager {
    try {
        if ($null -ne $Script:PrinterManagerForm -and $Script:PrinterManagerForm.Visible) {
            $Script:PrinterManagerForm.Activate(); return
        }

        $Script:PrinterManagerForm = New-Object System.Windows.Forms.Form
        $Script:PrinterManagerForm.Text = "Gerenciador de Impressoras XMenu"; $Script:PrinterManagerForm.Size = "780,650"; $Script:PrinterManagerForm.StartPosition = 'CenterParent'
        $Script:PrinterManagerForm.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 30); $Script:PrinterManagerForm.ForeColor = 'White'
        $Script:PrinterManagerForm.FormBorderStyle = 'FixedDialog'; $Script:PrinterManagerForm.MaximizeBox = $false

        # PAINEL 1: Impressoras Locais
        $pnlLocal = New-Object System.Windows.Forms.Panel
        $pnlLocal.Size = New-Object System.Drawing.Size(735, 520); $pnlLocal.Location = New-Object System.Drawing.Point(15, 65)
        $pnlLocal.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
        [void]$Script:PrinterManagerForm.Controls.Add($pnlLocal)

        # PAINEL 2: LPR/LPD
        $pnlLpr = New-Object System.Windows.Forms.Panel
        $pnlLpr.Size = New-Object System.Drawing.Size(735, 520); $pnlLpr.Location = New-Object System.Drawing.Point(15, 65)
        $pnlLpr.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
        $pnlLpr.Visible = $false
        [void]$Script:PrinterManagerForm.Controls.Add($pnlLpr)

        # PAINEL 3: Drivers de Impressoras
        $pnlDrivers = New-Object System.Windows.Forms.Panel
        $pnlDrivers.Size = New-Object System.Drawing.Size(735, 520); $pnlDrivers.Location = New-Object System.Drawing.Point(15, 65)
        $pnlDrivers.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
        $pnlDrivers.AutoScroll = $true
        $pnlDrivers.Visible = $false
        [void]$Script:PrinterManagerForm.Controls.Add($pnlDrivers)

        # Botões de Tabulação (Header da Janela) - 3 abas
        $tabActiveColor = [System.Drawing.Color]::FromArgb(14, 88, 62)
        $tabInactiveColor = [System.Drawing.Color]::FromArgb(45, 45, 50)

        $btnTabLocal = New-Object System.Windows.Forms.Button
        $btnTabLocal.Text = "Impressoras Locais"; $btnTabLocal.Size = '200,35'; $btnTabLocal.Location = '15,18'
        $btnTabLocal.FlatStyle = 'Flat'; $btnTabLocal.FlatAppearance.BorderSize = 0; $btnTabLocal.Cursor = 'Hand'
        $btnTabLocal.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnTabLocal.BackColor = $tabActiveColor; $btnTabLocal.ForeColor = 'White'
        
        $btnTabLpr = New-Object System.Windows.Forms.Button
        $btnTabLpr.Text = "USB via LPR (Win 11)"; $btnTabLpr.Size = '210,35'; $btnTabLpr.Location = '220,18'
        $btnTabLpr.FlatStyle = 'Flat'; $btnTabLpr.FlatAppearance.BorderSize = 0; $btnTabLpr.Cursor = 'Hand'
        $btnTabLpr.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnTabLpr.BackColor = $tabInactiveColor; $btnTabLpr.ForeColor = 'LightGray'

        $btnTabDrivers = New-Object System.Windows.Forms.Button
        $btnTabDrivers.Text = "Drivers de Impressoras"; $btnTabDrivers.Size = '210,35'; $btnTabDrivers.Location = '535,18'
        $btnTabDrivers.FlatStyle = 'Flat'; $btnTabDrivers.FlatAppearance.BorderSize = 0; $btnTabDrivers.Cursor = 'Hand'
        $btnTabDrivers.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnTabDrivers.BackColor = $tabInactiveColor; $btnTabDrivers.ForeColor = 'LightGray'

        $btnTabLocal.Add_Click({
            $pnlLocal.Visible = $true; $pnlLpr.Visible = $false; $pnlDrivers.Visible = $false
            $btnTabLocal.BackColor = $tabActiveColor; $btnTabLocal.ForeColor = 'White'
            $btnTabLpr.BackColor = $tabInactiveColor; $btnTabLpr.ForeColor = 'LightGray'
            $btnTabDrivers.BackColor = $tabInactiveColor; $btnTabDrivers.ForeColor = 'LightGray'
        })

        $btnTabLpr.Add_Click({
            $pnlLocal.Visible = $false; $pnlLpr.Visible = $true; $pnlDrivers.Visible = $false
            $btnTabLocal.BackColor = $tabInactiveColor; $btnTabLocal.ForeColor = 'LightGray'
            $btnTabLpr.BackColor = $tabActiveColor; $btnTabLpr.ForeColor = 'White'
            $btnTabDrivers.BackColor = $tabInactiveColor; $btnTabDrivers.ForeColor = 'LightGray'
        })

        $btnTabDrivers.Add_Click({
            $pnlLocal.Visible = $false; $pnlLpr.Visible = $false; $pnlDrivers.Visible = $true
            $btnTabLocal.BackColor = $tabInactiveColor; $btnTabLocal.ForeColor = 'LightGray'
            $btnTabLpr.BackColor = $tabInactiveColor; $btnTabLpr.ForeColor = 'LightGray'
            $btnTabDrivers.BackColor = $tabActiveColor; $btnTabDrivers.ForeColor = 'White'
        })

        [void]$Script:PrinterManagerForm.Controls.Add($btnTabLocal)
        [void]$Script:PrinterManagerForm.Controls.Add($btnTabLpr)
        [void]$Script:PrinterManagerForm.Controls.Add($btnTabDrivers)

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL DRIVERS (ABA 3)
        # -------------------------------------------------------------
        $baseUrl = "https://raw.githubusercontent.com/Delutto/thermal_printers/main"
        $drvY = 10

        # Função auxiliar para criar label de seção (marca)
        function Add-DriverSection {
            param($Panel, [ref]$Y, $Title, $Color)
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = $Title; $lbl.AutoSize = $true
            $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            $lbl.ForeColor = $Color; $lbl.Location = New-Object System.Drawing.Point(15, $Y.Value)
            [void]$Panel.Controls.Add($lbl)
            $Y.Value += 28
        }

        # Função auxiliar para criar botão de driver
        function Add-DriverButton {
            param($Panel, [ref]$Y, $Text, $Url, $FileName, $BgColor)
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = $Text; $btn.Size = New-Object System.Drawing.Size(700, 42)
            $btn.Location = New-Object System.Drawing.Point(15, $Y.Value)
            $btn.FlatStyle = 'Flat'; $btn.FlatAppearance.BorderSize = 0
            $btn.BackColor = $BgColor; $btn.ForeColor = 'White'
            $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
            $btn.TextAlign = 'MiddleLeft'; $btn.Padding = '10,0,0,0'; $btn.Cursor = 'Hand'
            $rr = $BgColor.R; $gg = $BgColor.G; $bb = $BgColor.B
            $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb([Math]::Min($rr+20,255), [Math]::Min($gg+20,255), [Math]::Min($bb+20,255))
            $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb([Math]::Max($rr-15,0), [Math]::Max($gg-15,0), [Math]::Max($bb-15,0))
            $btn.Tag = "$Url|$FileName"
            $btn.Add_Click({
                $parts = $this.Tag.Split('|')
                $dlUrl = $parts[0]; $dlFile = $parts[1]
                $dest = Join-Path $Script:DownloadFolder $dlFile
                $origText = $this.Text
                try {
                    $this.Enabled = $false; $this.Text = "  Iniciando download..."
                    Log-Message "INFO" "Baixando driver: $dlFile"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                    # Download assincrono com barra de progresso no proprio botao
                    $Script:DrvBtn = $this
                    $Script:DrvFile = $dlFile
                    $Script:DrvComplete = $false
                    $Script:DrvError = $null
                    $wc = New-Object System.Net.WebClient

                    $wc.Add_DownloadProgressChanged({
                        param($s, $e)
                        $pct = $e.ProgressPercentage
                        $barSize = 14
                        $filled = [Math]::Floor($pct / (100 / $barSize))
                        $bar = ("|" * $filled) + ("." * ($barSize - $filled))
                        $mb = [Math]::Round($e.BytesReceived / 1MB, 1)
                        $totMb = [Math]::Round($e.TotalBytesToReceive / 1MB, 1)
                        $Script:DrvBtn.Text = "  [$bar] $pct%   ($mb / $totMb MB)"
                    })
                    $wc.Add_DownloadFileCompleted({
                        param($s, $e)
                        if ($e.Error) { $Script:DrvError = $e.Error }
                        $Script:DrvComplete = $true
                    })

                    $cleanUrl = $dlUrl.Replace(" ", "%20")
                    $wc.DownloadFileAsync((New-Object Uri($cleanUrl)), $dest)
                    while (-not $Script:DrvComplete) {
                        [System.Windows.Forms.Application]::DoEvents()
                        Start-Sleep -Milliseconds 15
                    }
                    $wc.Dispose()
                    if ($Script:DrvError) { throw $Script:DrvError }

                    if (-not (Test-DownloadIntegrity -Path $dest)) {
                        Remove-Item $dest -Force -ErrorAction SilentlyContinue
                        throw "Arquivo baixado esta corrompido ou invalido (link quebrado ou pagina de erro)."
                    }
                    Log-Message "SUCESSO" "Download concluido: $dlFile"
                    $this.Text = "  Instalando $dlFile ..."
                    # WorkingDirectory na pasta de downloads: instaladores auto-extraiveis (WinRAR SFX)
                    # passam a sugerir essa pasta em vez de C:\WINDOWS\system32.
                    Start-Process -FilePath $dest -WorkingDirectory $Script:DownloadFolder
                    Log-Message "SUCESSO" "Instalador iniciado: $dlFile"
                    $this.Text = "✔ $origText"
                } catch {
                    $errMsg = $_.Exception.Message
                    if ($errMsg -match 'v[ií]rus|software.*indesejado|potentially unwanted|unwanted software') {
                        Log-Message "ERRO" "Windows Defender bloqueou o arquivo (provavel falso positivo): $dlFile"
                        [System.Windows.Forms.MessageBox]::Show(
                            "O Windows Defender bloqueou este driver.`n`n" +
                            "Isso costuma ser um FALSO POSITIVO em instaladores de driver (o arquivo vem de fonte oficial).`n`n" +
                            "A pasta 'Arquivos Xmenu' ja foi adicionada as excecoes do Defender - tente baixar novamente.`n`n" +
                            "Se ainda assim bloquear, restaure o arquivo em: Seguranca do Windows > Protecao contra virus > Historico de protecao (Quarentena).",
                            "Bloqueado pelo Windows Defender", "OK", "Warning") | Out-Null
                    }
                    else {
                        Log-Message "ERRO" "Falha ao baixar driver: $_"
                        [System.Windows.Forms.MessageBox]::Show("Erro ao baixar o driver: $_", "Erro", "OK", "Error") | Out-Null
                    }
                    $this.Text = $origText
                } finally {
                    $this.Enabled = $true
                }
            })
            [void]$Panel.Controls.Add($btn)
            $Y.Value += 47
        }

        # Botao que so abre a pagina oficial do fabricante (quando nao ha link direto confiavel de download)
        function Add-DriverLinkButton {
            param($Panel, [ref]$Y, $Text, $Url, $BgColor)
            $btn = New-Object System.Windows.Forms.Button
            $btn.Text = $Text; $btn.Size = New-Object System.Drawing.Size(700, 42)
            $btn.Location = New-Object System.Drawing.Point(15, $Y.Value)
            $btn.FlatStyle = 'Flat'; $btn.FlatAppearance.BorderSize = 0
            $btn.BackColor = $BgColor; $btn.ForeColor = 'White'
            $btn.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
            $btn.TextAlign = 'MiddleLeft'; $btn.Padding = '10,0,0,0'; $btn.Cursor = 'Hand'
            $rr = $BgColor.R; $gg = $BgColor.G; $bb = $BgColor.B
            $btn.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb([Math]::Min($rr+20,255), [Math]::Min($gg+20,255), [Math]::Min($bb+20,255))
            $btn.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb([Math]::Max($rr-15,0), [Math]::Max($gg-15,0), [Math]::Max($bb-15,0))
            $btn.Tag = $Url
            $btn.Add_Click({
                try {
                    Log-Message "INFO" "Abrindo pagina oficial: $($this.Tag)"
                    Start-Process $this.Tag
                } catch {
                    Log-Message "ERRO" "Falha ao abrir pagina: $_"
                }
            })
            [void]$Panel.Controls.Add($btn)
            $Y.Value += 47
        }

        $colorElgin   = [System.Drawing.Color]::FromArgb(25, 80, 140)
        $colorBema    = [System.Drawing.Color]::FromArgb(30, 100, 60)
        $colorEpson   = [System.Drawing.Color]::FromArgb(80, 40, 120)
        $colorTanca   = [System.Drawing.Color]::FromArgb(140, 70, 20)

        $colorElginUtil   = [System.Drawing.Color]::FromArgb(15, 60, 110)
        $colorBemaUtil    = [System.Drawing.Color]::FromArgb(20, 80, 45)
        $colorEpsonUtil   = [System.Drawing.Color]::FromArgb(60, 25, 95)
        $colorTancaUtil   = [System.Drawing.Color]::FromArgb(110, 50, 15)

        # --- ELGIN ---
        Add-DriverSection $pnlDrivers ([ref]$drvY) "ELGIN" ([System.Drawing.Color]::FromArgb(80, 160, 255))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Elgin i9 / i7  (v1.7.3)" "$baseUrl/Elgin/Elgin_i7_i9_v1.7.3.exe" "Elgin_i7_i9_v1.7.3.exe" $colorElgin
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Elgin i8  (v7.1.7)" "$baseUrl/Elgin/Elgin_i8_v7.1.7.exe" "Elgin_i8_v7.1.7.exe" $colorElgin
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Elgin i9 Utility  (v1.2.2.24)" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/UTILITY.ELGIN.I9.E.I7.1.exe" "UTILITY.ELGIN.I9.E.I7.1.exe" $colorElginUtil
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Elgin i7 / i8 Utility  (v3.2)" "$baseUrl/Utilities/Elgin_i7-i8_Utility_v3.2.exe" "Elgin_i7-i8_Utility_v3.2.exe" $colorElginUtil
        $drvY += 8

        # --- BEMATECH ---
        Add-DriverSection $pnlDrivers ([ref]$drvY) "BEMATECH" ([System.Drawing.Color]::FromArgb(80, 200, 120))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Bematech MP-4200 TH / MP-2500 / MP-4000  (Spooler x64 v4.4.0.3)" "$baseUrl/Bematech/BematechSpoolerDrivers_x64_v4.4.0.3.exe" "BematechSpoolerDrivers_x64_v4.4.0.3.exe" $colorBema
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Bematech MP-4200 HS  (v1.7.7)" "$baseUrl/Bematech/Bematech%20MP-4200-HS_Driver_v1.7.7.exe" "Bematech_MP-4200-HS_Driver_v1.7.7.exe" $colorBema
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Bematech MP-2800 TH  (Spooler v1.3)" "$baseUrl/Bematech/Bematech_MP_2800_SpoolerDrivers_v1.3.exe" "Bematech_MP_2800_SpoolerDrivers_v1.3.exe" $colorBema
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Bematech Utility  (v2.10.04 x64)" "$baseUrl/Utilities/Bematech_Utility_v2.10.04_x64.exe" "Bematech_Utility_v2.10.04_x64.exe" $colorBemaUtil
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Bematech MP-2800 TH Utility  (v1.4)" "$baseUrl/Utilities/Bematech_MP-2800_TH_Utility_v1.4.exe" "Bematech_MP-2800_TH_Utility_v1.4.exe" $colorBemaUtil
        $drvY += 8

        # --- EPSON ---
        Add-DriverSection $pnlDrivers ([ref]$drvY) "EPSON" ([System.Drawing.Color]::FromArgb(180, 120, 255))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Epson TM-T20  (APD v5.6.0.0)" "$baseUrl/Epson/Epson_TM-T20_v5.6.0.0.exe" "Epson_TM-T20_v5.6.0.0.exe" $colorEpson
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Epson TM-T20X  (APD v6.1.0.0)" "$baseUrl/Epson/Epson_TM-T20X_v6.1.0.0.exe" "Epson_TM-T20X_v6.1.0.0.exe" $colorEpson
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Epson TM-T20X II  (APD v6.9.1.0)" "$baseUrl/Epson/Epson_TM-20X-II_Driver_v6.9.1.0.exe" "Epson_TM-20X-II_Driver_v6.9.1.0.exe" $colorEpson
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Epson NetConfig  (v4.9.5)" "$baseUrl/Utilities/Epson_NetConfig_v4_9_5.exe" "Epson_NetConfig_v4_9_5.exe" $colorEpsonUtil
        $drvY += 8

        # --- TANCA ---
        Add-DriverSection $pnlDrivers ([ref]$drvY) "TANCA" ([System.Drawing.Color]::FromArgb(255, 160, 60))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Tanca TP-620  (v6.1.0)" "$baseUrl/Tanca/Tanca_TP-620_Driver_v6.1.0.exe" "Tanca_TP-620_Driver_v6.1.0.exe" $colorTanca
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Tanca TP-650  (v2.11)" "$baseUrl/Tanca/Tanca_TP-650_DriverInstall_v2.11.exe" "Tanca_TP-650_DriverInstall_v2.11.exe" $colorTanca
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Tanca TP-620 Utility  (v3.2.0.1)" "$baseUrl/Utilities/Tanca_TP-620_Utility_v3.2.0.1.exe" "Tanca_TP-620_Utility_v3.2.0.1.exe" $colorTancaUtil
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Tanca TP-650 Printer Tool  (v1.48E)" "$baseUrl/Utilities/Tanca_TP-650_PrinterTool_1.48E.exe" "Tanca_TP-650_PrinterTool_1.48E.exe" $colorTancaUtil
        $drvY += 8

        # --- OUTRAS MARCAS ---
        $colorDaruma  = [System.Drawing.Color]::FromArgb(130, 20, 50)
        $colorSweda   = [System.Drawing.Color]::FromArgb(100, 100, 30)
        $colorCtrlID  = [System.Drawing.Color]::FromArgb(60, 60, 80)
        $colorOtherUtil = [System.Drawing.Color]::FromArgb(40, 40, 45)

        Add-DriverSection $pnlDrivers ([ref]$drvY) "DARUMA / SWEDA / CONTROL ID" ([System.Drawing.Color]::FromArgb(220, 220, 220))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Daruma DR800  (Spooler v2.0.1.7)" "$baseUrl/Daruma/Daruma_800_Spooler_Driver_v2.0.1.7.exe" "Daruma_800_Spooler_Driver_v2.0.1.7.exe" $colorDaruma
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Sweda SI-300 / SI-300E / SI-300W  (v1.2.0)" "$baseUrl/Sweda/Sweda_SI-300_SI-300E_SI-300W_v1.2.0.exe" "Sweda_SI-300_SI-300E_SI-300W_v1.2.0.exe" $colorSweda
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Control iD Print iD / Print iD Touch  (v1.1.10.2)" "$baseUrl/PrintID/Print_iD_%26_Print_iD_Touch_v1.1.10.2.exe" "Print_iD_v1.1.10.2.exe" $colorCtrlID
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Daruma Utility  (v2.20.9)" "$baseUrl/Utilities/Daruma_Utility_v2.20.9.exe" "Daruma_Utility_v2.20.9.exe" $colorDaruma
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Sweda Utility  (v2.03)" "$baseUrl/Utilities/Sweda_Utility_v2.03.exe" "Sweda_Utility_v2.03.exe" $colorSweda
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Control iD Utility  (v1.0)" "$baseUrl/Utilities/PrintID_Utility_v1.0.exe" "PrintID_Utility_v1.0.exe" $colorCtrlID

        $drvY += 8

        # --- TOMATE / C3TECH / GENERICAS POS-80 ---
        # Tomate MDK, Knup, Kmex, Evadin e a maioria das 80mm chinesas usam
        # o mesmo "POS Printer Driver" generico.
        $colorPos     = [System.Drawing.Color]::FromArgb(150, 45, 30)
        $colorPosUtil = [System.Drawing.Color]::FromArgb(115, 30, 20)
        $colorC3      = [System.Drawing.Color]::FromArgb(20, 85, 115)

        Add-DriverSection $pnlDrivers ([ref]$drvY) "TOMATE / C3TECH / GENÉRICAS 80mm" ([System.Drawing.Color]::FromArgb(255, 130, 100))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Tomate MDK-006 / 007 / 008 / 080 / 081  (POS-80 genérico v11.3)" "$baseUrl/POS/POS_Printer_Driver_Setup_v11.3.0.0.exe" "POS_Printer_Driver_Setup_v11.3.0.0.exe" $colorPos
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Knup / Kmex / Evadin / demais POS-58 e POS-80  (mesmo driver v11.3)" "$baseUrl/POS/POS_Printer_Driver_Setup_v11.3.0.0.exe" "POS_Printer_Driver_Setup_v11.3.0.0.exe" $colorPos
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] POS Utilities  (teste, autoteste e configuração POS-80)" "$baseUrl/Utilities/POS_Utilities.exe" "POS_Utilities.exe" $colorPosUtil
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] C3Tech IT-100  (pacote oficial C3Tech - RAR, ~87 MB)" "https://c3technology.com.br/download/DRIVES%20IT-100.rar" "C3Tech_IT-100_Drivers.rar" $colorC3
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] C3Tech IT-110  (drivers + utilitários oficiais - ZIP, ~103 MB)" "https://c3technology.com.br/download/DRIVES%20E%20UTILITARIOS%20IT-110.zip" "C3Tech_IT-110_Drivers_Utilitarios.zip" $colorC3
        Add-DriverLinkButton $pnlDrivers ([ref]$drvY) "  [SITE] Tomate - suporte oficial (tutoriais e drivers por modelo)" "https://tomate.tv/support" $colorPosUtil
        $drvY += 8

        # --- FEASSO / JETWAY ---
        $colorFeasso = [System.Drawing.Color]::FromArgb(120, 60, 130)
        $colorJetway = [System.Drawing.Color]::FromArgb(35, 95, 105)
        Add-DriverSection $pnlDrivers ([ref]$drvY) "FEASSO / JETWAY" ([System.Drawing.Color]::FromArgb(200, 150, 255))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Feasso F-IMTER-01  (v1.7)" "$baseUrl/Feasso/Feasso_F-IMTER-01_Driver_v1.7.exe" "Feasso_F-IMTER-01_Driver_v1.7.exe" $colorFeasso
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Feasso F-IMTER-02  (v2.0)" "$baseUrl/Feasso/Feasso_F-IMTER-02_Driver_v2.0.exe" "Feasso_F-IMTER-02_Driver_v2.0.exe" $colorFeasso
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Feasso F-IMTER-03  (v1.5)" "$baseUrl/Feasso/Feasso_F-IMTER-03_Driver_v1.5.exe" "Feasso_F-IMTER-03_Driver_v1.5.exe" $colorFeasso
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Jetway JP-500  (v7.17)" "$baseUrl/Jetway/Jetway_JP-500_Printer_Driver_v7.17.exe" "Jetway_JP-500_Printer_Driver_v7.17.exe" $colorJetway
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Jetway JP-800  (v2.38E)" "$baseUrl/Jetway/Jetway_JP-800_PrinterDriver_v2.38E.exe" "Jetway_JP-800_PrinterDriver_v2.38E.exe" $colorJetway
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Jetway JMP-100  (v2.61J)" "$baseUrl/Jetway/Jetway_JMP-100_Driver_v2.61J.exe" "Jetway_JMP-100_Driver_v2.61J.exe" $colorJetway
        $drvY += 8

        # --- GERTEC / DIEBOLD / DIMEP / PERTO ---
        $colorGertec  = [System.Drawing.Color]::FromArgb(150, 100, 20)
        $colorDiebold = [System.Drawing.Color]::FromArgb(45, 70, 130)
        $colorPerto   = [System.Drawing.Color]::FromArgb(90, 45, 60)
        Add-DriverSection $pnlDrivers ([ref]$drvY) "GERTEC / DIEBOLD / DIMEP / PERTO" ([System.Drawing.Color]::FromArgb(255, 200, 90))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Gertec G250  (v1.0)" "$baseUrl/Gertec/Gertec_G250_Driver_v1.0.exe" "Gertec_G250_Driver_v1.0.exe" $colorGertec
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Gertec G250 Utility  (v2.57)" "$baseUrl/Utilities/Gertec_G250_Utility_v2.57.exe" "Gertec_G250_Utility_v2.57.exe" $colorGertec
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Diebold Mecaf / Perfecta  (v1.34 drv 1.9)" "$baseUrl/Diebold/Diebold_Printers_v1.34_drv_1.9.exe" "Diebold_Printers_v1.34_drv_1.9.exe" $colorDiebold
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Diebold IM113ID  (v1.2.0.10 x64)" "$baseUrl/Diebold/Diebold_IM113ID_v1.2.0.10_x64.exe" "Diebold_IM113ID_v1.2.0.10_x64.exe" $colorDiebold
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Dimep D-PRINT DUAL  (v2.1.4.4)" "$baseUrl/Dimep/Dimep_D-PRINT_DUAL_v2.1.4.4.exe" "Dimep_D-PRINT_DUAL_v2.1.4.4.exe" $colorPerto
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Perto PertoPrinter  (v2.5)" "$baseUrl/PertoPrinter/PertoPrinter_Driver_2.5.exe" "PertoPrinter_Driver_2.5.exe" $colorPerto
        $drvY += 8

        # --- STAR / WAYTEC / MENNO / DASCOM ---
        $colorStar   = [System.Drawing.Color]::FromArgb(25, 70, 95)
        $colorWaytec = [System.Drawing.Color]::FromArgb(70, 90, 40)
        $colorMenno  = [System.Drawing.Color]::FromArgb(100, 55, 25)
        Add-DriverSection $pnlDrivers ([ref]$drvY) "STAR / WAYTEC / MENNO / DASCOM" ([System.Drawing.Color]::FromArgb(140, 210, 255))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Star (todos os modelos)  (x64 v3.7.2)" "$baseUrl/Star/Star_PrinterDrivers_x64_v3.7.2.exe" "Star_PrinterDrivers_x64_v3.7.2.exe" $colorStar
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Waytec WP-100  (v7.17)" "$baseUrl/Waytec/Waytec_WP-100_Driver_v7.17.exe" "Waytec_WP-100_Driver_v7.17.exe" $colorWaytec
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Waytec WP-50  (v7.17.50)" "$baseUrl/Waytec/WayTec_WP-50_Driver_v7.17.50.exe" "WayTec_WP-50_Driver_v7.17.50.exe" $colorWaytec
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Waytec Utility  (v3.2.0.1)" "$baseUrl/Utilities/Waytec_Utility_v3.2.0.1.exe" "Waytec_Utility_v3.2.0.1.exe" $colorWaytec
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Menno  (v2.52)" "$baseUrl/Menno/Menno_Printer_Driver_v2.52.exe" "Menno_Printer_Driver_v2.52.exe" $colorMenno
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Menno Printer Tool  (v1.56)" "$baseUrl/Utilities/Menno_PrinterTool_v1.56.exe" "Menno_PrinterTool_v1.56.exe" $colorMenno
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Dascom DT-210 / DT-230  (v1.0.0.7)" "$baseUrl/Dascom/Dascom_DT-210_DT-230_Driver_v1.0.0.7.exe" "Dascom_DT-210_DT-230_Driver_v1.0.0.7.exe" $colorStar
        $drvY += 8

        # --- IMPRESSORAS XTAG (ETIQUETA) ---
        $colorXtag = [System.Drawing.Color]::FromArgb(0, 140, 130)
        $colorXtagUtil = [System.Drawing.Color]::FromArgb(0, 95, 90)
        $xtagBaseUrl = "https://raw.githubusercontent.com/ElginDeveloperCommunity/Impressoras/master/Impressoras%20de%20Etiqueta"
        Add-DriverSection $pnlDrivers ([ref]$drvY) "IMPRESSORAS XTAG (ETIQUETA)" ([System.Drawing.Color]::FromArgb(100, 220, 210))
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Elgin L42 PRO  (ZIP - contem instalador, v2020.4)" "$xtagBaseUrl/Elgin/L42PRO/Drivers/Windows_DriverL42PRO_V2020.4.zip" "Windows_DriverL42PRO_V2020.4.zip" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Elgin L42 PRO FULL  (v2022.1)" "$xtagBaseUrl/Elgin/L42PRO%20FULL/Drivers/L42PRO%20FULL_Windows_driver_2022.1.exe" "Elgin_L42PRO_FULL_Windows_driver_2022.1.exe" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Elgin L42 DT  (v7.4.3)" "$xtagBaseUrl/Elgin/L42DT/Drivers/Windows_DriverL42DT_7.4.3_M-5.exe" "Elgin_L42DT_Windows_driver_7.4.3.exe" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Zebra ZD220 / ZD230  (ZIP - contem instalador)" "https://www.zebra.com/content/dam/support-dam/en/driver/unrestricted/0002/zddriver-v1062628275-certified.zip" "Zebra_ZD220_ZD230_Driver.zip" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Argox  (Todos os modelos, v2022.1)" "$baseUrl/Argox/Argox_PrinterDrivers_v2022.1.exe" "Argox_PrinterDrivers_v2022.1.exe" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Gainscha  (Todos os modelos, v2020.1)" "$baseUrl/Gainscha/Gainscha_GPrinterDrivers_v2020.1.exe" "Gainscha_GPrinterDrivers_v2020.1.exe" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [DRIVER] Zetex Z60XT  (ZIP - Drive, ~225 MB)" "https://drive.usercontent.google.com/download?id=1wWLiTWrtHCBRP9L0P9GG2eRKGEgfo2HJ&export=download&confirm=t" "Zetex_Z60XT_Driver.zip" $colorXtag
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Gerenciador Elgin L42 PRO FULL  (v1.5.1)" "$xtagBaseUrl/Elgin/L42PRO%20FULL/Utilit%C3%A1rios/GerenciadorL42PRO_Full_1.5.1.exe" "GerenciadorL42PRO_Full_1.5.1.exe" $colorXtagUtil
        Add-DriverButton $pnlDrivers ([ref]$drvY) "  [UTILITÁRIO] Gerenciador Elgin L42 DT  (v1.5.6)" "$xtagBaseUrl/Elgin/L42DT/Utilit%C3%A1rios/GerenciadorL42DT_Full_1.5.6.exe" "GerenciadorL42DT_Full_1.5.6.exe" $colorXtagUtil

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL LOCAL (ABA 1)
        # -------------------------------------------------------------
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = '15,15'; $lv.Size = '705,300'
        $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false
        $lv.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 25); $lv.ForeColor = 'WhiteSmoke'
        $lv.BorderStyle = 'None'; $lv.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
        
        $lv.Columns.Add("Impressora", 260) | Out-Null
        $lv.Columns.Add("Porta", 130) | Out-Null
        $lv.Columns.Add("Compartilhada?", 120) | Out-Null
        $lv.Columns.Add("Nome Compart.", 190) | Out-Null
        [void]$pnlLocal.Controls.Add($lv)

        $LoadPrinters = {
            $lv.Items.Clear()
            try {
                $printers = Get-WmiObject Win32_Printer
                foreach ($p in $printers) {
                    $pName = if ($p.Name) { $p.Name } else { "Sem Nome" }
                    $pPort = if ($p.PortName) { $p.PortName } else { "" }
                    $pShareName = if ($p.ShareName) { $p.ShareName } else { "" }
                    $isShared = if ($p.Shared) { "Sim" } else { "Não" }

                    $item = New-Object System.Windows.Forms.ListViewItem($pName)
                    $item.SubItems.Add($pPort) | Out-Null
                    $item.SubItems.Add($isShared) | Out-Null
                    $item.SubItems.Add($pShareName) | Out-Null
                    
                    if ($p.Shared) {
                        $item.ForeColor = [System.Drawing.Color]::PaleGreen
                    }
                    [void]$lv.Items.Add($item)
                }
            } catch {
                Log-Message "ERRO" "Falha ao carregar impressoras: $_"
            }
        }
        &$LoadPrinters

        # Botões de Ação no Painel Local
        $btnRefresh = New-Object System.Windows.Forms.Button
        $btnRefresh.Text = "Atualizar Lista"; $btnRefresh.Location = '15,330'; $btnRefresh.Size = '130,40'
        $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 60); $btnRefresh.FlatStyle = 'Flat'; $btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnRefresh.Cursor = 'Hand'; $btnRefresh.ForeColor = 'White'; $btnRefresh.FlatAppearance.BorderSize = 0
        $btnRefresh.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(75, 75, 80)
        $btnRefresh.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(45, 45, 50)
        $btnRefresh.Add_Click({ &$LoadPrinters })
        [void]$pnlLocal.Controls.Add($btnRefresh)

        $btnTest = New-Object System.Windows.Forms.Button
        $btnTest.Text = "Página de Teste"; $btnTest.Location = '155,330'; $btnTest.Size = '140,40'
        $btnTest.BackColor = [System.Drawing.Color]::FromArgb(55, 55, 60); $btnTest.FlatStyle = 'Flat'; $btnTest.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnTest.Cursor = 'Hand'; $btnTest.ForeColor = 'White'; $btnTest.FlatAppearance.BorderSize = 0
        $btnTest.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(75, 75, 80)
        $btnTest.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(45, 45, 50)
        $btnTest.Add_Click({
            if ($lv.SelectedItems.Count -eq 0) { 
                [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Aviso", "OK", "Warning") | Out-Null
                return 
            }
            $pName = $lv.SelectedItems[0].Text
            try {
                $wmi = Get-WmiObject Win32_Printer -Filter "Name='$($pName -replace "'", "\'")'"
                $wmi.PrintTestPage() | Out-Null
                Log-Message "SUCESSO" "Página de teste enviada para: $pName"
            } catch {
                Log-Message "ERRO" "Falha ao imprimir página de teste: $_"
            }
        })
        [void]$pnlLocal.Controls.Add($btnTest)

        $btnShare = New-Object System.Windows.Forms.Button
        $btnShare.Text = "Compartilhar"; $btnShare.Location = '305,330'; $btnShare.Size = '130,40'
        $btnShare.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnShare.FlatStyle = 'Flat'; $btnShare.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnShare.Cursor = 'Hand'; $btnShare.ForeColor = 'White'; $btnShare.FlatAppearance.BorderSize = 0
        $btnShare.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 112, 80)
        $btnShare.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(10, 68, 48)
        $btnShare.Add_Click({
            if ($lv.SelectedItems.Count -eq 0) { 
                [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Aviso", "OK", "Warning") | Out-Null
                return 
            }
            $pName = $lv.SelectedItems[0].Text
            
            $fInput = New-Object System.Windows.Forms.Form
            $fInput.Text = "Nome do Compartilhamento"; $fInput.Size = "350,180"; $fInput.StartPosition = 'CenterParent'
            $fInput.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 40); $fInput.ForeColor = 'White'
            $fInput.FormBorderStyle = 'FixedDialog'; $fInput.MaximizeBox = $false
            
            $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Digite o nome (sem acentos/espaços):"; $lbl.Location = '20,20'; $lbl.AutoSize = $true
            [void]$fInput.Controls.Add($lbl)
            
            $txt = New-Object System.Windows.Forms.TextBox; $txt.Location = '20,45'; $txt.Width = 290
            $suggested = $pName -replace '[^a-zA-Z0-9]', ''
            if ($suggested.Length -gt 15) { $suggested = $suggested.Substring(0,15) }
            $txt.Text = $suggested.ToUpper()
            $txt.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60); $txt.ForeColor = 'White'; $txt.BorderStyle = 'FixedSingle'
            [void]$fInput.Controls.Add($txt)
            
            $btnOk = New-Object System.Windows.Forms.Button; $btnOk.Text = "OK"; $btnOk.Location = '130,90'; $btnOk.Size = '80,30'
            $btnOk.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnOk.FlatStyle = 'Flat'; $btnOk.Cursor = 'Hand'; $btnOk.ForeColor = 'White'; $btnOk.FlatAppearance.BorderSize = 0
            $btnOk.Add_Click({ $fInput.DialogResult = 'OK'; $fInput.Close() })
            [void]$fInput.Controls.Add($btnOk)
            
            $btnCan = New-Object System.Windows.Forms.Button; $btnCan.Text = "Cancelar"; $btnCan.Location = '220,90'; $btnCan.Size = '80,30'
            $btnCan.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65); $btnCan.FlatStyle = 'Flat'; $btnCan.Cursor = 'Hand'; $btnCan.ForeColor = 'White'; $btnCan.FlatAppearance.BorderSize = 0
            $btnCan.Add_Click({ $fInput.Close() })
            [void]$fInput.Controls.Add($btnCan)
            
            if ($fInput.ShowDialog() -eq 'OK') {
                $shareName = $txt.Text.Trim() -replace '\s+', '' -replace '[^a-zA-Z0-9]', ''
                if ($shareName) {
                    try {
                        $wmi = Get-WmiObject Win32_Printer -Filter "Name='$($pName -replace "'", "\'")'"
                        $wmi.Shared = $true
                        $wmi.ShareName = $shareName
                        $wmi.Put() | Out-Null
                        Log-Message "SUCESSO" "Impressora '$pName' compartilhada como '$shareName'"
                        
                        # --- APLICAR CORREÇÃO DE REGISTRO RPC (Win 10/11) ---
                        Log-Message "INFO" "Aplicando correcoes de registro RPC para compartilhamento..."
                        
                        $printPath = "HKLM:\System\CurrentControlSet\Control\Print"
                        $privName = "RpcAuthnLevelPrivacyEnabled"
                        if (-not (Get-ItemProperty -Path $printPath -Name $privName -ErrorAction SilentlyContinue)) {
                            New-ItemProperty -Path $printPath -Name $privName -Value 0 -PropertyType DWord -Force | Out-Null
                        } else {
                            Set-ItemProperty -Path $printPath -Name $privName -Value 0 | Out-Null
                        }

                        $rpcPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC"
                        if (-not (Test-Path $rpcPath)) {
                            New-Item -Path $rpcPath -Force | Out-Null
                        }
                        $pipeName = "RpcUseNamedPipeProtocol"
                        if (-not (Get-ItemProperty -Path $rpcPath -Name $pipeName -ErrorAction SilentlyContinue)) {
                            New-ItemProperty -Path $rpcPath -Name $pipeName -Value 1 -PropertyType DWord -Force | Out-Null
                        } else {
                            Set-ItemProperty -Path $rpcPath -Name $pipeName -Value 1 | Out-Null
                        }
                        
                        # --- LIBERAR FIREWALL (Compartilhamento de Arquivo e Impressora) ---
                        # Usa o ID interno do grupo (independe do idioma do Windows)
                        Log-Message "INFO" "Liberando Firewall para Compartilhamento de Arquivo e Impressora..."
                        try {
                            Get-NetFirewallRule -Group "@FirewallAPI.dll,-28502" -ErrorAction SilentlyContinue | Enable-NetFirewallRule -ErrorAction SilentlyContinue
                        } catch {}

                        Log-Message "INFO" "Reiniciando spooler para aplicar registros..."
                        Restart-Service -Name Spooler -Force
                        Log-Message "SUCESSO" "Registros RPC aplicados, Firewall liberado e Spooler reiniciado com sucesso!"

                        $netPath = "\\$env:COMPUTERNAME\$shareName"
                        [System.Windows.Forms.Clipboard]::SetText($netPath)
                        [System.Windows.Forms.MessageBox]::Show(
                            "Impressora compartilhada com sucesso e registros aplicados!`n`n" +
                            "Caminho da impressora para o portal:`n$netPath`n`n" +
                            "(Este caminho ja foi copiado para sua Area de Transferencia!)`n`n" +
                            "--------------------------------------------------`n" +
                            "COMO INSTALAR NO SERVIDOR (ou em outro PC da rede):`n" +
                            "1. No servidor, abra o Explorador de Arquivos.`n" +
                            "2. Cole o caminho na barra de endereco: $netPath`n" +
                            "3. De duplo-clique na impressora que aparecer.`n" +
                            "4. O Windows vai instalar e adicionar a impressora automaticamente.`n" +
                            "   (Se pedir driver manualmente, use o mesmo driver instalado nesta maquina.)`n" +
                            "--------------------------------------------------",
                            "Compartilhada com Sucesso", "OK", "Information") | Out-Null
                        
                        &$LoadPrinters
                    } catch {
                        Log-Message "ERRO" "Erro ao compartilhar/aplicar registros: $_"
                    }
                }
            }
        })
        [void]$pnlLocal.Controls.Add($btnShare)

        $btnUnshare = New-Object System.Windows.Forms.Button
        $btnUnshare.Text = "Remover Compart."; $btnUnshare.Location = '445,330'; $btnUnshare.Size = '140,40'
        $btnUnshare.BackColor = [System.Drawing.Color]::FromArgb(120, 30, 30); $btnUnshare.FlatStyle = 'Flat'; $btnUnshare.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnUnshare.Cursor = 'Hand'; $btnUnshare.ForeColor = 'White'; $btnUnshare.FlatAppearance.BorderSize = 0
        $btnUnshare.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(145, 45, 45)
        $btnUnshare.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(100, 20, 20)
        $btnUnshare.Add_Click({
            if ($lv.SelectedItems.Count -eq 0) { 
                [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Aviso", "OK", "Warning") | Out-Null
                return 
            }
            $pName = $lv.SelectedItems[0].Text
            try {
                $wmi = Get-WmiObject Win32_Printer -Filter "Name='$($pName -replace "'", "\'")'"
                $wmi.Shared = $false
                $wmi.Put() | Out-Null
                Log-Message "SUCESSO" "Compartilhamento removido para: $pName"
                &$LoadPrinters
            } catch {
                Log-Message "ERRO" "Erro ao remover compartilhamento: $_"
            }
        })
        [void]$pnlLocal.Controls.Add($btnUnshare)

        $btnCopyPath = New-Object System.Windows.Forms.Button
        $btnCopyPath.Text = "Copiar Caminho"; $btnCopyPath.Location = '595,330'; $btnCopyPath.Size = '125,40'
        $btnCopyPath.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnCopyPath.FlatStyle = 'Flat'; $btnCopyPath.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnCopyPath.Cursor = 'Hand'; $btnCopyPath.ForeColor = 'White'; $btnCopyPath.FlatAppearance.BorderSize = 0
        $btnCopyPath.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 112, 80)
        $btnCopyPath.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(10, 68, 48)
        $btnCopyPath.Add_Click({
            if ($lv.SelectedItems.Count -eq 0) { 
                [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Aviso", "OK", "Warning") | Out-Null
                return 
            }
            $pName = $lv.SelectedItems[0].Text
            try {
                $wmi = Get-WmiObject Win32_Printer -Filter "Name='$($pName -replace "'", "\'")'"
                if ($wmi.Shared -and $wmi.ShareName) {
                    $netPath = "\\$env:COMPUTERNAME\$($wmi.ShareName)"
                    [System.Windows.Forms.Clipboard]::SetText($netPath)
                    Log-Message "SUCESSO" "Caminho copiado: $netPath"
                    [System.Windows.Forms.MessageBox]::Show("Caminho de rede copiado para a Area de Transferencia:`n`n$netPath", "Caminho Copiado", "OK", "Information") | Out-Null
                } else {
                    [System.Windows.Forms.MessageBox]::Show("Esta impressora nao esta compartilhada. Compartilhe-a primeiro para copiar o caminho de rede.", "Aviso", "OK", "Warning") | Out-Null
                }
            } catch {
                Log-Message "ERRO" "Erro ao obter dados de compartilhamento: $_"
            }
        })
        [void]$pnlLocal.Controls.Add($btnCopyPath)

        $lblSep = New-Object System.Windows.Forms.Label
        $lblSep.Text = "________________________________________________________________________________________________________"
        $lblSep.Location = '15,390'; $lblSep.Size = '705,20'; $lblSep.ForeColor = 'Gray'
        [void]$pnlLocal.Controls.Add($lblSep)

        $btnSpool = New-Object System.Windows.Forms.Button
        $btnSpool.Text = "REINICIAR SPOOLER DE IMPRESSÃO"; $btnSpool.Location = '15,420'; $btnSpool.Size = '705,45'
        $btnSpool.BackColor = [System.Drawing.Color]::FromArgb(50, 55, 60); $btnSpool.FlatStyle = 'Flat'; $btnSpool.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnSpool.Cursor = 'Hand'; $btnSpool.ForeColor = 'White'; $btnSpool.FlatAppearance.BorderSize = 0
        $btnSpool.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(70, 75, 80)
        $btnSpool.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(40, 45, 50)
        $btnSpool.Add_Click({
            Invoke-SpoolerReset
        })
        [void]$pnlLocal.Controls.Add($btnSpool)

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL LPR/LPD (ABA 2)
        # -------------------------------------------------------------
        $lblLprTitle = New-Object System.Windows.Forms.Label
        $lblLprTitle.Text = "COMPARTILHAMENTO USB VIA REDE LPR/LPD (Evita Erros 0x00000709 / 0x0000011b)"; $lblLprTitle.Location = '15,15'; $lblLprTitle.Size = '700,25'
        $lblLprTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $lblLprTitle.ForeColor = [System.Drawing.Color]::Gold
        [void]$pnlLpr.Controls.Add($lblLprTitle)

        # Card Origem (Esquerda)
        $pnlServerCard = New-Object System.Windows.Forms.Panel
        $pnlServerCard.Location = '15,50'; $pnlServerCard.Size = '345,450'
        $pnlServerCard.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 40)
        [void]$pnlLpr.Controls.Add($pnlServerCard)

        $lblSrvTitle = New-Object System.Windows.Forms.Label
        $lblSrvTitle.Text = "ETAPA 1: PC da Impressora USB (Origem)"; $lblSrvTitle.Location = '15,15'; $lblSrvTitle.Size = '315,20'
        $lblSrvTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $lblSrvTitle.ForeColor = [System.Drawing.Color]::FromArgb(135, 206, 250) # LightSkyBlue
        [void]$pnlServerCard.Controls.Add($lblSrvTitle)

        $lblSrvDesc = New-Object System.Windows.Forms.Label
        $lblSrvDesc.Text = "Configure o computador onde a impressora está ligada no USB.`n`nAtiva o serviço LPD e a porta TCP 515 no Firewall."
        $lblSrvDesc.Location = '15,45'; $lblSrvDesc.AutoSize = $true; $lblSrvDesc.MaximumSize = New-Object System.Drawing.Size(315, 0)
        $lblSrvDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $lblSrvDesc.ForeColor = 'WhiteSmoke'
        [void]$pnlServerCard.Controls.Add($lblSrvDesc)

        $lblSrvAlert = New-Object System.Windows.Forms.Label
        $lblSrvAlert.Text = "[!] ATENÇÃO:`nVocê DEVE compartilhar a impressora na aba 'Impressoras Locais' com um nome simples (ex: IMPRESSORA) para que a rede possa acessá-la!"
        $lblSrvAlert.Location = '15,115'; $lblSrvAlert.AutoSize = $true; $lblSrvAlert.MaximumSize = New-Object System.Drawing.Size(315, 0)
        $lblSrvAlert.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        $lblSrvAlert.ForeColor = [System.Drawing.Color]::Gold
        [void]$pnlServerCard.Controls.Add($lblSrvAlert)

        $btnActServer = New-Object System.Windows.Forms.Button
        $btnActServer.Text = "ATIVAR LPD NESTE COMPUTADOR"; $btnActServer.Location = '15,215'; $btnActServer.Size = '315,45'
        $btnActServer.BackColor = [System.Drawing.Color]::FromArgb(30, 80, 30); $btnActServer.FlatStyle = 'Flat'; $btnActServer.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnActServer.Cursor = 'Hand'; $btnActServer.ForeColor = 'White'; $btnActServer.FlatAppearance.BorderSize = 0
        $btnActServer.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 100, 40)
        $btnActServer.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(20, 60, 20)
        $btnActServer.Add_Click({
            $btnActServer.Enabled = $false
            $btnActServer.Text = "Configurando LPD..."
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                Log-Message "INFO" "Habilitando Servico LPD..."
                $proc = Start-Process cmd -ArgumentList "/c title Ativando Recurso LPD (Aguarde...) && dism /online /enable-feature /featurename:Printing-Foundation-LPDPrintService /all /norestart" -PassThru
                while (-not $proc.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 100
                }
                # 3010 e 1641 NAO sao erro: o DISM instalou e esta avisando que
                # precisa reiniciar. Tratar como falha abortava a configuracao
                # inteira justamente na maquina onde o recurso ainda nao existia.
                $reinicioPendente = $false
                if ($proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1641) {
                    $reinicioPendente = $true
                    Log-Message "INFO" "Recurso instalado. O Windows pediu reinicio (codigo $($proc.ExitCode))."
                }
                elseif ($proc.ExitCode -ne 0) {
                    throw "Falha no DISM. Codigo: $($proc.ExitCode)"
                }

                Log-Message "INFO" "Configurando o servico LPDSVC..."
                sc.exe config LPDSVC start= auto | Out-Null

                # Se o servico cair no meio do movimento, o Windows sobe sozinho
                sc.exe failure LPDSVC reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null

                Log-Message "INFO" "Adicionando regra de Firewall..."
                # Apaga antes de criar: senao cada clique empilha uma regra igual
                netsh advfirewall firewall delete rule name="LPD Porta 515" 2>&1 | Out-Null
                netsh advfirewall firewall add rule name="LPD Porta 515" dir=in action=allow protocol=TCP localport=515 | Out-Null

                # O spooler REINICIA ANTES do LPD de proposito: o LPDSVC e um
                # servico dependente do Spooler, entao reiniciar o spooler
                # derruba o LPD junto e nao o religa. Fazendo nesta ordem o LPD
                # sobe por ultimo e fica de pe.
                Log-Message "INFO" "Reiniciando spooler..."
                Restart-Service -Name Spooler -Force
                Start-Sleep -Milliseconds 800

                Log-Message "INFO" "Iniciando o servico LPDSVC..."
                net start LPDSVC | Out-Null

                $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
                $txtIps = $ips -join " ou "
                if (-not $txtIps) { $txtIps = "Não detectado" }

                # --- CONFERENCIA REAL ---
                # O 'net start' acima nao avisa quando falha. Sem conferir aqui,
                # a janela dizia "Ativado com sucesso" mesmo com o LPD morto -
                # que e o caso classico de quando o recurso so sobe apos reiniciar.
                $svc = Get-Service LPDSVC -ErrorAction SilentlyContinue
                if ($svc -and $svc.Status -ne 'Running') {
                    try { Start-Service LPDSVC -ErrorAction Stop; Start-Sleep -Milliseconds 900 } catch {}
                    $svc = Get-Service LPDSVC -ErrorAction SilentlyContinue
                }
                $escutando = $false
                try { $escutando = [bool](Get-NetTCPConnection -LocalPort 515 -State Listen -ErrorAction Stop) } catch {}

                # Nome da fila que o outro PC vai usar na porta LPR
                $filas = @()
                try { $filas = @(Get-Printer -ErrorAction Stop | Where-Object { $_.Shared } | ForEach-Object { "   - $($_.ShareName)      (impressora: $($_.Name))" }) } catch {}
                $txtFilas = if ($filas.Count -gt 0) { $filas -join "`n" } else { "   (nenhuma compartilhada ainda - faca isso na Aba 1)" }

                if ($null -eq $svc) {
                    Log-Message "ERRO" "LPDSVC nao existe: o recurso so aparece depois de reiniciar o Windows."
                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:PrinterManagerForm,
                        "O recurso LPD foi INSTALADO com sucesso, mas o servico ainda nao existe nesta maquina.`n`nIsso e normal quando o recurso acabou de ser adicionado: o Windows so cria o LPDSVC depois de REINICIAR.`n`n>>> Reinicie o computador e clique neste botao de novo. <<<`n`nNao precisa refazer mais nada - a porta 515 no firewall ja foi liberada.",
                        "Precisa reiniciar", "OK", "Warning") | Out-Null
                }
                elseif ($svc.Status -ne 'Running' -or -not $escutando) {
                    Log-Message "ERRO" "LPD nao ficou ativo. Servico: $($svc.Status) | Porta 515: $(if ($escutando) { 'escutando' } else { 'nao escuta' })"
                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:PrinterManagerForm,
                        "A configuracao rodou, mas o LPD NAO ficou ativo:`n`n   Servico LPDSVC : $($svc.Status)`n   Porta 515      : $(if ($escutando) { 'escutando' } else { 'NAO esta escutando' })`n`n$(if ($reinicioPendente) { 'O Windows avisou que o recurso pede REINICIO. Reinicie e clique neste botao de novo.' } else { 'Na maioria das vezes resolve REINICIAR o computador e clicar neste botao de novo.' })`n`nSe continuar assim, verifique se algum antivirus esta bloqueando o servico.",
                        "LPD nao ativou", "OK", "Warning") | Out-Null
                }
                else {
                    Log-Message "SUCESSO" "LPD ativo e confirmado (servico Running, porta 515 escutando)."
                    Log-Message "INFO" ">>> IP DESTE COMPUTADOR: $txtIps <<<"
                    Log-Message "INFO" "IMPORTANTE: Agora compartilhe a impressora na Aba 1 com nome simples."

                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:PrinterManagerForm,
                        "LPD Ativado e testado com sucesso!`n`n   Servico LPDSVC : Rodando (com reinicio automatico)`n   Porta 515      : Escutando`n   IP da Maquina  : $txtIps`n`nFilas disponiveis para o LPR:`n$txtFilas`n`nProximos Passos:`n1. Compartilhe a impressora USB na Aba 1 (ex: IMPRESSORA).`n2. Fixe o IP deste computador no roteador.`n3. Va para o outro PC e configure como Cliente LPR.",
                        "LPD Configurado", "OK", "Information") | Out-Null
                }
            }
            catch {
                Log-Message "ERRO" "Falha ao configurar LPD: $_"
                [System.Windows.Forms.MessageBox]::Show($Script:PrinterManagerForm, "Erro na configuracao do LPD: $_", "Erro LPD", "OK", "Error") | Out-Null
            }
            finally {
                $btnActServer.Enabled = $true
                $btnActServer.Text = "ATIVAR LPD NESTE COMPUTADOR"
            }
        })
        [void]$pnlServerCard.Controls.Add($btnActServer)

        $btnGoShare = New-Object System.Windows.Forms.Button
        $btnGoShare.Text = "COMPARTILHAR IMPRESSORA AGORA"; $btnGoShare.Location = '15,270'; $btnGoShare.Size = '315,35'
        $btnGoShare.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnGoShare.FlatStyle = 'Flat'; $btnGoShare.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnGoShare.Cursor = 'Hand'; $btnGoShare.ForeColor = 'White'; $btnGoShare.FlatAppearance.BorderSize = 0
        $btnGoShare.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 112, 80)
        $btnGoShare.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(10, 68, 48)
        $btnGoShare.Add_Click({
            $pnlLocal.Visible = $true
            $pnlLpr.Visible = $false
            $btnTabLocal.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnTabLocal.ForeColor = 'White'
            $btnTabLpr.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 50); $btnTabLpr.ForeColor = 'LightGray'
        })
        [void]$pnlServerCard.Controls.Add($btnGoShare)

        $lblIpSrv = New-Object System.Windows.Forms.Label
        $lblIpSrv.Text = "IP Atual deste PC:"; $lblIpSrv.Location = '15,320'; $lblIpSrv.AutoSize = $true
        $lblIpSrv.ForeColor = 'Gray'
        [void]$pnlServerCard.Controls.Add($lblIpSrv)

        $txtIpSrv = New-Object System.Windows.Forms.TextBox
        $txtIpSrv.Location = '15,340'; $txtIpSrv.Width = 315; $txtIpSrv.ReadOnly = $true
        $txtIpSrv.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 50); $txtIpSrv.ForeColor = 'LimeGreen'; $txtIpSrv.BorderStyle = 'FixedSingle'
        $txtIpSrv.Font = New-Object System.Drawing.Font("Consolas", 10.5, [System.Drawing.FontStyle]::Bold)
        try {
            $activeIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
            $txtIpSrv.Text = $activeIps -join ", "
        } catch { $txtIpSrv.Text = "IP não encontrado" }
        [void]$pnlServerCard.Controls.Add($txtIpSrv)


        # Card Destino (Direita)
        $pnlClientCard = New-Object System.Windows.Forms.Panel
        $pnlClientCard.Location = '375,50'; $pnlClientCard.Size = '345,450'
        $pnlClientCard.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 40)
        [void]$pnlLpr.Controls.Add($pnlClientCard)

        $lblCliTitle = New-Object System.Windows.Forms.Label
        $lblCliTitle.Text = "ETAPA 2: No outro PC da rede (Destino)"; $lblCliTitle.Location = '15,15'; $lblCliTitle.Size = '315,20'
        $lblCliTitle.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $lblCliTitle.ForeColor = [System.Drawing.Color]::FromArgb(135, 206, 250) # LightSkyBlue
        [void]$pnlClientCard.Controls.Add($lblCliTitle)

        $lblCliDesc = New-Object System.Windows.Forms.Label
        $lblCliDesc.Text = "Configure o outro computador da rede que precisa enviar impressões para a impressora USB.`n`nAtiva o Monitor LPR do Windows e reinicia o spooler."
        $lblCliDesc.Location = '15,45'; $lblCliDesc.AutoSize = $true; $lblCliDesc.MaximumSize = New-Object System.Drawing.Size(315, 0)
        $lblCliDesc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
        $lblCliDesc.ForeColor = 'WhiteSmoke'
        [void]$pnlClientCard.Controls.Add($lblCliDesc)

        $btnActClient = New-Object System.Windows.Forms.Button
        $btnActClient.Text = "ATIVAR MONITOR LPR"; $btnActClient.Location = '15,125'; $btnActClient.Size = '315,45'
        $btnActClient.BackColor = [System.Drawing.Color]::FromArgb(30, 80, 30); $btnActClient.FlatStyle = 'Flat'; $btnActClient.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnActClient.Cursor = 'Hand'; $btnActClient.ForeColor = 'White'; $btnActClient.FlatAppearance.BorderSize = 0
        $btnActClient.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 100, 40)
        $btnActClient.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(20, 60, 20)
        $btnActClient.Add_Click({
            $btnActClient.Enabled = $false
            $btnActClient.Text = "Configurando LPR..."
            [System.Windows.Forms.Application]::DoEvents()
            
            try {
                Log-Message "INFO" "Habilitando Recurso LPR..."
                $proc = Start-Process cmd -ArgumentList "/c title Ativando Recurso LPR (Aguarde...) && dism /online /enable-feature /featurename:Printing-Foundation-LPRPortMonitor /all /norestart" -PassThru
                while (-not $proc.HasExited) {
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 100
                }
                # 3010 e 1641 NAO sao erro: o DISM instalou e esta avisando que
                # precisa reiniciar. Tratar como falha abortava a configuracao
                # inteira justamente na maquina onde o recurso ainda nao existia.
                $reinicioPendente = $false
                if ($proc.ExitCode -eq 3010 -or $proc.ExitCode -eq 1641) {
                    $reinicioPendente = $true
                    Log-Message "INFO" "Recurso instalado. O Windows pediu reinicio (codigo $($proc.ExitCode))."
                }
                elseif ($proc.ExitCode -ne 0) {
                    throw "Falha no DISM. Codigo: $($proc.ExitCode)"
                }

                Log-Message "INFO" "Reiniciando spooler..."
                Restart-Service -Name Spooler -Force
                
                Log-Message "SUCESSO" "Cliente LPR ativado com sucesso!"
                
                $colinha = @"
COLA RÁPIDA - INSTALAR VIA LPR
===============================
1. Selecione: 'A impressora que eu quero não está na lista'
2. Selecione: 'Adicionar uma impressora local ou de rede com configurações manuais'
3. Selecione: 'Criar uma nova porta' -> Escolha: 'LPR Port'
4. Digite o IP do PC com a Impressora USB no campo 'Nome ou endereço do servidor' (Ex: 192.168.0.10)
5. Digite o Nome do Compartilhamento no campo 'Nome da impressora ou fila' (Ex: IMPRESSORA)
6. Escolha o driver correspondente e conclua.
"@
                [System.Windows.Forms.Clipboard]::SetText($colinha)
                Log-Message "INFO" "Passo a passo de instalação LPR copiado para a Área de Trabalho."

                [System.Windows.Forms.MessageBox]::Show(
                    $Script:PrinterManagerForm,
                    "Cliente LPR Ativado com sucesso!`n`nO passo a passo foi copiado para sua Área de Transferência!$(if ($reinicioPendente) { "`n`nATENCAO: o Windows pediu REINICIO para o recurso valer.`nSe a opcao 'LPR Port' nao aparecer no assistente, reinicie o computador." })`n`nAgora clique no botao 'ABRIR ASSISTENTE' para adicionar a impressora no Windows.",
                    "LPR Configurado", "OK", "Information") | Out-Null
                
                Start-Process "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry /il"
            }
            catch {
                Log-Message "ERRO" "Falha ao configurar Cliente LPR: $_"
                [System.Windows.Forms.MessageBox]::Show($Script:PrinterManagerForm, "Erro na configuracao do Cliente LPR: $_", "Erro LPR", "OK", "Error") | Out-Null
            }
            finally {
                $btnActClient.Enabled = $true
                $btnActClient.Text = "ATIVAR MONITOR LPR"
            }
        })
        [void]$pnlClientCard.Controls.Add($btnActClient)

        $btnWizard = New-Object System.Windows.Forms.Button
        $btnWizard.Text = "ABRIR ASSISTENTE DO WINDOWS"; $btnWizard.Location = '15,180'; $btnWizard.Size = '315,45'
        $btnWizard.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btnWizard.FlatStyle = 'Flat'; $btnWizard.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnWizard.Cursor = 'Hand'; $btnWizard.ForeColor = 'White'; $btnWizard.FlatAppearance.BorderSize = 0
        $btnWizard.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 112, 80)
        $btnWizard.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(10, 68, 48)
        $btnWizard.Add_Click({
            Start-Process "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry /il"
            Log-Message "INFO" "Assistente de impressora aberto manualmente."
        })
        [void]$pnlClientCard.Controls.Add($btnWizard)

        $txtInstLpr = New-Object System.Windows.Forms.RichTextBox
        $txtInstLpr.Location = '15,240'; $txtInstLpr.Size = '315,195'
        $txtInstLpr.ReadOnly = $true; $txtInstLpr.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 30); $txtInstLpr.ForeColor = 'LightYellow'
        $txtInstLpr.BorderStyle = 'None'; $txtInstLpr.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $txtInstLpr.Text = "AJUDA DE INSTALAÇÃO (LPR):`n1. Criar nova porta -> LPR Port`n2. Servidor: [IP do PC com o cabo USB]`n3. Nome da fila: [Nome Compartilhado] (ex: IMPRESSORA)`n4. Escolha o driver correspondente."
        [void]$pnlClientCard.Controls.Add($txtInstLpr)

        $Script:PrinterManagerForm.Add_FormClosing({ $Script:PrinterManagerForm = $null })
        $Script:PrinterManagerForm.Add_Shown({ $this.ActiveControl = $null })
        $Script:PrinterManagerForm.ShowDialog($Script:MainForm)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Erro ao abrir Gerenciador de Impressoras: $_", "Erro")
    }
}

function Show-PingTester {
    param([string]$InitialIP = "")

    if ($null -ne $Script:PingForm -and -not $Script:PingForm.IsDisposed) {
        if ($InitialIP) { $Script:PingTxtIP.Text = $InitialIP }
        $Script:PingForm.Activate()
        return
    }

    # Esta janela nao e modal: quando a funcao retorna o escopo local morre.
    # Por isso tudo que os eventos usam fica em $Script: (mesmo padrao do
    # codigo original) - closures aqui nao servem, porque dentro de
    # GetNewClosure() o prefixo $Script: passa a apontar para outro escopo.
    $Script:PingHist = New-Object System.Collections.ArrayList
    $Script:PingEnviados = 0
    $Script:PingRecebidos = 0
    $Script:PingLogPath = ""
    $Script:PingInicial = $InitialIP

    $f = New-ToolForm "Teste de Ping" 720 640
    $Script:PingForm = $f

    New-ToolLabel $f "TESTE DE CONEXAO CONTINUO" 20 14 12 -Negrito | Out-Null
    New-ToolLabel $f "Destino (IP ou nome):" 20 48 9 -Cor $Script:UiSuave | Out-Null

    $Script:PingTxtIP = New-Object System.Windows.Forms.TextBox
    $Script:PingTxtIP.Location = New-Object System.Drawing.Point(160, 45)
    $Script:PingTxtIP.Size = New-Object System.Drawing.Size(220, 24)
    $Script:PingTxtIP.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
    $Script:PingTxtIP.ForeColor = $Script:UiTexto
    $Script:PingTxtIP.BorderStyle = 'FixedSingle'
    $Script:PingTxtIP.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    if ($InitialIP) { $Script:PingTxtIP.Text = $InitialIP }
    [void]$f.Controls.Add($Script:PingTxtIP)

    New-ToolLabel $f "Intervalo:" 396 48 9 -Cor $Script:UiSuave | Out-Null
    $Script:PingCmbInt = New-Object System.Windows.Forms.ComboBox
    $Script:PingCmbInt.Location = New-Object System.Drawing.Point(462, 45)
    $Script:PingCmbInt.Size = New-Object System.Drawing.Size(90, 24)
    $Script:PingCmbInt.DropDownStyle = 'DropDownList'
    $Script:PingCmbInt.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
    $Script:PingCmbInt.ForeColor = $Script:UiTexto
    $Script:PingCmbInt.FlatStyle = 'Flat'
    [void]$Script:PingCmbInt.Items.AddRange(@("0,5 seg", "1 seg", "2 seg", "5 seg"))
    $Script:PingCmbInt.SelectedIndex = 1
    [void]$f.Controls.Add($Script:PingCmbInt)

    $Script:PingBtnRun = New-ToolButton $f "INICIAR" 566 44 130 34 $Script:UiAzul $null "Comeca ou para o teste"

    # Atalhos para os destinos que mais aparecem no suporte
    New-ToolLabel $f "Atalhos:" 20 90 8.5 -Cor $Script:UiSuave | Out-Null
    $Script:PingGw = ""
    try {
        $cfgRede = Get-NetIPConfiguration | Where-Object { $null -ne $_.IPv4DefaultGateway } | Select-Object -First 1
        if ($cfgRede) { $Script:PingGw = $cfgRede.IPv4DefaultGateway.NextHop }
    }
    catch {}

    $bAt1 = New-ToolButton $f "Gateway" 82 86 120 28 $Script:UiCinza { $Script:PingTxtIP.Text = $Script:PingGw } "Testa o roteador da rede local"
    $bAt2 = New-ToolButton $f "Google DNS" 210 86 120 28 $Script:UiCinza { $Script:PingTxtIP.Text = "8.8.8.8" } "Testa a internet (8.8.8.8)"
    $bAt3 = New-ToolButton $f "NetControll" 338 86 140 28 $Script:UiCinza { $Script:PingTxtIP.Text = "adm2.netcontroll.com.br" } "Testa o servidor NetControll"
    $bAt4 = New-ToolButton $f "Site (DNS)" 486 86 120 28 $Script:UiCinza { $Script:PingTxtIP.Text = "google.com" } "Testa resolucao de nomes"
    foreach ($bb in @($bAt1, $bAt2, $bAt3, $bAt4)) {
        $bb.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
    }
    if (-not $Script:PingGw) { $bAt1.Enabled = $false }

    # Cartoes de estatistica
    $Script:PingGPerda = New-Gauge $f "PERDA DE PACOTES" 20 124 216 86 $Script:UiVerde
    $Script:PingGMedia = New-Gauge $f "TEMPO MEDIO" 246 124 216 86 $Script:UiAzul
    $Script:PingGUltimo = New-Gauge $f "ULTIMA RESPOSTA" 472 124 216 86 $Script:UiAzul

    # Grafico das ultimas respostas
    $Script:PingGraf = New-Object System.Windows.Forms.Panel
    $Script:PingGraf.Location = New-Object System.Drawing.Point(20, 220)
    $Script:PingGraf.Size = New-Object System.Drawing.Size(668, 96)
    $Script:PingGraf.Anchor = 'Top,Left,Right'
    $Script:PingGraf.BackColor = $Script:UiFundo
    $Script:PingGraf.Add_Paint({
            param($s, $e)
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $g.Clear($s.Parent.BackColor)
            $cartao = New-RoundedRectPath -X 0 -Y 0 -W $s.Width -H $s.Height -R 8
            $bc = New-Object System.Drawing.SolidBrush($Script:UiCartao)
            $g.FillPath($bc, $cartao)
            $bc.Dispose(); $cartao.Dispose()

            $dados = @($Script:PingHist)
            if ($dados.Count -lt 1) {
                $fnt = New-Object System.Drawing.Font("Segoe UI", 9)
                [System.Windows.Forms.TextRenderer]::DrawText($g, "O grafico das respostas aparece aqui durante o teste", $fnt,
                    (New-Object System.Drawing.Rectangle(0, 0, $s.Width, $s.Height)), $Script:UiSuave,
                    ([System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter))
                $fnt.Dispose()
                return
            }

            $margem = 10
            $larg = $s.Width - ($margem * 2)
            $alt = $s.Height - ($margem * 2)
            $maxV = 20
            foreach ($v in $dados) { if ($v -gt $maxV) { $maxV = $v } }

            $n = $dados.Count
            $lb = [Math]::Max(2, [int]($larg / $n) - 1)
            $i = 0
            foreach ($v in $dados) {
                $x = $margem + [int]($i * ($larg / $n))
                if ($v -lt 0) {
                    $b = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(190, 222, 70, 70))
                    $g.FillRectangle($b, $x, $margem, $lb, $alt)
                    $b.Dispose()
                }
                else {
                    $hb = [int](($v / $maxV) * $alt)
                    if ($hb -lt 2) { $hb = 2 }
                    $cor = if ($v -lt 50) { $Script:UiVerde } elseif ($v -lt 150) { $Script:UiAmarelo } else { $Script:UiVermelho }
                    $b = New-Object System.Drawing.SolidBrush($cor)
                    $g.FillRectangle($b, $x, ($margem + $alt - $hb), $lb, $hb)
                    $b.Dispose()
                }
                $i++
            }

            $fnt2 = New-Object System.Drawing.Font("Segoe UI", 8)
            [System.Windows.Forms.TextRenderer]::DrawText($g, "pico $maxV ms  -  vermelho = sem resposta", $fnt2,
                (New-Object System.Drawing.Rectangle(0, 4, ($s.Width - 12), 14)), $Script:UiSuave,
                ([System.Windows.Forms.TextFormatFlags]::Right))
            $fnt2.Dispose()
        })
    [void]$f.Controls.Add($Script:PingGraf)

    $Script:PingRtb = New-Object System.Windows.Forms.RichTextBox
    $Script:PingRtb.Location = New-Object System.Drawing.Point(20, 326)
    $Script:PingRtb.Size = New-Object System.Drawing.Size(668, 214)
    $Script:PingRtb.Anchor = 'Top,Left,Right,Bottom'
    $Script:PingRtb.BackColor = [System.Drawing.Color]::FromArgb(14, 17, 24)
    $Script:PingRtb.ForeColor = $Script:UiTexto
    $Script:PingRtb.ReadOnly = $true
    $Script:PingRtb.BorderStyle = 'None'
    $Script:PingRtb.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    [void]$f.Controls.Add($Script:PingRtb)

    $Script:PingChkLog = New-Object System.Windows.Forms.CheckBox
    $Script:PingChkLog.Text = "Salvar log na Area de Trabalho"
    $Script:PingChkLog.Location = New-Object System.Drawing.Point(20, 558)
    $Script:PingChkLog.AutoSize = $true
    $Script:PingChkLog.ForeColor = $Script:UiTexto
    $Script:PingChkLog.Anchor = 'Bottom,Left'
    [void]$f.Controls.Add($Script:PingChkLog)

    $Script:PingAtualizarCartoes = {
        $perdidos = $Script:PingEnviados - $Script:PingRecebidos
        $perdaPct = if ($Script:PingEnviados -gt 0) { ($perdidos / $Script:PingEnviados) * 100 } else { 0 }
        $corPerda = if ($perdaPct -ge 20) { $Script:UiVermelho } elseif ($perdaPct -ge 5) { $Script:UiAmarelo } else { $Script:UiVerde }
        Update-Gauge $Script:PingGPerda $perdaPct ("{0:N0} %" -f $perdaPct) "$perdidos perdidos de $($Script:PingEnviados)" $corPerda

        $ok = @($Script:PingHist | Where-Object { $_ -ge 0 })
        if ($ok.Count -gt 0) {
            $med = ($ok | Measure-Object -Average).Average
            $mn = ($ok | Measure-Object -Minimum).Minimum
            $mx = ($ok | Measure-Object -Maximum).Maximum
            $corMed = if ($med -ge 150) { $Script:UiVermelho } elseif ($med -ge 50) { $Script:UiAmarelo } else { $Script:UiVerde }
            Update-Gauge $Script:PingGMedia ([Math]::Min(100, $med / 3)) ("{0:N0} ms" -f $med) ("min $mn ms  -  max $mx ms") $corMed

            $ult = $Script:PingHist[$Script:PingHist.Count - 1]
            if ($ult -lt 0) {
                Update-Gauge $Script:PingGUltimo 100 "SEM RESPOSTA" "o destino nao respondeu" $Script:UiVermelho
            }
            else {
                $corU = if ($ult -ge 150) { $Script:UiVermelho } elseif ($ult -ge 50) { $Script:UiAmarelo } else { $Script:UiVerde }
                Update-Gauge $Script:PingGUltimo ([Math]::Min(100, $ult / 3)) ("{0:N0} ms" -f $ult) "resposta mais recente" $corU
            }
        }
        else {
            Update-Gauge $Script:PingGMedia 0 "--" "aguardando respostas" $Script:UiAzul
            Update-Gauge $Script:PingGUltimo 0 "--" "aguardando respostas" $Script:UiAzul
        }
        $Script:PingGraf.Invalidate()
    }

    $Script:PingTimerObj = New-Object System.Windows.Forms.Timer
    $Script:PingTimerObj.Interval = 1000

    $Script:PingTimerObj.Add_Tick({
            $alvo = $Script:PingTxtIP.Text.Trim()
            if ([string]::IsNullOrEmpty($alvo)) { return }

            $pingObj = New-Object System.Net.NetworkInformation.Ping
            $resp = $null
            try { $resp = $pingObj.Send($alvo, 1200) } catch {}
            $hora = Get-Date -Format "HH:mm:ss"
            $Script:PingEnviados++

            if ($null -ne $resp -and $resp.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $Script:PingRecebidos++
                $ms = [int]$resp.RoundtripTime
                [void]$Script:PingHist.Add($ms)
                $msg = "[$hora] Resposta de $($resp.Address): $ms ms   (TTL $($resp.Options.Ttl))`n"
                $Script:PingRtb.SelectionColor = if ($ms -lt 50) { $Script:UiVerde } elseif ($ms -lt 150) { $Script:UiAmarelo } else { $Script:UiVermelho }
            }
            else {
                [void]$Script:PingHist.Add(-1)
                $estado = if ($null -ne $resp) { $resp.Status } else { "Timeout" }
                $msg = "[$hora] FALHA ($estado) - sem resposta de $alvo`n"
                $Script:PingRtb.SelectionColor = $Script:UiVermelho
            }

            while ($Script:PingHist.Count -gt 120) { $Script:PingHist.RemoveAt(0) }

            $Script:PingRtb.AppendText($msg)
            $Script:PingRtb.ScrollToCaret()
            # Nao deixa o texto crescer sem limite dentro da janela
            if ($Script:PingRtb.Lines.Count -gt 600) {
                $Script:PingRtb.Text = ($Script:PingRtb.Lines | Select-Object -Last 300) -join "`n"
                $Script:PingRtb.SelectionStart = $Script:PingRtb.TextLength
            }

            & $Script:PingAtualizarCartoes

            if ($Script:PingChkLog.Checked -and $Script:PingLogPath -ne "") {
                $msg.Trim() | Out-File $Script:PingLogPath -Append -Encoding utf8
            }
        })

    $Script:PingBtnRun.Add_Click({
            if ($Script:PingTimerObj.Enabled) {
                $Script:PingTimerObj.Stop()
                $Script:PingBtnRun.Text = "INICIAR"
                $Script:PingBtnRun.BackColor = $Script:UiAzul
                $Script:PingBtnRun.Invalidate()
                $Script:PingTxtIP.Enabled = $true
                $Script:PingCmbInt.Enabled = $true
                $Script:PingChkLog.Enabled = $true
                $Script:PingRtb.SelectionColor = $Script:UiSuave
                $Script:PingRtb.AppendText("--- Parado. Enviados: $($Script:PingEnviados) | Recebidos: $($Script:PingRecebidos) | Perdidos: $($Script:PingEnviados - $Script:PingRecebidos) ---`n")
            }
            else {
                $alvo = $Script:PingTxtIP.Text.Trim()
                if ([string]::IsNullOrEmpty($alvo)) {
                    [System.Windows.Forms.MessageBox]::Show("Digite um IP ou nome de destino.", "Ping", "OK", "Information") | Out-Null
                    return
                }
                switch ($Script:PingCmbInt.SelectedIndex) {
                    0 { $Script:PingTimerObj.Interval = 500 }
                    1 { $Script:PingTimerObj.Interval = 1000 }
                    2 { $Script:PingTimerObj.Interval = 2000 }
                    3 { $Script:PingTimerObj.Interval = 5000 }
                }
                $Script:PingEnviados = 0
                $Script:PingRecebidos = 0
                $Script:PingHist.Clear()
                $Script:PingBtnRun.Text = "PARAR"
                $Script:PingBtnRun.BackColor = $Script:UiVermelho
                $Script:PingBtnRun.Invalidate()
                $Script:PingTxtIP.Enabled = $false
                $Script:PingCmbInt.Enabled = $false
                $Script:PingChkLog.Enabled = $false

                if ($Script:PingChkLog.Checked) {
                    $Script:PingLogPath = Join-Path $Script:DesktopPath "PingLog_$($alvo.Replace('.', '_').Replace(':', '_'))_$(Get-Date -Format 'yyyyMMdd_HHmm').txt"
                    "--- Log de ping para $alvo iniciado em $(Get-Date) ---" | Out-File $Script:PingLogPath -Encoding utf8
                    $Script:PingRtb.SelectionColor = $Script:UiSuave
                    $Script:PingRtb.AppendText(">> Gravando em: $Script:PingLogPath`n")
                }
                else { $Script:PingLogPath = "" }
                $Script:PingTimerObj.Start()
            }
        })

    New-ToolButton $f "LIMPAR" 300 552 120 32 $Script:UiCinza {
        $Script:PingRtb.Clear()
        $Script:PingHist.Clear()
        $Script:PingEnviados = 0
        $Script:PingRecebidos = 0
        & $Script:PingAtualizarCartoes
    } "Zera o historico e as estatisticas" | Out-Null

    $Script:PingBtnCopiar = New-ToolButton $f "COPIAR RESUMO" 430 552 258 32 $Script:UiCinza {
        $perdidos = $Script:PingEnviados - $Script:PingRecebidos
        $perdaPct = if ($Script:PingEnviados -gt 0) { ($perdidos / $Script:PingEnviados) * 100 } else { 0 }
        $ok = @($Script:PingHist | Where-Object { $_ -ge 0 })
        $med = if ($ok.Count -gt 0) { ($ok | Measure-Object -Average).Average } else { 0 }
        $mn = if ($ok.Count -gt 0) { ($ok | Measure-Object -Minimum).Minimum } else { 0 }
        $mx = if ($ok.Count -gt 0) { ($ok | Measure-Object -Maximum).Maximum } else { 0 }
        $txt = @"
=== TESTE DE PING ===
Destino:   $($Script:PingTxtIP.Text)
Data:      $(Get-Date -Format 'dd/MM/yyyy HH:mm')
Enviados:  $($Script:PingEnviados)
Recebidos: $($Script:PingRecebidos)
Perdidos:  $perdidos ($([Math]::Round($perdaPct, 1))%)
Tempo:     minimo $mn ms | medio $([Math]::Round($med, 1)) ms | maximo $mx ms
"@
        Set-Clipboard -Value $txt
        $Script:PingBtnCopiar.Text = "COPIADO!"
        $Script:PingBtnCopiar.Invalidate()
    } "Copia um resumo pronto para colar no chamado"

    $f.Add_FormClosing({
            param($s, $e)
            if ($Script:PingTimerObj.Enabled) {
                $r = [System.Windows.Forms.MessageBox]::Show("O teste esta rodando. Deseja parar e fechar?", "Confirmar",
                    [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
                if ($r -eq [System.Windows.Forms.DialogResult]::No) { $e.Cancel = $true; return }
            }
            try { $Script:PingTimerObj.Stop(); $Script:PingTimerObj.Dispose() } catch {}
            $Script:PingForm = $null
        })

    $f.Add_Shown({ if ($Script:PingInicial) { $Script:PingBtnRun.PerformClick() } })

    & $Script:PingAtualizarCartoes
    $f.Show()
}

# -----------------------------------------------------------------------------
# 3.45 FECHAR CONCENTRADOR E NETSTART (usado antes de instalar o TecnoSpeed)
# -----------------------------------------------------------------------------
function Close-NetControllSystem {
    Log-Message "INFO" "Fechando Concentrador e NetStart..."
    $closed = @()

    foreach ($name in @("Concentrador", "NetStart")) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                $closed += $_.ProcessName
            }
            catch {}
        }
    }

    $closed = $closed | Select-Object -Unique
    if ($closed.Count -gt 0) {
        Log-Message "SUCESSO" "Programas fechados: $($closed -join ', ')"
    }
    else {
        Log-Message "INFO" "Concentrador/NetStart nao estavam abertos."
    }
    Wait-UI 0.5
}

# -----------------------------------------------------------------------------
# 3.5 DEPLOY COM BACKUP AUTOMATICO (PDV / LinkXMenu)
# -----------------------------------------------------------------------------
function Deploy-WithBackup {
    param($SourcePath, $Type, $Version)
    
    $destPath = ""
    $backupName = ""
    
    if ($Type -eq "PDV") {
        $destPath = "C:\netcontroll\NetPDV"
        $backupName = "NetPDV.OLD"
    }
    elseif ($Type -eq "LinkXMenu") {
        $destPath = "C:\XMenu"
        $backupName = "XMenu.OLD"
    }
    else { return }
    
    $parentDir = Split-Path $destPath
    $backupPath = Join-Path $parentDir $backupName
    
    # Verifica se o programa esta aberto (arquivos travados)
    $processNames = @()
    if ($Type -eq "PDV") { $processNames = @("NetPDV") }
    elseif ($Type -eq "LinkXMenu") { $processNames = @("LinkXMenu", "XMenu") }
    
    foreach ($procName in $processNames) {
        $running = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($running) {
            Log-Message "ERRO" "O programa $procName esta aberto! Feche-o antes de atualizar."
            [System.Windows.Forms.MessageBox]::Show(
                "O programa '$procName' esta aberto!`n`nFeche o $Type completamente antes de atualizar.`nO deploy foi cancelado para evitar problemas.",
                "Programa Aberto - Deploy Cancelado", "OK", "Warning") | Out-Null
            return
        }
    }
    
    try {
        Log-Message "INFO" "Iniciando deploy com backup para $Type (Versao: $Version)..."
        [System.Windows.Forms.Application]::DoEvents()
        
        # Remove backup antigo se existir (rapido via robocopy /PURGE)
        if (Test-Path $backupPath) {
            Log-Message "LOG" "Removendo backup antigo: $backupPath"
            Remove-Item $backupPath -Recurse -Force -ErrorAction SilentlyContinue
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        # Faz backup usando robocopy /MIR /MT:8 (multithread, muito mais rapido)
        if (Test-Path $destPath) {
            Log-Message "INFO" "Criando backup (robocopy): $destPath -> $backupPath"
            [System.Windows.Forms.Application]::DoEvents()
            $roboBackup = Start-Process "robocopy.exe" -ArgumentList "`"$destPath`" `"$backupPath`" /MIR /MT:8 /NFL /NDL /NJH /NJS" -NoNewWindow -Wait -PassThru
            # robocopy: exit code < 8 = sucesso
            if ($roboBackup.ExitCode -lt 8) {
                Log-Message "SUCESSO" "Backup criado com sucesso: $backupPath"
            } else {
                Log-Message "ERRO" "Backup retornou codigo $($roboBackup.ExitCode) - pode ter falhado parcialmente."
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
        else {
            Log-Message "INFO" "Pasta destino nao existe ainda, sera criada: $destPath"
            if (!(Test-Path $parentDir)) { New-Item -Path $parentDir -ItemType Directory -Force | Out-Null }
            New-Item -Path $destPath -ItemType Directory -Force | Out-Null
        }
        
        # Copia novos arquivos com robocopy /MT:8 (multithread paralelo)
        Log-Message "INFO" "Copiando arquivos com robocopy..."
        [System.Windows.Forms.Application]::DoEvents()
        $roboCopy = Start-Process "robocopy.exe" -ArgumentList "`"$SourcePath`" `"$destPath`" /E /MT:8 /IS /IT /NFL /NDL /NJH /NJS" -NoNewWindow -Wait -PassThru
        [System.Windows.Forms.Application]::DoEvents()
        
        # Conta arquivos da fonte (ZIP) que foram copiados
        $count = (Get-ChildItem -Path $SourcePath -Recurse -File -ErrorAction SilentlyContinue).Count
        Log-Message "SUCESSO" "$Type atualizado para $Version ($count arquivos atualizados)"
        
        [System.Windows.Forms.MessageBox]::Show(
            "ATUALIZACAO CONCLUIDA`n--------------------------------------`nPrograma: $Type`nVersao: $Version`nArquivos atualizados: $count`n--------------------------------------`nDestino: $destPath`nBackup: $backupPath",
            "Atualizado com Sucesso", "OK", "Information") | Out-Null
    }
    catch {
        Log-Message "ERRO" "Falha no deploy: $($_.Exception.Message)"
        
        # Tenta restaurar backup se o deploy falhou
        if (Test-Path $backupPath) {
            Log-Message "INFO" "Restaurando backup apos falha..."
            if (Test-Path $destPath) { Remove-Item $destPath -Recurse -Force -ErrorAction SilentlyContinue }
            Start-Process "robocopy.exe" -ArgumentList "`"$backupPath`" `"$destPath`" /MIR /MT:8 /NFL /NDL /NJH /NJS" -NoNewWindow -Wait | Out-Null
            Log-Message "INFO" "Backup restaurado."
        }
        
        [System.Windows.Forms.MessageBox]::Show(
            "Falha no deploy!`n$($_.Exception.Message)`n`nO backup foi restaurado.",
            "Erro Deploy", "OK", "Error") | Out-Null
    }
}

# -----------------------------------------------------------------------------
# 4. MOTOR DE DOWNLOAD E INSTALACAO
# -----------------------------------------------------------------------------

# --- BOTAO CANCELAR SOBREPOSTO ---
# Aparece em cima do proprio botao que o usuario clicou para baixar.
# Desenhado na mao (cantos arredondados + gradiente + sombra) para nao
# ficar com a cara quadrada padrao do WinForms.
function New-RoundedRectPath {
    param([int]$X, [int]$Y, [int]$W, [int]$H, [int]$R)
    $p = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $R * 2
    $p.AddArc($X, $Y, $d, $d, 180, 90)
    $p.AddArc(($X + $W - $d), $Y, $d, $d, 270, 90)
    $p.AddArc(($X + $W - $d), ($Y + $H - $d), $d, $d, 0, 90)
    $p.AddArc($X, ($Y + $H - $d), $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Get-CancelOverlay {
    if ($null -eq $Script:CancelOverlay) {
        $Script:CancelOverlayLabel = "✕  CANCELAR"
        $Script:CancelOverlayState = 'normal'
        $Script:CancelOverlayFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

        $ov = New-Object System.Windows.Forms.Button
        $ov.Text = ""            # o texto e desenhado no evento Paint
        $ov.FlatStyle = 'Flat'
        $ov.FlatAppearance.BorderSize = 0
        $ov.BackColor = [System.Drawing.Color]::FromArgb(200, 140, 0)
        $ov.Cursor = 'Hand'
        $ov.TabStop = $false
        $ov.Visible = $false

        # Double buffer: evita piscar ao repintar sobre o botao de download
        try {
            $pi = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', 'Instance,NonPublic')
            $pi.SetValue($ov, $true, $null)
        }
        catch {}

        $ov.Add_MouseEnter({ $Script:CancelOverlayState = 'hover'; $this.Invalidate() })
        $ov.Add_MouseLeave({ $Script:CancelOverlayState = 'normal'; $this.Invalidate() })
        $ov.Add_MouseDown({ $Script:CancelOverlayState = 'down'; $this.Invalidate() })
        $ov.Add_MouseUp({ $Script:CancelOverlayState = 'hover'; $this.Invalidate() })

        $ov.Add_Paint({
                param($s, $e)
                $w = $s.Width; $h = $s.Height
                if ($w -le 6 -or $h -le 6) { return }

                $g = $e.Graphics
                $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

                # Fundo: repinta o pedaco da barra de progresso que fica embaixo,
                # para os cantos arredondados casarem com o botao (sem "degraus")
                $tgt = $Script:CancelOverlayTarget
                if ($tgt -and -not $tgt.IsDisposed -and $Script:ProgressButton -eq $tgt) {
                    $estado = $g.Save()
                    $g.TranslateTransform([float](-$Script:CancelOverlayDX), [float](-$Script:CancelOverlayDY))
                    Draw-ButtonProgress -G $g -Btn $tgt -Pct $Script:ProgressPercent
                    $g.Restore($estado)
                }
                else {
                    $g.Clear($s.BackColor)
                }

                if (-not $s.Enabled) {
                    $c1 = [System.Drawing.Color]::FromArgb(122, 52, 52)
                    $c2 = [System.Drawing.Color]::FromArgb(96, 36, 36)
                    $fg = [System.Drawing.Color]::FromArgb(228, 196, 196)
                }
                elseif ($Script:CancelOverlayState -eq 'down') {
                    $c1 = [System.Drawing.Color]::FromArgb(178, 28, 28)
                    $c2 = [System.Drawing.Color]::FromArgb(146, 16, 16)
                    $fg = [System.Drawing.Color]::White
                }
                elseif ($Script:CancelOverlayState -eq 'hover') {
                    $c1 = [System.Drawing.Color]::FromArgb(246, 102, 102)
                    $c2 = [System.Drawing.Color]::FromArgb(216, 48, 48)
                    $fg = [System.Drawing.Color]::White
                }
                else {
                    $c1 = [System.Drawing.Color]::FromArgb(230, 78, 78)
                    $c2 = [System.Drawing.Color]::FromArgb(198, 34, 40)
                    $fg = [System.Drawing.Color]::White
                }

                $bw = $w - 2
                $bh = $h - 3
                $raio = 8

                # Sombra suave deslocada
                $sombra = New-RoundedRectPath -X 2 -Y 3 -W $bw -H $bh -R $raio
                $bSombra = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 0, 0, 0))
                $g.FillPath($bSombra, $sombra)

                # Corpo com gradiente vertical
                $corpo = New-RoundedRectPath -X 0 -Y 0 -W $bw -H $bh -R $raio
                $rect = New-Object System.Drawing.Rectangle(0, 0, $bw, $bh)
                $bCorpo = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, [float]90)
                $g.FillPath($bCorpo, $corpo)

                # Borda clara de 1px (efeito vidro)
                $pBorda = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(110, 255, 255, 255), 1)
                $g.DrawPath($pBorda, $corpo)

                $flags = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
                    [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                    [System.Windows.Forms.TextFormatFlags]::EndEllipsis
                [System.Windows.Forms.TextRenderer]::DrawText($g, $Script:CancelOverlayLabel, $Script:CancelOverlayFont, $rect, $fg, $flags)

                $pBorda.Dispose(); $bCorpo.Dispose(); $bSombra.Dispose()
                $corpo.Dispose(); $sombra.Dispose()
            })

        $ov.Add_Click({ Cancel-Download })
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($ov, "Cancelar o download em andamento") }
        $Script:CancelOverlay = $ov
    }
    return $Script:CancelOverlay
}

function Update-CancelOverlay {
    if (-not $Script:CancelOverlayActive) { return }
    $ov = $Script:CancelOverlay
    $target = $Script:CancelOverlayTarget
    if ($null -eq $ov -or $null -eq $target) { return }
    try {
        if ($target.IsDisposed -or -not $target.IsHandleCreated) { return }
        $owner = $ov.Parent
        if ($null -eq $owner) { return }

        # Converte a posicao do botao alvo para as coordenadas do formulario
        $ptScreen = $target.Parent.PointToScreen($target.Location)
        $pt = $owner.PointToClient($ptScreen)

        $w = 132
        $h = [Math]::Max(26, $target.Height - 12)
        $x = $pt.X + $target.Width - $w - 8
        $y = $pt.Y + [int](($target.Height - $h) / 2)

        # Se o botao alvo saiu da area visivel (rolagem), esconde o overlay
        $visivel = $true
        if ($Script:ScrollPanel -and -not $Script:ScrollPanel.IsDisposed -and $Script:ScrollPanel.IsHandleCreated) {
            $spTop = $owner.PointToClient($Script:ScrollPanel.PointToScreen((New-Object System.Drawing.Point(0, 0))))
            if ($y -lt $spTop.Y -or ($y + $h) -gt ($spTop.Y + $Script:ScrollPanel.Height)) { $visivel = $false }
        }

        if (-not $visivel) {
            if ($ov.Visible) { $ov.Visible = $false }
            return
        }

        # Deslocamento do overlay dentro do botao: o Paint usa isso para
        # repintar o trecho da barra que fica atras dos cantos arredondados
        $Script:CancelOverlayDX = $x - $pt.X
        $Script:CancelOverlayDY = $y - $pt.Y
        if ($ov.BackColor -ne $target.BackColor) { $ov.BackColor = $target.BackColor }

        if ($ov.Width -ne $w -or $ov.Height -ne $h) { $ov.Size = New-Object System.Drawing.Size($w, $h) }
        if ($ov.Left -ne $x -or $ov.Top -ne $y) { $ov.Location = New-Object System.Drawing.Point($x, $y) }
        if (-not $ov.Visible) { $ov.Visible = $true }
        $ov.Invalidate()
        $ov.BringToFront()
    }
    catch {}
}

function Show-CancelOverlay {
    param($Button)
    if ($null -eq $Button) { return }
    try {
        $frm = $Button.FindForm()
        if ($null -eq $frm) { $frm = $Script:MainForm }
        if ($null -eq $frm) { return }

        $ov = Get-CancelOverlay
        $Script:CancelOverlayLabel = "✕  CANCELAR"
        $Script:CancelOverlayState = 'normal'
        $ov.Enabled = $true
        $ov.BackColor = $Button.BackColor
        $ov.Invalidate()

        if ($ov.Parent -ne $frm) {
            if ($ov.Parent) { $ov.Parent.Controls.Remove($ov) }
            [void]$frm.Controls.Add($ov)
        }

        $Script:CancelOverlayTarget = $Button
        $Script:CancelOverlayActive = $true
        Update-CancelOverlay

        # Timer mantem o overlay grudado no botao mesmo com rolagem/redimensionamento
        if ($null -eq $Script:CancelOverlayTimer) {
            $tmr = New-Object System.Windows.Forms.Timer
            $tmr.Interval = 120
            $tmr.Add_Tick({ Update-CancelOverlay })
            $Script:CancelOverlayTimer = $tmr
        }
        $Script:CancelOverlayTimer.Start()
    }
    catch {}
}

function Hide-CancelOverlay {
    $Script:CancelOverlayActive = $false
    $Script:CancelOverlayTarget = $null
    try { if ($Script:CancelOverlayTimer) { $Script:CancelOverlayTimer.Stop() } } catch {}
    try { if ($Script:CancelOverlay) { $Script:CancelOverlay.Visible = $false } } catch {}
}

# --- BARRA DE PROGRESSO DENTRO DO PROPRIO BOTAO ---
# Substitui o "[==== ] 52%" em texto por uma barra gradiente desenhada no botao.
function Draw-ButtonProgress {
    param($G, $Btn, [int]$Pct)
    $w = $Btn.Width; $h = $Btn.Height
    if ($w -le 10 -or $h -le 10) { return }

    $G.Clear($Btn.BackColor)                        # trilho
    $pct = [Math]::Max(0, [Math]::Min(100, $Pct))
    $fw = [int]($w * $pct / 100)

    if ($fw -gt 1) {
        # Gradiente calculado sobre a largura total: a cor de cada ponto nao
        # muda enquanto a barra cresce (fica bem mais suave que reescalar).
        $rectFull = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
        $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rectFull, `
            [System.Drawing.Color]::FromArgb(28, 116, 232), `
            [System.Drawing.Color]::FromArgb(0, 208, 158), [float]0)
        $antigo = $G.Clip
        $G.SetClip((New-Object System.Drawing.Rectangle(0, 0, $fw, $h)), [System.Drawing.Drawing2D.CombineMode]::Intersect)
        $G.FillRectangle($br, $rectFull)
        $G.Clip = $antigo
        $br.Dispose()

        # Brilho na ponta da barra
        if ($fw -lt ($w - 1)) {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 2)
            $G.DrawLine($pen, $fw, 1, $fw, ($h - 2))
            $pen.Dispose()
        }
    }

    $reserva = 150   # espaco reservado do botao CANCELAR na direita
    $flagsNome = [System.Windows.Forms.TextFormatFlags]::Left -bor `
        [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
        [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    $rNome = New-Object System.Drawing.Rectangle(12, 0, [Math]::Max(20, $w - $reserva - 65), $h)
    [System.Windows.Forms.TextRenderer]::DrawText($G, $Btn.Text, $Btn.Font, $rNome, [System.Drawing.Color]::White, $flagsNome)

    $flagsPct = [System.Windows.Forms.TextFormatFlags]::Right -bor `
        [System.Windows.Forms.TextFormatFlags]::VerticalCenter
    $rPct = New-Object System.Drawing.Rectangle(0, 0, [Math]::Max(30, $w - $reserva), $h)
    [System.Windows.Forms.TextRenderer]::DrawText($G, "$pct%", $Btn.Font, $rPct, [System.Drawing.Color]::White, $flagsPct)
}

# Estado final do botao: cor cheia (como antes), porem com gradiente,
# brilho no topo e selo de vidro na direita em vez da cor chapada.
#   ok     = verde   (baixado / extraido / executado)
#   cancel = salmao  (cancelado pelo usuario)
#   erro   = vermelho
function Draw-ButtonDone {
    param($G, $Btn, $Info)
    $w = $Btn.Width; $h = $Btn.Height
    if ($w -le 10 -or $h -le 10) { return }

    $tipo = [string]$Info.Kind
    $Label = [string]$Info.Label
    switch ($tipo) {
        'cancel' {
            # Salmao (essencia do Salmon antigo), um tom abaixo para o texto
            # branco ficar legivel em cima
            $c1 = [System.Drawing.Color]::FromArgb(222, 104, 92)
            $c2 = [System.Drawing.Color]::FromArgb(186, 66, 60)
            $icone = "✕"
        }
        'erro' {
            $c1 = [System.Drawing.Color]::FromArgb(216, 62, 62)
            $c2 = [System.Drawing.Color]::FromArgb(172, 30, 38)
            $icone = "!"
        }
        default {
            $c1 = [System.Drawing.Color]::FromArgb(0, 194, 146)
            $c2 = [System.Drawing.Color]::FromArgb(52, 208, 116)
            $icone = "✔"
        }
    }

    # Cor na largura toda, com gradiente horizontal
    $rTudo = New-Object System.Drawing.Rectangle(0, 0, $w, $h)
    $bFundo = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rTudo, $c1, $c2, [float]0)
    $G.FillRectangle($bFundo, $rTudo)
    $bFundo.Dispose()

    # Brilho suave na metade de cima (da profundidade, tira o ar de "chapado")
    $hTopo = [int]($h / 2)
    if ($hTopo -gt 2) {
        $rTopo = New-Object System.Drawing.Rectangle(0, 0, $w, $hTopo)
        $bTopo = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rTopo, `
            [System.Drawing.Color]::FromArgb(50, 255, 255, 255), `
            [System.Drawing.Color]::FromArgb(0, 255, 255, 255), [float]90)
        $G.FillRectangle($bTopo, $rTopo)
        $bTopo.Dispose()
    }

    # Selo de vidro na direita (mesma forma/posicao do botao CANCELAR)
    $pw = 132
    $ph = [Math]::Max(24, $h - 16)
    $px = $w - $pw - 8
    $py = [int](($h - $ph) / 2)
    if ($px -gt 40) {
        $rSelo = New-Object System.Drawing.Rectangle($px, $py, $pw, $ph)
        $pSelo = New-RoundedRectPath -X $px -Y $py -W $pw -H $ph -R 8
        $bSelo = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(60, 255, 255, 255))
        $G.FillPath($bSelo, $pSelo)
        $pBorda = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(150, 255, 255, 255), 1)
        $G.DrawPath($pBorda, $pSelo)
        $flagsSelo = [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor `
            [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
            [System.Windows.Forms.TextFormatFlags]::EndEllipsis
        [System.Windows.Forms.TextRenderer]::DrawText($G, "$icone $Label", $Script:DoneFont, $rSelo, [System.Drawing.Color]::White, $flagsSelo)
        $pBorda.Dispose(); $bSelo.Dispose(); $pSelo.Dispose()
    }

    # Nome do item. Em cancelamento/erro o texto do botao vira so a palavra de
    # estado ("Cancelado", "Erro"), que o selo ja mostra - entao usa o nome real.
    if ($tipo -eq 'ok' -or [string]::IsNullOrEmpty([string]$Info.Nome)) {
        $txt = [string]$Btn.Text
    }
    else {
        $txt = [string]$Info.Nome
    }
    $txt = $txt.TrimStart([char]0x2714, ' ')
    $flagsNome = [System.Windows.Forms.TextFormatFlags]::Left -bor `
        [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
        [System.Windows.Forms.TextFormatFlags]::EndEllipsis
    $rNome = New-Object System.Drawing.Rectangle(12, 0, [Math]::Max(20, $w - $pw - 32), $h)
    [System.Windows.Forms.TextRenderer]::DrawText($G, $txt, $Btn.Font, $rNome, [System.Drawing.Color]::White, $flagsNome)
}

function Set-ButtonDone {
    param($Button, [string]$Label = "CONCLUÍDO", [string]$Kind = 'ok', [string]$Nome = "")
    try {
        if ($null -eq $Script:DoneMap) { $Script:DoneMap = @{} }
        if ($null -eq $Script:DoneFont) {
            $Script:DoneFont = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        }
        $Script:DoneMap[$Button] = @{ Label = $Label; Kind = $Kind; Nome = $Nome }
        $Button.Invalidate()
    }
    catch {}
}

function Clear-ButtonDone {
    param($Button)
    try {
        if ($Script:DoneMap -and $Script:DoneMap.ContainsKey($Button)) {
            $Script:DoneMap.Remove($Button)
            $Button.Invalidate()
        }
    }
    catch {}
}

$Script:ButtonProgressPaint = {
    param($s, $e)
    if ($Script:ProgressButton -eq $s) {
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        Draw-ButtonProgress -G $e.Graphics -Btn $s -Pct $Script:ProgressPercent
        return
    }
    if ($Script:DoneMap -and $Script:DoneMap.ContainsKey($s)) {
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        Draw-ButtonDone -G $e.Graphics -Btn $s -Info $Script:DoneMap[$s]
        return
    }
    # Sem download nem conclusao: pintura normal do WinForms
}

function Enable-ButtonProgress {
    param($Button)
    try {
        if ($null -eq $Script:ProgressHooked) { $Script:ProgressHooked = New-Object System.Collections.ArrayList }
        # Add_Paint so uma vez por botao: o handler se anula sozinho quando
        # o botao nao e o do download atual.
        if (-not $Script:ProgressHooked.Contains($Button)) {
            $Button.Add_Paint($Script:ButtonProgressPaint)
            [void]$Script:ProgressHooked.Add($Button)
        }
        Clear-ButtonDone -Button $Button      # re-download: sai do estado concluido
        $Script:ProgressPercent = 0
        $Script:ProgressButton = $Button
        $Button.BackColor = [System.Drawing.Color]::FromArgb(22, 30, 46)  # trilho
        $Button.Invalidate()
    }
    catch {}
}

function Disable-ButtonProgress {
    try {
        $b = $Script:ProgressButton
        $Script:ProgressButton = $null
        $Script:ProgressPercent = 0
        if ($b -and -not $b.IsDisposed) { $b.Invalidate() }
    }
    catch {}
}

function Cancel-Download {
    if ($Script:CurrentWebClient -ne $null -and $Global:XM_DOWNLOAD_IN_PROGRESS) {
        $Script:CancelRequested = $true
        try { $Script:CurrentWebClient.CancelAsync() } catch {}
        Log-Message "CANCEL" "Solicitacao de cancelamento enviada..."

        # Feedback imediato: o botao muda de estado assim que e clicado
        if ($Script:CancelOverlay) {
            $Script:CancelOverlayLabel = "CANCELANDO..."
            $Script:CancelOverlay.Enabled = $false
            $Script:CancelOverlay.Invalidate()
        }
        if ($Script:StatusLabel) { $Script:StatusLabel.Text = "Cancelando download..." }
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Start-Download {
    param($Url, $FileName, $Button)

    # Resultado desta chamada, para quem chamou poder reagir (o TEF HUB usa
    # isso para abrir a pagina da Elgin quando as 3 tentativas falham).
    # "Cancelado" tambem cobre os casos em que o download nem chegou a comecar.
    $Script:UltimoDownloadOk = $false
    $Script:UltimoDownloadCancelado = $false

    if ($Global:XM_DOWNLOAD_IN_PROGRESS) {
        $Script:UltimoDownloadCancelado = $true
        [System.Windows.Forms.MessageBox]::Show("Já existe um download ou tarefa em andamento. Aguarde a conclusão ou cancele o atual.", "Sistema Ocupado", "OK", "Warning") | Out-Null
        return
    }

    if ($Button.Text -like "*Instalado" -or $Button.Text -like "*Aberto" -or $Button.Text -like "*Extraido") {
        $Script:UltimoDownloadCancelado = $true
        return
    }

    $originalText = $Button.Text
    $originalBack = $Button.BackColor
    $Global:XM_DOWNLOAD_IN_PROGRESS = $true
    $Script:CancelRequested = $false

    # Bloqueio visual de toda a tabela para evitar cliques fantasmas
    try { if ($tbl) { $tbl.Enabled = $false } } catch {}

    # Barra de progresso desenhada no botao + botao de cancelar sobreposto
    Enable-ButtonProgress -Button $Button
    Show-CancelOverlay -Button $Button

    try {
        $Script:DownloadComplete = $false
        $Script:DownloadError = $null

        if ($Script:ProgressBar) { $Script:ProgressBar.Value = 0 }

        $Button.Text = "Conectando..."
        $Button.Enabled = $false

        $destPath = Join-Path $Script:DownloadFolder $FileName
        Log-Message "DOWN" "Iniciando download: $FileName"
        if ($Script:StatusLabel) { $Script:StatusLabel.Text = "Baixando $FileName...  -  clique em ✕ CANCELAR sobre o botao para parar" }

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
                        if ($Script:ProgressBar) { $Script:ProgressBar.Value = $e.ProgressPercentage }

                        if ($Script:CancelRequested) { try { $s.CancelAsync() } catch {} }
                        else {
                            # A barra e o percentual sao desenhados pelo ButtonProgressPaint
                            $Script:ProgressPercent = $e.ProgressPercentage
                            $Button.Text = $originalText
                            $Button.Invalidate()
                        }
                    })

                $wc.Add_DownloadFileCompleted({
                        param($s, $e)
                        if ($e.Cancelled) {
                            $Script:CancelRequested = $true
                        }
                        elseif ($e.Error) { 
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

            }
            catch {
                if ($Script:CancelRequested) { break }
                Log-Message "ERRO" "Falha na tentativa ${retryCount}: $($_.Exception.Message)"
                Wait-UI 2
            }
            finally {
                if ($wc) { $wc.Dispose(); $wc = $null }
                $Script:CurrentWebClient = $null
            }
        }

        # Download encerrado: barra e cancelar nao se aplicam mais (instalacao/extracao)
        Disable-ButtonProgress
        Hide-CancelOverlay

        if ($Script:CancelRequested) {
            $Script:UltimoDownloadCancelado = $true
            $Button.Text = "Cancelado"
            Set-ButtonDone -Button $Button -Label "CANCELADO" -Kind 'cancel' -Nome $originalText
            $Script:StatusLabel.Text = "Cancelado."
            if (Test-Path $destPath) {
                Wait-UI 0.5
                try { Remove-Item $destPath -Force -ErrorAction SilentlyContinue | Out-Null } catch {}
            }
            Wait-UI 1
            Clear-ButtonDone -Button $Button
            $Button.BackColor = $originalBack
            $Button.Text = $originalText

        }
        elseif ($downloadSuccessful) {
            
            # Verificacao de integridade basica (tamanho minimo + assinatura binaria)
            if (-not (Test-DownloadIntegrity -Path $destPath -MinBytes 50000)) {
                Log-Message "ERRO" "Arquivo corrompido ou link invalido (Tamanho: $((Get-Item $destPath).Length) bytes)."
                Remove-Item $destPath -Force -ErrorAction SilentlyContinue
                $Button.Text = "Erro (Arquivo Invalido)"
                Set-ButtonDone -Button $Button -Label "ARQUIVO INVÁLIDO" -Kind 'erro' -Nome $originalText
                return
            }

            Log-Message "SUCESSO" "Download concluido."
            $Script:UltimoDownloadOk = $true
            $Button.BackColor = $originalBack
            $Button.Text = "Instalado"
            Set-ButtonDone -Button $Button -Label "BAIXADO"
            
            Unblock-File -Path $destPath -ErrorAction SilentlyContinue

            if ($FileName.EndsWith(".zip")) {
                Log-Message "ZIP" "Extraindo arquivo..."
                $Button.Text = "Extraindo..."
                [System.Windows.Forms.Application]::DoEvents()
                
                try {
                    # Usa ZipFile do .NET diretamente — muito mais rapido que Expand-Archive
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    
                    $folderName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
                    $finalPath = Join-Path $Script:DownloadFolder $folderName
                    $tempPath  = Join-Path $Script:DownloadFolder "temp_$folderName"
                    
                    if (Test-Path $tempPath)  { Remove-Item $tempPath  -Recurse -Force | Out-Null }
                    if (Test-Path $finalPath) { Remove-Item $finalPath -Recurse -Force | Out-Null }
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    # Extrai com ZipFile (nativo .NET - rapido e nao trava)
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($destPath, $tempPath)
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    # Se o ZIP tem uma pasta raiz unica, sobe um nivel
                    $items = Get-ChildItem -Path $tempPath
                    if ($items.Count -eq 1 -and $items[0].PSIsContainer) {
                        Move-Item -Path $items[0].FullName -Destination $finalPath
                        Remove-Item $tempPath -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
                    }
                    else {
                        Rename-Item -Path $tempPath -NewName $folderName
                    }
                    
                    if (-not $Script:DeployMode) {
                        Invoke-Item $finalPath
                        $Button.Text = "Pasta Aberta"
                    }
                    else {
                        $Button.Text = "Extraido"
                    }
                    Log-Message "SUCESSO" "Extraido com sucesso para: $folderName"
                    Wait-UI 1.5
                    $Button.Text = "✔ $originalText"
                    Set-ButtonDone -Button $Button -Label "EXTRAÍDO"
                }
                catch {
                    Log-Message "ERRO" "Falha ao extrair ZIP: $($_.Exception.Message)"
                    $Button.Text = "Erro ZIP"
                    Set-ButtonDone -Button $Button -Label "ERRO NO ZIP" -Kind 'erro' -Nome $originalText
                }

            }
            elseif ($FileName.EndsWith(".rar")) {
                $Button.Text = "Baixado (RAR)"
                Invoke-Item $destPath
                Wait-UI 1.5
                $Button.Text = "✔ $originalText"
                Set-ButtonDone -Button $Button -Label "BAIXADO"
            }
            else {
                Log-Message "EXEC" "Executando instalador..."
                # WorkingDirectory na pasta de downloads: instaladores auto-extraiveis (WinRAR SFX)
                # passam a sugerir essa pasta em vez de C:\WINDOWS\system32.
                Start-Process $destPath -WorkingDirectory $Script:DownloadFolder
                $Button.Text = "Executado"
                Wait-UI 1.5
                $Button.Text = "✔ $originalText"
                Set-ButtonDone -Button $Button -Label "EXECUTADO"
            }
        }
        else {
            if (-not $Script:CancelRequested) {
                Log-Message "ERRO" "Falha definitiva no download."
                $Button.Text = "Erro"
                Set-ButtonDone -Button $Button -Label "FALHOU" -Kind 'erro' -Nome $originalText
                Wait-UI 2
                Clear-ButtonDone -Button $Button
                $Button.BackColor = $originalBack
                $Button.Text = $originalText
            }
        }

    }
    catch {
        Log-Message "ERRO" "Erro Fatal de Script: $($_.Exception.Message)"
        $Button.Text = "Erro Fatal"
        Set-ButtonDone -Button $Button -Label "ERRO FATAL" -Kind 'erro' -Nome $originalText
    }
    finally {
        $Global:XM_DOWNLOAD_IN_PROGRESS = $false
        $Script:CurrentWebClient = $null
        $Script:CancelRequested = $false
        
        try { if ($tbl) { $tbl.Enabled = $true } } catch {}
        Disable-ButtonProgress
        Hide-CancelOverlay
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

    $aviso = "ATENÇÃO - INSTALAÇÃO MANUAL E AVANÇADA`n`n" +
             "Este botão baixa o SQL 2019 e o SSMS SEPARADAMENTE, para instalação manual (passo a passo).`n`n" +
             "Se você só precisa instalar o banco de dados normalmente, use o botão azul 'SQL Server 2019 (Instalador)' (automático).`n`n" +
             "Deseja realmente continuar com a instalação MANUAL?"
    $resp = [System.Windows.Forms.MessageBox]::Show($aviso, "Instalação Manual - Confirmação", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }

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
    }
    finally {
        $Button.Enabled = $true
    }
}

function Open-Selector {
    param($Type, $Button)
    $height = if ($Type -eq "PDV" -or $Type -eq "LinkXMenu") { 380 } else { 220 }

    $fSel = New-Object System.Windows.Forms.Form
    $fSel.Text = "Versoes - $Type"; $fSel.Size = "400,$height"; $fSel.StartPosition = 'CenterParent'
    $fSel.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $fSel.ForeColor = 'White'
    $fSel.FormBorderStyle = 'FixedDialog'; $fSel.MaximizeBox = $false
    
    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "Selecione da Lista:"; $lbl.Location = '20,20'; $lbl.AutoSize = $true
    [void]$fSel.Controls.Add($lbl)

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = '20,45'; $cb.Width = 340; $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'
    $cb.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60); $cb.ForeColor = 'White'
    
    $versions = @()
    if ($Type -eq "PDV") {
        $versions += @{Name = "NetPDV v1.3.64.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/64/0/NetPDV.zip"; File = "NetPDV_1.3.64.0.zip" }
        $versions += @{Name = "NetPDV v1.3.63.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/63/0/NetPDV.zip"; File = "NetPDV_1.3.63.0.zip" }
        $versions += @{Name = "NetPDV v1.3.60.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/60/0/NetPDV.zip"; File = "NetPDV_1.3.60.0.zip" }
        $versions += @{Name = "NetPDV v1.3.59.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/59/0/NetPDV.zip"; File = "NetPDV_1.3.59.0.zip" }
        $versions += @{Name = "NetPDV v1.3.55.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.zip"; File = "NetPDV_1.3.55.0.zip" }
        $versions += @{Name = "NetPDV v1.3.46.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/46/0/NetPDV.zip"; File = "NetPDV_1.3.46.0.zip" }
        $versions += @{Name = "NetPDV v1.3.44.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/44/0/NetPDV.zip"; File = "NetPDV_1.3.44.0.zip" }
        $versions += @{Name = "NetPDV v1.3.40.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/40/0/NetPDV.zip"; File = "NetPDV_1.3.40.0.zip" }
    }
    elseif ($Type -eq "LinkXMenu") {
        $versions += @{Name = "Link XMenu v10.17"; Url = "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/17/LinkXMenu.zip"; File = "LinkXMenu_10.17.zip" }
        $versions += @{Name = "Link XMenu v10.16"; Url = "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/16/LinkXMenu.zip"; File = "LinkXMenu_10.16.zip" }
        $versions += @{Name = "Link XMenu v10.12"; Url = "http://netcontroll.com.br/util/instaladores/LinkXMenu/10/12/LinkXMenu.zip"; File = "LinkXMenu_10.12.zip" }
    }
    elseif ($Type -eq "Tablet") {
        $versions += @{Name = "Cardapio Tablet 1.1.17.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/Tablet.1.1.17.0.zip"; File = "CardapioTablet_1.1.17.0.zip" }
        $versions += @{Name = "Cardapio Tablet 1.1.16.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/TABLET.1.1.16.0.zip"; File = "CardapioTablet_1.1.16.0.zip" }
        $versions += @{Name = "Cardapio Tablet 1.1.15.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/TABLET.1.1.15.0.zip"; File = "CardapioTablet_1.1.15.0.zip" }
    }
    elseif ($Type -eq "Totem") {
        $versions += @{Name = "Totem 1.0.88.51"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/Totem.1.0.88.51.zip"; File = "Totem_1.0.88.51.zip" }
        $versions += @{Name = "Totem 1.0.88.50"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/Totem.1.0.88.50.zip"; File = "Totem_1.0.88.50.zip" }
        $versions += @{Name = "Totem 1.0.88.44"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Tablet_totem/Totem.1.0.88.44.zip"; File = "Totem_1.0.88.44.zip" }
    }
    else {
        $versions += @{Name = "Concentrador v1.3.63.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.63.0.zip"; File = "Concentrador.1.3.63.0.zip" }
        $versions += @{Name = "Concentrador v1.3.59.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.59.0.zip"; File = "Concentrador.1.3.59.0.zip" }
        $versions += @{Name = "Concentrador v1.3.55.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.55.0.zip"; File = "Concentrador.1.3.55.0.zip" }
        $versions += @{Name = "Concentrador v1.3.50.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.50.0.zip"; File = "Concentrador.1.3.50.0.zip" }
        $versions += @{Name = "Concentrador v1.3.46.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.46.0.zip"; File = "Concentrador.1.3.46.0.zip" }
        $versions += @{Name = "Concentrador v1.3.44.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.44.0.zip"; File = "Concentrador.1.3.44.0.zip" }
        $versions += @{Name = "Concentrador v1.3.40.0"; Url = "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Concentrador_files/Concentrador.1.3.40.0.zip"; File = "Concentrador.1.3.40.0.zip" }
    }

    foreach ($v in $versions) { [void]$cb.Items.Add($v.Name) }
    $cb.SelectedIndex = 0
    [void]$fSel.Controls.Add($cb)

    $btn = New-Object System.Windows.Forms.Button
    $btn.Text = "BAIXAR SELECIONADO"; $btn.Location = '20,80'; $btn.Size = '340,35'
    $btn.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $btn.ForeColor = 'White'; $btn.FlatStyle = 'Flat'
    $btn.Add_Click({
            $selected = $versions[$cb.SelectedIndex]
            $deployFlag = if ($null -ne $chkDeploy) { $chkDeploy.Checked } else { $false }
            $fSel.Tag = @{ Url = $selected.Url; File = $selected.File; Name = $selected.Name; Deploy = $deployFlag }
            $fSel.DialogResult = 'OK'
            $fSel.Close()
        })
    [void]$fSel.Controls.Add($btn)

    # Checkbox de deploy automatico (visivel apenas para PDV e LinkXMenu)
    $chkDeploy = $null
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
        }
        else {
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
                        $fSel.Tag = @{ Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/$v/0/NetPDV.zip"; File = "NetPDV_1.3.$v.0.zip"; Deploy = $chkDeploy.Checked }
                    }
                    else {
                        $fSel.Tag = @{ Url = "http://netcontroll.com.br/util/instaladores/LinkXMenu/10/$v/LinkXMenu.zip"; File = "LinkXMenu_10.$v.zip"; Deploy = $chkDeploy.Checked }
                    }
                    $fSel.DialogResult = 'OK'
                    $fSel.Close()
                }
                else { [System.Windows.Forms.MessageBox]::Show("Digite apenas o numero da versao (Ex: 62 ou 16)", "Erro", "OK", "Warning") | Out-Null }
            })
        [void]$fSel.Controls.Add($btnMan)

        # Separador e Checkbox de deploy
        $sep2 = New-Object System.Windows.Forms.Label; $sep2.Text = "__________________________________________________"
        $sep2.Location = '20,218'; $sep2.AutoSize = $true; $sep2.ForeColor = 'Gray'
        [void]$fSel.Controls.Add($sep2)

        $destLabel = if ($Type -eq "PDV") { "C:\netcontroll\NetPDV" } else { "C:\XMenu" }
        $chkDeploy = New-Object System.Windows.Forms.CheckBox
        $chkDeploy.Text = "Atualizar pasta do programa (cria backup .OLD)"
        $chkDeploy.Location = '20,248'; $chkDeploy.AutoSize = $true; $chkDeploy.Checked = $true
        $chkDeploy.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        [void]$fSel.Controls.Add($chkDeploy)

        $lblDest = New-Object System.Windows.Forms.Label
        $lblDest.Text = "Pasta: $destLabel"; $lblDest.Location = '38,272'; $lblDest.AutoSize = $true
        $lblDest.ForeColor = [System.Drawing.Color]::Gray; $lblDest.Font = New-Object System.Drawing.Font("Segoe UI", 8)
        [void]$fSel.Controls.Add($lblDest)
    }

    [void]$fSel.ShowDialog()
    if ($fSel.DialogResult -eq 'OK' -and $fSel.Tag) {
        # Ativa modo deploy para nao abrir pasta automaticamente
        $Script:DeployMode = $fSel.Tag.Deploy -and ($Type -eq "PDV" -or $Type -eq "LinkXMenu")
        
        Start-Download $fSel.Tag.Url $fSel.Tag.File $Button
        
        # Deploy automatico com backup se checkbox marcado
        if ($Script:DeployMode) {
            if ($Button.Text -ne "Erro" -and $Button.Text -ne "Erro Fatal" -and $Button.Text -ne "Cancelado" -and $Button.Text -ne "Erro ZIP") {
                $folderName = [System.IO.Path]::GetFileNameWithoutExtension($fSel.Tag.File)
                $extractedPath = Join-Path $Script:DownloadFolder $folderName
                if (Test-Path $extractedPath) {
                    $versionName = $fSel.Tag.File -replace '\.(zip|rar)$', '' -replace '_', ' '
                    Deploy-WithBackup $extractedPath $Type $versionName
                }
                else {
                    Log-Message "ERRO" "Pasta extraida nao encontrada para deploy: $extractedPath"
                }
            }
        }
        $Script:DeployMode = $false
    }
}

# -----------------------------------------------------------------------------
# 5. CONFIGURACAO DO AMBIENTE (REGISTRY E OTIMIZACOES)
# -----------------------------------------------------------------------------
function Run-Config {
    param($Btn)
    $Btn.Enabled = $false; $Btn.Text = "AGUARDE... CONFIGURANDO"; $Btn.BackColor = [System.Drawing.Color]::Gray
    $Script:ProgressBar.Value = 0
    
    Log-Message "LOG" "--- INICIANDO OTIMIZAÇÃO DO SISTEMA ---"
    [System.Windows.Forms.Application]::DoEvents()
    
    # NEW: Language and Region Settings
    Log-Message "LOG" "IDIOMA E REGIÃO:"
    Log-Message "LOG" "     Verificando se o idioma está em Português (Brasil)..."
    try {
        $currentLocale = Get-WinSystemLocale
        if ($currentLocale.Name -ne "pt-BR") {
            Log-Message "CMD" "COMANDO: Set-WinSystemLocale -SystemLocale pt-BR"
            Set-WinSystemLocale -SystemLocale pt-BR
            Log-Message "INFO" "Idioma do sistema (non-Unicode) configurado para pt-BR."
        }
        else {
            Log-Message "INFO" "Idioma do sistema já está em pt-BR."
        }

        Log-Message "LOG" "     Resetando padrões de número, moeda, hora e data (Padrão pt-BR)..."
        Log-Message "CMD" "COMANDO: Set-Culture pt-BR"
        Set-Culture pt-BR
        Set-WinHomeLocation -GeoId 32 # Brasil
        Set-WinUserLanguageList pt-BR -Force

        # Força o reset via Registry para garantir que overrides manuais sejam removidos (Igual ao botão 'Redefinir' da tela)
        $regPath = "HKCU:\Control Panel\International"
        $regValues = @{
            "sDecimal" = ","; "sThousand" = "."; "sList" = ";"; 
            "sCurrency" = "R$"; "sMonDecimalSep" = ","; "sMonThousandSep" = ".";
            "sShortDate" = "dd/MM/yyyy"; "sTimeFormat" = "HH:mm:ss"; "sShortTime" = "HH:mm";
            "iDate" = "1"; "iTime" = "1"; "iCurrency" = "2"
            # Itens que o Set-Culture nem sempre restaura quando existe override
            # manual na maquina. Sem eles a validacao regional acusa diferenca.
            "iDigits" = "2"; "sGrouping" = "3;0"; "sNegativeSign" = "-"
            "iNegNumber" = "1"; "iLZero" = "1"; "sNativeDigits" = "0123456789"
            "iMeasure" = "0"; "iCurrDigits" = "2"; "sMonGrouping" = "3;0"
            "iNegCurr" = "9"; "sLongDate" = "dddd, d' de 'MMMM' de 'yyyy"
        }
        foreach ($name in $regValues.Keys) {
            Set-ItemProperty -Path $regPath -Name $name -Value $regValues[$name] -Force -ErrorAction SilentlyContinue
        }

        Log-Message "SUCESSO" "Formatos regionais (Moeda, Números, Data) resetados com sucesso."
    }
    catch {
        Log-Message "ERRO" "Falha ao configurar Idioma/Região: $($_.Exception.Message)"
    }
    
    Log-Message "LOG" "1. SEGURANÇA E ACESSO (UAC):"
    Log-Message "LOG" "     Ajustando permissões para evitar avisos técnicos constantes..."
    Log-Message "CMD" "COMANDO: reg ADD HKLM\...\System /v EnableLUA /t REG_DWORD /d 0 /f"
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v EnableLUA /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    Log-Message "CMD" "COMANDO: reg ADD HKLM\...\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f"
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v ConsentPromptBehaviorAdmin /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    Log-Message "CMD" "COMANDO: reg ADD HKLM\...\System /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f"
    Start-Process "reg.exe" -ArgumentList "ADD HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System /v PromptOnSecureDesktop /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    $Script:ProgressBar.Value = 15
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "2. PLANO DE ENERGIA:"
    Log-Message "LOG" "     Turbinando o Windows para o máximo desempenho..."
    Log-Message "CMD" "COMANDO: powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c | Out-Null
    Log-Message "CMD" "COMANDO: powercfg /change monitor-timeout-ac 0"
    powercfg /change monitor-timeout-ac 0 | Out-Null
    Log-Message "CMD" "COMANDO: powercfg /change disk-timeout-ac 0"
    powercfg /change disk-timeout-ac 0 | Out-Null
    Log-Message "CMD" "COMANDO: powercfg /change standby-timeout-ac 0"
    powercfg /change standby-timeout-ac 0 | Out-Null
    Log-Message "LOG" "     Garantindo um desligamento real e boot limpo..."
    Log-Message "CMD" "COMANDO: powercfg /h off"
    powercfg /h off | Out-Null
    Log-Message "CMD" "COMANDO: reg ADD HKLM\...\Power /v HiberbootEnabled /t REG_DWORD /d 0 /f"
    Start-Process "reg.exe" -ArgumentList "ADD ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    $Script:ProgressBar.Value = 30
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "3. EXPLORER E AJUSTES VISUAIS:"
    Log-Message "LOG" "     Padronizando formato de data e exibição de arquivos..."
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... sShortDate dd/MM/yyyy"
    Set-ItemProperty -Path "HKCU:\Control Panel\International" -Name "sShortDate" -Value "dd/MM/yyyy" -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... LaunchTo 1"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1 -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... HideFileExt 0"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Otimizacoes visuais preparadas (Ajuste Final Manual)."
    $Script:ProgressBar.Value = 45
    
    Log-Message "LOG" "     Exibindo ícones principais na Área de Trabalho..."
    $iconPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel"
    if (!(Test-Path $iconPath)) { New-Item -Path $iconPath -Force | Out-Null }
    # Ativa Computer, RecycleBin, User, Network
    Set-ItemProperty -Path $iconPath -Name "{20D04FE0-3AEA-1069-A2D8-08002B30309D}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{645FF040-5081-101B-9F08-00AA002F954E}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{59031a47-3f72-44a7-89c5-5595fe6b30ee}" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $iconPath -Name "{F02C1A0D-BE21-4350-88B0-7367FC96EF3C}" -Value 0 -Force -ErrorAction SilentlyContinue
    $Script:ProgressBar.Value = 45
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "4. REDE E SEGURANÇA:"
    Log-Message "LOG" "     Preparando registros de rede para ajuste manual..."
    
    # 1. Forca Perfil de Rede PARTICULAR (Se estiver Publica, o Windows ignora a mudanca de senha)
    try { Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue } catch {}

    # 2. Registro Master (LSA e Lanman)
    $lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Set-ItemProperty -Path $lsa -Name "everyoneincludesanonymous" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $lsa -Name "LimitBlankPasswordUse" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $lsa -Name "ForceGuest" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "restrictnullsessaccess" -Value 0 -Force -ErrorAction SilentlyContinue
    
    # 3. Localizacao Dinamica da Conta Guest/Convidado e Ativacao Hard
    # REMOVIDO: Ativacao automatica da conta Guest. Sera feito manualmente.

    # 4. Reinicia Servicos de Rede (Crucial para o Painel de Controle atualizar)
    try {
        Restart-Service Server, LanmanWorkstation -Force -ErrorAction SilentlyContinue
    }
    catch {
        Log-Message "LOG" "Aguardando consolidacao de rede..."
    }
    
    Log-Message "SUCESSO" "Registros de rede aplicados. Ajuste final sera manual."
    
    # --- PERFORMANCE NETWORK ---
    Log-Message "LOG" "     Acelerando a comunicação de rede para o PDV (Baixa Latência)..."
    $tcpKey = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
    Get-ChildItem $tcpKey | ForEach-Object {
        New-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
        New-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    }
    $Script:ProgressBar.Value = 60
    
    Log-Message "LOG" "5. LIMPEZA E DESEMPENHO:"
    Log-Message "LOG" "     Desativando serviços de telemetria e coleta de dados..."
    Log-Message "CMD" "COMANDO: Stop-Service SysMain"
    Stop-Service "SysMain" -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-Service SysMain -StartupType Disabled"
    Set-Service "SysMain" -StartupType Disabled -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Stop-Service DiagTrack"
    Stop-Service "DiagTrack" -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-Service DiagTrack -StartupType Disabled"
    Set-Service "DiagTrack" -StartupType Disabled -ErrorAction SilentlyContinue

    Log-Message "LOG" "     Limpando aplicativos inúteis que pesam no PC (Bloatware)..."
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
    
    Log-Message "LOG" "     Desativando Widgets e instaladores automáticos..."
    Log-Message "CMD" "COMANDO: Get-AppxPackage ... | Remove-AppxPackage"
    Get-AppxPackage -AllUsers *Microsoft.DesktopAppInstaller* | Remove-AppxPackage -ErrorAction SilentlyContinue
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh")) { New-Item "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Force | Out-Null }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Force -ErrorAction SilentlyContinue

    # No Windows 11 o App Installer (winget) e marcado como NonRemovable: o
    # Remove-AppxPackage acima falha com 0x80073CFA e o erro fica escondido.
    # O jeito que realmente desliga e por diretiva.
    Log-Message "LOG" "     Bloqueando o winget (App Installer) por diretiva..."
    Log-Message "CMD" "COMANDO: HKLM\...\Policies\Microsoft\Windows\AppInstaller -> EnableAppInstaller = 0"
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller")) { New-Item "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller" -Force | Out-Null }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller" -Name "EnableAppInstaller" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller" -Name "EnableWindowsPackageManagerCommandLineInterfaces" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AppInstaller" -Name "EnableMSAppInstallerProtocol" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue

    # Sem isso a Loja continua atualizando aplicativos sozinha
    Log-Message "LOG" "     Desligando atualizacao automatica da Microsoft Store..."
    if (!(Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore")) { New-Item "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" -Force | Out-Null }
    Set-ItemProperty "HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore" -Name "AutoDownload" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue

    # --- LIMPEZA DE TOOLBARS E ICONES (RESTAURADA) ---
    Log-Message "LOG" "     Limpando e organizando a Barra de Tarefas..."
    
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
    
    Log-Message "LOG" "     Eliminando lixo e arquivos temporários..."
    Log-Message "CMD" "COMANDO: Remove-Item $env:TEMP\*"
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Log-Message "CMD" "COMANDO: Remove-Item $env:windir\Temp\*"
    Get-ChildItem -Path "$env:windir\Temp" -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue | Out-Null
    $Script:ProgressBar.Value = 80
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "6. PERSONALIZAÇÃO E SUPORTE:"
    Log-Message "LOG" "     Aplicando papel de parede padrão XMenu..."
    $tempDir = Join-Path $env:TEMP "XmenuResources"
    if (!(Test-Path $tempDir)) { New-Item $tempDir -ItemType Directory -Force | Out-Null }
    $wallPath = Join-Path $tempDir "fundo.png"
    
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile("$Script:RepoBase/fundo.png", $wallPath)
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallpaperStyle" -Value "10" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "TileWallPaper" -Value "0" -Force
        Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name "WallPaper" -Value $wallPath -Force
        [XMenuTools.WinAPI]::SystemParametersInfo(0x0014, 0, $wallPath, 3) | Out-Null
    }
    catch { Log-Message "ERRO" "Falha no Wallpaper: $($_.Exception.Message)" }
    
    Log-Message "LOG" "     Gerando atalho de suporte na Área de Trabalho..."
    $configDir = "C:\Netcontroll\SuporteXmenuChat\Config"
    if (!(Test-Path $configDir)) { New-Item $configDir -ItemType Directory -Force | Out-Null }
    
    $filesToDownload = @(
        @{ U = "$Script:RepoBase/Config/Suporte%20Xmenu.html"; D = "$configDir\Suporte Xmenu.html" },
        @{ U = "$Script:RepoBase/Config/iconeatalho.ico"; D = "$configDir\iconeatalho.ico" },
        @{ U = "$Script:RepoBase/Config/faviconxmenu.ico"; D = "$configDir\faviconxmenu.ico" },
        @{ U = "$Script:RepoBase/Config/iconheaderxmenu.png"; D = "$configDir\iconheaderxmenu.png" },
        @{ U = "$Script:RepoBase/Config/SuporteXmenuDicas.pdf"; D = "$configDir\SuporteXmenuDicas.pdf" }
    )
    foreach ($file in $filesToDownload) {
        try { (New-Object System.Net.WebClient).DownloadFile($file.U, $file.D) } 
        catch { Log-Message "ERRO" "Falha ao baixar $($file.D): $($_.Exception.Message)" }
    }
    
    try {
        $shell = New-Object -ComObject WScript.Shell
        $desktopPub = [Environment]::GetFolderPath('CommonDesktopDirectory')
        $lnkPath = Join-Path $desktopPub "Suporte Xmenu.lnk"
        $lnk = $shell.CreateShortcut($lnkPath)
        $lnk.TargetPath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
        $lnk.Arguments = "--app=`"file:///C:/Netcontroll/SuporteXmenuChat/Config/Suporte%20Xmenu.html`""
        $lnk.IconLocation = "$configDir\iconeatalho.ico"
        $lnk.Save()
        Log-Message "LOG" "     Atalho criado com sucesso (modo App Chrome)."
    }
    catch { Log-Message "ERRO" "Falha no atalho: $($_.Exception.Message)" }
    
    # Dois ajustes que todo PDV precisa e que antes dependiam do tecnico
    # lembrar de clicar nos botoes de suporte:
    Log-Message "LOG" "     Protegendo as portas USB (impressora que desconecta sozinha)..."
    try { Invoke-UsbPowerFix -Silencioso } catch { Log-Message "ERRO" "Falha no ajuste de USB: $($_.Exception.Message)" }

    Log-Message "LOG" "     Acertando o relogio pelo pool.ntp.br (NFC-e)..."
    try { Invoke-ClockSync -Silencioso } catch { Log-Message "ERRO" "Falha ao sincronizar o relogio: $($_.Exception.Message)" }

    Log-Message "LOG" "7. FINALIZAÇÃO:"
    Log-Message "LOG" "     Atualizando interface do Windows (Explorer)..."
    Get-ChildItem "$env:LOCALAPPDATA\IconCache.db" -ErrorAction SilentlyContinue | Remove-Item -Force | Out-Null
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Wait-UI 2 # Espera nao travante
    if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Start-Process explorer.exe }
    
    Log-Message "LOG" "--- TUDO PRONTO! ---"
    
    # Limpa cliques anteriores e configura o novo texto (solicitacao usuario)
    $Btn.remove_Click( { Invoke-Preparo }.GetNewClosure() ) 
    $Btn.Text = "REALIZAR AJUSTES MANUAIS"; $Btn.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113); $Btn.Enabled = $true
    $Script:ProgressBar.Value = 100
    
    $Script:MainForm.Activate()
    
    # --- FUNCAO PARA CRIAR JANELA DE INSTRUCOES INDEPENDENTE ---
    function Show-ManualGuide {
        # ... (conteudo da funcao mantido, apenas mudando o ShowDialog para garantir foco)
        $finalForm = New-Object System.Windows.Forms.Form
        $finalForm.Text = "XMenu - Guia de Configuração Manual"
        $finalForm.Size = New-Object System.Drawing.Size(550, 500)
        $finalForm.StartPosition = "CenterScreen"
        $finalForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35); $finalForm.ForeColor = 'White'
        $finalForm.FormBorderStyle = 'FixedDialog'; $finalForm.MaximizeBox = $false; $finalForm.TopMost = $true
        
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = "Siga os passos abaixo:"; $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold)
        $lblTitle.ForeColor = [System.Drawing.Color]::Gold; $lblTitle.Location = '20,15'; $lblTitle.Size = '320,30'
        [void]$finalForm.Controls.Add($lblTitle)

        $txtInst = New-Object System.Windows.Forms.RichTextBox
        $txtInst.Location = '20,55'; $txtInst.Size = '495,310'; $txtInst.ReadOnly = $true; $txtInst.BorderStyle = 'None'
        $txtInst.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 45); $txtInst.ForeColor = 'White'
        $txtInst.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        
        $instrucoes = @"
1. NA TELA DE REDE:
   - Marque: "Desativar compartilhamento protegido por senha"
   - Clique em "Salvar alterações".

2. NA TELA DE DESEMPENHO:
   - Escolha: "Ajustar para obter um melhor desempenho"
   - Em seguida, MARQUE APENAS estas 5 opções:
     [ ] Mostrar retângulo de seleção translúcido
     [ ] Mostrar sombras sob o ponteiro do mouse
     [ ] Salvar visualizações de miniaturas da barra de tarefas
     [ ] Usar fontes de tela com cantos arredondados
     [ ] Usar sombras subjacentes para rótulos de ícones desktop

3. NA TELA DE RECURSOS: Ative estas duas opções:
   - .NET Framework 3.5 (inclui .NET 2.0 e 3.0)
   - .NET Framework 4.8 Advanced Services

4. NA TELA DE REGIÃO: Apenas clique em OK para confirmar o formato pt-BR.
"@
        $txtInst.Text = $instrucoes
        [void]$finalForm.Controls.Add($txtInst)
        
        $Script:FinalCountdown = 300 # Fecha em 5 minutos (silencioso)
        $timerG = New-Object System.Windows.Forms.Timer
        $timerG.Interval = 1000
        $timerG.Add_Tick({
                $Script:FinalCountdown--
                if ($Script:FinalCountdown -le 0) { $timerG.Stop(); $finalForm.Close() }
            })

        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = "FECHAR GUIA"; $btnClose.Location = '100,385'; $btnClose.Size = '350,45'
        $btnClose.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113); $btnClose.ForeColor = 'White'; $btnClose.FlatStyle = 'Flat'
        $btnClose.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnClose.Add_Click({ 
                $timerG.Stop()
                $finalForm.Close() 
            })
        [void]$finalForm.Controls.Add($btnClose)

        $timerG.Start()
        
        # ABERTURA AUTOMATICA DAS JANELAS (SOLICITACAO USUARIO)
        Start-Process "control.exe" -ArgumentList "/name Microsoft.NetworkAndSharingCenter /page Advanced"
        Start-Process "systempropertiesperformance.exe"
        Start-Process "OptionalFeatures.exe"
        Start-Process "intl.cpl"

        [void]$finalForm.ShowDialog() # ShowDialog impede o fechamento prematuro
    }

    # BOTAO MANUAL (Para caso feche e queira abrir de novo)
    $Btn.Add_Click({ Show-ManualGuide })

    # ABERTURA AUTOMATICA AO FINAL DA PREPARACAO
    Show-ManualGuide
}

# -----------------------------------------------------------------------------
# 6. UI WINDOWS FORMS
# -----------------------------------------------------------------------------
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$formWidth = if ($screen.Width -lt 1200) { $screen.Width - 50 } else { 1200 }
$formHeight = if ($screen.Height -lt 900) { $screen.Height - 50 } else { 900 }

$form = New-Object System.Windows.Forms.Form
$form.Text = "XMenu System Manager v17.59"
$form.Size = New-Object System.Drawing.Size($formWidth, $formHeight)
$form.StartPosition = "CenterScreen"
$form.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 30); $form.ForeColor = 'White'
$form.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$Script:MainForm = $form

# === CONTEXT MENU PARA LINKS ÚTEIS (NOVO) ===
$linkMenu = New-Object System.Windows.Forms.ContextMenuStrip
$linkMenu.ShowImageMargin = $false
$linkMenu.Font = New-Object System.Drawing.Font("Segoe UI", 10)

function Add-CtxLink {
    param($Text, $Url)
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
$head = New-Object System.Windows.Forms.Panel; $head.Dock = 'Top'; $head.Height = 200
$head.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $head.Padding = '20,20,20,0'
[void]$form.Controls.Add($head)

$hLeft = New-Object System.Windows.Forms.Panel; $hLeft.Dock = 'Fill'; $hLeft.BackColor = 'Transparent'
[void]$head.Controls.Add($hLeft)
$lT = New-Object System.Windows.Forms.Label; $lT.Text = "XMenu Manager"; $lT.AutoSize = $true
$lT.ForeColor = [System.Drawing.Color]::White
$lT.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold); $lT.Location = '0,10'
[void]$hLeft.Controls.Add($lT)
$lS = New-Object System.Windows.Forms.Label; $lS.Text = "Desenvolvido por Vinicius Mazaroski"; $lS.AutoSize = $true
$lS.ForeColor = [System.Drawing.Color]::Gold
$lS.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lS.Location = '5,60'
[void]$hLeft.Controls.Add($lS)

$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$ram = Get-CimInstance Win32_ComputerSystem
$disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"
$gpu = Get-CimInstance Win32_VideoController | Select-Object -First 1
$gpuName = if ($gpu) { $gpu.Name } else { "N/A" }

$localIP = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notmatch '^127\.|^169\.254\.' } | Select-Object -First 1).IPAddress
if (-not $localIP) { $localIP = "Offline" }

$diskType = "Disco"
try {
    $physDisk = Get-PhysicalDisk -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($physDisk.MediaType -match 'SSD') { $diskType = "SSD" }
    elseif ($physDisk.MediaType -match 'HDD') { $diskType = "HD" }
}
catch {}

$lHw1 = New-Object System.Windows.Forms.Label
$lHw1.Text = "[ Host: $env:COMPUTERNAME   |   IP Local: $localIP   |   Usuario: $env:USERNAME ]"
$lHw1.AutoSize = $true; $lHw1.ForeColor = [System.Drawing.Color]::WhiteSmoke
$lHw1.Font = New-Object System.Drawing.Font("Consolas", 10.5, [System.Drawing.FontStyle]::Bold)
$lHw1.Location = '5,105'
[void]$hLeft.Controls.Add($lHw1)

$lHw2 = New-Object System.Windows.Forms.Label
$lHw2.Text = "Sistema: $($os.Caption -replace 'Microsoft ','')   |   CPU: $($cpu.Name.Trim())"
$lHw2.AutoSize = $true; $lHw2.ForeColor = [System.Drawing.Color]::WhiteSmoke
$lHw2.Font = New-Object System.Drawing.Font("Consolas", 10.5, [System.Drawing.FontStyle]::Bold)
$lHw2.Location = '5,125'
[void]$hLeft.Controls.Add($lHw2)

$lHw3 = New-Object System.Windows.Forms.Label
$lHw3.Text = "RAM: $([Math]::Round($ram.TotalPhysicalMemory / 1GB)) GB   |   $diskType (C:): $([Math]::Round($disk.Size / 1GB)) GB   |   Video: $gpuName"
$lHw3.AutoSize = $true; $lHw3.ForeColor = [System.Drawing.Color]::WhiteSmoke
$lHw3.Font = New-Object System.Drawing.Font("Consolas", 10.5, [System.Drawing.FontStyle]::Bold)
$lHw3.Location = '5,145'
[void]$hLeft.Controls.Add($lHw3)

$hwCopyAction = {
    $fullText = "$($lHw1.Text)`r`n$($lHw2.Text)`r`n$($lHw3.Text)"
    [System.Windows.Forms.Clipboard]::SetText($fullText)
    Log-Message "SUCESSO" "Informações de hardware copiadas para a área de transferência."
}
$lHw1.Cursor = [System.Windows.Forms.Cursors]::Hand; $lHw1.Add_Click($hwCopyAction)
$lHw2.Cursor = [System.Windows.Forms.Cursors]::Hand; $lHw2.Add_Click($hwCopyAction)
$lHw3.Cursor = [System.Windows.Forms.Cursors]::Hand; $lHw3.Add_Click($hwCopyAction)

$hRight = New-Object System.Windows.Forms.FlowLayoutPanel; $hRight.Dock = 'Right'; $hRight.Width = 140
$hRight.FlowDirection = 'TopDown'; $hRight.BackColor = 'Transparent'; $hRight.WrapContents = $false
$hRight.Padding = '0,40,0,0'
[void]$head.Controls.Add($hRight)

# O diagnostico de rede agora fica na grade de SUPORTE E DIAGNOSTICO,
# junto com as outras ferramentas (nao precisa mais de botao no cabecalho).

# --- NOVO BOTAO LINKS NO HEADER ---
$btnLinks = New-Object System.Windows.Forms.Button; $btnLinks.Text = "LINKS ÚTEIS ▼"; $btnLinks.Size = '140,40'
$btnLinks.BackColor = 'White'; $btnLinks.ForeColor = [System.Drawing.Color]::FromArgb(12, 78, 55)
$btnLinks.FlatStyle = 'Flat'; $btnLinks.FlatAppearance.BorderSize = 0; $btnLinks.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnLinks.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnLinks.Margin = '0,0,0,0'
$btnLinks.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$btnLinks.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnLinks.Add_Click({ 
        $linkMenu.Show($btnLinks, 0, $btnLinks.Height) 
    })
[void]$hRight.Controls.Add($btnLinks)
# ----------------------------------

# FOOTER
$foot = New-Object System.Windows.Forms.Panel; $foot.Dock = 'Bottom'; $foot.Height = 30
$foot.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 45)
[void]$form.Controls.Add($foot)
$prog = New-Object System.Windows.Forms.ProgressBar; $prog.Dock = 'Top'; $prog.Height = 5
[void]$foot.Controls.Add($prog); $Script:ProgressBar = $prog
$stat = New-Object System.Windows.Forms.Label; $stat.Text = "Pronto."; $stat.Dock = 'Fill'
$stat.TextAlign = 'MiddleLeft'; $stat.Padding = '10,0,0,0'; $stat.ForeColor = 'Gray'
[void]$foot.Controls.Add($stat); $Script:StatusLabel = $stat

# O cancelamento fica apenas no botao sobreposto (Show-CancelOverlay),
# em cima do proprio item que esta sendo baixado.

# MAIN LAYOUT
$layout = New-Object System.Windows.Forms.TableLayoutPanel; $layout.Dock = 'Fill'; $layout.ColumnCount = 1
$layout.Padding = '20'; $layout.RowCount = 3
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 70)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 80)))
[void]$form.Controls.Add($layout); $layout.BringToFront()

$gLog = New-Object System.Windows.Forms.GroupBox; $gLog.Text = "Log"; $gLog.ForeColor = 'Gray'; $gLog.Dock = 'Fill'
[void]$layout.Controls.Add($gLog, 0, 0)
$tLog = New-Object System.Windows.Forms.RichTextBox; $tLog.Dock = 'Fill'; $tLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$tLog.ForeColor = 'White'; $tLog.BorderStyle = 'None'; $tLog.ReadOnly = $true; $tLog.Font = New-Object System.Drawing.Font("Consolas", 9)
[void]$gLog.Controls.Add($tLog); $Script:LogBox = $tLog

$bCfg = New-Object System.Windows.Forms.Button; $bCfg.Text = "PREPARAR AMBIENTE WINDOWS"
$bCfg.Dock = 'Fill'; $bCfg.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $bCfg.ForeColor = 'White'
$bCfg.FlatStyle = 'Flat'; $bCfg.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$bCfg.Margin = '0,10,0,10'; $bCfg.Cursor = 'Hand'
$bCfg.FlatAppearance.BorderSize = 0
$bCfg.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(20, 112, 80)
$bCfg.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(10, 68, 48)

# TOOLTIP (NOVO)
if ($null -eq $Script:ToolTip) {
    $Script:ToolTip = New-Object System.Windows.Forms.ToolTip
    $Script:ToolTip.InitialDelay = 500
    $Script:ToolTip.AutoPopDelay = 10000
}
$Script:ToolTip.SetToolTip($bCfg, "Ajusta UAC, Energia, Performance, Rede, Limpeza e Personalização padrão XMenu.")

$bCfg.Add_Click({ Run-Config $this })
[void]$layout.Controls.Add($bCfg, 0, 1)

$pScroll = New-Object System.Windows.Forms.Panel; $pScroll.Dock = 'Fill'; $pScroll.AutoScroll = $true
[void]$layout.Controls.Add($pScroll, 0, 2)
$Script:ScrollPanel = $pScroll
$pScroll.Add_Scroll({ Update-CancelOverlay })
$tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = 'Top'; $tbl.AutoSize = $true
$tbl.ColumnCount = 2; [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pScroll.Controls.Add($tbl)

function Add-Title {
    param($T) 
    $l = New-Object System.Windows.Forms.Label; $l.Text = $T; $l.AutoSize = $true
    $l.ForeColor = [System.Drawing.Color]::FromArgb(26, 188, 138); $l.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $l.Margin = '5,15,0,5'; [void]$tbl.Controls.Add($l, 0, -1); $tbl.SetColumnSpan($l, 2)
    $null = $l
}

function Add-Btn {
    param($T, $D, $U, $F, $Sel = $false, $Type = "", $Color = $null, $Help = "") 
    $b = New-Object System.Windows.Forms.Button; $b.Height = 50; $b.Dock = 'Top'
    $b.ForeColor = 'WhiteSmoke'
    $b.FlatStyle = 'Flat'
    $b.TextAlign = 'MiddleLeft'; $b.Padding = '10,0,0,0'; $b.Margin = '5'
    $b.Text = $T; $b.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderSize = 0

    $baseColor = if ($Color) { $Color } else { [System.Drawing.Color]::FromArgb(22, 52, 41) }
    $b.BackColor = $baseColor
    
    # Hover: mais claro
    $r = [Math]::Min(255, $baseColor.R + 20)
    $g = [Math]::Min(255, $baseColor.G + 20)
    $bl = [Math]::Min(255, $baseColor.B + 20)
    $b.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb($r, $g, $bl)
    
    # Clique: mais escuro
    $rD = [Math]::Max(0, $baseColor.R - 15)
    $gD = [Math]::Max(0, $baseColor.G - 15)
    $blD = [Math]::Max(0, $baseColor.B - 15)
    $b.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb($rD, $gD, $blD)

    if ($Help -ne "") {
        $Script:ToolTip.SetToolTip($b, $Help)
    }

    if ($Sel) {
        $b.Tag = $Type; $b.Add_Click({ Open-Selector $this.Tag $this })
    }
    elseif ($U -eq "TEFHUB-X86") {
        # Link resolvido na hora do clique (a Elgin troca a versao sem aviso)
        $b.Add_Click({ Install-TefHub $this })
    }
    else {
        $b.Tag = "$U|$F"; $b.Add_Click({ $d = $this.Tag.Split('|'); Start-Download $d[0] $d[1] $this })
    }
    [void]$tbl.Controls.Add($b)
    $null = $b
}

$colorBlue = [System.Drawing.Color]::FromArgb(22, 52, 41)

Add-Title "BANCO DE DADOS"
Add-Btn "SQL Server 2008 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2008x64_DESCONTINUADO.exe" "SQL2008x64.exe" -Color $colorBlue -Help "Instalador clássico do SQL 2008 R2 (Padrão NetControll)"
Add-Btn "SQL Server 2019 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2019.exe" "SQL2019.exe" -Color $colorBlue -Help "Instalador automático do SQL Server 2019 Express."

$bSqlMan = New-Object System.Windows.Forms.Button; $bSqlMan.Height = 50; $bSqlMan.Dock = 'Top'
$bSqlMan.BackColor = [System.Drawing.Color]::FromArgb(22, 52, 41); $bSqlMan.ForeColor = 'WhiteSmoke'
$bSqlMan.FlatStyle = 'Flat'; $bSqlMan.FlatAppearance.BorderSize = 0; $bSqlMan.TextAlign = 'MiddleLeft'; $bSqlMan.Padding = '10,0,0,0'; $bSqlMan.Margin = '5'
$bSqlMan.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(33, 72, 57)
$bSqlMan.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(13, 36, 28)
$bSqlMan.Text = "SQL 2019 + SSMS (Manual / Avançado)"; $bSqlMan.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSqlMan.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bSqlMan, "ATENÇÃO: Instalação MANUAL e AVANÇADA. Baixa o SQL 2019 e o SSMS SEPARADAMENTE, para instalar passo a passo. Para a instalação normal/automática, use o botão azul 'SQL Server 2019 (Instalador)'.")
$bSqlMan.Add_Click({ Install-SqlManual $this })
[void]$tbl.Controls.Add($bSqlMan)

Add-Title "PROGRAMAS NETCONTROLL"
Add-Btn "Concentrador (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/InstaladorConcentrador.exe" "Concentrador.exe" -Color $colorBlue -Help "Instalador automático do Concentrador XMenu."
Add-Btn "Concentrador (ZIP)" "" "" "" $true "Concentrador" -Help "Permite escolher uma versão específica do Concentrador em arquivo ZIP."
Add-Btn "NetPDV (Instalador)" "" "https://netcontroll.com.br/util/instaladores/netpdv/1.3/55/0/NetPDV.exe" "NetPDV.exe" -Color $colorBlue -Help "Instalador padrão do NetPDV"
Add-Btn "NetPDV (ZIP)" "" "" "" $true "PDV" -Help "Menu para baixar versões específicas ou manuais do NetPDV."
Add-Btn "Link XMenu (Instalador)" "" "https://netcontroll.com.br/util/instaladores/LinkXMenu/10/11/LinkXMenu.exe" "LinkXMenu.exe" -Color $colorBlue -Help "Instalador do Link XMenu"
Add-Btn "Link XMenu (ZIP)" "" "" "" $true "LinkXMenu" -Help "Menu para baixar versões específicas do Link XMenu."
Add-Btn "XBot" "" "https://aws.netcontroll.com.br/XBotClient/setup.exe" "XBotSetup.exe" -Color $colorBlue -Help "Instalador do bot de auto-atendimento"
Add-Btn "XTag Client 2.0" "" "https://aws.netcontroll.com.br/XTagClient2.0/setup.exe" "XTagSetup.exe" -Color $colorBlue -Help "Instalador Xtag"
Add-Btn "Cardápio Tablet (ZIP)" "" "" "" $true "Tablet" -Help "Versões compactadas para Cardápio Digital em Tablets."
Add-Btn "Totem Auto-Atendimento (ZIP)" "" "" "" $true "Totem" -Help "Versões compactadas para o sistema de Totem (Auto-atendimento)."

Add-Title "EXTERNOS"

$bTecno = New-Object System.Windows.Forms.Button; $bTecno.Height = 50; $bTecno.Dock = 'Top'
$bTecno.BackColor = $colorBlue; $bTecno.ForeColor = 'WhiteSmoke'
$bTecno.FlatStyle = 'Flat'; $bTecno.FlatAppearance.BorderSize = 0; $bTecno.TextAlign = 'MiddleLeft'; $bTecno.Padding = '10,0,0,0'; $bTecno.Margin = '5'
$bTecno.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(33, 72, 57)
$bTecno.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(13, 36, 28)
$bTecno.Text = "TecnoSpeed NFCe (11.1.7.27)"; $bTecno.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bTecno.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bTecno, "Fecha todo o sistema NetControll (NetPDV, LinkXMenu, XMenu, Concentrador, XBot, XTag) e instala o componente TecnoSpeed para NFC-e.")
$bTecno.Add_Click({
        Close-NetControllSystem
        Start-Download "https://netcontroll.com.br/util/instaladores/NFCE/11.1.7.27/InstaladorNFCe.exe" "InstaladorNFCe.exe" $this
    })
[void]$tbl.Controls.Add($bTecno)

$bVspe = New-Object System.Windows.Forms.Button; $bVspe.Height = 50; $bVspe.Dock = 'Top'
$bVspe.BackColor = [System.Drawing.Color]::FromArgb(22, 52, 41); $bVspe.ForeColor = 'WhiteSmoke'
$bVspe.FlatStyle = 'Flat'; $bVspe.FlatAppearance.BorderSize = 0; $bVspe.TextAlign = 'MiddleLeft'; $bVspe.Padding = '10,0,0,0'; $bVspe.Margin = '5'
$bVspe.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(33, 72, 57)
$bVspe.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(13, 36, 28)
$bVspe.Text = "VSPE + Epson Virtual Port"; $bVspe.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bVspe.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bVspe, "Instala o emulador de porta serial VSPE e os drivers de porta virtual da Epson.")
$bVspe.Add_Click({ Install-VSPE-Combined $this })
[void]$tbl.Controls.Add($bVspe)

Add-Btn "TeamViewer Full" "" "https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe" "Teamviewer.exe" -Help "Cliente completo para acesso remoto TeamViewer."
Add-Btn "AnyDesk" "" "https://download.anydesk.com/AnyDesk.exe" "AnyDesk.exe" -Help "Ferramenta de acesso remoto AnyDesk."
Add-Btn "Google Chrome" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/ChromeSetup.exe" "ChromeSetup.exe" -Help "Instalador online do navegador Google Chrome."
Add-Btn "Revo Uninstaller" "" "https://download.revouninstaller.com/download/revosetup.exe" "revosetup.exe" -Help "Utilitário para desinstalação completa de programas e limpeza de restos."
Add-Btn "TEF HUB Windows (x86 - sempre a versão atual)" "" "TEFHUB-X86" "" -Help "Consulta o GitHub oficial da Elgin no momento do clique e baixa a versão x86 mais recente do TEF HUB. Não precisa mais trocar o link na mão."
Add-Btn "Advanced IP Scanner" "" "https://download.advanced-ip-scanner.com/download/files/Advanced_IP_Scanner_2.5.4594.1.exe" "Advanced_IP_Scanner.exe" -Help "Ferramenta de varredura de rede local Advanced IP Scanner."
Add-Btn "Balança Teste" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/BalancaTeste.exe" "BalancaTeste.exe" -Help "Aplicativo para testar o funcionamento e comunicação da balança."
# Link do Drive no formato drive.usercontent: o "uc?export=download" devolve
# a pagina de aviso de virus em HTML em vez do arquivo.
Add-Btn "Driver Balança Serial PCI (ZIP)" "" "https://drive.usercontent.google.com/download?id=1P2CH59rEporytibv32tMRsdX6uXby2p3&export=download&confirm=t" "Driver_Multi_Serial_PCI.zip" -Help "Driver da placa multi serial PCI usada para ligar a balança na porta serial. Baixa do Google Drive (120 MB) e extrai a pasta automaticamente."

$colorDiag = [System.Drawing.Color]::FromArgb(30, 80, 30)
$colorFix = [System.Drawing.Color]::FromArgb(100, 30, 30)

function Format-SupportBtn {
    param($Button, $Color)
    $Button.FlatStyle = 'Flat'
    $Button.FlatAppearance.BorderSize = 0
    $Button.BackColor = $Color
    $Button.ForeColor = 'WhiteSmoke'
    $Button.TextAlign = 'MiddleLeft'
    $Button.Padding = '10,0,0,0'
    $Button.Margin = '5'
    
    # Hover: mais claro
    $r = [Math]::Min(255, $Color.R + 20)
    $g = [Math]::Min(255, $Color.G + 20)
    $bl = [Math]::Min(255, $Color.B + 20)
    $Button.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb($r, $g, $bl)
    
    # Clique: mais escuro
    $rD = [Math]::Max(0, $Color.R - 15)
    $gD = [Math]::Max(0, $Color.G - 15)
    $blD = [Math]::Max(0, $Color.B - 15)
    $Button.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb($rD, $gD, $blD)
}

# Ocupa a celula que sobra quando um grupo de cor tem numero impar de botoes,
# para o proximo grupo sempre comecar numa linha nova (alinhado por cor).
function Add-SupportSpacer {
    $sp = New-Object System.Windows.Forms.Label
    $sp.Text = ""
    $sp.Dock = 'Fill'
    [void]$tbl.Controls.Add($sp)
}

Add-Title "SUPORTE E DIAGNÓSTICO"

# --- IMPRESSORAS E REDE (AZUL ESCURO / CINZA) ---
$colorGray = [System.Drawing.Color]::FromArgb(50, 55, 60)
$colorCyan = [System.Drawing.Color]::FromArgb(25, 75, 95)

$bPrintMgr = New-Object System.Windows.Forms.Button; $bPrintMgr.Height = 50; $bPrintMgr.Dock = 'Top'
$bPrintMgr.Text = "Gerenciador de Impressoras (LPR/LPD)"; $bPrintMgr.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$bPrintMgr.Cursor = 'Hand'
Format-SupportBtn $bPrintMgr $colorCyan
$Script:ToolTip.SetToolTip($bPrintMgr, "Gerencia impressoras locais, compartilhamentos e configura rede via protocolo LPR/LPD para corrigir erros no Windows 11.")
$bPrintMgr.Add_Click({ Show-PrinterManager })
[void]$tbl.Controls.Add($bPrintMgr)
Add-SupportSpacer   # fecha a linha do grupo azul

# --- DIAGNÓSTICOS (VERDE) ---
$bInfo = New-Object System.Windows.Forms.Button; $bInfo.Height = 50; $bInfo.Dock = 'Top'
$bInfo.Text = "Avaliação de Hardware"; $bInfo.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$bInfo.Cursor = 'Hand'
Format-SupportBtn $bInfo $colorDiag
$Script:ToolTip.SetToolTip($bInfo, "Analisa CPU, RAM e SSD usando WMI (Win32_Processor, Win32_LogicalDisk) e compara com requisitos XMenu.")
$bInfo.Add_Click({ Show-SystemInfo })
[void]$tbl.Controls.Add($bInfo)

$bScan = New-Object System.Windows.Forms.Button; $bScan.Height = 50; $bScan.Dock = 'Top'
$bScan.Text = "Scanner de Impressoras (IP Scan)"; $bScan.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bScan.Cursor = 'Hand'
Format-SupportBtn $bScan $colorDiag
$Script:ToolTip.SetToolTip($bScan, "Executa 'arp -a' e varredura de sockets (TCP 9100, 515, 631) para identificar impressoras e IPs na rede.")
$bScan.Add_Click({ Show-PrinterScanner })
[void]$tbl.Controls.Add($bScan)

$bPing = New-Object System.Windows.Forms.Button; $bPing.Height = 50; $bPing.Dock = 'Top'
$bPing.Text = "Teste de Ping Contínuo (com Log)"; $bPing.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bPing.Cursor = 'Hand'
Format-SupportBtn $bPing $colorDiag
$Script:ToolTip.SetToolTip($bPing, "Executa 'Test-Connection' continuamente para o IP alvo, permitindo monitorar perdas de pacotes com log local.")
$bPing.Add_Click({ Show-PingTester })
[void]$tbl.Controls.Add($bPing)

$bRes = New-Object System.Windows.Forms.Button; $bRes.Height = 50; $bRes.Dock = 'Top'
$bRes.Text = "Monitorar CPU e RAM"; $bRes.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bRes.Cursor = 'Hand'
Format-SupportBtn $bRes $colorDiag
$Script:ToolTip.SetToolTip($bRes, "Utiliza 'Get-Process' para listar os 5 processos com maior consumo de CPU e Memória RAM em tempo real.")
$bRes.Add_Click({ Show-ResourceMonitor })
[void]$tbl.Controls.Add($bRes)

$bSrv = New-Object System.Windows.Forms.Button; $bSrv.Height = 50; $bSrv.Dock = 'Top'
$bSrv.Text = "Serviços do SQL Server e do Sistema"; $bSrv.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSrv.Cursor = 'Hand'
Format-SupportBtn $bSrv $colorDiag
$Script:ToolTip.SetToolTip($bSrv, "Mostra o estado do SQL Server, SQL Browser, Spooler e serviços do sistema. Permite iniciar, parar, reiniciar, deixar em início automático e testar a porta 1433 do servidor.")
$bSrv.Add_Click({ Show-ServiceManager })
[void]$tbl.Controls.Add($bSrv)

$bNet = New-Object System.Windows.Forms.Button; $bNet.Height = 50; $bNet.Dock = 'Top'
$bNet.Text = "Diagnóstico de Rede"; $bNet.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bNet.Cursor = 'Hand'
Format-SupportBtn $bNet $colorDiag
$Script:ToolTip.SetToolTip($bNet, "IP, gateway, DNS, placa e MAC, mais os testes de rede local, internet, DNS e servidor NetControll. Aponta em qual ponto a conexão quebrou.")
$bNet.Add_Click({ Show-IPs })
[void]$tbl.Controls.Add($bNet)

# --- REPAROS E RESETS (VERMELHO) ---
$bSfc = New-Object System.Windows.Forms.Button; $bSfc.Height = 50; $bSfc.Dock = 'Top'
$bSfc.Text = "SFC /Scannow (Reparar Sistema)"; $bSfc.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSfc.Cursor = 'Hand'
Format-SupportBtn $bSfc $colorFix
$Script:ToolTip.SetToolTip($bSfc, "Executa o comando 'sfc /scannow' em uma nova janela para verificar e reparar arquivos corrompidos da instalação do Windows.")
$bSfc.Add_Click({ Invoke-SFC })
[void]$tbl.Controls.Add($bSfc)

$bDism = New-Object System.Windows.Forms.Button; $bDism.Height = 50; $bDism.Dock = 'Top'
$bDism.Text = "Reparar Imagem (DISM)"; $bDism.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bDism.Cursor = 'Hand'
Format-SupportBtn $bDism $colorFix
$Script:ToolTip.SetToolTip($bDism, "Executa 'dism /online /cleanup-image /restorehealth' para corrigir erros profundos na imagem do sistema operacional.")
$bDism.Add_Click({ Invoke-DISM })
[void]$tbl.Controls.Add($bDism)

$bClean = New-Object System.Windows.Forms.Button; $bClean.Height = 50; $bClean.Dock = 'Top'
$bClean.Text = "Limpeza de Disco Profunda"; $bClean.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bClean.Cursor = 'Hand'
Format-SupportBtn $bClean $colorFix
$Script:ToolTip.SetToolTip($bClean, "Limpa pastas TEMP, Prefetch, Logs do Windows e executa 'cleanmgr.exe /sagerun:1' para liberar espaço em disco.")
$bClean.Add_Click({ Invoke-DeepClean })
[void]$tbl.Controls.Add($bClean)

$bWinUp = New-Object System.Windows.Forms.Button; $bWinUp.Height = 50; $bWinUp.Dock = 'Top'
$bWinUp.Text = "Reparar Windows Update"; $bWinUp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bWinUp.Cursor = 'Hand'
Format-SupportBtn $bWinUp $colorFix
$Script:ToolTip.SetToolTip($bWinUp, "Interrompe wuauserv/bits, limpa a pasta SoftwareDistribution e reinicia os serviços de atualização.")
$bWinUp.Add_Click({ Invoke-WindowsUpdateReset })
[void]$tbl.Controls.Add($bWinUp)

$bSpool = New-Object System.Windows.Forms.Button; $bSpool.Height = 50; $bSpool.Dock = 'Top'
$bSpool.Text = "Reiniciar Spooler de Impressão"; $bSpool.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSpool.Cursor = 'Hand'
Format-SupportBtn $bSpool $colorGray
$Script:ToolTip.SetToolTip($bSpool, "Comando 'Stop-Service Spooler', deleta conteúdo de C:\Windows\System32\spool\PRINTERS\* e reinicia o serviço.")
$bSpool.Add_Click({ Invoke-SpoolerReset })
[void]$tbl.Controls.Add($bSpool)

$bUsb = New-Object System.Windows.Forms.Button; $bUsb.Height = 50; $bUsb.Dock = 'Top'
$bUsb.Text = "Corrigir Impressora USB que Desconecta"; $bUsb.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bUsb.Cursor = 'Hand'
Format-SupportBtn $bUsb $colorGray
$Script:ToolTip.SetToolTip($bUsb, "Desliga a suspensão seletiva de USB no plano de energia e a economia de energia das portas USB. Resolve a impressora térmica USB que para de responder depois de um tempo parada.")
$bUsb.Add_Click({ Invoke-UsbPowerFix })
[void]$tbl.Controls.Add($bUsb)

$bNetR = New-Object System.Windows.Forms.Button; $bNetR.Height = 50; $bNetR.Dock = 'Top'
$bNetR.Text = "Reset de Rede e DNS"; $bNetR.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bNetR.Cursor = 'Hand'
Format-SupportBtn $bNetR $colorGray
$Script:ToolTip.SetToolTip($bNetR, "Executa 'ipconfig /flushdns', 'netsh winsock reset', 'netsh int ip reset', 'ipconfig /release' e 'ipconfig /renew' para restaurar toda a pilha de rede e renovar o IP.")
$bNetR.Add_Click({ Invoke-NetworkReset })
[void]$tbl.Controls.Add($bNetR)

$bClock = New-Object System.Windows.Forms.Button; $bClock.Height = 50; $bClock.Dock = 'Top'
$bClock.Text = "Sincronizar Relógio (NFC-e)"; $bClock.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bClock.Cursor = 'Hand'
Format-SupportBtn $bClock $colorGray
$Script:ToolTip.SetToolTip($bClock, "Liga o serviço de horário, aponta para o pool.ntp.br e sincroniza. Relógio adiantado ou atrasado faz a SEFAZ rejeitar NFC-e.")
$bClock.Add_Click({ Invoke-ClockSync })
[void]$tbl.Controls.Add($bClock)

Log-Message "INFO" "XMenu System Manager v17.59 - Central de Preparo e Suporte"
Log-Message "LOG" "==============================================================="
Log-Message "SUCESSO" "[NOVIDADE] Nova aba 'Drivers de Impressoras' no Gerenciador!"
Log-Message "SUCESSO" "           - Download direto de drivers e utilitários de configuração."
Log-Message "LOG" "---------------------------------------------------------------"
Log-Message "LOG" "Este utilitário automatiza a configuração de ambientes XMenu,"
Log-Message "LOG" "garantindo que o Windows esteja otimizado para máxima performance."
Log-Message "LOG" ""
Log-Message "INFO" "[1] PREPARO: Otimização de UAC, Energia e Performance em um clique."
Log-Message "INFO" "[2] DOWNLOADS: Acesso rápido a instaladores (SQL, PDV, XBot, etc)."
Log-Message "INFO" "[3] DIAGNÓSTICO: Auditoria de Hardware e Scanner de Rede Profissional."
Log-Message "INFO" "[4] MANUTENÇÃO: Reparos de Rede, Spooler e do Sistema Windows."
Log-Message "LOG" "==============================================================="
Log-Message "SUCESSO" "Sistema pronto para suporte técnico."

$form.Add_Shown({ $this.ActiveControl = $null })
[void]$form.ShowDialog()
