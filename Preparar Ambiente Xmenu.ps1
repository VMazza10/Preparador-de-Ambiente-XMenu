# =============================================================================
# PREPARADOR XMENU v5.9
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
$Script:BackupPasta = Join-Path $Script:DownloadFolder "Backup NetWebPDV"
$Script:RepoBase = "https://raw.githubusercontent.com/VMazza10/Preparador-de-Ambiente-XMenu/main"

if (-not (Test-Path $Script:DownloadFolder)) {
    New-Item -Path $Script:DownloadFolder -ItemType Directory -Force | Out-Null
}

# Exclui a pasta de downloads do Windows Defender.
# Evita falsos positivos que bloqueiam instaladores de driver legitimos
# (comum em auto-extraiveis WinRAR SFX e drivers antigos).
# ATENCAO: essa pasta deixa de ser escaneada pelo antivirus.
# Roda em segundo plano: o Add-MpPreference leva quase 1 s e atrasava a abertura da
# janela. A pasta so e usada quando o tecnico clica para baixar alguma coisa.
try {
    $Script:ExclusaoDefender = [PowerShell]::Create()
    [void]$Script:ExclusaoDefender.AddScript({
            param($Pasta)
            if (Get-Command Add-MpPreference -ErrorAction SilentlyContinue) {
                Add-MpPreference -ExclusionPath $Pasta -ErrorAction SilentlyContinue
            }
        }).AddArgument($Script:DownloadFolder)
    [void]$Script:ExclusaoDefender.BeginInvoke()
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

# A API do papel de parede (XMenuTools.WinAPI) e compilada no Run-Config, na hora de
# aplicar o fundo: compilar aqui atrasava a abertura de todo mundo.

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

function Save-DownloadExtras {
    # Arquivos que vao junto dentro da pasta extraida de uma versao especifica
    # (ex.: AjustesInstalacao.exe do Concentrador 1.3.68.0).
    # Devolve a lista de falhas; vazia quando tudo foi baixado.
    param([string]$Pasta, $Extras)
    $falhas = @()
    foreach ($extra in @($Extras)) {
        if ($null -eq $extra) { continue }
        $destino = Join-Path $Pasta $extra.File
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Log-Message "INFO" "Baixando $($extra.File) para a pasta $(Split-Path $Pasta -Leaf)..."
            $wc = New-Object System.Net.WebClient
            try { $wc.DownloadFile($extra.Url, $destino) }
            finally { $wc.Dispose() }
            if (-not (Test-DownloadIntegrity -Path $destino)) {
                Remove-Item -LiteralPath $destino -Force -ErrorAction SilentlyContinue
                throw "o arquivo baixado veio corrompido ou inválido"
            }
            Unblock-File -LiteralPath $destino -ErrorAction SilentlyContinue
            Log-Message "SUCESSO" "$($extra.File) colocado na pasta $(Split-Path $Pasta -Leaf)"
        }
        catch {
            $falhas += "$($extra.File): $($_.Exception.Message)"
            Log-Message "ERRO" "Falha ao baixar $($extra.File): $($_.Exception.Message)"
        }
    }
    return $falhas
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
    # -Resultado: sem mensagem, devolve @{ Feitos; Falhas } (usado pelo CORRIGIR IMPRESSORA USB)
    param([switch]$Silencioso, [switch]$Resultado)
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

    if ($Resultado) { return @{ Feitos = $feitos; Falhas = $falhas } }
    if ($Silencioso) { return }

    [System.Windows.Forms.MessageBox]::Show($texto, "Energia das portas USB", "OK",
        $(if ($falhas.Count -gt 0) { "Warning" } else { "Information" })) | Out-Null
}

# -----------------------------------------------------------------------------
# IMPRESSORA USB (MP-4200 TH e outras): diagnostico e correcao em um clique
# Os tres defeitos que mais aparecem no suporte:
#  - cabo em outra entrada USB: o Windows cria outra porta (USB002, USB003) e a
#    impressora continua apontando para a antiga, que nao esta mais conectada;
#  - para depois de um tempo parada: economia de energia do USB e do aparelho;
#  - nao imprime ao ligar o PC: a inicializacao rapida nao desliga o USB de verdade.
# -----------------------------------------------------------------------------

function Get-NomeFabricanteUsb {
    # Fabricante pelo VID do USB, so os que aparecem nos PDVs
    param([string]$Vid)
    $nomes = @{ '0B1B' = 'Bematech'; '04B8' = 'Epson'; '0519' = 'Star'; '1504' = 'Bixolon'; '0DD4' = 'Custom' }
    $v = "$Vid".ToUpper()
    if ($nomes.ContainsKey($v)) { return $nomes[$v] }
    return ""
}

function Test-DriverDoFabricante {
    # O driver da impressora do Windows e do mesmo fabricante do aparelho USB?
    param([string]$Driver, [string]$Fabricante)
    $apelidos = @{
        'Bematech' = 'Bematech|MP-?4200|MP-?2500|MP-?4000|MP-?2800|MP-?100'
        'Epson' = 'Epson|TM-'; 'Star' = 'Star|TSP'; 'Bixolon' = 'Bixolon|SRP'; 'Custom' = 'Custom'
    }
    if ("$Fabricante" -eq "" -or -not $apelidos.ContainsKey($Fabricante)) { return $false }
    return ("$Driver" -match $apelidos[$Fabricante])
}

function Get-PortasUsbImpressora {
    # Portas USB00x que o Windows ja criou para impressoras (interface usbprint),
    # com o aparelho de cada uma e se ele esta conectado agora (Control\Linked = 1).
    # -Raiz: o CurrentControlSet (o teste usa uma copia falsa no HKCU)
    param([string]$Raiz = "HKLM:\SYSTEM\CurrentControlSet")
    $lista = @()
    $classe = Join-Path $Raiz "Control\DeviceClasses\{28d78fad-5a12-11d1-ae5b-0000f803a8c2}"
    if (-not (Test-Path -LiteralPath $classe)) { return , $lista }
    foreach ($k in @(Get-ChildItem -LiteralPath $classe -ErrorAction SilentlyContinue)) {
        $parametros = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath "#\Device Parameters") -ErrorAction SilentlyContinue
        if ($null -eq $parametros -or $null -eq $parametros.'Port Number') { continue }
        $base = "$($parametros.'Base Name')"
        if ($base -eq "") { $base = "USB" }
        $porta = $base + ([int]$parametros.'Port Number').ToString("000")
        $instancia = "$((Get-ItemProperty -LiteralPath $k.PSPath -Name DeviceInstance -ErrorAction SilentlyContinue).DeviceInstance)"
        $controle = Get-ItemProperty -LiteralPath (Join-Path $k.PSPath "#\Control") -ErrorAction SilentlyContinue
        $conectada = ($null -ne $controle -and $controle.Linked -eq 1)
        $vid = ""
        $produto = ""
        if (("$($k.PSChildName) $instancia") -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') { $vid = $matches[1].ToUpper(); $produto = $matches[2].ToUpper() }
        $descricao = ""
        if ($instancia -ne "") {
            $enum = Get-ItemProperty -LiteralPath (Join-Path $Raiz "Enum\$instancia") -ErrorAction SilentlyContinue
            if ($null -ne $enum) {
                $descricao = "$($enum.FriendlyName)"
                if ($descricao -eq "") { $descricao = "$($enum.DeviceDesc)" }
            }
        }
        # "@usbprint.inf,%usbprint.devicedesc%;Suporte para impressao USB" -> so o texto
        $descricao = $descricao -replace '^@[^;]*;', ''
        $lista += @{
            Porta = $porta; Instancia = $instancia; Conectada = $conectada; Vid = $vid; Produto = $produto
            Descricao = $descricao; Fabricante = (Get-NomeFabricanteUsb $vid)
        }
    }
    return , @($lista | Sort-Object { $_.Porta })
}

function Get-ImpressorasUsb {
    # Impressoras do Windows ligadas numa porta USB00x
    $lista = @()
    try {
        foreach ($p in @(Get-WmiObject Win32_Printer -ErrorAction Stop)) {
            if ("$($p.PortName)" -match '^USB\d+$') {
                $lista += @{ Nome = "$($p.Name)"; Porta = "$($p.PortName)".ToUpper(); Driver = "$($p.DriverName)"; Offline = [bool]$p.WorkOffline }
            }
        }
    }
    catch {}
    return , $lista
}

function Get-PlanoPortasUsb {
    # Decide o que fazer com cada impressora USB. Devolve hashtable:
    #   Certas ..... impressoras ja numa porta conectada
    #   Mover ...... @{ Nome; De; Para } que da para acertar sozinho
    #   Escolher ... impressoras em porta desconectada quando ha mais de uma opcao
    #   Livres ..... portas conectadas sem impressora (sobram depois do Mover)
    #   SemConexao . nenhuma impressora USB conectada agora
    param($Impressoras, $Portas)
    $conectadas = @($Portas | Where-Object { $_.Conectada })
    $porNome = @{}
    foreach ($c in $conectadas) { $porNome[$c.Porta] = $c }
    $certas = @($Impressoras | Where-Object { $porNome.ContainsKey($_.Porta) })
    $orfas = @($Impressoras | Where-Object { -not $porNome.ContainsKey($_.Porta) })
    $usadas = @{}
    foreach ($i in $certas) { $usadas[$i.Porta] = $true }
    $livres = @($conectadas | Where-Object { -not $usadas.ContainsKey($_.Porta) })

    $mover = @()
    $escolher = @()
    if ($orfas.Count -gt 0 -and $livres.Count -gt 0) {
        if ($orfas.Count -eq 1 -and $livres.Count -eq 1) {
            $mover += @{ Nome = $orfas[0].Nome; De = $orfas[0].Porta; Para = $livres[0].Porta }
        }
        else {
            # Mais de uma opcao: so casa sozinho quando o fabricante deixa um par unico
            # (driver MP-4200 com o unico aparelho Bematech livre, e vice-versa)
            $candidatas = @{}
            foreach ($o in $orfas) { $candidatas[$o.Nome] = @($livres | Where-Object { Test-DriverDoFabricante -Driver $o.Driver -Fabricante $_.Fabricante }) }
            foreach ($o in $orfas) {
                $opcoes = @($candidatas[$o.Nome])
                if ($opcoes.Count -eq 1) {
                    $portaUnica = $opcoes[0].Porta
                    $disputa = @($orfas | Where-Object { @($candidatas[$_.Nome] | Where-Object { $_.Porta -eq $portaUnica }).Count -gt 0 })
                    if ($disputa.Count -eq 1) {
                        $mover += @{ Nome = $o.Nome; De = $o.Porta; Para = $portaUnica }
                        continue
                    }
                }
                $escolher += $o
            }
        }
    }
    $destinos = @{}
    foreach ($m in $mover) { $destinos[$m.Para] = $true }
    $livresRestantes = @($livres | Where-Object { -not $destinos.ContainsKey($_.Porta) })
    return @{
        Certas = $certas; Mover = $mover; Escolher = $escolher; Livres = $livresRestantes
        Orfas = $orfas; SemConexao = ($conectadas.Count -eq 0)
    }
}

function Set-PortaImpressora {
    # Troca a porta da impressora; Set-Printer e, se nao der, pelo WMI
    param([string]$Nome, [string]$Porta)
    try { Set-Printer -Name $Nome -PortName $Porta -ErrorAction Stop; return }
    catch {
        $filtro = "Name='" + $Nome.Replace("\", "\\").Replace("'", "\'") + "'"
        $wmi = Get-WmiObject Win32_Printer -Filter $filtro -ErrorAction Stop
        if ($null -eq $wmi) { throw "impressora $Nome não encontrada" }
        $wmi.PortName = $Porta
        [void]$wmi.Put()
    }
}

function Set-ImpressoraOnline {
    # Desmarca "Usar impressora offline", que o Windows marca quando a porta some
    param([string]$Nome)
    $filtro = "Name='" + $Nome.Replace("\", "\\").Replace("'", "\'") + "'"
    $wmi = Get-WmiObject Win32_Printer -Filter $filtro -ErrorAction Stop
    if ($null -ne $wmi -and $wmi.WorkOffline) {
        $wmi.WorkOffline = $false
        [void]$wmi.Put()
    }
}

function Set-EnergiaAparelhoUsb {
    # Desliga a economia de energia do proprio aparelho USB, que a caixinha do
    # Gerenciador de Dispositivos nao alcanca. Vale na proxima vez que o cabo for
    # conectado ou o PC reiniciar. Aplica em todas as entradas USB que a impressora
    # ja usou, para continuar valendo se trocarem o cabo de lugar.
    # Devolve @{ Ajustados; Falhas }
    param($Instancias, [string]$Raiz = "HKLM:\SYSTEM\CurrentControlSet")
    $alvos = New-Object System.Collections.Generic.List[string]
    foreach ($inst in @($Instancias | Where-Object { "$_" -ne "" } | Select-Object -Unique)) {
        $alvos.Add($inst)
        # Aparelho composto (&MI_xx): a energia fica no aparelho pai, VID&PID sem o MI
        if ($inst -match '^(USB\\VID_[0-9A-Fa-f]{4}&PID_[0-9A-Fa-f]{4})&MI_') {
            $pai = $matches[1]
            foreach ($filho in @(Get-ChildItem -LiteralPath (Join-Path $Raiz "Enum\$pai") -ErrorAction SilentlyContinue)) { $alvos.Add($pai + "\" + $filho.PSChildName) }
        }
    }
    $ajustados = 0
    $falhas = 0
    foreach ($alvo in @($alvos | Select-Object -Unique)) {
        $aparelho = Join-Path $Raiz "Enum\$alvo"
        if (-not (Test-Path -LiteralPath $aparelho)) { continue }
        $chave = Join-Path $aparelho "Device Parameters"
        try {
            if (-not (Test-Path -LiteralPath $chave)) { [void](New-Item -Path $chave -Force -ErrorAction Stop) }
            foreach ($nomeValor in @('EnhancedPowerManagementEnabled', 'AllowIdleIrpInD3', 'DeviceSelectiveSuspended')) {
                New-ItemProperty -LiteralPath $chave -Name $nomeValor -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
            }
            # SelectiveSuspendEnabled: alguns drivers gravam como binario; so zera o que
            # ja existe, mantendo o tipo que o driver usa
            $atual = (Get-Item -LiteralPath $chave -ErrorAction Stop)
            if ($atual.GetValueNames() -contains 'SelectiveSuspendEnabled') {
                if ($atual.GetValueKind('SelectiveSuspendEnabled') -eq [Microsoft.Win32.RegistryValueKind]::Binary) {
                    New-ItemProperty -LiteralPath $chave -Name 'SelectiveSuspendEnabled' -Value ([byte[]](0)) -PropertyType Binary -Force -ErrorAction Stop | Out-Null
                }
                else { New-ItemProperty -LiteralPath $chave -Name 'SelectiveSuspendEnabled' -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null }
            }
            $ajustados++
        }
        catch { $falhas++ }
    }
    return @{ Ajustados = $ajustados; Falhas = $falhas }
}

function Disable-InicializacaoRapida {
    # Com a inicializacao rapida o PC nao desliga de verdade e a impressora USB
    # muitas vezes nao e reconhecida ao ligar. Devolve o que aconteceu.
    param([string]$Raiz = "HKLM:\SYSTEM\CurrentControlSet")
    $chave = Join-Path $Raiz "Control\Session Manager\Power"
    $antes = (Get-ItemProperty -LiteralPath $chave -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
    if ($null -ne $antes -and [int]$antes -eq 0) { return "já estava desligada" }
    if (-not (Test-Path -LiteralPath $chave)) { [void](New-Item -Path $chave -Force -ErrorAction Stop) }
    New-ItemProperty -LiteralPath $chave -Name HiberbootEnabled -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    return "desligada"
}

function Set-RecuperacaoSpooler {
    # Spooler que cai volta sozinho em 5 s (tres tentativas, zera a contagem por dia)
    $p = Start-Process "sc.exe" -ArgumentList "failure Spooler reset= 86400 actions= restart/5000/restart/5000/restart/5000" -Wait -PassThru -WindowStyle Hidden
    return ($p.ExitCode -eq 0)
}

function Show-EscolhaPortaUsb {
    # Mais de uma impressora ou mais de uma porta: o tecnico escolhe qual vai onde.
    # Devolve @{ Nome; De; Para } so das que ganharam porta.
    param($Orfas, $Livres)
    $escolhas = @()
    $fe = New-ToolForm "Qual impressora está em qual porta USB?" 720 (190 + 40 * @($Orfas).Count)
    New-ToolLabel $fe "Estas impressoras apontam para uma porta USB que não está conectada. Escolha a porta USB conectada de cada uma (a lista mostra o fabricante do aparelho)." 16 12 9 -W 680 | Out-Null
    $combos = @()
    $y = 60
    foreach ($o in @($Orfas)) {
        New-ToolLabel $fe "$($o.Nome)  (hoje em $($o.Porta), desconectada)" 16 ($y + 4) 9 -W 380 | Out-Null
        $cb = New-Object System.Windows.Forms.ComboBox
        $cb.DropDownStyle = 'DropDownList'
        $cb.Location = New-Object System.Drawing.Point(410, $y)
        $cb.Width = 280
        [void]$cb.Items.Add("(deixar como está)")
        foreach ($l in @($Livres)) {
            $fab = $l.Fabricante
            if ($fab -eq "") { $fab = "VID $($l.Vid)" }
            [void]$cb.Items.Add("$($l.Porta) - $fab - conectada")
        }
        $cb.SelectedIndex = 0
        [void]$fe.Controls.Add($cb)
        $combos += , @($o, $cb)
        $y += 40
    }
    $btnOk = New-ToolButton $fe "APLICAR" 400 ($y + 20) 140 32 $Script:UiVerde $null "Troca a porta das impressoras escolhidas"
    $btnCancelar = New-ToolButton $fe "CANCELAR" 550 ($y + 20) 140 32 $Script:UiCinza $null "Não troca nenhuma porta"
    $btnOk.Add_Click({ $fe.DialogResult = 'OK'; $fe.Close() })
    $btnCancelar.Add_Click({ $fe.DialogResult = 'Cancel'; $fe.Close() })
    $resposta = $fe.ShowDialog($Script:MainForm)
    if ($resposta -eq 'OK') {
        foreach ($par in $combos) {
            $idx = $par[1].SelectedIndex
            if ($idx -gt 0) { $escolhas += @{ Nome = $par[0].Nome; De = $par[0].Porta; Para = @($Livres)[$idx - 1].Porta } }
        }
    }
    $fe.Dispose()
    return , $escolhas
}

function Invoke-CorrigirImpressoraUsb {
    # Botao CORRIGIR IMPRESSORA USB: acha a porta USB certa, tira a economia de
    # energia (USB, aparelho e PC), desliga a inicializacao rapida e mostra o relatorio
    Log-Message "INFO" "Impressora USB: conferindo portas, energia e inicialização..."
    $rel = New-Object System.Collections.Generic.List[string]
    $houveFalha = $false
    $prontas = New-Object System.Collections.Generic.List[string]

    # 1) PORTA USB
    $rel.Add("PORTA USB")
    $portas = @()
    $impressoras = @()
    try {
        $portas = Get-PortasUsbImpressora
        $impressoras = Get-ImpressorasUsb
    }
    catch { Log-Message "ERRO" "   > Falha ao ler as portas USB: $($_.Exception.Message)" }
    $plano = Get-PlanoPortasUsb -Impressoras $impressoras -Portas $portas
    $descPorta = @{}
    foreach ($p in $portas) {
        $fab = $p.Fabricante
        if ($fab -eq "" -and $p.Vid -ne "") { $fab = "VID $($p.Vid)" }
        $descPorta[$p.Porta] = $fab
    }

    $mover = @($plano.Mover)
    if (@($plano.Escolher).Count -gt 0 -and @($plano.Livres).Count -gt 0) {
        # Sem @(): a janela ja devolve a lista inteira como um objeto so
        $escolhidas = Show-EscolhaPortaUsb -Orfas $plano.Escolher -Livres $plano.Livres
        foreach ($esc in @($escolhidas)) { if ($null -ne $esc) { $mover += $esc } }
    }
    $movidas = @{}
    foreach ($m in $mover) {
        try {
            Set-PortaImpressora -Nome $m.Nome -Porta $m.Para
            $movidas[$m.Nome] = $true
            $fabTxt = ""
            if ("$($descPorta[$m.Para])" -ne "") { $fabTxt = ", $($descPorta[$m.Para])" }
            $rel.Add("  $($m.Nome): $($m.De) (desconectada) -> $($m.Para) (conectada$fabTxt)")
            Log-Message "SUCESSO" "   > $($m.Nome): porta $($m.De) -> $($m.Para)"
            $prontas.Add($m.Nome)
        }
        catch {
            $houveFalha = $true
            $rel.Add("  $($m.Nome): não deu para trocar $($m.De) -> $($m.Para) ($($_.Exception.Message))")
            Log-Message "ERRO" "   > Falha ao trocar a porta de $($m.Nome): $($_.Exception.Message)"
        }
    }
    foreach ($c in @($plano.Certas)) {
        $rel.Add("  $($c.Nome): já está na porta certa ($($c.Porta), conectada)")
        $prontas.Add($c.Nome)
    }
    foreach ($o in @($plano.Orfas)) {
        if ($movidas.ContainsKey($o.Nome)) { continue }
        $houveFalha = $true
        if ($plano.SemConexao) { $rel.Add("  $($o.Nome): aponta para $($o.Porta), mas nenhuma impressora USB está conectada agora. Confira cabo, energia e se ela está ligada.") }
        else { $rel.Add("  $($o.Nome): continua em $($o.Porta), que não está conectada (porta não escolhida).") }
    }
    foreach ($l in @($plano.Livres)) {
        $usada = @($mover | Where-Object { $_.Para -eq $l.Porta -and $movidas.ContainsKey($_.Nome) }).Count -gt 0
        if (-not $usada) { $rel.Add("  $($l.Porta) ($($descPorta[$l.Porta])) está conectada, mas nenhuma impressora do Windows usa essa porta: instale o driver ou aponte a impressora para ela.") }
    }
    if (@($impressoras).Count -eq 0) { $rel.Add("  Nenhuma impressora do Windows usa porta USB neste PC.") }

    # "Usar impressora offline" marcado pelo Windows quando a porta sumiu
    foreach ($nome in @($prontas)) {
        $imp = @($impressoras | Where-Object { $_.Nome -eq $nome })
        if ($imp.Count -gt 0 -and $imp[0].Offline) {
            try { Set-ImpressoraOnline -Nome $nome; $rel.Add("  $($nome): tirada do modo offline") }
            catch { $houveFalha = $true; $rel.Add("  $($nome): continua marcada como offline ($($_.Exception.Message))") }
        }
    }

    # 2) ENERGIA
    $rel.Add("")
    $rel.Add("ENERGIA")
    try {
        $energia = Invoke-UsbPowerFix -Resultado
        foreach ($x in @($energia.Feitos)) { $rel.Add("  $x") }
        foreach ($x in @($energia.Falhas)) { $houveFalha = $true; $rel.Add("  Não aplicado: $x") }
    }
    catch { $houveFalha = $true; $rel.Add("  Falha no ajuste de energia do USB: $($_.Exception.Message)") }
    $instancias = @($portas | ForEach-Object { $_.Instancia } | Where-Object { $_ -ne "" })
    if ($instancias.Count -gt 0) {
        $aparelho = Set-EnergiaAparelhoUsb -Instancias $instancias
        if ($aparelho.Ajustados -gt 0) { $rel.Add("  Economia de energia da própria impressora desligada ($($aparelho.Ajustados) entrada(s) USB; vale ao reconectar o cabo ou reiniciar)") }
        if ($aparelho.Falhas -gt 0) { $houveFalha = $true; $rel.Add("  $($aparelho.Falhas) entrada(s) USB recusaram o ajuste de energia do aparelho") }
    }
    try {
        if (Set-RecuperacaoSpooler) { $rel.Add("  Serviço de impressão volta sozinho se travar") }
        else { $rel.Add("  Não deu para configurar o serviço de impressão para voltar sozinho") }
    }
    catch { $rel.Add("  Não deu para configurar o serviço de impressão para voltar sozinho") }

    # 3) INICIALIZACAO
    $rel.Add("")
    $rel.Add("AO LIGAR O PC")
    try {
        $rapida = Disable-InicializacaoRapida
        $rel.Add("  Inicialização rápida do Windows: $rapida")
    }
    catch { $houveFalha = $true; $rel.Add("  Não deu para desligar a inicialização rápida: $($_.Exception.Message)") }

    $rel.Add("")
    $rel.Add("Se a impressora ainda não responder, tire e ponha o cabo USB uma vez (de preferência numa porta atrás do gabinete, direto na placa).")
    foreach ($linhaRel in $rel) { if ($linhaRel -ne "") { Log-Message "INFO" "   $linhaRel" } }

    $icone = "Information"
    if ($houveFalha) { $icone = "Warning" }
    $texto = ($rel -join "`r`n")
    $unica = @($prontas | Select-Object -Unique)
    if ($unica.Count -eq 1) {
        $texto = $texto + "`r`n`r`nImprimir uma folha de teste em ""$($unica[0])"" agora?"
        $resp = [System.Windows.Forms.MessageBox]::Show($texto, "Corrigir impressora USB", "YesNo", $icone)
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            try {
                Send-TesteImpressao -Impressora $unica[0] -Detalhe "Teste depois do CORRIGIR IMPRESSORA USB"
                Log-Message "SUCESSO" "Impressora USB: teste enviado para $($unica[0])"
            }
            catch {
                Log-Message "ERRO" "Impressora USB: falha ao enviar o teste - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show("Não deu para enviar o teste para $($unica[0]): $($_.Exception.Message)", "Corrigir impressora USB", "OK", "Warning") | Out-Null
            }
        }
    }
    else {
        [System.Windows.Forms.MessageBox]::Show($texto, "Corrigir impressora USB", "OK", $icone) | Out-Null
    }
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
# BAIXAR XMLs DE NOTAS (BANCO)
# Le as NFC-e direto do netwebpdv e grava em lote numa pasta + zip.
#
# Estrutura real do banco (conferida em cliente com movimento):
#   NFCeTokenID    = controle de numeracao, 1 linha por nota (Serie + ID).
#                    Inutilizada=1 -> XML completo em XmlInutilizada (ProcInutNFe).
#                    OFFLine=1     -> XML em xmlEnvioOff (NFe crua, contingencia).
#   NFCeTokenIDLog = log de transmissao. Liga por IDParceiro + SerieTokenID + IDTokenID.
#                    xmlEnvio    = <NFe> sem declaracao.
#                    xmlResposta = nfeProc COMPLETO (NFe + protNFe) -> fonte preferida.
#
# A PK clusterizada da NFCeTokenID comeca em IDParceiro, por isso ele entra em
# todo WHERE. A NFCeTokenIDLog so tem indice por ID, entao a busca nela e sempre
# table scan: o lote vai em blocos com um unico scan por bloco, nunca por nota.
# -----------------------------------------------------------------------------

function ConvertFrom-FaixaNotas {
    # Converte texto livre em array de inteiros ordenado e sem duplicados.
    # Aceita "1-10", "1,5,9", "1-10,15,20-25" e tolera espacos. Inverte "10-1".
    # Tokens invalidos ("abc") sao ignorados; se nada sobrar, devolve erro amigavel.
    # Devolve hashtable: Ok / Notas / Total / Erro / Ignorados / Confirmar
    param(
        [string]$Texto,
        [int]$LimiteAviso = 2000,
        [int]$LimiteRigido = 200000,
        [switch]$Confirmar
    )

    $res = @{ Ok = $false; Notas = @(); Total = 0; Erro = ""; Ignorados = @(); Confirmar = $false }
    $amigavel = "Não entendi o intervalo. Informe algo como 1-15 ou 1,5,9."

    if ([string]::IsNullOrWhiteSpace($Texto)) { $res.Erro = $amigavel; return $res }

    # Virgula, ponto-e-virgula, quebra de linha, TAB e espaco valem como separador: a
    # lista costuma vir colada de uma planilha ou de outro programa, uma nota por linha
    # ou separada por tabulacao. O hifen e normalizado antes para "1 - 10" continuar
    # sendo o intervalo 1-10, e nao tres pedacos soltos.
    $limpo = "$Texto" -replace '\s*-\s*', '-'
    $limpo = $limpo -replace '[;\r\n\t]+', ','
    $limpo = $limpo -replace ' +', ','
    $partes = $limpo -split ','
    $conjunto = New-Object 'System.Collections.Generic.HashSet[int]'

    foreach ($p in $partes) {
        $item = "$p".Trim()
        if ($item -eq '') { continue }

        if ($item -match '^(\d+)\s*-\s*(\d+)$') {
            $a = 0; $b = 0
            if (-not [int]::TryParse($matches[1], [ref]$a) -or -not [int]::TryParse($matches[2], [ref]$b)) {
                $res.Ignorados += $item; continue
            }
            if ($a -gt $b) { $t = $a; $a = $b; $b = $t }   # "10-1" vira 1-10
            if ($b -lt 1) { $res.Ignorados += $item; continue }
            if ($a -lt 1) { $a = 1 }
            if (($b - $a + 1) -gt $LimiteRigido) {
                $res.Erro = "O intervalo $item é grande demais (limite de $LimiteRigido notas por busca)."
                return $res
            }
            for ($n = $a; $n -le $b; $n++) { [void]$conjunto.Add($n) }
        }
        elseif ($item -match '^(\d+)$') {
            $n = 0
            if (-not [int]::TryParse($matches[1], [ref]$n)) { $res.Ignorados += $item; continue }
            if ($n -lt 1) { $res.Ignorados += $item; continue }
            [void]$conjunto.Add($n)
        }
        else {
            $res.Ignorados += $item
        }
    }

    if ($conjunto.Count -eq 0) { $res.Erro = $amigavel; return $res }

    $res.Notas = @(@($conjunto) | Sort-Object)
    $res.Total = $res.Notas.Count
    $res.Ok = $true

    # Lote muito grande: avisa (e pergunta, quando chamada pela interface)
    if ($res.Total -gt $LimiteAviso) {
        $res.Confirmar = $true
        if ($Confirmar) {
            $msg = "Você selecionou $($res.Total) notas. Isso pode demorar bastante e gerar muitos arquivos.`r`n`r`nDeseja continuar mesmo assim?"
            $r = [System.Windows.Forms.MessageBox]::Show($msg, "Baixar XMLs NFC-e", "YesNo", "Warning")
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) {
                $res.Ok = $false
                $res.Erro = "Busca cancelada: $($res.Total) notas é um lote muito grande."
            }
        }
    }

    return $res
}

function ConvertTo-FaixaTexto {
    # Caminho inverso: 3,7,8,9,12 vira "3, 7-9, 12" (usado no relatorio de faltantes)
    param([int[]]$Numeros)
    if ($null -eq $Numeros -or $Numeros.Count -eq 0) { return "" }
    $ord = @($Numeros | Sort-Object -Unique)
    $partes = @()
    $ini = $ord[0]; $ant = $ord[0]
    for ($i = 1; $i -lt $ord.Count; $i++) {
        if ($ord[$i] -eq ($ant + 1)) { $ant = $ord[$i]; continue }
        $partes += $(if ($ini -eq $ant) { "$ini" } else { "$ini-$ant" })
        $ini = $ord[$i]; $ant = $ord[$i]
    }
    $partes += $(if ($ini -eq $ant) { "$ini" } else { "$ini-$ant" })
    return ($partes -join ", ")
}

function Get-XmlDbValor {
    # Le uma coluna do SqlDataReader devolvendo $null no lugar de DBNull.
    #
    # Nao usa GetOrdinal de proposito: em servidor com collation que diferencia
    # maiuscula de minuscula (ou acento), ele pode nao achar a coluna e derrubar a
    # leitura da linha inteira - a nota vinha sem numero e virava uma "nota 0" na
    # lista. Aqui os nomes das colunas do proprio resultado viram um mapa, montado
    # uma vez por leitor, e a busca ignora maiusculas. De quebra fica mais rapido.
    param($Reader, [string]$Coluna)
    try {
        # PowerShell 4 (Windows Server 2012 R2) as vezes entrega o leitor dentro de um
        # array de um elemento: sem isso, toda coluna vinha vazia e a nota perdia o numero
        if ($Reader -is [System.Array] -and $Reader.Length -gt 0) { $Reader = $Reader[0] }
        $i = $Reader.GetOrdinal($Coluna)
        if ($Reader.IsDBNull($i)) { return $null }
        return $Reader.GetValue($i)
    }
    catch {
        # GetOrdinal falhou (collation que diferencia maiuscula, por exemplo): procura a
        # coluna na mao. Guardar um mapa de colunas entre consultas ja causou estrago -
        # uma consulta pegava o mapa da outra e a nota vinha sem numero -, entao aqui e
        # sempre leitura direta, sem cache.
        try {
            for ($k = 0; $k -lt $Reader.FieldCount; $k++) {
                if ([string]::Equals($Reader.GetName($k), $Coluna, [System.StringComparison]::OrdinalIgnoreCase)) {
                    if ($Reader.IsDBNull($k)) { return $null }
                    return $Reader.GetValue($k)
                }
            }
        }
        catch {}
        return $null
    }
}

function Repair-XmlAcentos {
    # As colunas de XML sao varchar (nao nvarchar). Se o sistema gravou bytes UTF-8
    # numa coluna de collation Latin1, os acentos voltam como "Ã§", "Ã£", "Âº".
    # So mexe quando encontra esse padrao, e desfaz sozinho se o palpite estiver errado.
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return $Texto }
    if ($Texto -notmatch '[\u00C3\u00C2][\u0080-\u00BF]') { return $Texto }
    try {
        $latin = [System.Text.Encoding]::GetEncoding(28591)
        $bytes = $latin.GetBytes($Texto)
        $utf = New-Object System.Text.UTF8Encoding($false, $true)
        return $utf.GetString($bytes)
    }
    catch { return $Texto }
}

function Resolve-XmlNfe {
    # Decide o conteudo final do arquivo a partir do que veio do banco.
    # Prioridade: xmlResposta (que no NetPDV ja e o nfeProc pronto) > montagem
    # manual de NFe + protNFe > NFe crua. Nunca lanca excecao: em ultimo caso
    # devolve o texto original marcado, para o lote nao parar por causa de uma nota.
    # Devolve hashtable: Ok / Conteudo / Forma / Chave / Aviso / Motivo
    param([string]$XmlEnvio, [string]$XmlResposta, [switch]$MontarProc)

    $res = @{ Ok = $false; Conteudo = ""; Forma = "vazio"; Chave = ""; Aviso = ""; Motivo = "" }
    $decl = '<?xml version="1.0" encoding="UTF-8"?>'

    # Protocolo so vale quando a SEFAZ autorizou: 100, ou 150 (fora de prazo).
    # Rejeicao e denegacao tambem chegam dentro de um protNFe, e montar o nfeProc
    # com elas gerava um XML que aparecia AUTORIZADA e o contador recusava.
    # Devolve "" quando autorizado, senao o motivo.
    $motivoRecusa = {
        param($Prot)
        $cs = $Prot.SelectSingleNode(".//*[local-name()='cStat']")
        if ($null -eq $cs) { return "protocolo sem cStat" }
        $codigo = "$($cs.InnerText)".Trim()
        if ($codigo -eq '100' -or $codigo -eq '150') { return "" }
        $txt = "SEFAZ devolveu cStat $codigo"
        $mot = $Prot.SelectSingleNode(".//*[local-name()='xMotivo']")
        if ($null -ne $mot -and "$($mot.InnerText)".Trim() -ne "") { $txt = $txt + " - " + "$($mot.InnerText)".Trim() }
        return $txt
    }
    $motivoProt = ""

    $limpa = {
        param([string]$s)
        if ([string]::IsNullOrWhiteSpace($s)) { return "" }
        $s = Repair-XmlAcentos $s
        $s = $s.Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
        $p = $s.IndexOf('<')
        if ($p -gt 0) { $s = $s.Substring($p) }
        return $s
    }

    $envio = & $limpa $XmlEnvio
    $resposta = & $limpa $XmlResposta

    # 1) A resposta da SEFAZ ja costuma ser o nfeProc completo: e o arquivo ideal.
    # PreserveWhitespace mantem o XML byte a byte: espaco removido dentro da parte
    # assinada invalidaria a assinatura.
    $docR = $null
    if ($resposta -ne "") {
        $docR = New-Object System.Xml.XmlDocument
        $docR.PreserveWhitespace = $true
        try {
            $docR.LoadXml($resposta)
            if ($docR.DocumentElement.LocalName -eq 'nfeProc') {
                $protR = $docR.SelectSingleNode("//*[local-name()='protNFe']")
                if ($null -ne $protR) { $motivoProt = & $motivoRecusa $protR }
                if ($null -ne $protR -and $motivoProt -eq "") {
                    $res.Conteudo = $decl + $docR.DocumentElement.OuterXml
                    $res.Forma = "nfeProc"
                    $res.Chave = Get-XmlChave $docR
                    $res.Ok = $true
                    return $res
                }
            }
        }
        catch { $docR = $null }
    }

    if ($envio -eq "") {
        # Sem o envio, mas a resposta traz a nota dentro de um nfeProc sem
        # protocolo valido: segue com a nota de la para sair como SEM PROTOCOLO
        if ($null -ne $docR -and $docR.DocumentElement.LocalName -eq 'nfeProc') { $envio = $docR.DocumentElement.OuterXml }
        elseif ($resposta -ne "") {
            # So a resposta, sem a nota: nao e uma NFC-e autorizada
            $res.Conteudo = $resposta; $res.Forma = "resposta crua"; $res.Ok = $true
            $res.Aviso = "SEM PROTOCOLO"; $res.Motivo = "o banco só tem a resposta da SEFAZ, sem a nota"
            return $res
        }
        else {
            $res.Aviso = "sem XML no banco"
            return $res
        }
    }

    $docE = New-Object System.Xml.XmlDocument
    $docE.PreserveWhitespace = $true
    try { $docE.LoadXml($envio) }
    catch {
        # Nao parseia: grava assim mesmo, quem chama marca o arquivo como corrompido
        $res.Conteudo = $envio
        $res.Forma = "não parseável"
        $res.Aviso = "XML do banco não é um documento válido"
        $res.Ok = $true
        return $res
    }

    $raiz = $docE.DocumentElement.LocalName
    $res.Chave = Get-XmlChave $docE

    # 2) Ja veio pronto no proprio envio, com protocolo autorizado
    if ($raiz -eq 'nfeProc') {
        $protE = $docE.SelectSingleNode("//*[local-name()='protNFe']")
        if ($null -ne $protE) {
            $m = & $motivoRecusa $protE
            if ($m -eq "") {
                $res.Conteudo = $decl + $docE.DocumentElement.OuterXml
                $res.Forma = "nfeProc"
                $res.Ok = $true
                return $res
            }
            $motivoProt = $m
        }
    }

    # 3) Acha o no <NFe>: solto, dentro de um lote <enviNFe> ou de um nfeProc
    # cujo protocolo nao era de autorizacao
    $nfe = $null
    if ($raiz -eq 'NFe') { $nfe = $docE.DocumentElement }
    elseif ($raiz -eq 'enviNFe' -or $raiz -eq 'nfeProc') {
        foreach ($n in $docE.DocumentElement.ChildNodes) {
            if ($n.LocalName -eq 'NFe') { $nfe = $n; break }
        }
    }

    if ($null -eq $nfe) {
        # Inutilizacao (ProcInutNFe), evento, ou formato que eu nao conheco: grava inteiro
        $res.Conteudo = $decl + $docE.DocumentElement.OuterXml
        $res.Forma = $raiz
        $res.Ok = $true
        return $res
    }

    if (-not $MontarProc) {
        $res.Conteudo = $decl + $nfe.OuterXml
        $res.Forma = "NFe"
        $res.Ok = $true
        return $res
    }

    # 4) Monta o nfeProc na mao: NFe + protNFe tirado da resposta. Resposta de
    # lote pode trazer o protocolo de mais de uma nota: vale o da mesma chave.
    $prot = $null
    if ($resposta -ne "") {
        try {
            if ($null -eq $docR) {
                $docR = New-Object System.Xml.XmlDocument
                $docR.PreserveWhitespace = $true
                $docR.LoadXml($resposta)
            }
            foreach ($p in $docR.SelectNodes("//*[local-name()='protNFe']")) {
                $ch = $p.SelectSingleNode(".//*[local-name()='chNFe']")
                if ($res.Chave -eq "" -or $null -eq $ch -or "$($ch.InnerText)".Trim() -eq $res.Chave) { $prot = $p; break }
            }
        }
        catch { $prot = $null }
    }
    if ($null -ne $prot) {
        $m = & $motivoRecusa $prot
        if ($m -ne "") { $motivoProt = $m; $prot = $null }
    }

    $versao = "4.00"
    foreach ($n in $nfe.ChildNodes) {
        if ($n.LocalName -eq 'infNFe') {
            $v = $n.GetAttribute('versao')
            if (-not [string]::IsNullOrWhiteSpace($v)) { $versao = $v }
            break
        }
    }

    if ($null -ne $prot) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append($decl)
        [void]$sb.Append('<nfeProc xmlns="http://www.portalfiscal.inf.br/nfe" versao="' + $versao + '">')
        [void]$sb.Append($nfe.OuterXml)
        [void]$sb.Append($prot.OuterXml)
        [void]$sb.Append('</nfeProc>')
        $res.Conteudo = $sb.ToString()
        $res.Forma = "nfeProc montado"
        $res.Ok = $true
    }
    else {
        $res.Conteudo = $decl + $nfe.OuterXml
        $res.Forma = "NFe"
        $res.Aviso = "SEM PROTOCOLO"
        $res.Motivo = $motivoProt
        $res.Ok = $true
    }
    return $res
}

function ConvertTo-XmlArquivo {
    # Deixa um XML guardado no banco pronto para gravar em UTF-8: conserta os
    # acentos, tira o lixo antes do primeiro "<" e troca a declaracao original
    # (que pode dizer utf-16 ou iso-8859-1) pela de UTF-8. Se nao parsear,
    # devolve o texto limpo como esta.
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return "" }
    $s = (Repair-XmlAcentos $Texto).Trim([char]0xFEFF, [char]0x20, [char]0x09, [char]0x0D, [char]0x0A)
    $p = $s.IndexOf('<')
    if ($p -gt 0) { $s = $s.Substring($p) }
    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    try { $doc.LoadXml($s) } catch { return $s }
    return '<?xml version="1.0" encoding="UTF-8"?>' + $doc.DocumentElement.OuterXml
}

function Get-XmlChave {
    # Tira a chave de acesso (44 posicoes) de qualquer um dos formatos. Desde o
    # CNPJ alfanumerico (julho de 2026) as 12 primeiras posicoes do CNPJ dentro da
    # chave podem ter letras: 6 digitos + 12 letras/digitos + 26 digitos.
    param($Doc)
    $padrao = '(\d{6}[0-9A-Z]{12}\d{26})'
    try {
        $no = $Doc.DocumentElement.SelectSingleNode("//*[local-name()='infNFe']")
        if ($null -ne $no) {
            $id = "$($no.GetAttribute('Id'))".ToUpper()
            if ($id -match $padrao) { return $matches[1] }
        }
        $no = $Doc.DocumentElement.SelectSingleNode("//*[local-name()='chNFe']")
        if ($null -ne $no -and "$($no.InnerText)".ToUpper() -match $padrao) { return $matches[1] }
    }
    catch {}
    return ""
}

function Get-XmlCertificadoAssinatura {
    # Certificado que assinou a nota, lido do <X509Certificate> da propria assinatura:
    # e o nome que aparece no Windows ("EMPRESA LTDA:12345678000199"). Serve para dar
    # nome aos certificados quando o banco emite com mais de um.
    # Devolve hashtable Nome / Cnpj / Vence, ou $null se o XML nao tiver assinatura.
    param([string]$Xml)
    if ([string]::IsNullOrEmpty($Xml)) { return $null }
    $achou = [regex]::Match($Xml, '<(?:\w+:)?X509Certificate>\s*([A-Za-z0-9+/=\s]+?)\s*</(?:\w+:)?X509Certificate>')
    if (-not $achou.Success) { return $null }
    try {
        $bytes = [Convert]::FromBase64String(($achou.Groups[1].Value -replace '\s', ''))
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 (, $bytes)
        $cn = "$($cert.GetNameInfo([System.Security.Cryptography.X509Certificates.X509NameType]::SimpleName, $false))".Trim()
        $nome = $cn; $cnpj = ""
        # e-CNPJ da ICP-Brasil: "RAZAO SOCIAL:CNPJ" (o CNPJ alfanumerico tambem cabe aqui)
        if ($cn -match '^(.*\S)\s*:\s*([0-9A-Za-z]{14})$') { $nome = $matches[1]; $cnpj = $matches[2].ToUpper() }
        return @{ Nome = $nome; Cnpj = $cnpj; Vence = $cert.NotAfter }
    }
    catch { return $null }
}

function Get-XmlNomeArquivo {
    # Nome dos arquivos de uma nota, sem extensao. O fim do nome diz a situacao,
    # para o arquivo continuar legivel quando sai da pasta do lote e se mistura.
    # Devolve hashtable: Nota (a propria nota) / Evento (XML do cancelamento)
    param($Item, [switch]$Corrompido)
    $base = "serie$($Item.Serie)_nota$($Item.Nota)"
    if ("$($Item.Chave)" -ne "") { $base = $base + "_" + $Item.Chave }
    $base = ($base -replace '[\\/:*?"<>|]', '_')

    $nota = $base
    if ([bool]$Item.Inutilizada) { $nota = $nota + "_INUT" }
    elseif ([bool]$Item.Cancelada) { $nota = $nota + "_CANC" }
    elseif ("$($Item.Status)" -eq "SEM PROTOCOLO") { $nota = $nota + "_SEM_PROTOCOLO" }
    if ($Corrompido) { $nota = $nota + "_CORROMPIDO" }

    return @{ Nota = $nota; Evento = $base + "_CANC_EVENTO" }
}

function Get-XmlNomeLote {
    # Nome da pasta e do zip do lote, feito para mandar direto ao cliente: diz o
    # que tem dentro e nada mais, sem data e hora da geracao. Baixar o mesmo
    # filtro de novo vira "(2)", "(3)" em New-XmlLotePasta.
    #   Serie ...  XML NFC-e - Série 1 - Notas 1 a 15 e 2000 | ... - Nota 5
    #   Periodo .  XML NFC-e - Agosto de 2026 | ... - Julho a Agosto de 2026
    #              XML NFC-e - 01-08-2026 a 12-09-2026 | ... - 12-09-2026
    #   Chave ...  XML NFC-e - 3 chaves de acesso
    #   Pedido ..  XML NFC-e - Pedido 73432 | ... - Pedidos 73400 a 73432 | ... - Pedido 577 - 12-09-2026
    #   -Series: series das notas gravadas, usadas quando nao ha serie escolhida
    #            ("Séries 7 e 8"; acima de 3 vira "4 séries")
    #   -Notas: no modo Pedido, os numeros dos pedidos
    #   -Titulo: "Espelho NFC-e" no lote de PDFs
    #   -Empresa: banco com mais de um certificado; cada empresa tem o seu lote
    #             ("XML NFC-e - ALTA ALIMENTOS LTDA - Série 1 - Notas 1 a 15")
    param(
        [ValidateSet('Serie', 'Periodo', 'Chave', 'Pedido')][string]$Modo,
        [string]$Serie = "",
        [int[]]$Series = @(),
        [int[]]$Notas = @(),
        [datetime]$De,
        [datetime]$Ate,
        [int]$Quantidade = 0,
        [string]$Titulo = "XML NFC-e",
        [string]$Empresa = ""
    )
    $partes = @($Titulo)
    if ("$Empresa".Trim() -ne "") { $partes += "$Empresa".Trim() }
    if ("$Serie".Trim() -ne "") { $partes += "Série " + "$Serie".Trim() }
    else {
        $listaSeries = @($Series | Sort-Object -Unique)
        if ($listaSeries.Count -eq 1) { $partes += "Série $($listaSeries[0])" }
        elseif ($listaSeries.Count -ge 2 -and $listaSeries.Count -le 3) {
            $partes += "Séries " + ($listaSeries[0..($listaSeries.Count - 2)] -join ", ") + " e " + $listaSeries[-1]
        }
        elseif ($listaSeries.Count -gt 3) { $partes += "$($listaSeries.Count) séries" }
    }

    if ($Modo -eq 'Serie' -or $Modo -eq 'Pedido') {
        $palavra = "Nota"
        if ($Modo -eq 'Pedido') { $palavra = "Pedido" }
        $ord = @($Notas | Sort-Object -Unique)
        if ($ord.Count -eq 1) { $partes += "$palavra $($ord[0])" }
        elseif ($ord.Count -gt 1) {
            # "1-10, 15, 20-25" vira "1 a 10, 15 e 20 a 25"
            $trechos = @((ConvertTo-FaixaTexto $ord) -split ',\s*' | ForEach-Object { $_ -replace '-', ' a ' })
            $faixa = $trechos[-1]
            if ($trechos.Count -gt 1) { $faixa = ($trechos[0..($trechos.Count - 2)] -join ", ") + " e " + $faixa }
            # Lista picada demais nao cabe no nome: resume em quantidade + menor e maior
            if ($faixa.Length -gt 40) { $partes += "$($ord.Count) $($palavra.ToLower())s de $($ord[0]) a $($ord[-1])" }
            else { $partes += "$($palavra)s $faixa" }
        }
        # Pedido que zera por dia: o dia buscado entra no nome para separar os lotes
        if ($Modo -eq 'Pedido' -and $PSBoundParameters.ContainsKey('De')) { $partes += $De.ToString("dd-MM-yyyy") }
    }
    elseif ($Modo -eq 'Periodo') {
        # Mes por extenso fixo em portugues: nao depende do idioma do Windows
        $meses = @("", "Janeiro", "Fevereiro", "Março", "Abril", "Maio", "Junho", "Julho",
            "Agosto", "Setembro", "Outubro", "Novembro", "Dezembro")
        $d1 = $De.Date; $d2 = $Ate.Date
        $mesesCheios = ($d1.Day -eq 1 -and $d2.AddDays(1).Day -eq 1 -and $d2 -gt $d1)
        if ($d1 -eq $d2) { $partes += $d1.ToString("dd-MM-yyyy") }
        elseif ($mesesCheios -and $d1.Year -eq $d2.Year -and $d1.Month -eq $d2.Month) {
            $partes += "$($meses[$d1.Month]) de $($d1.Year)"
        }
        elseif ($mesesCheios -and $d1.Year -eq $d2.Year) {
            $partes += "$($meses[$d1.Month]) a $($meses[$d2.Month]) de $($d2.Year)"
        }
        elseif ($mesesCheios) {
            $partes += "$($meses[$d1.Month]) de $($d1.Year) a $($meses[$d2.Month]) de $($d2.Year)"
        }
        else { $partes += $d1.ToString("dd-MM-yyyy") + " a " + $d2.ToString("dd-MM-yyyy") }
    }
    else {
        if ($Quantidade -eq 1) { $partes += "1 chave de acesso" }
        else { $partes += "$Quantidade chaves de acesso" }
    }

    return ($partes -join " - ")
}

function New-XmlLotePasta {
    # Cria a pasta do lote em "Arquivos Xmenu\XMLs" sem nunca sobrescrever outra.
    # Confere o zip tambem: quem manda o zip e apaga a pasta nao pode perder o
    # zip antigo quando baixar o mesmo filtro de novo. -Subpasta troca a pasta
    # de cima (os PDFs vao para "Espelhos NFC-e").
    param([string]$Nome, [string]$Subpasta = "XMLs")
    $raiz = Join-Path $Script:DownloadFolder $Subpasta
    if (-not (Test-Path $raiz)) { New-Item -Path $raiz -ItemType Directory -Force | Out-Null }
    $limpo = (($Nome -replace '[\\/:*?"<>|]', '-') -replace '\s+', ' ').Trim()
    if ($limpo.Length -gt 90) { $limpo = $limpo.Substring(0, 90) }
    # O Windows descarta ponto e espaco no fim do nome da pasta
    $limpo = $limpo.TrimEnd('.', ' ')
    if ($limpo -eq '') { $limpo = "XML NFC-e" }
    $destino = Join-Path $raiz $limpo
    # Copia do mesmo lote segue o padrao do Windows: "Nome (2)", "Nome (3)"
    $n = 1
    while ((Test-Path -LiteralPath $destino) -or (Test-Path -LiteralPath ($destino + ".zip"))) {
        $n++; $destino = Join-Path $raiz ($limpo + " ($n)")
    }
    New-Item -Path $destino -ItemType Directory -Force | Out-Null
    return $destino
}

# -----------------------------------------------------------------------------
# DANFE NFC-e EM PDF
# Espelho da nota no formato do cupom que o PDV imprime (bobina de 80 mm, letra
# de largura fixa), feito a partir do XML autorizado que ja vem do banco. O PDF
# e escrito pelo proprio script com as fontes Courier que todo leitor de PDF ja
# tem: nao depende de navegador, de impressora virtual nem de internet.
# -----------------------------------------------------------------------------

function Initialize-QrCodigo {
    # Gerador de QR Code (modo byte, correcao nivel M) em C#, compilado so na
    # primeira vez que precisa: em PowerShell puro cada QR levava segundos.
    if ('XMenuTools.QrCodigo' -as [type]) { return }
    $codigoQr = @'
using System;
using System.Collections.Generic;
using System.Text;

namespace XMenuTools
{
    public static class QrCodigo
    {
        static readonly int[] EccPorBloco = { -1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28 };
        static readonly int[] NumBlocos = { -1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49 };

        // Matriz [linha, coluna]; true = modulo escuro
        public static bool[,] Gerar(string texto)
        {
            byte[] dados = Encoding.UTF8.GetBytes(texto ?? "");
            int versao = 0;
            int capBits = 0;
            for (int v = 1; v <= 40; v++)
            {
                capBits = NumDataCodewords(v) * 8;
                int usados = 4 + (v <= 9 ? 8 : 16) + dados.Length * 8;
                if (usados <= capBits) { versao = v; break; }
            }
            if (versao == 0) throw new ArgumentException("Texto grande demais para um QR Code.");

            List<int> bits = new List<int>();
            AddBits(bits, 4, 4);
            AddBits(bits, dados.Length, versao <= 9 ? 8 : 16);
            foreach (byte b in dados) AddBits(bits, b, 8);
            AddBits(bits, 0, Math.Min(4, capBits - bits.Count));
            AddBits(bits, 0, (8 - bits.Count % 8) % 8);
            for (int pad = 0xEC; bits.Count < capBits; pad ^= 0xEC ^ 0x11) AddBits(bits, pad, 8);

            byte[] cw = new byte[bits.Count / 8];
            for (int i = 0; i < bits.Count; i++) cw[i >> 3] |= (byte)(bits[i] << (7 - (i & 7)));

            Matriz m = new Matriz(versao);
            m.DesenharFuncoes();
            m.DesenharCodewords(AdicionarEcc(cw, versao));
            // Mascara: primeiro a que menos forma "falsos quadrados de posicao" nos
            // dados (com eles o leitor do celular se perde e nao le o QR), depois a
            // pontuacao da norma
            int melhor = 0;
            int menor = int.MaxValue;
            for (int k = 0; k < 8; k++)
            {
                m.AplicarMascara(k);
                m.DesenharFormato(k);
                int p = m.FalsosLocalizadores() * 100000 + m.Penalidade();
                if (p < menor) { menor = p; melhor = k; }
                m.AplicarMascara(k);
            }
            m.AplicarMascara(melhor);
            m.DesenharFormato(melhor);
            return m.Modulos;
        }

        static void AddBits(List<int> lista, int valor, int qtd)
        {
            for (int i = qtd - 1; i >= 0; i--) lista.Add((valor >> i) & 1);
        }

        static bool Bit(int x, int i) { return ((x >> i) & 1) != 0; }

        static int NumRawModules(int v)
        {
            int r = (16 * v + 128) * v + 64;
            if (v >= 2)
            {
                int na = v / 7 + 2;
                r -= (25 * na - 10) * na - 55;
                if (v >= 7) r -= 36;
            }
            return r;
        }

        static int NumDataCodewords(int v)
        {
            return NumRawModules(v) / 8 - EccPorBloco[v] * NumBlocos[v];
        }

        static byte[] AdicionarEcc(byte[] dados, int v)
        {
            int numBlocos = NumBlocos[v];
            int eccLen = EccPorBloco[v];
            int raw = NumRawModules(v) / 8;
            int curtos = numBlocos - raw % numBlocos;
            int curtoLen = raw / numBlocos;
            byte[] divisor = Divisor(eccLen);
            byte[][] blocos = new byte[numBlocos][];
            int k = 0;
            for (int i = 0; i < numBlocos; i++)
            {
                int datLen = curtoLen - eccLen + (i < curtos ? 0 : 1);
                byte[] dat = new byte[datLen];
                Array.Copy(dados, k, dat, 0, datLen);
                k += datLen;
                byte[] bloco = new byte[curtoLen + 1];
                Array.Copy(dat, bloco, datLen);
                byte[] ecc = Resto(dat, divisor);
                Array.Copy(ecc, 0, bloco, bloco.Length - eccLen, eccLen);
                blocos[i] = bloco;
            }
            byte[] res = new byte[raw];
            k = 0;
            for (int i = 0; i < blocos[0].Length; i++)
                for (int j = 0; j < numBlocos; j++)
                    if (i != curtoLen - eccLen || j >= curtos) { res[k] = blocos[j][i]; k++; }
            return res;
        }

        static int Mul(int x, int y)
        {
            int z = 0;
            for (int i = 7; i >= 0; i--)
            {
                z = (z << 1) ^ ((z >> 7) * 0x11D);
                z ^= ((y >> i) & 1) * x;
            }
            return z;
        }

        static byte[] Divisor(int grau)
        {
            byte[] r = new byte[grau];
            r[grau - 1] = 1;
            int raiz = 1;
            for (int i = 0; i < grau; i++)
            {
                for (int j = 0; j < grau; j++)
                {
                    r[j] = (byte)Mul(r[j], raiz);
                    if (j + 1 < grau) r[j] ^= r[j + 1];
                }
                raiz = Mul(raiz, 2);
            }
            return r;
        }

        static byte[] Resto(byte[] dados, byte[] divisor)
        {
            byte[] r = new byte[divisor.Length];
            foreach (byte b in dados)
            {
                int fator = b ^ r[0];
                Array.Copy(r, 1, r, 0, r.Length - 1);
                r[r.Length - 1] = 0;
                for (int i = 0; i < r.Length; i++) r[i] ^= (byte)Mul(divisor[i], fator);
            }
            return r;
        }

        class Matriz
        {
            public readonly int Versao;
            public readonly int Tam;
            public readonly bool[,] Modulos;
            readonly bool[,] Funcao;

            public Matriz(int versao)
            {
                Versao = versao;
                Tam = versao * 4 + 17;
                Modulos = new bool[Tam, Tam];
                Funcao = new bool[Tam, Tam];
            }

            void Set(int x, int y, bool escuro) { Modulos[y, x] = escuro; Funcao[y, x] = true; }

            public void DesenharFuncoes()
            {
                for (int i = 0; i < Tam; i++) { Set(6, i, i % 2 == 0); Set(i, 6, i % 2 == 0); }
                Localizador(3, 3);
                Localizador(Tam - 4, 3);
                Localizador(3, Tam - 4);
                int[] pos = PosicoesAlinhamento();
                int n = pos.Length;
                for (int i = 0; i < n; i++)
                    for (int j = 0; j < n; j++)
                        if (!(i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0))
                            Alinhamento(pos[i], pos[j]);
                DesenharFormato(0);
                DesenharVersao();
            }

            int[] PosicoesAlinhamento()
            {
                if (Versao == 1) return new int[0];
                int n = Versao / 7 + 2;
                int passo = (Versao == 32) ? 26 : (Versao * 4 + n * 2 + 1) / (n * 2 - 2) * 2;
                int[] r = new int[n];
                r[0] = 6;
                for (int i = n - 1, p = Tam - 7; i >= 1; i--, p -= passo) r[i] = p;
                return r;
            }

            void Localizador(int x, int y)
            {
                for (int dy = -4; dy <= 4; dy++)
                    for (int dx = -4; dx <= 4; dx++)
                    {
                        int d = Math.Max(Math.Abs(dx), Math.Abs(dy));
                        int xx = x + dx, yy = y + dy;
                        if (xx >= 0 && xx < Tam && yy >= 0 && yy < Tam) Set(xx, yy, d != 2 && d != 4);
                    }
            }

            void Alinhamento(int x, int y)
            {
                for (int dy = -2; dy <= 2; dy++)
                    for (int dx = -2; dx <= 2; dx++)
                        Set(x + dx, y + dy, Math.Max(Math.Abs(dx), Math.Abs(dy)) != 1);
            }

            public void DesenharFormato(int mascara)
            {
                // Nivel M = bits 00
                int dados = mascara;
                int resto = dados;
                for (int i = 0; i < 10; i++) resto = (resto << 1) ^ ((resto >> 9) * 0x537);
                int bits = (dados << 10 | resto) ^ 0x5412;
                for (int i = 0; i <= 5; i++) Set(8, i, Bit(bits, i));
                Set(8, 7, Bit(bits, 6));
                Set(8, 8, Bit(bits, 7));
                Set(7, 8, Bit(bits, 8));
                for (int i = 9; i < 15; i++) Set(14 - i, 8, Bit(bits, i));
                for (int i = 0; i < 8; i++) Set(Tam - 1 - i, 8, Bit(bits, i));
                for (int i = 8; i < 15; i++) Set(8, Tam - 15 + i, Bit(bits, i));
                Set(8, Tam - 8, true);
            }

            void DesenharVersao()
            {
                if (Versao < 7) return;
                int resto = Versao;
                for (int i = 0; i < 12; i++) resto = (resto << 1) ^ ((resto >> 11) * 0x1F25);
                int bits = Versao << 12 | resto;
                for (int i = 0; i < 18; i++)
                {
                    bool b = Bit(bits, i);
                    int a = Tam - 11 + i % 3;
                    int c = i / 3;
                    Set(a, c, b);
                    Set(c, a, b);
                }
            }

            public void DesenharCodewords(byte[] dados)
            {
                int i = 0;
                for (int direita = Tam - 1; direita >= 1; direita -= 2)
                {
                    if (direita == 6) direita = 5;
                    for (int vert = 0; vert < Tam; vert++)
                        for (int j = 0; j < 2; j++)
                        {
                            int x = direita - j;
                            bool subindo = ((direita + 1) & 2) == 0;
                            int y = subindo ? Tam - 1 - vert : vert;
                            if (!Funcao[y, x] && i < dados.Length * 8)
                            {
                                Modulos[y, x] = Bit(dados[i >> 3], 7 - (i & 7));
                                i++;
                            }
                        }
                }
            }

            public void AplicarMascara(int k)
            {
                for (int y = 0; y < Tam; y++)
                    for (int x = 0; x < Tam; x++)
                    {
                        bool inv;
                        switch (k)
                        {
                            case 0: inv = (x + y) % 2 == 0; break;
                            case 1: inv = y % 2 == 0; break;
                            case 2: inv = x % 3 == 0; break;
                            case 3: inv = (x + y) % 3 == 0; break;
                            case 4: inv = (x / 3 + y / 2) % 2 == 0; break;
                            case 5: inv = x * y % 2 + x * y % 3 == 0; break;
                            case 6: inv = (x * y % 2 + x * y % 3) % 2 == 0; break;
                            default: inv = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
                        }
                        if (inv && !Funcao[y, x]) Modulos[y, x] = !Modulos[y, x];
                    }
            }

            // Pontos escuros onde os dados desenham o 1:1:3:1:1 do quadrado de
            // posicao na horizontal e na vertical ao mesmo tempo (centro de 2 a 4,
            // que e a folga que os leitores aceitam)
            public int FalsosLocalizadores()
            {
                int total = 0;
                for (int y = 0; y < Tam; y++)
                    for (int x = 0; x < Tam; x++)
                    {
                        if (!Modulos[y, x]) continue;
                        if ((x < 8 && y < 8) || (x >= Tam - 8 && y < 8) || (x < 8 && y >= Tam - 8)) continue;
                        if (PadraoEm(x, y, 1, 0) && PadraoEm(x, y, 0, 1)) total++;
                    }
                return total;
            }

            int Corrida(ref int x, ref int y, int dx, int dy, bool cor, int limite)
            {
                int n = 0;
                while (n <= limite)
                {
                    bool dentro = x >= 0 && x < Tam && y >= 0 && y < Tam;
                    bool atual = dentro && Modulos[y, x];
                    if (atual != cor) break;
                    if (!dentro) { n = limite + 1; break; }
                    n++; x += dx; y += dy;
                }
                return n;
            }

            bool PadraoEm(int x0, int y0, int dx, int dy)
            {
                int x = x0, y = y0;
                int centroTras = Corrida(ref x, ref y, -dx, -dy, true, 6);
                int claroTras = Corrida(ref x, ref y, -dx, -dy, false, 3);
                int escuroTras = Corrida(ref x, ref y, -dx, -dy, true, 3);
                x = x0 + dx; y = y0 + dy;
                int centroFrente = Corrida(ref x, ref y, dx, dy, true, 6);
                int claroFrente = Corrida(ref x, ref y, dx, dy, false, 3);
                int escuroFrente = Corrida(ref x, ref y, dx, dy, true, 3);
                int centro = centroTras + centroFrente;
                return centro >= 2 && centro <= 4 && claroTras == 1 && escuroTras == 1 && claroFrente == 1 && escuroFrente == 1;
            }

            public int Penalidade()
            {
                int r = 0;
                for (int passada = 0; passada < 2; passada++)
                {
                    for (int a = 0; a < Tam; a++)
                    {
                        bool cor = false;
                        int run = 0;
                        int[] hist = new int[7];
                        for (int b = 0; b < Tam; b++)
                        {
                            bool atual = passada == 0 ? Modulos[a, b] : Modulos[b, a];
                            if (atual == cor)
                            {
                                run++;
                                if (run == 5) r += 3; else if (run > 5) r++;
                            }
                            else
                            {
                                AddHist(run, hist);
                                if (!cor) r += ContaPadroes(hist) * 40;
                                cor = atual;
                                run = 1;
                            }
                        }
                        r += FechaEConta(cor, run, hist) * 40;
                    }
                }
                for (int y = 0; y < Tam - 1; y++)
                    for (int x = 0; x < Tam - 1; x++)
                    {
                        bool c = Modulos[y, x];
                        if (c == Modulos[y, x + 1] && c == Modulos[y + 1, x] && c == Modulos[y + 1, x + 1]) r += 3;
                    }
                int escuros = 0;
                foreach (bool m in Modulos) if (m) escuros++;
                int total = Tam * Tam;
                int k = (Math.Abs(escuros * 20 - total * 10) + total - 1) / total - 1;
                return r + k * 10;
            }

            int ContaPadroes(int[] h)
            {
                int n = h[1];
                bool nucleo = n > 0 && h[2] == n && h[3] == n * 3 && h[4] == n && h[5] == n;
                return (nucleo && h[0] >= n * 4 && h[6] >= n ? 1 : 0) + (nucleo && h[6] >= n * 4 && h[0] >= n ? 1 : 0);
            }

            int FechaEConta(bool cor, int run, int[] h)
            {
                if (cor) { AddHist(run, h); run = 0; }
                run += Tam;
                AddHist(run, h);
                return ContaPadroes(h);
            }

            void AddHist(int run, int[] h)
            {
                if (h[0] == 0) run += Tam;
                Array.Copy(h, 0, h, 1, h.Length - 1);
                h[0] = run;
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $codigoQr -Language CSharp
}

function Get-XmlNoTexto {
    # Texto do primeiro no no caminho de nomes locais ("pag/vTroco"), sem depender
    # do namespace do XML. Devolve "" quando o no nao existe.
    param($Pai, [string]$Caminho)
    if ($null -eq $Pai) { return "" }
    $xp = ".//" + ((($Caminho -split '/') | ForEach-Object { "*[local-name()='$_']" }) -join '/')
    $no = $Pai.SelectSingleNode($xp)
    if ($null -eq $no) { return "" }
    return "$($no.InnerText)".Trim()
}

function Format-DanfeValor {
    # "114.8" do XML vira "114,80". -Unitario mantem ate 4 casas quando o preco
    # tem (combustivel, granel) para nao arredondar; -Quantidade usa 3 casas.
    param([string]$Valor, [switch]$Unitario, [switch]$Quantidade)
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $br = [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")
    $d = [decimal]0
    if (-not [decimal]::TryParse("$Valor".Trim(), [System.Globalization.NumberStyles]::Number, $inv, [ref]$d)) { return "$Valor".Trim() }
    if ($Quantidade) { return $d.ToString("#,##0.000", $br) }
    if ($Unitario) { return $d.ToString("#,##0.00##", $br) }
    return $d.ToString("#,##0.00", $br)
}

function Format-DanfeDocumento {
    # CNPJ (tambem o alfanumerico) e CPF com pontuacao
    param([string]$Numero)
    $s = ("$Numero" -replace '[^0-9A-Za-z]', '').ToUpper()
    if ($s.Length -eq 14) { return $s.Substring(0, 2) + "." + $s.Substring(2, 3) + "." + $s.Substring(5, 3) + "/" + $s.Substring(8, 4) + "-" + $s.Substring(12, 2) }
    if ($s.Length -eq 11) { return $s.Substring(0, 3) + "." + $s.Substring(3, 3) + "." + $s.Substring(6, 3) + "-" + $s.Substring(9, 2) }
    return "$Numero".Trim()
}

function Format-DanfeData {
    # "2026-09-13T00:32:11-03:00" vira "13/09/2026 00:32:11", no horario escrito
    # na nota (sem converter fuso)
    param([string]$Iso)
    if ("$Iso" -match '^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2}):(\d{2}))?') {
        $data = $matches[3] + "/" + $matches[2] + "/" + $matches[1]
        if ($matches[4]) { $data = $data + " " + $matches[4] + ":" + $matches[5] + ":" + $matches[6] }
        return $data
    }
    return "$Iso".Trim()
}

function Get-DanfeFormaPagamento {
    # Nome curto do meio de pagamento (tPag), para caber na linha dos totais
    param([string]$Codigo, [string]$Descricao = "")
    $nomes = @{
        '01' = 'Dinheiro'; '02' = 'Cheque'; '03' = 'Cartão de Crédito'; '04' = 'Cartão de Débito'
        '05' = 'Crédito Loja'; '10' = 'Vale Alimentação'; '11' = 'Vale Refeição'; '12' = 'Vale Presente'
        '13' = 'Vale Combustível'; '15' = 'Boleto Bancário'; '16' = 'Depósito Bancário'; '17' = 'PIX'
        '18' = 'Transferência'; '19' = 'Cashback'; '20' = 'PIX Estático'; '90' = 'Sem Pagamento'
    }
    $cod = "$Codigo".Trim()
    if ("$Descricao".Trim() -ne "" -and ($cod -eq '99' -or -not $nomes.ContainsKey($cod))) { return "$Descricao".Trim() }
    if ($nomes.ContainsKey($cod)) { return $nomes[$cod] }
    return "Outros"
}

function Split-DanfeTexto {
    # Quebra o texto em linhas de no maximo $Largura letras, pelas palavras.
    # Palavra maior que a linha (URL, codigo) e cortada no meio.
    param([string]$Texto, [int]$Largura)
    $linhas = New-Object System.Collections.Generic.List[string]
    foreach ($paragrafo in ("$Texto" -split "`r?`n")) {
        $atual = ""
        foreach ($palavra in ($paragrafo -split ' ')) {
            if ($palavra -eq "") { continue }
            while ($palavra.Length -gt $Largura) {
                if ($atual -ne "") { $linhas.Add($atual); $atual = "" }
                $linhas.Add($palavra.Substring(0, $Largura))
                $palavra = $palavra.Substring($Largura)
            }
            if ($palavra -eq "") { continue }
            if ($atual -eq "") { $atual = $palavra }
            elseif ($atual.Length + 1 + $palavra.Length -le $Largura) { $atual = $atual + " " + $palavra }
            else { $linhas.Add($atual); $atual = $palavra }
        }
        if ($atual -ne "") { $linhas.Add($atual) }
    }
    return , $linhas.ToArray()
}

function Get-DanfeNfceDados {
    # Tira do XML da NFC-e (nfeProc, ou NFe solta) tudo que o DANFE mostra
    param([string]$Xml)
    $doc = New-Object System.Xml.XmlDocument
    try { $doc.LoadXml($Xml) }
    catch { throw "o XML da nota não abriu como documento válido" }
    $raiz = $doc.DocumentElement
    $inf = $doc.SelectSingleNode("//*[local-name()='infNFe']")
    if ($null -eq $inf) { throw "o XML não tem os dados da nota (infNFe)" }
    $ide = $inf.SelectSingleNode("*[local-name()='ide']")
    $emit = $inf.SelectSingleNode("*[local-name()='emit']")
    $dest = $inf.SelectSingleNode("*[local-name()='dest']")
    $tot = $inf.SelectSingleNode("*[local-name()='total']/*[local-name()='ICMSTot']")

    $modelo = Get-XmlNoTexto $ide "mod"
    if ($modelo -ne "" -and $modelo -ne "65") { throw "a nota é modelo $modelo, e o espelho aqui é só de NFC-e (modelo 65)" }

    $d = @{}
    $d.Emitente = Get-XmlNoTexto $emit "xNome"
    $cnpj = Get-XmlNoTexto $emit "CNPJ"
    if ($cnpj -ne "") { $d.EmitenteDoc = "CNPJ " + (Format-DanfeDocumento $cnpj) }
    else { $d.EmitenteDoc = "CPF " + (Format-DanfeDocumento (Get-XmlNoTexto $emit "CPF")) }

    $end = $null
    if ($null -ne $emit) { $end = $emit.SelectSingleNode("*[local-name()='enderEmit']") }
    $rua = @((Get-XmlNoTexto $end "xLgr"), (Get-XmlNoTexto $end "nro"), (Get-XmlNoTexto $end "xCpl")) | Where-Object { $_ -ne "" }
    $cidade = @((Get-XmlNoTexto $end "xMun"), (Get-XmlNoTexto $end "UF")) | Where-Object { $_ -ne "" }
    $d.Endereco = (@(($rua -join ", "), (Get-XmlNoTexto $end "xBairro"), ($cidade -join "-")) | Where-Object { $_ -ne "" }) -join ", "

    $d.Numero = (Get-XmlNoTexto $ide "nNF").PadLeft(9, '0')
    $d.Serie = (Get-XmlNoTexto $ide "serie").PadLeft(3, '0')
    $emissao = Get-XmlNoTexto $ide "dhEmi"
    if ($emissao -eq "") { $emissao = Get-XmlNoTexto $ide "dEmi" }
    $d.Emissao = Format-DanfeData $emissao
    $d.Ambiente = Get-XmlNoTexto $ide "tpAmb"
    $d.TipoEmissao = Get-XmlNoTexto $ide "tpEmis"
    $d.Chave = ("$($inf.GetAttribute('Id'))" -replace '^NFe', '')

    $itens = @()
    foreach ($det in $inf.SelectNodes("*[local-name()='det']")) {
        $prod = $det.SelectSingleNode("*[local-name()='prod']")
        $itens += @{
            Codigo = Get-XmlNoTexto $prod "cProd"; Descricao = Get-XmlNoTexto $prod "xProd"
            Qtd = Get-XmlNoTexto $prod "qCom"; Un = Get-XmlNoTexto $prod "uCom"
            Unit = Get-XmlNoTexto $prod "vUnCom"; Total = Get-XmlNoTexto $prod "vProd"
        }
    }
    $d.Itens = $itens

    $d.ValorTotal = Get-XmlNoTexto $tot "vProd"
    $d.Desconto = Get-XmlNoTexto $tot "vDesc"
    $d.ValorPagar = Get-XmlNoTexto $tot "vNF"
    $d.Tributos = Get-XmlNoTexto $tot "vTotTrib"
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $acrescimo = [decimal]0
    foreach ($campo in @("vOutro", "vFrete", "vSeg")) {
        $v = [decimal]0
        if ([decimal]::TryParse((Get-XmlNoTexto $tot $campo), [System.Globalization.NumberStyles]::Number, $inv, [ref]$v)) { $acrescimo += $v }
    }
    $d.Acrescimo = $acrescimo.ToString($inv)

    # Leiaute 4.00 tem pag/detPag; o 3.10 repetia o proprio pag
    $pags = @($inf.SelectNodes(".//*[local-name()='detPag']"))
    if ($pags.Count -eq 0) { $pags = @($inf.SelectNodes("*[local-name()='pag']")) }
    $pagamentos = @()
    foreach ($p in $pags) {
        $pagamentos += @{ Forma = (Get-DanfeFormaPagamento (Get-XmlNoTexto $p "tPag") (Get-XmlNoTexto $p "xPag")); Valor = Get-XmlNoTexto $p "vPag" }
    }
    $d.Pagamentos = $pagamentos
    $d.Troco = Get-XmlNoTexto $inf "pag/vTroco"

    $d.ConsumidorDoc = ""
    $d.ConsumidorNome = ""
    $d.ConsumidorEndereco = ""
    if ($null -ne $dest) {
        $docDest = Get-XmlNoTexto $dest "CNPJ"
        if ($docDest -ne "") { $d.ConsumidorDoc = "CNPJ " + (Format-DanfeDocumento $docDest) }
        elseif ((Get-XmlNoTexto $dest "CPF") -ne "") { $d.ConsumidorDoc = "CPF " + (Format-DanfeDocumento (Get-XmlNoTexto $dest "CPF")) }
        elseif ((Get-XmlNoTexto $dest "idEstrangeiro") -ne "") { $d.ConsumidorDoc = "ID " + (Get-XmlNoTexto $dest "idEstrangeiro") }
        $d.ConsumidorNome = Get-XmlNoTexto $dest "xNome"
        $endD = $dest.SelectSingleNode("*[local-name()='enderDest']")
        if ($null -ne $endD) {
            $ruaD = @((Get-XmlNoTexto $endD "xLgr"), (Get-XmlNoTexto $endD "nro"), (Get-XmlNoTexto $endD "xBairro")) | Where-Object { $_ -ne "" }
            $cidD = @((Get-XmlNoTexto $endD "xMun"), (Get-XmlNoTexto $endD "UF")) | Where-Object { $_ -ne "" }
            $d.ConsumidorEndereco = (@(($ruaD -join ", "), ($cidD -join "-")) | Where-Object { $_ -ne "" }) -join ", "
        }
    }

    $d.QrCode = Get-XmlNoTexto $raiz "infNFeSupl/qrCode"
    $d.UrlChave = Get-XmlNoTexto $raiz "infNFeSupl/urlChave"
    $d.Protocolo = Get-XmlNoTexto $raiz "protNFe/infProt/nProt"
    $d.Autorizacao = Format-DanfeData (Get-XmlNoTexto $raiz "protNFe/infProt/dhRecbto")
    $d.InfCpl = Get-XmlNoTexto $inf "infAdic/infCpl"
    return $d
}

function New-DanfeNfceBlocos {
    # Monta o cupom na ordem que o PDV imprime. O numero de colunas define o
    # tamanho da letra: 54 no texto miudo, 30 nos totais e 42 no consumidor.
    param($Dados, [switch]$Cancelada, $DataCancelamento = $null)
    $b = New-Object System.Collections.Generic.List[object]
    $txt = { param([string]$T, [int]$Col = 54, [string]$Al = 'C', [switch]$Neg) $b.Add(@{ K = 'txt'; Txt = $T; Col = $Col; Al = $Al; Neg = [bool]$Neg }) }
    $lin = { param([string]$T, [int]$Col = 54, [switch]$Neg) $b.Add(@{ K = 'lin'; Txt = $T; Col = $Col; Neg = [bool]$Neg }) }
    $par = { param([string]$E, [string]$D, [int]$Col = 30, [switch]$Neg) $b.Add(@{ K = 'par'; Esq = $E; Dir = $D; Col = $Col; Neg = [bool]$Neg }) }
    $sep = { $b.Add(@{ K = 'sep' }) }
    $faixa = { param([string[]]$Linhas, [int]$Col = 17) $b.Add(@{ K = 'faixa'; Linhas = $Linhas; Col = $Col }) }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $maiorQueZero = {
        param([string]$V)
        $n = [decimal]0
        return ([decimal]::TryParse("$V", [System.Globalization.NumberStyles]::Number, $inv, [ref]$n) -and $n -gt 0)
    }

    & $sep
    & $txt ($Dados.EmitenteDoc + " " + $Dados.Emitente)
    if ($Dados.Endereco -ne "") { & $txt $Dados.Endereco }
    & $txt "Documento Auxiliar da Nota Fiscal de Consumidor Eletrônica" 58

    if ($Cancelada) {
        & $faixa @("NOTA CANCELADA") 18
        $quando = ""
        if ($null -ne $DataCancelamento) { try { $quando = " em " + ([datetime]$DataCancelamento).ToString("dd/MM/yyyy HH:mm") } catch {} }
        & $txt ("Esta NFC-e foi cancelada" + $quando + " e não tem valor fiscal.") -Neg
    }
    & $sep

    # Itens em colunas, como no cupom. Codigo comprido (EAN) aperta a descricao:
    # abaixo de 16 letras cada item vai em duas linhas.
    $itens = @($Dados.Itens | ForEach-Object {
            @{
                C = "$($_.Codigo)"; D = "$($_.Descricao)"; Q = (Format-DanfeValor $_.Qtd -Quantidade)
                U = "$($_.Un)"; VU = (Format-DanfeValor $_.Unit -Unitario); VT = (Format-DanfeValor $_.Total)
            }
        })
    $maior = { param($Campo, [int]$Minimo) $m = $Minimo; foreach ($i in $itens) { if ($i[$Campo].Length -gt $m) { $m = $i[$Campo].Length } }; return $m }
    $wc = [Math]::Min((& $maior 'C' 6), 14)
    $wq = & $maior 'Q' 4
    $wu = [Math]::Min((& $maior 'U' 2), 6)
    $wvu = & $maior 'VU' 7
    $wt = & $maior 'VT' 8
    $wd = 49 - ($wc + $wq + $wu + $wvu + $wt)
    if ($wd -ge 16) {
        & $lin ("Código".PadRight($wc) + " " + "Descrição".PadRight($wd) + " " + "Qtde".PadLeft($wq) + " " + "UN".PadRight($wu) + " " + "Vl Unit".PadLeft($wvu) + " " + "Vl Total".PadLeft($wt)) -Neg
        foreach ($i in $itens) {
            $cod = $i.C; if ($cod.Length -gt $wc) { $cod = $cod.Substring(0, $wc) }
            $un = $i.U; if ($un.Length -gt $wu) { $un = $un.Substring(0, $wu) }
            $partes = Split-DanfeTexto $i.D $wd
            if ($partes.Count -eq 0) { $partes = @("") }
            & $lin ($cod.PadRight($wc) + " " + $partes[0].PadRight($wd) + " " + $i.Q.PadLeft($wq) + " " + $un.PadRight($wu) + " " + $i.VU.PadLeft($wvu) + " " + $i.VT.PadLeft($wt))
            for ($k = 1; $k -lt $partes.Count; $k++) { & $lin ((" " * ($wc + 1)) + $partes[$k]) }
        }
    }
    else {
        & $lin "Código Descrição" -Neg
        & $par "" "Qtde UN x Vl Unit = Vl Total" 54 -Neg
        foreach ($i in $itens) {
            & $txt ($i.C + " " + $i.D) 54 'E'
            & $par "" ($i.Q + " " + $i.U + " x " + $i.VU + " = " + $i.VT) 54
        }
    }
    & $sep

    & $par "QTD TOTAL DE ITENS" "$($itens.Count)"
    & $par "VALOR TOTAL R$" (Format-DanfeValor $Dados.ValorTotal)
    if (& $maiorQueZero $Dados.Desconto) { & $par "DESCONTO R$" (Format-DanfeValor $Dados.Desconto) }
    if (& $maiorQueZero $Dados.Acrescimo) { & $par "ACRÉSCIMO R$" (Format-DanfeValor $Dados.Acrescimo) }
    & $par "VALOR A PAGAR R$" (Format-DanfeValor $Dados.ValorPagar) -Neg
    & $par "FORMA PAGAMENTO" "VALOR PAGO R$"
    foreach ($p in @($Dados.Pagamentos)) { & $par $p.Forma (Format-DanfeValor $p.Valor) }
    $troco = "0.00"
    if ("$($Dados.Troco)" -ne "") { $troco = $Dados.Troco }
    & $par "TROCO" (Format-DanfeValor $troco)
    & $sep

    & $txt "Consulte pela Chave de Acesso em" -Neg
    # Endereco de consulta numa linha so: quebrado no meio ninguem consegue digitar
    if ($Dados.UrlChave -ne "") { & $txt $Dados.UrlChave ([Math]::Min([Math]::Max(54, $Dados.UrlChave.Length), 72)) }
    & $txt ((($Dados.Chave -split '(.{4})') | Where-Object { $_ -ne '' }) -join ' ')
    & $sep

    if ($Dados.ConsumidorDoc -ne "") {
        & $txt ("CONSUMIDOR " + $Dados.ConsumidorDoc) 42 -Neg
        if ($Dados.ConsumidorNome -ne "") { & $txt $Dados.ConsumidorNome }
        if ($Dados.ConsumidorEndereco -ne "") { & $txt $Dados.ConsumidorEndereco }
    }
    else { & $txt "CONSUMIDOR NÃO IDENTIFICADO" 42 -Neg }
    & $txt ("NFC-e nº " + $Dados.Numero + " Série " + $Dados.Serie + " " + $Dados.Emissao)
    if ($Dados.TipoEmissao -eq "9") { & $txt "EMITIDA EM CONTINGÊNCIA" 42 -Neg }
    if ($Dados.Ambiente -eq "2") { & $txt "EMITIDA EM AMBIENTE DE HOMOLOGAÇÃO - SEM VALOR FISCAL" -Neg }
    if ($Dados.Protocolo -ne "") {
        & $txt ("Protocolo de Autorização " + $Dados.Protocolo)
        & $txt ("Data de Autorização " + $Dados.Autorizacao)
    }
    & $sep

    if ($Dados.QrCode -ne "") {
        try {
            Initialize-QrCodigo
            # Matriz guardada por atribuicao: dentro de @{} o PowerShell desenrolaria
            # o bool[,] numa lista solta de true/false
            $matriz = [XMenuTools.QrCodigo]::Gerar($Dados.QrCode)
            $blocoQr = @{ K = 'qr'; Mm = 32 }
            $blocoQr.Mat = $matriz
            $b.Add($blocoQr)
        }
        catch { & $txt "O QR Code não pôde ser desenhado neste PC. Consulte pela chave de acesso acima." }
    }
    else { & $txt "Esta nota não tem QR Code no XML. Consulte pela chave de acesso acima." }
    & $sep

    # Pedido e codigo XMenu, quando o PDV grava nas informacoes complementares,
    # saem na tarja preta como no cupom; o resto do texto vem logo abaixo.
    # O NetPDV grava a quebra de linha como o texto "\n", nao como quebra de verdade.
    $cpl = "$($Dados.InfCpl)" -replace '\\r\\n|\\n', "`n"
    $linhasFaixa = @()
    foreach ($rotulo in @('Pedido', 'XMenu')) {
        $achou = [regex]::Match($cpl, '(?i)\b' + $rotulo + '\s*:\s*(\d+)')
        if ($achou.Success) {
            $linhasFaixa += "$($rotulo): $($achou.Groups[1].Value)"
            $cpl = $cpl.Remove($achou.Index, $achou.Length)
        }
    }
    if ($linhasFaixa.Count -gt 0) { & $faixa $linhasFaixa 17 }
    if ((& $maiorQueZero $Dados.Tributos) -and $cpl -notmatch '(?i)tribut') {
        & $txt ("Tributos Totais Incidentes (Lei Federal 12.741/2012): R$ " + (Format-DanfeValor $Dados.Tributos)) 54 'E'
    }
    $cpl = ($cpl -replace '\|', "`n").Trim()
    if ($cpl -ne "") { & $txt $cpl 54 'E' }

    if ($Cancelada) {
        & $sep
        & $faixa @("NOTA CANCELADA") 18
    }
    & $sep
    return $b.ToArray()
}

function Save-PdfCupom {
    # PDF de uma pagina com a largura da bobina (80 mm) e a altura do conteudo.
    # Blocos: txt (texto quebrado por palavras), lin (linha pronta, alinhada por
    # espacos), par (esquerda e direita na mesma linha), sep (tracejado), qr e
    # faixa (tarja preta com letra branca). Na Courier toda letra tem 0,6 da
    # altura de largura, entao o tamanho sai exato do numero de colunas.
    param($Blocos, [string]$Caminho, [string]$Titulo = "")
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $larg = 80 / 25.4 * 72
    $marg = 3 / 25.4 * 72
    $util = $larg - 2 * $marg
    $tamDe = { param([int]$Col) return ($util / ($Col * 0.6)) }

    # 1) Mede: cada bloco vira operacoes de desenho com a altura que ocupam
    $ops = New-Object System.Collections.Generic.List[object]
    foreach ($bl in @($Blocos)) {
        if ($bl.K -eq 'txt') {
            $tam = & $tamDe $bl.Col
            foreach ($l in (Split-DanfeTexto $bl.Txt $bl.Col)) {
                $ops.Add(@{ K = 't'; Txt = $l; Tam = $tam; Al = $bl.Al; Neg = $bl.Neg; Alt = $tam * 1.2 })
            }
        }
        elseif ($bl.K -eq 'lin' -or $bl.K -eq 'par') {
            $tam = & $tamDe $bl.Col
            $l = "$($bl.Txt)"
            if ($bl.K -eq 'par') {
                $dir = "$($bl.Dir)"
                $esq = "$($bl.Esq)"
                $cabe = [Math]::Max(0, $bl.Col - $dir.Length - 1)
                if ($esq.Length -gt $cabe) { $esq = $esq.Substring(0, $cabe) }
                $l = $esq.PadRight([Math]::Max(0, $bl.Col - $dir.Length)) + $dir
            }
            if ($l.Length -gt $bl.Col) { $l = $l.Substring(0, $bl.Col) }
            $ops.Add(@{ K = 't'; Txt = $l; Tam = $tam; Al = 'E'; Neg = $bl.Neg; Alt = $tam * 1.2 })
        }
        elseif ($bl.K -eq 'sep') { $ops.Add(@{ K = 's'; Alt = 6.0 }) }
        elseif ($bl.K -eq 'qr') {
            $lado = $bl.Mm / 25.4 * 72
            $opQr = @{ K = 'q'; Lado = $lado; Alt = $lado + 8 }
            $opQr.Mat = $bl.Mat
            $ops.Add($opQr)
        }
        elseif ($bl.K -eq 'faixa') {
            $col = $bl.Col
            foreach ($l in @($bl.Linhas)) { if ($l.Length -gt $col) { $col = $l.Length } }
            $tam = & $tamDe $col
            $ops.Add(@{ K = 'f'; Linhas = @($bl.Linhas); Tam = $tam; Alt = @($bl.Linhas).Count * $tam * 1.15 + 8 })
        }
    }
    $altura = 20.0
    foreach ($op in $ops) { $altura += $op.Alt }

    # 2) Desenha de cima para baixo (no PDF o zero do eixo Y fica embaixo)
    $n = "0.###"
    $esc = { param([string]$s) return $s.Replace('\', '\\').Replace('(', '\(').Replace(')', '\)') }
    $sb = New-Object System.Text.StringBuilder
    $y = $altura - 8
    foreach ($op in $ops) {
        if ($op.K -eq 't') {
            $largTxt = $op.Txt.Length * 0.6 * $op.Tam
            $x = $marg
            if ($op.Al -eq 'C') { $x = ($larg - $largTxt) / 2 }
            elseif ($op.Al -eq 'D') { $x = $larg - $marg - $largTxt }
            $fonte = "F1"
            if ($op.Neg) { $fonte = "F2" }
            $base = $y - $op.Tam * 0.82
            [void]$sb.Append("BT /" + $fonte + " " + ([double]$op.Tam).ToString($n, $inv) + " Tf " + ([double]$x).ToString($n, $inv) + " " + ([double]$base).ToString($n, $inv) + " Td (" + (& $esc $op.Txt) + ") Tj ET`n")
        }
        elseif ($op.K -eq 's') {
            $yy = ([double]($y - $op.Alt / 2)).ToString($n, $inv)
            [void]$sb.Append("0.5 w [1.5 1.5] 0 d " + ([double]$marg).ToString($n, $inv) + " " + $yy + " m " + ([double]($larg - $marg)).ToString($n, $inv) + " " + $yy + " l S [] 0 d`n")
        }
        elseif ($op.K -eq 'q') {
            $mat = $op.Mat
            $qtd = $mat.GetLength(0)
            $mod = $op.Lado / $qtd
            $x0 = ($larg - $op.Lado) / 2
            $topo = $y - 4
            $altMod = ([double]($mod + 0.05)).ToString($n, $inv)
            for ($r = 0; $r -lt $qtd; $r++) {
                $yMod = ([double]($topo - ($r + 1) * $mod)).ToString($n, $inv)
                $c = 0
                while ($c -lt $qtd) {
                    if ($mat[$r, $c]) {
                        $ini = $c
                        while ($c -lt $qtd -and $mat[$r, $c]) { $c++ }
                        [void]$sb.Append(([double]($x0 + $ini * $mod)).ToString($n, $inv) + " " + $yMod + " " + ([double](($c - $ini) * $mod)).ToString($n, $inv) + " " + $altMod + " re`n")
                    }
                    else { $c++ }
                }
            }
            [void]$sb.Append("f`n")
        }
        elseif ($op.K -eq 'f') {
            [void]$sb.Append("0 g " + ([double]$marg).ToString($n, $inv) + " " + ([double]($y - $op.Alt + 2)).ToString($n, $inv) + " " + ([double]$util).ToString($n, $inv) + " " + ([double]($op.Alt - 4)).ToString($n, $inv) + " re f 1 g`n")
            $topoTxt = $y - 4
            foreach ($l in $op.Linhas) {
                $largTxt = $l.Length * 0.6 * $op.Tam
                $x = ($larg - $largTxt) / 2
                $base = $topoTxt - $op.Tam * 0.85
                [void]$sb.Append("BT /F2 " + ([double]$op.Tam).ToString($n, $inv) + " Tf " + ([double]$x).ToString($n, $inv) + " " + ([double]$base).ToString($n, $inv) + " Td (" + (& $esc $l) + ") Tj ET`n")
                $topoTxt -= $op.Tam * 1.15
            }
            [void]$sb.Append("0 g`n")
        }
        $y -= $op.Alt
    }

    # 3) Arquivo: letras em Windows-1252, que e o que a WinAnsiEncoding das
    # fontes padrao do PDF entende (acentos do portugues inclusos)
    $enc = [System.Text.Encoding]::GetEncoding(1252)
    $conteudo = $enc.GetBytes($sb.ToString())
    $ms = New-Object System.IO.MemoryStream
    $posicoes = New-Object 'System.Collections.Generic.List[long]'
    $escreve = { param([string]$s) $bytes = $enc.GetBytes($s); $ms.Write($bytes, 0, $bytes.Length) }
    $objeto = { param([string]$s) $posicoes.Add($ms.Position); & $escreve $s }

    & $escreve "%PDF-1.4`n"
    $ms.Write([byte[]](0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A), 0, 6)
    & $objeto "1 0 obj`n<< /Type /Catalog /Pages 2 0 R >>`nendobj`n"
    & $objeto "2 0 obj`n<< /Type /Pages /Kids [3 0 R] /Count 1 >>`nendobj`n"
    & $objeto ("3 0 obj`n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 " + ([double]$larg).ToString($n, $inv) + " " + ([double]$altura).ToString($n, $inv) + "] /Resources << /Font << /F1 5 0 R /F2 6 0 R >> >> /Contents 4 0 R >>`nendobj`n")
    & $objeto ("4 0 obj`n<< /Length " + $conteudo.Length + " >>`nstream`n")
    $ms.Write($conteudo, 0, $conteudo.Length)
    & $escreve "`nendstream`nendobj`n"
    & $objeto "5 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >>`nendobj`n"
    & $objeto "6 0 obj`n<< /Type /Font /Subtype /Type1 /BaseFont /Courier-Bold /Encoding /WinAnsiEncoding >>`nendobj`n"
    & $objeto ("7 0 obj`n<< /Title (" + (& $esc $Titulo) + ") /Producer (Preparador de Ambiente XMenu) /CreationDate (D:" + (Get-Date -Format "yyyyMMddHHmmss") + ") >>`nendobj`n")
    $inicioXref = $ms.Position
    & $escreve "xref`n0 8`n0000000000 65535 f`r`n"
    foreach ($pos in $posicoes) { & $escreve ($pos.ToString("0000000000") + " 00000 n`r`n") }
    & $escreve ("trailer`n<< /Size 8 /Root 1 0 R /Info 7 0 R >>`nstartxref`n" + $inicioXref + "`n%%EOF`n")
    [System.IO.File]::WriteAllBytes($Caminho, $ms.ToArray())
    $ms.Dispose()
}

function Export-DanfeNfcePdf {
    # XML da NFC-e -> PDF do DANFE. Lanca excecao com o motivo quando nao da.
    param([string]$Xml, [string]$Caminho, [switch]$Cancelada, $DataCancelamento = $null)
    $dados = Get-DanfeNfceDados -Xml $Xml
    $blocos = New-DanfeNfceBlocos -Dados $dados -Cancelada:$Cancelada -DataCancelamento $DataCancelamento
    Save-PdfCupom -Blocos $blocos -Caminho $Caminho -Titulo ("Espelho NFC-e " + $dados.Numero + " Serie " + $dados.Serie)
}

function Show-XmlDownloader {
    try {
        if ($null -ne $Script:XmlForm -and -not $Script:XmlForm.IsDisposed) {
            $Script:XmlForm.Activate(); return
        }

        # Credenciais padrao de todo cliente: senha num ponto so
        $senhaPadrao = "netcontroll"
        $bancoPadrao = "netwebpdv"

        $Script:XmlCancelar = $false
        $Script:XmlOcupado = $false
        $Script:XmlOrdemCol = -1
        $Script:XmlOrdemAsc = $true
        $Script:XmlResultados = @()
        $Script:XmlPedidas = @()
        $Script:XmlUltimoLote = ""
        $Script:XmlUltimoZip = ""
        $Script:XmlFaltantes = @()
        $Script:XmlArqServidor = Join-Path $Script:DownloadFolder "xml_ultimo_servidor.txt"

        # Servidor da ultima execucao, se houver. O arquivo e lido sempre como UTF-8 e o
        # conteudo e conferido: ja apareceu cliente com esse arquivo gravado noutra
        # codificacao, e o campo Servidor abria cheio de caractere estranho. Nome de
        # servidor so tem letras, numeros, ponto, traco, barra invertida e virgula (porta).
        $srvInicial = "127.0.0.1"
        try {
            if (Test-Path $Script:XmlArqServidor) {
                $lido = "$([System.IO.File]::ReadAllText($Script:XmlArqServidor, [System.Text.Encoding]::UTF8))"
                $lido = ($lido -split "`n")[0]
                $lido = ($lido -replace "[`0`r`n]", "").Trim()
                if ($lido -match '^[A-Za-z0-9._\\,\-]{1,80}$') { $srvInicial = $lido }
                elseif ($lido -ne "") { Log-Message "ERRO" "XMLs: o arquivo do último servidor estava ilegível; voltando para 127.0.0.1" }
            }
        }
        catch {}

        $f = New-ToolForm "Baixar XMLs NFC-e" 1000 720
        $f.MinimumSize = New-Object System.Drawing.Size(1000, 720)
        $Script:XmlForm = $f

        # Cartao: agrupa cada etapa no mesmo tom que os medidores do monitor usam
        $novoCartao = {
            param([int]$X, [int]$Y, [int]$W, [int]$H)
            $p = New-Object System.Windows.Forms.Panel
            $p.Location = New-Object System.Drawing.Point($X, $Y)
            $p.Size = New-Object System.Drawing.Size($W, $H)
            $p.BackColor = $Script:UiCartao
            $p.Anchor = 'Top,Left,Right'
            [void]$f.Controls.Add($p)
            return $p
        }

        $novoCampo = {
            param($Pai, [int]$X, [int]$Y, [int]$W, [string]$Valor = "", [int]$H = 24, [switch]$Multi)
            $t = New-Object System.Windows.Forms.TextBox
            $t.Location = New-Object System.Drawing.Point($X, $Y)
            $t.Size = New-Object System.Drawing.Size($W, $H)
            $t.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $t.ForeColor = $Script:UiTexto
            $t.BorderStyle = 'FixedSingle'
            if ($Multi) { $t.Multiline = $true; $t.ScrollBars = 'Vertical' }
            $t.Text = $Valor
            [void]$Pai.Controls.Add($t)
            return $t
        }

        $novaCombo = {
            param($Pai, [int]$X, [int]$Y, [int]$W, [switch]$Editavel)
            $c = New-Object System.Windows.Forms.ComboBox
            $c.Location = New-Object System.Drawing.Point($X, $Y)
            $c.Width = $W
            $c.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $c.ForeColor = $Script:UiTexto
            $c.FlatStyle = 'Flat'
            if ($Editavel) { $c.DropDownStyle = 'DropDown' } else { $c.DropDownStyle = 'DropDownList' }
            [void]$Pai.Controls.Add($c)
            return $c
        }

        $novoRadio = {
            param($Pai, [string]$Texto, [int]$X, [int]$Y, [int]$W)
            $r = New-Object System.Windows.Forms.RadioButton
            $r.Text = $Texto
            $r.Location = New-Object System.Drawing.Point($X, $Y)
            $r.Size = New-Object System.Drawing.Size($W, 20)
            $r.ForeColor = $Script:UiTexto
            $r.BackColor = [System.Drawing.Color]::Transparent
            $r.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
            $r.Cursor = 'Hand'
            [void]$Pai.Controls.Add($r)
            return $r
        }

        $novaData = {
            param($Pai, [int]$X, [int]$Y, [int]$W)
            $d = New-Object System.Windows.Forms.DateTimePicker
            $d.Location = New-Object System.Drawing.Point($X, $Y)
            $d.Width = $W
            $d.Format = 'Short'
            $d.CalendarMonthBackground = $Script:UiCartao
            $d.CalendarForeColor = $Script:UiTexto
            $d.CalendarTitleBackColor = $Script:UiAzul
            $d.CalendarTitleForeColor = [System.Drawing.Color]::White
            [void]$Pai.Controls.Add($d)
            return $d
        }

        # ---------------------------------------------------------------------
        # CARTAO 1: conexao
        # ---------------------------------------------------------------------
        $cardConn = & $novoCartao 12 10 960 80
        New-ToolLabel $cardConn "CONEXÃO COM O BANCO" 14 8 10 -Negrito | Out-Null
        New-ToolLabel $cardConn "Servidor:" 14 36 9 -Cor $Script:UiSuave | Out-Null
        $txtServidor = & $novoCampo $cardConn 78 33 160 $srvInicial
        New-ToolLabel $cardConn "Senha:" 254 36 9 -Cor $Script:UiSuave | Out-Null
        $txtSenha = & $novoCampo $cardConn 302 33 120 $senhaPadrao
        New-ToolLabel $cardConn "Parceiro:" 438 36 9 -Cor $Script:UiSuave | Out-Null
        $cmbParceiro = & $novaCombo $cardConn 498 33 110
        $dicaTestar = "Conecta no banco $bancoPadrao, mostra a versao do SQL e carrega parceiros e series"
        $btnTestar = New-ToolButton $cardConn "TESTAR CONEXÃO" 624 32 150 27 $Script:UiAzul $null $dicaTestar
        $btnPendentes = New-ToolButton $cardConn "NOTAS PENDENTES" 786 32 160 27 $Script:UiAmarelo $null "Lista as NFC-e que não subiram: sem autorização da SEFAZ e sem inutilização, com a situação e o motivo (sem resposta, rejeitada, contingência não enviada, ignorada)."
        $lblConn = New-ToolLabel $cardConn "Informe o servidor e clique em TESTAR CONEXÃO." 14 60 9 -Cor $Script:UiSuave -W 930
        # Certificado: so aparece quando o banco emite com mais de um (IDServidorFiscal).
        # Raro, mas nesses clientes as duas empresas usam a mesma serie e os numeros se repetem.
        # Ganha uma linha propria no cartao ($mostrarLinhaCert abre o espaco).
        $lblCert = New-ToolLabel $cardConn "Certificado:" 14 90 9 -Cor $Script:UiSuave
        $cmbCert = & $novaCombo $cardConn 98 86 480
        $cmbCert.DropDownWidth = 520
        $lblCert.Visible = $false
        $cmbCert.Visible = $false
        $Script:XmlTemServidor = $false
        $Script:XmlServidores = @()
        $Script:XmlNomeServidor = @{}
        $Script:XmlFaltantesTexto = ""

        # ---------------------------------------------------------------------
        # CARTAO 2: os quatro modos de busca
        # ---------------------------------------------------------------------
        $cardBusca = & $novoCartao 12 98 960 184
        New-ToolLabel $cardBusca "O QUE BAIXAR" 14 4 10 -Negrito | Out-Null

        $rbSerie = & $novoRadio $cardBusca "Por série + sequência" 12 24 230
        $rbSerie.Checked = $true
        New-ToolLabel $cardBusca "Série:" 32 51 9 -Cor $Script:UiSuave | Out-Null
        $cmbSerie = & $novaCombo $cardBusca 76 48 90 -Editavel
        New-ToolLabel $cardBusca "Notas:" 182 51 9 -Cor $Script:UiSuave | Out-Null
        $txtNotas = & $novoCampo $cardBusca 232 48 300 "1-15,2000"
        $lblContagem = New-ToolLabel $cardBusca "" 546 51 9 -Cor $Script:UiVerde -W 390

        $rbPeriodo = & $novoRadio $cardBusca "Por período" 12 76 230
        New-ToolLabel $cardBusca "De:" 32 103 9 -Cor $Script:UiSuave | Out-Null
        $dtIni = & $novaData $cardBusca 60 100 110
        New-ToolLabel $cardBusca "Até:" 184 103 9 -Cor $Script:UiSuave | Out-Null
        $dtFim = & $novaData $cardBusca 216 100 110
        New-ToolLabel $cardBusca "Série (opcional):" 342 103 9 -Cor $Script:UiSuave | Out-Null
        $cmbSerie2 = & $novaCombo $cardBusca 450 100 90 -Editavel

        $rbChave = & $novoRadio $cardBusca "Por chave de acesso (44 posições)" 12 128 300
        $txtChaves = & $novoCampo $cardBusca 32 150 430 "" 26 -Multi

        # Pedido do PDV (o numero que sai no cupom, "Pedido: 73432"): o banco liga
        # Pedidos.IDNSUFiscal a NSUFiscal, que guarda a serie e o numero da NFC-e
        $rbPedido = & $novoRadio $cardBusca "Por número do pedido   (ex.: 73432  ou  73400-73432)" 490 128 460
        $txtPedidos = & $novoCampo $cardBusca 510 150 150 ""
        # O numero do pedido zera por dia em muitos clientes: o dia (do caixa) separa
        # o pedido 577 de ontem do 577 de hoje
        $chkDiaPedido = New-Object System.Windows.Forms.CheckBox
        $chkDiaPedido.Text = "No dia:"
        $chkDiaPedido.Location = New-Object System.Drawing.Point(674, 152)
        $chkDiaPedido.Size = New-Object System.Drawing.Size(70, 20)
        $chkDiaPedido.ForeColor = $Script:UiTexto
        $chkDiaPedido.BackColor = [System.Drawing.Color]::Transparent
        $chkDiaPedido.Cursor = 'Hand'
        [void]$cardBusca.Controls.Add($chkDiaPedido)
        $dtPedido = & $novaData $cardBusca 746 150 110
        New-ToolLabel $cardBusca "(opcional)" 864 154 8.5 -Cor $Script:UiSuave -W 80 | Out-Null


        # ---------------------------------------------------------------------
        # OPCOES DO ARQUIVO
        # ---------------------------------------------------------------------
        New-ToolLabel $f "Tipo de nota:" 16 293 9 -Cor $Script:UiSuave | Out-Null
        $cmbTipo = & $novaCombo $f 108 290 180
        [void]$cmbTipo.Items.Add("Todas")
        [void]$cmbTipo.Items.Add("Somente autorizadas")
        [void]$cmbTipo.Items.Add("Somente inutilizadas")
        [void]$cmbTipo.Items.Add("Somente canceladas")
        $cmbTipo.SelectedIndex = 0

        # A busca vem com tudo desmarcado: o comum e pegar uma ou outra nota do
        # periodo, e para levar tudo existe o BAIXAR TUDO. Este botao marca ou
        # limpa a lista de uma vez e o contador ao lado mostra quantas estao marcadas.
        $btnMarcar = New-ToolButton $f "MARCAR TODAS" 300 288 140 26 $Script:UiCinza $null "Marca todas as notas com XML da lista. Com alguma marcada, vira DESMARCAR TODAS."
        $btnMarcar.Enabled = $false
        $lblMarcadas = New-ToolLabel $f "" 450 293 9 -Cor $Script:UiSuave -W 150

        # Sem checkbox: gravar a nota sem o protocolo geraria um XML que a SEFAZ e o
        # contador recusam, e o cancelamento so aparece quando a nota foi cancelada
        # mesmo. Nao ha escolha util aqui, entao o comportamento e fixo.
        $lblSaida = New-ToolLabel $f "XML completo, com protocolo e cancelamento quando houver" 622 293 8.5 -Cor $Script:UiSuave -W 350
        $lblSaida.TextAlign = 'TopRight'
        $lblSaida.Anchor = 'Top,Right'

        # ---------------------------------------------------------------------
        # LISTA
        # A cor da linha ja diz o que aconteceu (verde autorizada, amarelo
        # inutilizada, vermelho sem XML), entao nao existe coluna de status.
        # ---------------------------------------------------------------------
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(12, 320)
        $lv.Size = New-Object System.Drawing.Size(960, 230)
        $lv.Anchor = 'Top,Left,Right,Bottom'
        $lv.MultiSelect = $true
        $lv.CheckBoxes = $true
        $lv.ShowItemToolTips = $true
        Format-ToolListView $lv
        [void]$lv.Columns.Add("Nota", 55)
        [void]$lv.Columns.Add("Série", 50)
        [void]$lv.Columns.Add("Data", 115)
        [void]$lv.Columns.Add("Situação", 115)
        [void]$lv.Columns.Add("Chave de acesso", 260)
        [void]$lv.Columns.Add("Tamanho", 75)
        [void]$lv.Columns.Add("Arquivo gerado", 130)
        # Por ultimo para nao mudar a posicao das outras colunas (SubItems 3, 5 e 6)
        [void]$lv.Columns.Add("Pedido", 60)
        # Total da nota: com o pedido repetido (zera por dia) o valor mostra qual e a certa
        $colValor = $lv.Columns.Add("Valor R$", 75)
        $colValor.TextAlign = 'Right'
        # Empresa do certificado que emitiu: largura 0 quando o banco tem um so
        $colCert = $lv.Columns.Add("Certificado", 0)
        [void]$f.Controls.Add($lv)

        # Colunas arrastaveis pelo cabecalho. So muda a posicao na tela: o indice de
        # cada coluna (SubItems e ordenacao) continua o mesmo. A ordem fica guardada
        # para a proxima vez que a janela abrir.
        $lv.AllowColumnReorder = $true
        $Script:XmlArqColunas = Join-Path $Script:DownloadFolder "xml_ordem_colunas.txt"
        try {
            if (Test-Path $Script:XmlArqColunas) {
                $ordemSalva = @(("$(Get-Content -Path $Script:XmlArqColunas -TotalCount 1 -ErrorAction Stop)".Trim()) -split ',' | ForEach-Object { [int]$_ })
                # Lista de outra versao (com outro numero de colunas) e ignorada
                if ($ordemSalva.Count -eq $lv.Columns.Count -and (@($ordemSalva | Sort-Object) -join ',') -eq ((0..($lv.Columns.Count - 1)) -join ',')) {
                    for ($i = 0; $i -lt $ordemSalva.Count; $i++) { $lv.Columns[$i].DisplayIndex = $ordemSalva[$i] }
                }
            }
        }
        catch {}

        # Aviso sobreposto a lista: no rodape ficava discreto demais para uma
        # consulta que pode levar alguns segundos.
        $lblCarregando = New-Object System.Windows.Forms.Label
        $lblCarregando.TextAlign = 'MiddleCenter'
        $lblCarregando.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        $lblCarregando.ForeColor = $Script:UiAmarelo
        $lblCarregando.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
        $lblCarregando.Location = New-Object System.Drawing.Point(13, 400)
        $lblCarregando.Size = New-Object System.Drawing.Size(958, 70)
        $lblCarregando.Anchor = 'Top,Left,Right'
        $lblCarregando.Visible = $false
        [void]$f.Controls.Add($lblCarregando)

        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        $miChave = $menu.Items.Add("Copiar chave")
        $miPasta = $menu.Items.Add("Abrir pasta do arquivo")
        [void]$menu.Items.Add("-")
        $miTodos = $menu.Items.Add("Marcar todos")
        $miNenhum = $menu.Items.Add("Desmarcar todos")
        $lv.ContextMenuStrip = $menu

        # Cada campo explica a si mesmo no balao, para nao precisar abrir a ajuda.
        # Fica aqui no fim porque todos os controles ja tem que existir.
        if ($Script:ToolTip) {
            $Script:ToolTip.SetToolTip($txtServidor, "Onde está o SQL Server. Deixe 127.0.0.1 quando o banco roda na própria máquina; use o IP ou o nome do servidor quando o PDV é terminal. A janela lembra o último usado.")
            $Script:ToolTip.SetToolTip($txtSenha, "Senha do usuário sa. Nos clientes é sempre netcontroll; só mude se esse cliente tiver senha diferente.")
            $Script:ToolTip.SetToolTip($cmbParceiro, "Código da loja dentro do banco. Carrega sozinho ao testar a conexão. Quando só existe um, já vem escolhido.")
            $Script:ToolTip.SetToolTip($cmbCert, "Este banco emite NFC-e com mais de um certificado (uma empresa em cada caixa). Escolha de qual empresa são as notas; em Todos, cada empresa sai no seu próprio lote e zip. O nome vem do certificado que assinou as notas.")
            $Script:ToolTip.SetToolTip($rbSerie, "O modo mais usado: você sabe a série e os números das notas que o cliente pediu.")
            $Script:ToolTip.SetToolTip($cmbSerie, "Série do caixa. A lista vem do próprio banco depois de testar a conexão.")
            $Script:ToolTip.SetToolTip($txtNotas, "Aceita intervalo, lista ou os dois juntos:  1-15  |  1,5,9  |  1-10,15,20-25. Pode digitar com espaços. Enter já faz a busca.")
            $Script:ToolTip.SetToolTip($rbPeriodo, "Quando o cliente pede tudo de um dia ou de um mês, em vez de números específicos.")
            $Script:ToolTip.SetToolTip($rbChave, "Quando o cliente mandou a chave de acesso da nota em vez do número.")
            $Script:ToolTip.SetToolTip($txtChaves, "Cole as chaves de 44 posições separadas por vírgula ou uma por linha. Pontos, espaços e o NFe da frente são ignorados. Aceita a chave de CNPJ alfanumérico (com letras).")
            $Script:ToolTip.SetToolTip($rbPedido, "Quando o cliente só tem o número do pedido, o que sai no cupom como ""Pedido: 73432"".")
            $Script:ToolTip.SetToolTip($txtPedidos, "Um pedido, uma lista ou intervalo:  73432  |  73430,73432  |  73400-73432. Pedido sem NFC-e (venda não fiscal) aparece no aviso depois da busca. Número que se repete (zera por dia) traz uma nota por dia, a mais recente primeiro; marque No dia para trazer só a do dia certo. Enter já faz a busca.")
            $Script:ToolTip.SetToolTip($chkDiaPedido, "Busca o pedido só nesse dia de caixa. Venda depois da meia-noite conta no dia em que o caixa foi aberto.")
            $Script:ToolTip.SetToolTip($cmbTipo, "Serve como filtro da lista também: depois de buscar, troque a opção e a tela mostra só o que interessa, sem consultar o banco de novo. Em 'Todas', cada número traz a nota autorizada e, se aquele número tiver sido inutilizado, traz a inutilizada no lugar — nunca as duas para o mesmo número.")
            $Script:ToolTip.SetToolTip($lv, "A coluna Situação diz o que é cada nota. Verde = autorizada, vale. Vermelho = cancelada, não vale. Amarelo = inutilizada ou sem protocolo. Cinza = não existe no banco. Passe o mouse na linha para o detalhe, clique no cabeçalho para ordenar, arraste o cabeçalho para mudar a coluna de lugar e use o botão direito para marcar ou desmarcar tudo.")
        }

        # ---------------------------------------------------------------------
        # PROGRESSO E RODAPE
        # ---------------------------------------------------------------------
        $lblProg = New-ToolLabel $f "" 12 560 9 -Cor $Script:UiSuave -W 260
        $lblProg.Anchor = 'Bottom,Left'

        $pb = New-Object System.Windows.Forms.ProgressBar
        $pb.Location = New-Object System.Drawing.Point(280, 560)
        $pb.Size = New-Object System.Drawing.Size(572, 16)
        $pb.Style = 'Continuous'
        $pb.Anchor = 'Bottom,Left'
        [void]$f.Controls.Add($pb)

        $btnCancelar = New-ToolButton $f "CANCELAR" 862 556 110 24 $Script:UiVermelho $null "Interrompe a busca em andamento, ou o download na próxima nota fechando o zip com o que já veio"
        $btnCancelar.Enabled = $false
        $btnCancelar.Anchor = 'Bottom,Left'

        # Rodape em grade: 5 colunas de 184px com 10px de respiro. As duas linhas
        # comecam em 12 e terminam em 972, alinhadas entre si e com a lista.
        $btnBuscar = New-ToolButton $f "BUSCAR" 12 586 184 30 $Script:UiAzul $null "Consulta o banco e lista as notas do filtro, sem gravar nada ainda"
        $btnBaixarSel = New-ToolButton $f "BAIXAR SELECIONADOS" 206 586 184 30 $Script:UiVerde $null "Grava so as linhas marcadas na lista"
        $btnBaixarTudo = New-ToolButton $f "BAIXAR TUDO" 400 586 184 30 $Script:UiVerde $null "Grava todas as linhas que estão aparecendo na lista. Se o Tipo de nota estiver filtrando, baixa só o que o filtro deixou à mostra."
        $btnConferir = New-ToolButton $f "CONFERIR SEQUÊNCIA" 594 586 184 30 $Script:UiAmarelo $null "So consulta: aponta as lacunas da numeracao na serie, sem baixar nada"
        $btnAjuda = New-ToolButton $f "COMO USAR" 788 586 184 30 $Script:UiCinza $null "Abre um passo a passo da janela"
        $btnCopiar = New-ToolButton $f "COPIAR FALTANTES" 12 620 184 30 $Script:UiCinza $null "Copia os números que faltaram na última busca ou conferência, já formatados, para colar num e-mail ou WhatsApp para o cliente"
        $btnPasta = New-ToolButton $f "ABRIR PASTA" 206 620 184 30 $Script:UiCinza $null "Abre a pasta do ultimo lote baixado"
        $btnZip = New-ToolButton $f "ABRIR ZIP" 400 620 184 30 $Script:UiCinza $null "Abre a pasta compactada do ultimo lote"
        $btnPdf = New-ToolButton $f "ESPELHO FISCAL (PDF)" 594 620 184 30 $Script:UiVerde $null "Gera o espelho fiscal da nota em PDF, igual ao cupom (80 mm, com QR Code), das notas marcadas. Por chave ou por pedido, busca e gera direto."
        $btnFechar = New-ToolButton $f "FECHAR" 788 620 184 30 $Script:UiCinza $null "Fecha esta janela"
        foreach ($b in @($btnBuscar, $btnBaixarSel, $btnBaixarTudo, $btnConferir, $btnAjuda, $btnCopiar, $btnPasta, $btnZip, $btnPdf, $btnFechar)) {
            $b.Anchor = 'Bottom,Left'
        }

        $lblStatus = New-ToolLabel $f "Pronto." 12 656 9 -Cor $Script:UiSuave -W 960
        $lblStatus.Anchor = 'Bottom,Left,Right'

        # ---------------------------------------------------------------------
        # ROTINAS DA JANELA
        # ---------------------------------------------------------------------
        $setStatus = {
            param([string]$Texto, $Cor = $null)
            if ($Cor) { $lblStatus.ForeColor = $Cor } else { $lblStatus.ForeColor = $Script:UiSuave }
            $lblStatus.Text = $Texto
            [System.Windows.Forms.Application]::DoEvents()
        }

        # Campos do modo nao escolhido ficam desabilitados, nunca escondidos
        $atualizaModo = {
            $m1 = $rbSerie.Checked; $m2 = $rbPeriodo.Checked; $m3 = $rbChave.Checked; $m4 = $rbPedido.Checked
            $cmbSerie.Enabled = $m1; $txtNotas.Enabled = $m1; $lblContagem.Visible = $m1
            $dtIni.Enabled = $m2; $dtFim.Enabled = $m2; $cmbSerie2.Enabled = $m2
            $txtChaves.Enabled = $m3
            $txtPedidos.Enabled = $m4
            $chkDiaPedido.Enabled = $m4
            $dtPedido.Enabled = ($m4 -and $chkDiaPedido.Checked)
            # Destaca o modo ativo: o escolhido em verde, os outros apagados
            if ($m1) { $rbSerie.ForeColor = $Script:UiVerde } else { $rbSerie.ForeColor = $Script:UiSuave }
            if ($m2) { $rbPeriodo.ForeColor = $Script:UiVerde } else { $rbPeriodo.ForeColor = $Script:UiSuave }
            if ($m3) { $rbChave.ForeColor = $Script:UiVerde } else { $rbChave.ForeColor = $Script:UiSuave }
            if ($m4) { $rbPedido.ForeColor = $Script:UiVerde } else { $rbPedido.ForeColor = $Script:UiSuave }
            $btnConferir.Enabled = $m1
            $btnCopiar.Enabled = ($Script:XmlFaltantes.Count -gt 0)
        }

        $contaNotas = {
            $bruto = "$($txtNotas.Text)".Trim()
            if ($bruto -eq "") {
                # Campo vazio vira a propria explicacao de como se preenche
                $lblContagem.ForeColor = $Script:UiSuave
                $lblContagem.Text = "ex.:  1-15   |   1,5,9   |   1-10,15,20-25"
                return
            }
            $r = ConvertFrom-FaixaNotas -Texto $bruto
            if ($r.Ok) {
                $lblContagem.ForeColor = $Script:UiVerde
                $txt = "$($r.Total) notas selecionadas"
                if ($r.Confirmar) { $txt = $txt + " (lote grande)" }
                $lblContagem.Text = $txt
            }
            else {
                $lblContagem.ForeColor = $Script:UiVermelho
                $lblContagem.Text = $r.Erro
            }
        }

        $novaConexao = {
            param([int]$Timeout = 8)
            $srv = "$($txtServidor.Text)".Trim()
            if ($srv -eq "") { $srv = "127.0.0.1" }
            # Servidor remoto vai forcado por TCP. Sem protocolo, quando o TCP falha o
            # SqlClient ainda tenta Named Pipes, que ignora o Connect Timeout: IP
            # errado levava de 11 a 24 s para dar erro. A propria maquina fica como
            # esta (memoria compartilhada) e quem ja digitou "tcp:"/"np:" tambem.
            $local = '^(\.|\(local\)|localhost|127\.0\.0\.1|' + [regex]::Escape($env:COMPUTERNAME) + ')([\\,]|$)'
            if ($srv -notmatch ':' -and $srv -notmatch $local) { $srv = "tcp:" + $srv }
            $senha = "$($txtSenha.Text)"
            $cs = "Server=$srv;Database=$bancoPadrao;User Id=sa;Password=$senha;Connect Timeout=$Timeout;TrustServerCertificate=True"
            return (New-Object System.Data.SqlClient.SqlConnection($cs))
        }

        # Abre a conexao sem travar a janela. O Open() segurava a tela inteira ate
        # o SQL desistir ("Nao respondendo"); o OpenAsync volta na hora e a janela
        # segue respondendo enquanto espera. -Rotulo mostra os segundos passando.
        $abrirConexao = {
            param([int]$Timeout = 8, $Rotulo = $null)
            $cn = & $novaConexao $Timeout
            $tarefa = $cn.OpenAsync()
            $relogio = [System.Diagnostics.Stopwatch]::StartNew()
            $textoBase = ""
            if ($null -ne $Rotulo) { $textoBase = $Rotulo.Text }
            $f.UseWaitCursor = $true
            try {
                while (-not $tarefa.IsCompleted) {
                    if ($null -ne $Rotulo) { $Rotulo.Text = "$textoBase $([int]$relogio.Elapsed.TotalSeconds)s" }
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 40
                }
            }
            finally { $f.UseWaitCursor = $false }
            if ($tarefa.IsFaulted) {
                $erro = $tarefa.Exception.GetBaseException()
                $cn.Dispose()
                throw $erro
            }
            return $cn
        }

        # Roda a consulta sem travar a janela e devolve o leitor. O ExecuteReader
        # segurava a tela ate o SQL Server responder, e um periodo grande num banco
        # pesado deixava a janela em "Nao respondendo" por dezenas de segundos.
        # -Cancelavel: o botao CANCELAR interrompe a consulta no proprio servidor.
        $executarLeitor = {
            param($Cmd, [switch]$Cancelavel)
            $tarefa = $Cmd.ExecuteReaderAsync()
            $pediuCancelar = $false
            $f.UseWaitCursor = $true
            try {
                while (-not $tarefa.IsCompleted) {
                    if ($Cancelavel -and $Script:XmlCancelar -and -not $pediuCancelar) {
                        $pediuCancelar = $true
                        try { $Cmd.Cancel() } catch {}
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                    Start-Sleep -Milliseconds 40
                }
            }
            finally { $f.UseWaitCursor = $false }
            if ($Cancelavel -and $Script:XmlCancelar) {
                if (-not $tarefa.IsFaulted -and -not $tarefa.IsCanceled) {
                    try { $Cmd.Cancel(); $tarefa.Result.Close() } catch {}
                }
                throw "Busca cancelada."
            }
            if ($tarefa.IsFaulted) { throw $tarefa.Exception.GetBaseException() }
            # A virgula impede o PowerShell de desenrolar o leitor linha por linha
            return , $tarefa.Result
        }

        # Quando a busca nao acha nada, registra no log o que esta conexao esta vendo:
        # banco, servidor, usuario e quantas linhas a tabela tem. Se a tabela vier vazia
        # aqui e cheia no SSMS, o programa esta olhando outro lugar - e isso o log conta.
        $conferirConexao = {
            try {
                $onde = "$((& $escalar $cn "SELECT DB_NAME() + ' | ' + CONVERT(varchar(128), @@SERVERNAME) + ' | ' + SUSER_NAME() + ' | schema ' + SCHEMA_NAME()"))"
                $totTab = "$((& $escalar $cn 'SELECT COUNT(*) FROM NFCeTokenID'))"
                $totPar = "$((& $escalar $cn ("SELECT COUNT(*) FROM NFCeTokenID WHERE IDParceiro = $([long]$parceiro)")))"
                $ultima = "$((& $escalar $cn ("SELECT CONVERT(varchar(30), MAX(COALESCE(DataEmissao, data)), 120) FROM NFCeTokenID WHERE IDParceiro = $([long]$parceiro)")))"
                Log-Message "INFO" "XMLs: conexão vê -> $onde | NFCeTokenID: $totTab linha(s) | parceiro $($parceiro): $totPar | nota mais nova: $ultima"
            }
            catch { Log-Message "ERRO" "XMLs: não consegui conferir o que a conexão está vendo: $($_.Exception.Message)" }
        }

        # Conta simples numa conexao ja aberta (usada pelo diagnostico da busca)
        $escalar = {
            param($Conexao, [string]$Sql)
            $c = $Conexao.CreateCommand()
            $c.CommandTimeout = 60
            $c.CommandText = $Sql
            return "$($c.ExecuteScalar())"
        }

        # Traduz a falha de conexao numa frase que diz o que conferir. Erro que nao
        # e de conexao (consulta, permissao) volta com a mensagem original.
        $explicaFalha = {
            param($Erro)
            $srv = "$($txtServidor.Text)".Trim()
            $sql = $Erro
            while ($null -ne $sql -and $sql -isnot [System.Data.SqlClient.SqlException]) { $sql = $sql.InnerException }
            if ($null -eq $sql) { return "$($Erro.Message)" }
            if ($sql.Number -eq 18456) { return "O SQL em $srv recusou o usuário sa com essa senha." }
            if ($sql.Number -eq 4060) { return "Conectou em $srv, mas o banco $bancoPadrao não existe nesse SQL." }
            if ($sql.Number -eq 11001) { return "Não achei o servidor ""$srv"" na rede. Confira o nome ou use o IP." }
            if (@(-1, 2, 26, 40, 53, 64, 258, 1225, 10060, 10061, 10065) -contains $sql.Number) {
                return "Não achei o SQL Server em $srv. Confira o IP, se a máquina está ligada e se o SQL aceita conexão pela rede (porta 1433)."
            }
            # 207 coluna / 208 tabela que nao existe: banco de versao antiga do NetWebPDV
            if ($sql.Number -eq 207 -or $sql.Number -eq 208) {
                return "Este banco não tem uma tabela ou coluna que essa busca usa (pode ser versão antiga do NetWebPDV): $($sql.Message)"
            }
            return "$($sql.Message)"
        }

        $carregarSeries = {
            param($Conexao, $Parceiro)
            $cmbSerie.Items.Clear(); $cmbSerie2.Items.Clear()
            $cmd = $Conexao.CreateCommand()
            $cmd.CommandTimeout = 30
            $cmd.CommandText = "SELECT DISTINCT Serie FROM NFCeTokenID WHERE IDParceiro = @p ORDER BY Serie"
            $par = $cmd.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = [long]$Parceiro
            $rd = & $executarLeitor $cmd
            if ($rd -is [System.Array]) { $rd = $rd[0] }
            while ($rd.Read()) {
                $s = "$($rd['Serie'])"
                [void]$cmbSerie.Items.Add($s)
                [void]$cmbSerie2.Items.Add($s)
            }
            $rd.Close()
            if ($cmbSerie.Items.Count -gt 0 -and "$($cmbSerie.Text)".Trim() -eq "") { $cmbSerie.SelectedIndex = 0 }
        }

        # Certificados do parceiro (IDServidorFiscal da NFCeTokenID). O filtro so aparece
        # com dois ou mais: a grande maioria dos bancos tem so o 0 e fica como sempre foi.
        # O nome sai do certificado que assinou a ultima nota autorizada de cada um.
        $carregarCertificados = {
            param($Conexao, $Parceiro)
            $Script:XmlTemServidor = $false
            $Script:XmlServidores = @()
            $Script:XmlNomeServidor = @{}
            $cmd = $Conexao.CreateCommand()
            $cmd.CommandTimeout = 30
            # Banco de versao antiga do NetWebPDV nao tem a coluna: a busca segue sem ela
            $cmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE name = 'IDServidorFiscal' AND object_id IN (OBJECT_ID('dbo.NFCeTokenID'), OBJECT_ID('dbo.NFCeTokenIDLog'))"
            $Script:XmlTemServidor = ([int]$cmd.ExecuteScalar() -eq 2)
            $cmd.CommandText = "SELECT COUNT(*) FROM sys.columns WHERE name = 'IDServidorFiscal' AND object_id = OBJECT_ID('dbo.NSUFiscal')"
            $Script:XmlNsuTemServidor = ([int]$cmd.ExecuteScalar() -eq 1)
            if ($Script:XmlTemServidor) {
                # Um certificado por volta, direto pela PK (IDParceiro, IDServidorFiscal, Serie, ID),
                # sem varrer a tabela: num banco grande o DISTINCT levaria segundos
                $cmd.CommandText = "SET NOCOUNT ON; DECLARE @s int; DECLARE @r TABLE (Servidor int); " +
                "SELECT @s = MIN(IDServidorFiscal) FROM NFCeTokenID WHERE IDParceiro = @p; " +
                "WHILE @s IS NOT NULL BEGIN INSERT INTO @r (Servidor) VALUES (@s); " +
                "SELECT @s = MIN(IDServidorFiscal) FROM NFCeTokenID WHERE IDParceiro = @p AND IDServidorFiscal > @s; END " +
                "SELECT Servidor FROM @r ORDER BY Servidor"
                $par = $cmd.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = [long]$Parceiro
                $ids = @()
                $rd = & $executarLeitor $cmd
                if ($rd -is [System.Array]) { $rd = $rd[0] }
                try { while ($rd.Read()) { $ids += [int]$rd.GetValue(0) } } finally { $rd.Close() }

                if ($ids.Count -gt 1) {
                    foreach ($idServ in $ids) {
                        $nomeServ = ""; $cnpjServ = ""; $venceServ = $null
                        try {
                            $c2 = $Conexao.CreateCommand()
                            $c2.CommandTimeout = 20
                            $c2.CommandText = "SELECT TOP 1 xmlEnvio, xmlResposta FROM NFCeTokenIDLog WHERE IDParceiro = @p AND IDServidorFiscal = @s AND CodigoRetorno = 100 ORDER BY ID DESC"
                            $par = $c2.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = [long]$Parceiro
                            $par = $c2.Parameters.Add("@s", [System.Data.SqlDbType]::Int); $par.Value = $idServ
                            $rd2 = & $executarLeitor $c2
                            if ($rd2 -is [System.Array]) { $rd2 = $rd2[0] }
                            try {
                                if ($rd2.Read()) {
                                    $cert = Get-XmlCertificadoAssinatura "$(Get-XmlDbValor $rd2 'xmlEnvio')"
                                    if ($null -eq $cert) { $cert = Get-XmlCertificadoAssinatura "$(Get-XmlDbValor $rd2 'xmlResposta')" }
                                    if ($null -ne $cert) { $nomeServ = $cert.Nome; $cnpjServ = $cert.Cnpj; $venceServ = $cert.Vence }
                                }
                            }
                            finally { $rd2.Close() }
                        }
                        catch {}
                        # Sem nota assinada: o nome do cadastro do servidor fiscal (tabela SATs)
                        if ($nomeServ -eq "" -and $idServ -gt 0) {
                            try {
                                $c3 = $Conexao.CreateCommand()
                                $c3.CommandTimeout = 20
                                $c3.CommandText = "IF OBJECT_ID('dbo.SATs') IS NOT NULL SELECT TOP 1 NomeCertificado, Nome, CNPJ FROM SATs WHERE IDParceiro = @p AND ID = @s"
                                $par = $c3.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = [long]$Parceiro
                                $par = $c3.Parameters.Add("@s", [System.Data.SqlDbType]::Int); $par.Value = $idServ
                                $rd3 = & $executarLeitor $c3
                                if ($rd3 -is [System.Array]) { $rd3 = $rd3[0] }
                                try {
                                    if ($rd3.Read()) {
                                        $nomeServ = "$(Get-XmlDbValor $rd3 'NomeCertificado')".Trim()
                                        if ($nomeServ -eq "") { $nomeServ = "$(Get-XmlDbValor $rd3 'Nome')".Trim() }
                                        $cnpjServ = "$(Get-XmlDbValor $rd3 'CNPJ')" -replace '[^0-9A-Za-z]', ''
                                    }
                                }
                                finally { $rd3.Close() }
                            }
                            catch {}
                        }
                        if ($nomeServ -eq "") {
                            if ($idServ -eq 0) { $nomeServ = "Certificado principal" } else { $nomeServ = "Certificado $idServ" }
                        }
                        $rotulo = $nomeServ
                        if ($cnpjServ.Length -eq 14) { $rotulo = $rotulo + " - " + (Format-DanfeDocumento $cnpjServ) }
                        $Script:XmlServidores += @{ Id = $idServ; Nome = $nomeServ; Cnpj = $cnpjServ; Vence = $venceServ; Rotulo = $rotulo }
                        $Script:XmlNomeServidor["$idServ"] = $nomeServ
                    }
                }
            }

            $multi = (@($Script:XmlServidores).Count -gt 1)
            $cmbCert.Items.Clear()
            if ($multi) {
                [void]$cmbCert.Items.Add("Todos os certificados")
                foreach ($sv in $Script:XmlServidores) { [void]$cmbCert.Items.Add($sv.Rotulo) }
                $cmbCert.SelectedIndex = 0
                Log-Message "INFO" ("XMLs: banco com $(@($Script:XmlServidores).Count) certificados - " + (($Script:XmlServidores | ForEach-Object { $_.Rotulo }) -join " | "))
            }
            & $mostrarLinhaCert $multi
            if ($multi) { $colCert.Width = 170 } else { $colCert.Width = 0 }
        }

        # Abre (ou fecha) a linha do Certificado embaixo do status da conexao: o cartao
        # cresce e o resto da janela desce junto. A lista perde essa altura, e a janela
        # cresce o mesmo tanto quando cabe na tela, para a lista nao ficar menor.
        $Script:XmlLinhaCert = $false
        $mostrarLinhaCert = {
            param([bool]$Mostrar)
            $lblCert.Visible = $Mostrar
            $cmbCert.Visible = $Mostrar
            if ($Script:XmlLinhaCert -eq $Mostrar) { return }
            $Script:XmlLinhaCert = $Mostrar
            $extra = 36
            if (-not $Mostrar) { $extra = -36 }
            $limite = $cardConn.Bottom
            # Em tela pequena o conteudo mora dentro do painel que rola, e nao no formulario
            $pai = $cardConn.Parent
            $f.SuspendLayout()
            try {
                $cardConn.Height = $cardConn.Height + $extra
                foreach ($ctl in @($pai.Controls)) {
                    if ($ctl -eq $cardConn -or $ctl.Top -lt $limite) { continue }
                    # Painel preso na borda (o rodape fixo das telas pequenas) se vira sozinho
                    if ("$($ctl.Dock)" -ne 'None') { continue }
                    $ancora = "$($ctl.Anchor)"
                    # O que esta preso embaixo (botoes, barra, status) fica onde esta
                    if ($ancora -notmatch 'Top') { continue }
                    $ctl.Top = $ctl.Top + $extra
                    if ($ancora -match 'Bottom') { $ctl.Height = $ctl.Height - $extra }
                }
                # A area de rolagem cresce junto, senao a lista e que perderia a altura
                if ($pai -ne $f -and $pai.AutoScroll) {
                    $pai.AutoScrollMinSize = New-Object System.Drawing.Size($pai.AutoScrollMinSize.Width, [Math]::Max(0, $pai.AutoScrollMinSize.Height + $extra))
                }
                # Em tela pequena o minimo ja foi reduzido pelo Set-JanelaAdaptavel: nao pode
                # voltar a crescer alem da tela, senao a janela trava maior que o monitor
                $areaMin = [System.Windows.Forms.Screen]::FromControl($f).WorkingArea
                $altMin = [Math]::Min($f.MinimumSize.Height + $extra, $areaMin.Height - 10)
                $minimo = New-Object System.Drawing.Size($f.MinimumSize.Width, $altMin)
                # Crescendo, a altura vai antes do minimo (senao o minimo ja esticaria a
                # janela sozinho); diminuindo, o minimo baixa antes. Na volta tira so o
                # que foi acrescentado, mesmo que a tela nao tenha deixado crescer tudo.
                $area = [System.Windows.Forms.Screen]::FromControl($f).WorkingArea
                if ($Mostrar) {
                    $Script:XmlLinhaCertCresceu = 0
                    if ($f.WindowState -eq 'Normal') {
                        $novaAltura = [Math]::Min($f.Height + $extra, $area.Height)
                        $Script:XmlLinhaCertCresceu = [Math]::Max(0, $novaAltura - $f.Height)
                        $f.Height = $novaAltura
                    }
                    $f.MinimumSize = $minimo
                }
                else {
                    $f.MinimumSize = $minimo
                    if ($f.WindowState -eq 'Normal' -and $Script:XmlLinhaCertCresceu -gt 0) { $f.Height = $f.Height - $Script:XmlLinhaCertCresceu }
                    $Script:XmlLinhaCertCresceu = 0
                }
                if ($f.WindowState -eq 'Normal' -and $f.Bottom -gt $area.Bottom) { $f.Top = [Math]::Max($area.Top, $area.Bottom - $f.Height) }
            }
            finally { $f.ResumeLayout() }
        }

        # IDServidorFiscal escolhido no filtro, ou $null para todos (e para banco com um so)
        $servidorEscolhido = {
            if (-not $cmbCert.Visible -or $cmbCert.SelectedIndex -le 0) { return $null }
            return [int]$Script:XmlServidores[$cmbCert.SelectedIndex - 1].Id
        }

        # Parametro @servidor de toda consulta: DBNull quando nao ha filtro
        $addServidor = {
            param($Cmd)
            $p = $Cmd.Parameters.Add("@servidor", [System.Data.SqlDbType]::Int)
            $sel = & $servidorEscolhido
            if ($null -eq $sel) { $p.Value = [System.DBNull]::Value } else { $p.Value = $sel }
        }

        # Faltantes separados por empresa ("ALTA ALIMENTOS LTDA: 5, 9 | NICOLETTI...: 7") para
        # o aviso e o COPIAR FALTANTES; vazio quando o banco tem um certificado so
        $faltantesPorEmpresa = {
            param($Itens)
            if (@($Script:XmlServidores).Count -le 1) { return "" }
            $partesF = @()
            foreach ($grupoF in @(@($Itens) | Group-Object { "$($_.Servidor)" } | Sort-Object Name)) {
                $numsF = @($grupoF.Group | ForEach-Object { [long]$_.Nota } | Sort-Object -Unique)
                if ($numsF.Count -eq 0) { continue }
                $partesF += "$(& $nomeEmpresa $grupoF.Group[0].Servidor): $(ConvertTo-FaixaTexto $numsF)"
            }
            return ($partesF -join " | ")
        }

        # Nome curto da empresa de um IDServidorFiscal (vazio quando o banco tem um so)
        $nomeEmpresa = {
            param($Servidor)
            if (@($Script:XmlServidores).Count -le 1 -or $null -eq $Servidor) { return "" }
            $n = $Script:XmlNomeServidor["$Servidor"]
            if ($null -eq $n) { return "Certificado $Servidor" }
            return $n
        }

        $testar = {
            # -Auto e a tentativa unica feita ao abrir a janela: timeout curto para
            # nao deixar a tela presa quando a maquina nao tem SQL instalado.
            param([switch]$Auto)
            # A janela responde enquanto conecta: sem essa trava, um segundo clique
            # abriria outra conexao por cima da primeira
            if ($Script:XmlOcupado) { return }
            $Script:XmlOcupado = $true
            $cn = $null
            try {
                $btnTestar.Enabled = $false
                $lblConn.ForeColor = $Script:UiAmarelo
                $srvTexto = "$($txtServidor.Text)".Trim()
                if ($srvTexto -eq "") { $srvTexto = "127.0.0.1" }
                $lblConn.Text = "Conectando em $srvTexto..."

                if ($Auto) { $cn = & $abrirConexao 3 $lblConn } else { $cn = & $abrirConexao 5 $lblConn }

                $cmd = $cn.CreateCommand()
                $cmd.CommandTimeout = 30
                $cmd.CommandText = "SELECT @@VERSION AS versao, DB_NAME() AS banco"
                $rd = & $executarLeitor $cmd
                if ($rd -is [System.Array]) { $rd = $rd[0] }
                $versao = ""; $banco = ""
                if ($rd.Read()) {
                    $versao = ("$($rd['versao'])" -split "`n")[0].Trim()
                    $banco = "$($rd['banco'])"
                }
                $rd.Close()

                $cmd2 = $cn.CreateCommand()
                $cmd2.CommandTimeout = 30
                $cmd2.CommandText = "SELECT IDParceiro, COUNT(*) AS notas FROM NFCeTokenID GROUP BY IDParceiro ORDER BY notas DESC"
                $rd2 = & $executarLeitor $cmd2
                if ($rd2 -is [System.Array]) { $rd2 = $rd2[0] }
                $cmbParceiro.Items.Clear()
                while ($rd2.Read()) { [void]$cmbParceiro.Items.Add("$($rd2['IDParceiro'])") }
                $rd2.Close()

                if ($cmbParceiro.Items.Count -eq 0) {
                    $lblConn.ForeColor = $Script:UiAmarelo
                    $lblConn.Text = "Conectado em $banco ($versao), mas a tabela NFCeTokenID está vazia."
                    Log-Message "INFO" "XMLs: conectado em $banco sem notas na NFCeTokenID"
                    return
                }
                $cmbParceiro.SelectedIndex = 0
                & $carregarSeries $cn ("$($cmbParceiro.Text)".Trim())
                try { & $carregarCertificados $cn ("$($cmbParceiro.Text)".Trim()) }
                catch { Log-Message "INFO" "XMLs: não deu para ler os certificados do banco - $($_.Exception.Message)" }

                $lblConn.ForeColor = $Script:UiVerde
                if (@($Script:XmlServidores).Count -gt 1) {
                    # Linha dividida com o filtro de certificado: sem a versao do SQL, que ja foi para o log
                    $lblConn.Text = "OK - banco: $banco | séries: $($cmbSerie.Items.Count) | $(@($Script:XmlServidores).Count) certificados"
                    Log-Message "INFO" "XMLs: $versao"
                }
                else { $lblConn.Text = "OK - $versao | banco: $banco | parceiros: $($cmbParceiro.Items.Count) | séries: $($cmbSerie.Items.Count)" }
                Log-Message "SUCESSO" "XMLs: conectado em $($txtServidor.Text) / $banco"

                # Lembra o servidor para a proxima abertura. Grava direto em UTF-8, sem
                # passar pelo Out-File: com a codificacao errada o arquivo voltava como
                # caractere estranho e a proxima abertura tentava conectar nesse lixo.
                try {
                    $srvGravar = "$($txtServidor.Text)".Trim()
                    if ($srvGravar -match '^[A-Za-z0-9._\\,\-]{1,80}$') {
                        [System.IO.File]::WriteAllText($Script:XmlArqServidor, $srvGravar, (New-Object System.Text.UTF8Encoding($false)))
                    }
                }
                catch {}
            }
            catch {
                $msg = $_.Exception.Message
                $amigavel = & $explicaFalha $_.Exception
                $lblConn.ForeColor = $Script:UiVermelho
                if ($Auto) {
                    $lblConn.Text = "Não conectou sozinho. $amigavel"
                    Log-Message "INFO" "XMLs: conexão automática não respondeu - $msg"
                }
                else {
                    $lblConn.Text = $amigavel
                    Log-Message "ERRO" "XMLs: falha de conexão - $msg"
                }
            }
            finally {
                if ($null -ne $cn) { try { $cn.Close() } catch {} }
                $btnTestar.Enabled = $true
                $Script:XmlOcupado = $false
            }
        }

        # ---------------------------------------------------------------------
        # SQL
        # A log so tem indice por ID, entao ela e varrida uma vez por bloco e
        # deduplicada com ROW_NUMBER (preferindo a autorizada, CodigoRetorno 100).
        # ---------------------------------------------------------------------
        # Com mais de um certificado a mesma serie e o mesmo numero existem uma vez por
        # IDServidorFiscal (a PK e IDParceiro + IDServidorFiscal + Serie + ID): a nota e o
        # XML so se ligam certo com ele. Sem a coluna (banco antigo) fica a ligacao de antes.
        # Devolve hashtable: CteLogs / Colunas / Juncao / FiltroT / FiltroG
        $sqlBase = {
            $servG = ""; $servT = ""; $servJ = ""; $fT = ""; $fG = ""
            if ($Script:XmlTemServidor) {
                $servG = "g.IDServidorFiscal, "
                $servT = "t.IDServidorFiscal, "
                $servJ = "AND l.IDServidorFiscal = t.IDServidorFiscal "
                $fT = " AND (@servidor IS NULL OR t.IDServidorFiscal = @servidor)"
                $fG = " AND (@servidor IS NULL OR g.IDServidorFiscal = @servidor)"
            }
            return @{
                CteLogs = "SELECT g.IDParceiro, " + $servG + "g.SerieTokenID, g.IDTokenID, g.Chave, g.nProtocolo, " +
                "g.CodigoRetorno, g.DataEmissao AS LogDataEmissao, g.xmlEnvio, g.xmlResposta, " +
                "g.xmlCancelamento, g.xmlRespostaCancelamento, g.DataEmissaoCancelamento, " +
                "g.ChaveCancelamento, ROW_NUMBER() OVER (PARTITION BY " +
                "g.IDParceiro, " + $servG + "g.SerieTokenID, g.IDTokenID ORDER BY " +
                "CASE WHEN g.CodigoRetorno = 100 THEN 0 ELSE 1 END, " +
                "CASE WHEN g.xmlResposta IS NULL THEN 1 ELSE 0 END, g.ID DESC) AS rn FROM NFCeTokenIDLog g"
                Colunas = $servT + "t.Serie, t.ID, t.Usada, t.Inutilizada, t.Erro, t.Ignorada, t.OFFLine, " +
                "t.DataEmissao, t.data, t.xmlEnvioOff, t.XmlInutilizada, t.MotivoInutilizada, " +
                "l.Chave, l.nProtocolo, l.CodigoRetorno, l.LogDataEmissao, l.xmlEnvio, l.xmlResposta, " +
                "l.xmlCancelamento, l.xmlRespostaCancelamento, l.DataEmissaoCancelamento, l.ChaveCancelamento"
                Juncao = "FROM NFCeTokenID t LEFT JOIN logs l ON l.IDParceiro = t.IDParceiro " +
                "AND l.SerieTokenID = t.Serie AND l.IDTokenID = t.ID " + $servJ + "AND l.rn = 1"
                FiltroT = $fT
                FiltroG = $fG
            }
        }

        # Transforma uma linha do reader no registro usado pela lista e pelo download.
        # A situacao sai so dos dados, nunca do "Tipo de nota": o filtro e aplicado
        # depois, na tela, e trocar a opcao nao pode mudar o que a nota e.
        $lerLinha = {
            param($rd, [bool]$MontarProc, [bool]$IncluirCanc)

            $dataE = Get-XmlDbValor $rd "DataEmissao"
            if ($null -eq $dataE) { $dataE = Get-XmlDbValor $rd "LogDataEmissao" }
            if ($null -eq $dataE) { $dataE = Get-XmlDbValor $rd "data" }

            $item = @{
                Nota = [long](Get-XmlDbValor $rd "ID"); Serie = [int](Get-XmlDbValor $rd "Serie")
                Data = $dataE; Chave = ""; Status = "NÃO ENCONTRADA"; Origem = ""
                Conteudo = ""; Arquivo = ""; Tamanho = 0; Aviso = ""; Inutilizada = $false
                Codigo = Get-XmlDbValor $rd "CodigoRetorno"; Cancelamento = ""; ChaveCanc = ""
                Cancelada = $false; DataCancelamento = $null; Linha = $null
                Pedido = Get-XmlDbValor $rd "Pedido"; Valor = $null
                # Certificado que emitiu (null em banco sem a coluna)
                Servidor = Get-XmlDbValor $rd "IDServidorFiscal"
            }

            # Linha veio sem numero: o banco devolveu algo que nao da para ler. Registra
            # uma vez os nomes das colunas, que e o que diz onde a leitura se perdeu.
            if ($null -eq $item.Nota -or [long]$item.Nota -le 0) {
                if (-not $Script:XmlAvisouColunas) {
                    $Script:XmlAvisouColunas = $true
                    $cols = @()
                    try { for ($k = 0; $k -lt $rd.FieldCount; $k++) { $cols += $rd.GetName($k) } } catch {}
                    $tipoRd = "?"
                    try { $tipoRd = "$($rd.GetType().FullName)" } catch {}
                    $testeDireto = "?"
                    try { $testeDireto = "GetOrdinal(ID) = $($rd.GetOrdinal('ID'))" } catch { $testeDireto = "GetOrdinal(ID) falhou: $($_.Exception.Message)" }
                    Log-Message "ERRO" ("XMLs: linha sem número de nota. Leitor: $tipoRd | $testeDireto | " + @($cols).Count + " coluna(s): " + ($cols -join ', '))
                }
            }

            $xEnvio = Get-XmlDbValor $rd "xmlEnvio"
            $xResp = Get-XmlDbValor $rd "xmlResposta"
            $xOff = Get-XmlDbValor $rd "xmlEnvioOff"
            $xInut = Get-XmlDbValor $rd "XmlInutilizada"
            $chaveLog = "$(Get-XmlDbValor $rd 'Chave')".Trim()

            $flagInut = Get-XmlDbValor $rd "Inutilizada"
            $temNormal = ($null -ne $xResp -or $null -ne $xEnvio -or $null -ne $xOff)
            $temInut = ($null -ne $xInut -or ($null -ne $flagInut -and [bool]$flagInut))

            # Inutilizada ganha da normal: o numero inutilizado quase sempre deixa no
            # log a tentativa de envio que falhou, e essa tentativa nunca teve
            # protocolo - era ela que fazia a inutilizada aparecer como SEM PROTOCOLO.
            if ($temInut) {
                $item.Status = "INUTILIZADA"
                $item.Inutilizada = $true
                $r = Resolve-XmlNfe -XmlEnvio "$xInut" -XmlResposta ""
                if ($null -ne $xInut -and $r.Ok) {
                    $item.Conteudo = $r.Conteudo
                    $item.Origem = "XmlInutilizada"
                    $item.Chave = $r.Chave
                }
                else { $item.Aviso = "inutilizada, mas o XML da inutilização não ficou no banco" }
            }
            elseif ($temNormal) {
                $fonte = $xEnvio
                if ($null -eq $fonte) { $fonte = $xOff }
                $r = Resolve-XmlNfe -XmlEnvio "$fonte" -XmlResposta "$xResp" -MontarProc:$MontarProc
                if ($r.Ok) {
                    $item.Conteudo = $r.Conteudo
                    $item.Status = "AUTORIZADA"
                    $item.Aviso = $r.Aviso
                    if ($r.Forma -eq "nfeProc") { $item.Origem = "xmlResposta" }
                    elseif ($r.Forma -eq "nfeProc montado") { $item.Origem = "xmlEnvio+protNFe" }
                    elseif ($null -eq $xEnvio -and $null -ne $xOff) { $item.Origem = "xmlEnvioOff" }
                    else { $item.Origem = "xmlEnvio" }
                    if ($chaveLog -ne "") { $item.Chave = $chaveLog } else { $item.Chave = $r.Chave }
                    if ($r.Aviso -eq "SEM PROTOCOLO") {
                        $item.Status = "SEM PROTOCOLO"
                        # O motivo (rejeicao, denegacao) aparece no balao da linha
                        if ("$($r.Motivo)" -ne "") { $item.Aviso = $r.Motivo }
                    }
                }
            }

            # Nas outras buscas o pedido sai das informacoes complementares do XML
            # ("Pedido: 73432"), que e o numero impresso no cupom
            if ($null -eq $item.Pedido -and -not $item.Inutilizada -and $item.Conteudo -ne "") {
                $achouPedido = [regex]::Match($item.Conteudo, '<infCpl>[^<]*?\bPedido\s*:\s*(\d+)')
                if ($achouPedido.Success) { $item.Pedido = [long]$achouPedido.Groups[1].Value }
            }
            # Valor total da nota (vNF), para separar pedidos repetidos pelo valor
            if (-not $item.Inutilizada -and $item.Conteudo -ne "") {
                $achouValor = [regex]::Match($item.Conteudo, '<vNF>([0-9.]+)</vNF>')
                $valorNota = [decimal]0
                if ($achouValor.Success -and [decimal]::TryParse($achouValor.Groups[1].Value, [System.Globalization.NumberStyles]::Number, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$valorNota)) {
                    $item.Valor = $valorNota
                }
            }

            # Numero inutilizado nunca foi autorizado, entao nao tem o que cancelar
            if ($IncluirCanc -and -not $item.Inutilizada) {
                # Mesma logica da nota: o documento util e a RESPOSTA da SEFAZ.
                # xmlRespostaCancelamento traz o procEventoNFe autorizado, enquanto
                # xmlCancelamento (so o envio) costuma vir nulo neste banco.
                # DataEmissaoCancelamento sozinha ja prova que a nota foi cancelada.
                $dataCanc = Get-XmlDbValor $rd "DataEmissaoCancelamento"
                $fonteCanc = Get-XmlDbValor $rd "xmlRespostaCancelamento"
                if ($null -eq $fonteCanc -or "$fonteCanc".Trim() -eq "") {
                    $fonteCanc = Get-XmlDbValor $rd "xmlCancelamento"
                }
                if ($null -ne $fonteCanc -and "$fonteCanc".Trim() -ne "") {
                    # Mesmo tratamento da nota: acentos consertados e declaracao UTF-8
                    $item.Cancelamento = ConvertTo-XmlArquivo "$fonteCanc"
                    $item.ChaveCanc = "$(Get-XmlDbValor $rd 'ChaveCancelamento')".Trim()
                    $item.Cancelada = $true
                }
                elseif ($null -ne $dataCanc) {
                    # Cancelada, mas o XML do evento nao ficou guardado
                    $item.Cancelada = $true
                    $item.Aviso = "cancelada sem XML do evento"
                }
                if ($null -ne $dataCanc) { $item.DataCancelamento = $dataCanc }
            }
            return $item
        }

        # Le todas as linhas de uma consulta para a lista, com a janela respondendo
        # enquanto chegam. Devolve quantas linhas vieram.
        $lerParaLista = {
            param($Cmd, $Lista)
            $rd = & $executarLeitor $Cmd -Cancelavel
            if ($rd -is [System.Array]) { $rd = $rd[0] }
            $n = 0
            try {
                while ($rd.Read()) {
                    $Lista.Add((& $lerLinha $rd $true $true))
                    $n++
                    if ($n % 50 -eq 0) {
                        [System.Windows.Forms.Application]::DoEvents()
                        # Cancel antes do Close: sem ele o Close ainda baixaria o resto
                        if ($Script:XmlCancelar) { try { $Cmd.Cancel() } catch {}; throw "Busca cancelada." }
                    }
                }
            }
            finally { $rd.Close() }
            return $n
        }

        $pintaLinha = {
            param($Item)
            $lvi = New-Object System.Windows.Forms.ListViewItem("$($Item.Nota)")
            [void]$lvi.SubItems.Add("$($Item.Serie)")
            $dt = ""
            if ($null -ne $Item.Data) { try { $dt = ([datetime]$Item.Data).ToString("dd/MM/yyyy HH:mm") } catch { $dt = "$($Item.Data)" } }
            [void]$lvi.SubItems.Add($dt)

            # Situacao escrita na coluna: uma nota cancelada continua autorizada,
            # mas o que importa ver na lista e que ela foi cancelada.
            $sit = $Item.Status
            if ([bool]$Item.Cancelada) { $sit = "CANCELADA" }
            [void]$lvi.SubItems.Add($sit)

            [void]$lvi.SubItems.Add($Item.Chave)
            $tam = ""
            if ($Item.Tamanho -gt 0) { $tam = "{0:N0} B" -f $Item.Tamanho }
            [void]$lvi.SubItems.Add($tam)
            [void]$lvi.SubItems.Add($Item.Arquivo)
            [void]$lvi.SubItems.Add("$($Item.Pedido)")
            $valorTxt = ""
            if ($null -ne $Item.Valor) { $valorTxt = ([decimal]$Item.Valor).ToString("#,##0.00", [System.Globalization.CultureInfo]::GetCultureInfo("pt-BR")) }
            [void]$lvi.SubItems.Add($valorTxt)
            [void]$lvi.SubItems.Add((& $nomeEmpresa $Item.Servidor))

            # verde = valida | amarelo = atencao | vermelho = nao vale | cinza = nao existe
            if ($sit -eq "CANCELADA") { $lvi.ForeColor = $Script:UiVermelho }
            elseif ($sit -eq "AUTORIZADA") { $lvi.ForeColor = $Script:UiVerde }
            elseif ($sit -eq "INUTILIZADA" -or $sit -eq "SEM PROTOCOLO") { $lvi.ForeColor = $Script:UiAmarelo }
            elseif ($sit -eq "CORROMPIDO" -or $sit -eq "ERRO") { $lvi.ForeColor = $Script:UiVermelho }
            else { $lvi.ForeColor = $Script:UiSuave }

            $dica = $Item.Status
            if ("$($Item.Origem)" -ne "") { $dica = $dica + " - origem: $($Item.Origem)" }
            if ("$($Item.Aviso)" -ne "" -and $Item.Aviso -ne $Item.Status) { $dica = $dica + " - $($Item.Aviso)" }
            if ([bool]$Item.Cancelada) {
                $dica = $dica + " - CANCELADA"
                if ($null -ne $Item.DataCancelamento) {
                    try { $dica = $dica + " em " + ([datetime]$Item.DataCancelamento).ToString("dd/MM/yyyy HH:mm") } catch {}
                }
            }
            $lvi.ToolTipText = $dica
            # Linha nova entra desmarcada; ao reordenar ou filtrar volta como estava
            if ($Item.ContainsKey('Marcado')) { $lvi.Checked = [bool]$Item.Marcado }
            else { $lvi.Checked = $false }
            $lvi.Tag = $Item
            $Item.Linha = $lvi
            [void]$lv.Items.Add($lvi)
        }

        $mostraCarregando = {
            param([string]$Texto)
            if ($Texto -eq "") { $lblCarregando.Visible = $false }
            else {
                $lblCarregando.Text = $Texto
                $lblCarregando.Visible = $true
                $lblCarregando.BringToFront()
            }
            [System.Windows.Forms.Application]::DoEvents()
        }

        # O "Tipo de nota" vale como filtro da tela tambem: depois de buscar tudo
        # da para trocar a opcao e ver so o que interessa, sem voltar ao banco.
        $filtraTipo = {
            param($Item)
            $idx = $cmbTipo.SelectedIndex
            # Sem protocolo nao e autorizada: fica fora de "Somente autorizadas"
            if ($idx -eq 1) { return ($Item.Status -eq "AUTORIZADA") }
            if ($idx -eq 2) { return ($Item.Status -eq "INUTILIZADA") }
            if ($idx -eq 3) { return ([bool]$Item.Cancelada) }
            return $true
        }

        # Contador "2 de 291 marcadas" e o texto do botao ao lado do filtro.
        # Com alguma marcada o botao oferece limpar; com nenhuma, marcar de volta.
        $atualizaMarcadas = {
            $total = $lv.Items.Count
            if ($total -eq 0) {
                $lblMarcadas.Text = ""
                $btnMarcar.Text = "MARCAR TODAS"
                $btnMarcar.Enabled = $false
                return
            }
            $marc = $lv.CheckedItems.Count
            if ($marc -eq 1) { $lblMarcadas.Text = "1 de $total marcada" }
            else { $lblMarcadas.Text = "$marc de $total marcadas" }
            if ($marc -eq 0) { $lblMarcadas.ForeColor = $Script:UiSuave } else { $lblMarcadas.ForeColor = $Script:UiVerde }
            if ($marc -gt 0) { $btnMarcar.Text = "DESMARCAR TODAS" } else { $btnMarcar.Text = "MARCAR TODAS" }
            $btnMarcar.Enabled = $true
        }

        # Marca ou desmarca a lista inteira de uma vez. Marcar pega so as que tem
        # XML, igual a busca faz: nota sem XML marcada so geraria aviso no fim.
        $marcarTodas = {
            param([bool]$Marcar)
            # Cada Checked dispararia o ItemChecked: o evento sai enquanto marca
            # e o contador e refeito uma vez so no fim
            $lv.remove_ItemChecked($aoMarcarLinha)
            $lv.BeginUpdate()
            try {
                foreach ($lvi in $lv.Items) {
                    if ($Marcar) { $lvi.Checked = ($null -ne $lvi.Tag -and "$($lvi.Tag.Conteudo)" -ne "") }
                    else { $lvi.Checked = $false }
                }
            }
            finally {
                $lv.EndUpdate()
                $lv.add_ItemChecked($aoMarcarLinha)
            }
            & $atualizaMarcadas
        }

        $repintaLista = {
            # Reaplica ordem e filtro sobre o resultado da ultima busca
            foreach ($lvi in $lv.Items) { if ($null -ne $lvi.Tag) { $lvi.Tag.Marcado = $lvi.Checked } }
            $vis = @($Script:XmlResultados | Where-Object { & $filtraTipo $_ })
            # Item que entra ja marcado tambem dispara o ItemChecked: com o evento
            # ligado, 5000 linhas recontariam a lista inteira 5000 vezes
            $lv.remove_ItemChecked($aoMarcarLinha)
            $lv.BeginUpdate()
            try {
                $lv.Items.Clear()
                foreach ($a in $vis) { & $pintaLinha $a }
            }
            finally {
                $lv.EndUpdate()
                $lv.add_ItemChecked($aoMarcarLinha)
            }
            & $atualizaMarcadas
            return $vis.Count
        }

        # Chaves digitadas: 44 posicoes, sem repetir, ignorando pontos, espacos e o
        # "NFe" da frente. Com o CNPJ alfanumerico a chave pode ter letras nas 12
        # primeiras posicoes do CNPJ, entao so numeros deixaria essas notas de fora.
        $lerChaves = {
            return @(("$($txtChaves.Text)" -replace '[;\r\n]', ',') -split ',' |
                ForEach-Object { (($_ -replace '[^0-9A-Za-z]', '').ToUpper() -replace '^NFE(?=.{44}$)', '') } |
                Where-Object { $_ -match '^\d{6}[0-9A-Z]{12}\d{26}$' } | Select-Object -Unique)
        }

        # O que define a busca por pedido: os numeros e, se marcado, o dia. Serve
        # para o ESPELHO FISCAL saber se a lista ja e dessa busca.
        $textoPedido = {
            $txtP = "$($txtPedidos.Text)".Trim()
            if ($chkDiaPedido.Checked) { $txtP = $txtP + "|" + $dtPedido.Value.ToString("yyyy-MM-dd") }
            return $txtP
        }

        $buscar = {
            if ($Script:XmlOcupado) { return $false }
            $Script:XmlOcupado = $true
            $cn = $null
            try {
                $lv.Items.Clear()
                & $atualizaMarcadas
                $Script:XmlResultados = @()
                $Script:XmlPedidas = @()
                $Script:XmlFaltantes = @()
                $Script:XmlFaltantesTexto = ""
                $pb.Value = 0
                $lblProg.Text = ""

                if ($cmbParceiro.Items.Count -eq 0 -or "$($cmbParceiro.Text)".Trim() -eq "") {
                    & $setStatus "Clique em TESTAR CONEXÃO antes de buscar." $Script:UiVermelho
                    return $false
                }
                $parceiro = [long]("$($cmbParceiro.Text)".Trim())
                # Lista em vez de "+=": somar num array copia tudo a cada nota, e
                # num periodo de 20 mil notas isso sozinho levava minutos
                $achados = New-Object 'System.Collections.Generic.List[object]'

                # A busca agora pode ser interrompida pelo CANCELAR
                $Script:XmlCancelar = $false
                $btnCancelar.Enabled = $true
                & $setStatus "Consultando o banco..." $Script:UiAmarelo
                & $mostraCarregando "Consultando o banco..."
                $cn = & $abrirConexao

                $sb = & $sqlBase
                $cteLogs = $sb.CteLogs; $colunas = $sb.Colunas; $juncao = $sb.Juncao
                # Certificados que esta busca cobre: com o filtro, so o escolhido; em Todos, cada
                # um. Banco com um certificado so conta como um ($null), igual era antes.
                $multiEmp = (@($Script:XmlServidores).Count -gt 1)
                $servSel = & $servidorEscolhido
                if (-not $multiEmp) { $Script:XmlServidoresBusca = @($null) }
                elseif ($null -eq $servSel) { $Script:XmlServidoresBusca = @($Script:XmlServidores | ForEach-Object { $_.Id }) }
                else { $Script:XmlServidoresBusca = @($servSel) }

                if ($rbSerie.Checked) {
                    if ("$($cmbSerie.Text)".Trim() -eq "") {
                        & $setStatus "Escolha a série." $Script:UiVermelho; return $false
                    }
                    $serie = [int]("$($cmbSerie.Text)".Trim())
                    $fx = ConvertFrom-FaixaNotas -Texto $txtNotas.Text -Confirmar
                    if (-not $fx.Ok) { & $setStatus $fx.Erro $Script:UiVermelho; return $false }
                    $Script:XmlPedidas = $fx.Notas

                    # Blocos de no maximo 500 numeros por query
                    for ($ini = 0; $ini -lt $fx.Notas.Count; $ini += 500) {
                        $fim = [Math]::Min($ini + 499, $fx.Notas.Count - 1)
                        $bloco = @($fx.Notas[$ini..$fim])
                        $nomes = @()
                        for ($i = 0; $i -lt $bloco.Count; $i++) { $nomes += "@n$i" }
                        $inSql = ($nomes -join ",")

                        $sql = ";WITH logs AS (" + $cteLogs + " WHERE g.IDParceiro = @parceiro " +
                        "AND g.SerieTokenID = @serie AND g.IDTokenID IN ($inSql)" + $sb.FiltroG + ") SELECT " + $colunas +
                        " " + $juncao + " WHERE t.IDParceiro = @parceiro AND t.Serie = @serie " +
                        "AND t.ID IN ($inSql)" + $sb.FiltroT + " ORDER BY t.ID"

                        $cmd = $cn.CreateCommand()
                        $cmd.CommandTimeout = 120
                        $cmd.CommandText = $sql
                        $par = $cmd.Parameters.Add("@parceiro", [System.Data.SqlDbType]::BigInt); $par.Value = $parceiro
                        $par = $cmd.Parameters.Add("@serie", [System.Data.SqlDbType]::Int); $par.Value = $serie
                        & $addServidor $cmd
                        for ($i = 0; $i -lt $bloco.Count; $i++) {
                            $par = $cmd.Parameters.Add("@n$i", [System.Data.SqlDbType]::BigInt)
                            $par.Value = [long]$bloco[$i]
                        }
                        $lidasBloco = & $lerParaLista $cmd $achados
                        Log-Message "INFO" "XMLs: série $serie, parceiro $parceiro - pedi $($bloco.Count) número(s) e o banco devolveu $lidasBloco linha(s)"

                        # Plano B: a consulta de cima usa CTE com ROW_NUMBER, e ja apareceu
                        # cliente com SQL antigo (2008 R2) em que ela volta vazia mesmo com a
                        # nota gravada. Aqui vai a versao simples, sem CTE: o log de cada nota
                        # sai por subconsulta. Se esta achar, a busca continua funcionando e o
                        # motivo fica registrado no log.
                        if ($lidasBloco -eq 0) {
                            $colB = $colunas.Replace("l.LogDataEmissao", "l.DataEmissao AS LogDataEmissao")
                            $servJoinB = ""
                            $servSubB = ""
                            if ($Script:XmlTemServidor) {
                                $servJoinB = "AND l.IDServidorFiscal = t.IDServidorFiscal "
                                $servSubB = "AND g2.IDServidorFiscal = t.IDServidorFiscal "
                            }
                            $sqlB = "SELECT " + $colB + " FROM NFCeTokenID t LEFT JOIN NFCeTokenIDLog l " +
                            "ON l.IDParceiro = t.IDParceiro AND l.SerieTokenID = t.Serie AND l.IDTokenID = t.ID " + $servJoinB +
                            "AND l.ID = (SELECT TOP 1 g2.ID FROM NFCeTokenIDLog g2 WHERE g2.IDParceiro = t.IDParceiro " +
                            "AND g2.SerieTokenID = t.Serie AND g2.IDTokenID = t.ID " + $servSubB +
                            "ORDER BY CASE WHEN g2.CodigoRetorno = 100 THEN 0 ELSE 1 END, " +
                            "CASE WHEN g2.xmlResposta IS NULL THEN 1 ELSE 0 END, g2.ID DESC) " +
                            "WHERE t.IDParceiro = @parceiro AND t.Serie = @serie AND t.ID IN ($inSql)" + $sb.FiltroT + " ORDER BY t.ID"

                            $cmdB = $cn.CreateCommand()
                            $cmdB.CommandTimeout = 120
                            $cmdB.CommandText = $sqlB
                            $par = $cmdB.Parameters.Add("@parceiro", [System.Data.SqlDbType]::BigInt); $par.Value = $parceiro
                            $par = $cmdB.Parameters.Add("@serie", [System.Data.SqlDbType]::Int); $par.Value = $serie
                            & $addServidor $cmdB
                            for ($i = 0; $i -lt $bloco.Count; $i++) {
                                $par = $cmdB.Parameters.Add("@n$i", [System.Data.SqlDbType]::BigInt)
                                $par.Value = [long]$bloco[$i]
                            }
                            $lidasB = & $lerParaLista $cmdB $achados
                            if ($lidasB -gt 0) {
                                Log-Message "SUCESSO" "XMLs: a consulta simples achou $lidasB nota(s) que a consulta principal não trouxe (banco antigo)"
                            }
                            else {
                                Log-Message "INFO" "XMLs: a consulta simples também não achou essas notas neste parceiro e série"
                            }

                            # Terceira tentativa: os numeros vao escritos no proprio comando,
                            # sem parametro nenhum. Em maquina antiga (PowerShell 4 com SQL
                            # 2008 R2) ja apareceu caso de a nota existir e o filtro por
                            # parametro nao casar. Sao todos numeros inteiros conferidos
                            # antes ([long]/[int]), entao nao ha risco de injecao.
                            if ($lidasB -eq 0) {
                                $listaLiteral = (@($bloco | ForEach-Object { [long]$_ }) -join ',')
                                $filtroServLit = ""
                                if ($Script:XmlTemServidor -and $null -ne $servSel) { $filtroServLit = " AND t.IDServidorFiscal = $([int]$servSel)" }
                                $sqlC = "SELECT " + $colB + " FROM NFCeTokenID t LEFT JOIN NFCeTokenIDLog l " +
                                "ON l.IDParceiro = t.IDParceiro AND l.SerieTokenID = t.Serie AND l.IDTokenID = t.ID " + $servJoinB +
                                "AND l.ID = (SELECT TOP 1 g2.ID FROM NFCeTokenIDLog g2 WHERE g2.IDParceiro = t.IDParceiro " +
                                "AND g2.SerieTokenID = t.Serie AND g2.IDTokenID = t.ID " + $servSubB +
                                "ORDER BY CASE WHEN g2.CodigoRetorno = 100 THEN 0 ELSE 1 END, " +
                                "CASE WHEN g2.xmlResposta IS NULL THEN 1 ELSE 0 END, g2.ID DESC) " +
                                "WHERE t.IDParceiro = $([long]$parceiro) AND t.Serie = $([int]$serie) " +
                                "AND t.ID IN ($listaLiteral)" + $filtroServLit + " ORDER BY t.ID"

                                $cmdC = $cn.CreateCommand()
                                $cmdC.CommandTimeout = 120
                                $cmdC.CommandText = $sqlC
                                $lidasC = & $lerParaLista $cmdC $achados
                                if ($lidasC -gt 0) {
                                    Log-Message "SUCESSO" "XMLs: a consulta sem parâmetros achou $lidasC nota(s) - neste PC o filtro por parâmetro não estava casando"
                                }
                                else {
                                    # Conta onde cada filtro derruba, para o log dizer o motivo
                                    try {
                                        $qtdSo = "$((& $escalar $cn ("SELECT COUNT(*) FROM NFCeTokenID WHERE ID IN ($listaLiteral)")))"
                                        $qtdPar = "$((& $escalar $cn ("SELECT COUNT(*) FROM NFCeTokenID WHERE ID IN ($listaLiteral) AND IDParceiro = $([long]$parceiro)")))"
                                        $qtdSer = "$((& $escalar $cn ("SELECT COUNT(*) FROM NFCeTokenID WHERE ID IN ($listaLiteral) AND IDParceiro = $([long]$parceiro) AND Serie = $([int]$serie)")))"
                                        Log-Message "ERRO" "XMLs: nem sem parâmetros achou. Só pelo número: $qtdSo | + parceiro $($parceiro): $qtdPar | + série $($serie): $qtdSer"
                                    }
                                    catch { Log-Message "ERRO" "XMLs: não consegui conferir os filtros: $($_.Exception.Message)" }
                                }
                            }
                        }
                        & $setStatus "Consultando... $($achados.Count) notas lidas" $Script:UiAmarelo
                    }

                    # Linha sem numero de nota nao existe na NFCeTokenID (a chave primaria
                    # e IDParceiro + Serie + ID): se aparecer, e lixo de leitura e vai fora,
                    # senao o tecnico ve uma "nota 0" fantasma na lista.
                    $fantasmas = @($achados | Where-Object { $null -eq $_.Nota -or [long]$_.Nota -le 0 })
                    if ($fantasmas.Count -gt 0) {
                        Log-Message "ERRO" "XMLs: o banco devolveu $($fantasmas.Count) linha(s) sem número de nota; foram descartadas"
                        $sobraram = @($achados | Where-Object { $null -ne $_.Nota -and [long]$_.Nota -gt 0 })
                        $achados = New-Object 'System.Collections.Generic.List[object]'
                        foreach ($a in $sobraram) { $achados.Add($a) }
                    }

                    # Nada veio do banco: em vez de so dizer "não encontrada", procura os
                    # mesmos números sem o filtro de parceiro e de série. Quase sempre é o
                    # Parceiro ou a Série da tela que não batem com o que está no banco.
                    $Script:XmlDicaBusca = ""
                    if ($achados.Count -eq 0) {
                        try {
                            $amostra = @($fx.Notas | Select-Object -First 50)
                            $nomesD = @(); for ($i = 0; $i -lt $amostra.Count; $i++) { $nomesD += "@d$i" }
                            $cmdD = $cn.CreateCommand()
                            $cmdD.CommandTimeout = 60
                            $cmdD.CommandText = "SELECT TOP 10 IDParceiro, Serie, qtd = COUNT(*) FROM NFCeTokenID " +
                            "WHERE ID IN ($($nomesD -join ',')) GROUP BY IDParceiro, Serie ORDER BY COUNT(*) DESC"
                            for ($i = 0; $i -lt $amostra.Count; $i++) {
                                $p = $cmdD.Parameters.Add("@d$i", [System.Data.SqlDbType]::BigInt); $p.Value = [long]$amostra[$i]
                            }
                            $onde = @()
                            $rdD = & $executarLeitor $cmdD
                            if ($rdD -is [System.Array]) { $rdD = $rdD[0] }
                            try { while ($rdD.Read()) { $onde += "parceiro $($rdD.GetValue(0)), série $($rdD.GetValue(1)): $($rdD.GetValue(2)) nota(s)" } }
                            finally { $rdD.Close() }
                            if ($onde.Count -gt 0) {
                                $Script:XmlDicaBusca = "Esses números existem no banco, mas em outro lugar - " + ($onde -join " | ") + ". Ajuste o Parceiro e a Série aqui em cima."
                            }
                            else {
                                $Script:XmlDicaBusca = "Esses números não existem na tabela NFCeTokenID deste banco, em nenhum parceiro ou série."
                            }
                            Log-Message "INFO" "XMLs: busca sem resultado (parceiro $parceiro, série $serie). $($Script:XmlDicaBusca)"
                        }
                        catch { Log-Message "ERRO" "XMLs: não consegui conferir onde estão essas notas: $($_.Exception.Message)" }
                        & $conferirConexao
                    }

                    # Numero pedido que nem linha tem na tabela de numeracao. Com mais de um
                    # certificado confere em cada empresa: a nota 100 de uma nao tampa a falta da outra.
                    $vistos = @{}
                    foreach ($a in $achados) {
                        if ($multiEmp) { $vistos["$($a.Servidor)|$($a.Nota)"] = $true } else { $vistos["$($a.Nota)"] = $true }
                    }
                    foreach ($servBusca in $Script:XmlServidoresBusca) {
                        foreach ($n in $fx.Notas) {
                            $chaveVisto = "$n"
                            if ($multiEmp) { $chaveVisto = "$servBusca|$n" }
                            if (-not $vistos.ContainsKey($chaveVisto)) {
                                $achados.Add(@{
                                        Nota = [long]$n; Serie = $serie; Data = $null; Chave = ""
                                        Status = "NÃO ENCONTRADA"; Origem = ""; Conteudo = ""; Arquivo = ""
                                        Tamanho = 0; Aviso = "sem registro na NFCeTokenID"; Inutilizada = $false
                                        Codigo = $null; Cancelamento = ""; ChaveCanc = ""
                                        Cancelada = $false; DataCancelamento = $null; Linha = $null
                                        Servidor = $servBusca
                                    })
                            }
                        }
                    }
                    $achados = @($achados | Sort-Object { [long]$_.Nota }, { "$($_.Servidor)" })
                }
                elseif ($rbPeriodo.Checked) {
                    $d1 = $dtIni.Value.Date
                    $d2 = $dtFim.Value.Date.AddDays(1)
                    if ($d2 -le $d1) { & $setStatus "A data final não pode ser anterior à inicial." $Script:UiVermelho; return $false }
                    $serieOpc = "$($cmbSerie2.Text)".Trim()

                    $filtroPeriodo = "t.IDParceiro = @parceiro AND (@serie IS NULL OR t.Serie = @serie) " +
                    "AND COALESCE(t.DataEmissao, t.data) >= @d1 AND COALESCE(t.DataEmissao, t.data) < @d2" + $sb.FiltroT
                    $novoCmdPeriodo = {
                        param([string]$Sql)
                        $c = $cn.CreateCommand()
                        $c.CommandTimeout = 300
                        $c.CommandText = $Sql
                        $p = $c.Parameters.Add("@parceiro", [System.Data.SqlDbType]::BigInt); $p.Value = $parceiro
                        $p = $c.Parameters.Add("@serie", [System.Data.SqlDbType]::Int)
                        if ($serieOpc -eq "") { $p.Value = [System.DBNull]::Value } else { $p.Value = [int]$serieOpc }
                        $p = $c.Parameters.Add("@d1", [System.Data.SqlDbType]::DateTime); $p.Value = $d1
                        $p = $c.Parameters.Add("@d2", [System.Data.SqlDbType]::DateTime); $p.Value = $d2
                        & $addServidor $c
                        return $c
                    }

                    # Conta antes de buscar. Antes havia um TOP (5000) calado: um mes de
                    # supermercado vinha cortado e a tela dizia que estava tudo certo.
                    $rdTotal = & $executarLeitor (& $novoCmdPeriodo ("SELECT COUNT(*) FROM NFCeTokenID t WHERE " + $filtroPeriodo)) -Cancelavel
                    if ($rdTotal -is [System.Array]) { $rdTotal = $rdTotal[0] }
                    $totalPeriodo = 0
                    try { if ($rdTotal.Read()) { $totalPeriodo = [int]$rdTotal.GetValue(0) } }
                    finally { $rdTotal.Close() }

                    # Nao veio nada: refaz a conta com os valores escritos no proprio
                    # comando. Em maquina antiga (PowerShell 4 com SQL 2008 R2) o filtro por
                    # parametro ja deixou de casar; se a conta literal trouxer notas, a busca
                    # inteira passa a usar essa forma. Sao datas e numeros conferidos aqui.
                    if ($totalPeriodo -eq 0) {
                        $filtroLit = "t.IDParceiro = $([long]$parceiro) " +
                        $(if ($serieOpc -eq "") { "" } else { "AND t.Serie = $([int]$serieOpc) " }) +
                        "AND COALESCE(t.DataEmissao, t.data) >= CONVERT(datetime, '$($d1.ToString('yyyy-MM-dd HH:mm:ss'))', 120) " +
                        "AND COALESCE(t.DataEmissao, t.data) < CONVERT(datetime, '$($d2.ToString('yyyy-MM-dd HH:mm:ss'))', 120)" +
                        $(if ($Script:XmlTemServidor -and $null -ne $servSel) { " AND t.IDServidorFiscal = $([int]$servSel)" } else { "" })
                        $totalLit = 0
                        try { $totalLit = [int]"$((& $escalar $cn ("SELECT COUNT(*) FROM NFCeTokenID t WHERE " + $filtroLit)))" } catch {}
                        Log-Message "INFO" "XMLs: período $($d1.ToString('dd/MM/yyyy')) a $($dtFim.Value.ToString('dd/MM/yyyy')), parceiro $parceiro - com parâmetros: 0 nota(s), sem parâmetros: $totalLit nota(s)"
                        if ($totalLit -gt 0) {
                            Log-Message "SUCESSO" "XMLs: período sem resultado com parâmetros; a consulta sem parâmetros achou $totalLit nota(s) - a busca vai usar essa forma"
                            $filtroPeriodo = $filtroLit
                            $totalPeriodo = $totalLit
                        }
                        else { & $conferirConexao }
                    }

                    if ($totalPeriodo -gt 10000) {
                        & $mostraCarregando ""
                        $resp = [System.Windows.Forms.MessageBox]::Show(
                            "O período tem $totalPeriodo notas.`r`n`r`nBuscar todas pode levar alguns minutos e usar bastante memória. Se não precisar de tudo, diminua o período ou escolha a série.`r`n`r`nDeseja buscar as $totalPeriodo notas?",
                            "Baixar XMLs NFC-e", "YesNo", "Warning")
                        if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) {
                            & $setStatus "Busca cancelada: o período tem $totalPeriodo notas." $Script:UiAmarelo
                            return $false
                        }
                    }

                    # Paginas de 5000 por (Serie, ID): ate 5000 notas continua sendo uma
                    # consulta so, igual antes; acima disso vem tudo, pagina a pagina
                    $pagina = 5000
                    $ultSerie = -1; $ultId = [long]-1; $ultServ = [int]::MinValue
                    # Com o certificado na PK a pagina anda por (IDServidorFiscal, Serie, ID): sem ele a
                    # nota de mesmo numero da outra empresa podia ficar de fora entre duas paginas
                    $ordemPagina = " AND (t.Serie > @ultSerie OR (t.Serie = @ultSerie AND t.ID > @ultId)) ORDER BY t.Serie, t.ID"
                    if ($Script:XmlTemServidor) {
                        $ordemPagina = " AND (t.IDServidorFiscal > @ultServ OR (t.IDServidorFiscal = @ultServ AND " +
                        "(t.Serie > @ultSerie OR (t.Serie = @ultSerie AND t.ID > @ultId)))) ORDER BY t.IDServidorFiscal, t.Serie, t.ID"
                    }
                    do {
                        $texto = "Consultando o banco... $($achados.Count) de $totalPeriodo notas"
                        & $setStatus $texto $Script:UiAmarelo
                        & $mostraCarregando $texto

                        $sql = ";WITH logs AS (" + $cteLogs + " WHERE g.IDParceiro = @parceiro " +
                        "AND (@serie IS NULL OR g.SerieTokenID = @serie)" + $sb.FiltroG + ") SELECT TOP (@pagina) " + $colunas +
                        " " + $juncao + " WHERE " + $filtroPeriodo + $ordemPagina
                        $cmd = & $novoCmdPeriodo $sql
                        $par = $cmd.Parameters.Add("@pagina", [System.Data.SqlDbType]::Int); $par.Value = $pagina
                        $par = $cmd.Parameters.Add("@ultSerie", [System.Data.SqlDbType]::Int); $par.Value = $ultSerie
                        $par = $cmd.Parameters.Add("@ultId", [System.Data.SqlDbType]::BigInt); $par.Value = $ultId
                        $par = $cmd.Parameters.Add("@ultServ", [System.Data.SqlDbType]::Int); $par.Value = $ultServ

                        $veio = & $lerParaLista $cmd $achados
                        if ($veio -gt 0) {
                            $ultimo = $achados[$achados.Count - 1]
                            $ultSerie = [int]$ultimo.Serie
                            $ultId = [long]$ultimo.Nota
                            if ($null -ne $ultimo.Servidor) { $ultServ = [int]$ultimo.Servidor }
                        }
                    } while ($veio -eq $pagina)
                }
                elseif ($rbPedido.Checked) {
                    $fxP = ConvertFrom-FaixaNotas -Texto $txtPedidos.Text -Confirmar
                    if (-not $fxP.Ok) { & $setStatus ("Pedidos: " + $fxP.Erro) $Script:UiVermelho; return $false }
                    $Script:XmlPedidosBuscados = @($fxP.Notas)
                    $Script:XmlPedidoDia = $null
                    if ($chkDiaPedido.Checked) { $Script:XmlPedidoDia = $dtPedido.Value.Date }

                    # Pedido -> NSUFiscal (tipoDoc 2 = NFC-e, com serie e numero) -> nota.
                    # Pedido de venda nao fiscal nao tem NSU de NFC-e e fica de fora.
                    # O numero do pedido zera por dia em muitos clientes (a chave da
                    # tabela Pedidos inclui o GUID): o mesmo numero traz uma nota por
                    # dia, da mais recente para a mais antiga. Com "No dia" vale o dia
                    # do caixa (DataCaixa), que segura a venda depois da meia-noite no
                    # dia em que o caixa abriu.
                    for ($ini = 0; $ini -lt $fxP.Notas.Count; $ini += 500) {
                        $fim = [Math]::Min($ini + 499, $fxP.Notas.Count - 1)
                        $bloco = @($fxP.Notas[$ini..$fim])
                        $nomes = @()
                        for ($i = 0; $i -lt $bloco.Count; $i++) { $nomes += "@n$i" }
                        $inSql = ($nomes -join ",")

                        $sql = ";WITH peds AS (SELECT DISTINCT p.IDParceiro, p.ID AS Pedido, n.Serie AS PSerie, n.NumeroNota AS PNota " +
                        "FROM Pedidos p JOIN NSUFiscal n ON n.IDParceiro = p.IDParceiro AND n.ID = p.IDNSUFiscal AND n.tipoDoc = 2 " +
                        "WHERE p.IDParceiro = @parceiro AND p.ID IN ($inSql) AND (@dia IS NULL OR p.DataCaixa = @dia " +
                        "OR (p.DataCaixa IS NULL AND p.Data >= @dia AND p.Data < DATEADD(day, 1, @dia)))), logs AS (" + $cteLogs + " WHERE g.IDParceiro = @parceiro " +
                        "AND EXISTS (SELECT 1 FROM peds pd WHERE pd.PSerie = g.SerieTokenID AND pd.PNota = g.IDTokenID)) " +
                        "SELECT " + $colunas + ", pd.Pedido " + $juncao + " JOIN peds pd ON pd.IDParceiro = t.IDParceiro " +
                        "AND pd.PSerie = t.Serie AND pd.PNota = t.ID ORDER BY pd.Pedido, COALESCE(t.DataEmissao, t.data) DESC"
                        if ($Script:XmlTemServidor) {
                            # Mesma serie e numero nas duas empresas: vale a nota cuja chave e a da venda
                            # (a NSUFiscal as vezes grava o certificado errado); sem chave, o certificado da
                            # NSUFiscal. Uma nota por venda, e o filtro de certificado por cima.
                            $servNsu = "CAST(NULL AS int)"
                            if ($Script:XmlNsuTemServidor) { $servNsu = "n.IDServidorFiscal" }
                            $sql = ";WITH peds AS (SELECT DISTINCT p.IDParceiro, p.ID AS Pedido, n.Serie AS PSerie, n.NumeroNota AS PNota, " +
                            "$servNsu AS PServ, RIGHT(ISNULL(n.Chave, ''), 44) AS PChave " +
                            "FROM Pedidos p JOIN NSUFiscal n ON n.IDParceiro = p.IDParceiro AND n.ID = p.IDNSUFiscal AND n.tipoDoc = 2 " +
                            "WHERE p.IDParceiro = @parceiro AND p.ID IN ($inSql) AND (@dia IS NULL OR p.DataCaixa = @dia " +
                            "OR (p.DataCaixa IS NULL AND p.Data >= @dia AND p.Data < DATEADD(day, 1, @dia)))), logs AS (" + $cteLogs + " WHERE g.IDParceiro = @parceiro " +
                            "AND EXISTS (SELECT 1 FROM peds pd WHERE pd.PSerie = g.SerieTokenID AND pd.PNota = g.IDTokenID)), " +
                            "cand AS (SELECT " + $colunas + ", pd.Pedido, " +
                            "CASE WHEN LEN(pd.PChave) = 44 AND RIGHT(ISNULL(l.Chave, ''), 44) = pd.PChave THEN 0 " +
                            "WHEN pd.PServ IS NULL OR t.IDServidorFiscal = pd.PServ THEN 1 ELSE 2 END AS PrefServ, " +
                            "ROW_NUMBER() OVER (PARTITION BY pd.Pedido, pd.PSerie, pd.PNota, pd.PChave, pd.PServ ORDER BY " +
                            "CASE WHEN LEN(pd.PChave) = 44 AND RIGHT(ISNULL(l.Chave, ''), 44) = pd.PChave THEN 0 " +
                            "WHEN pd.PServ IS NULL OR t.IDServidorFiscal = pd.PServ THEN 1 ELSE 2 END, t.IDServidorFiscal) AS RnServ " +
                            $juncao + " JOIN peds pd ON pd.IDParceiro = t.IDParceiro AND pd.PSerie = t.Serie AND pd.PNota = t.ID) " +
                            "SELECT c.* FROM cand c WHERE c.RnServ = 1 AND c.PrefServ < 2 AND (@servidor IS NULL OR c.IDServidorFiscal = @servidor) " +
                            "ORDER BY c.Pedido, COALESCE(c.DataEmissao, c.data) DESC"
                        }

                        $cmd = $cn.CreateCommand()
                        $cmd.CommandTimeout = 120
                        $cmd.CommandText = $sql
                        & $addServidor $cmd
                        $par = $cmd.Parameters.Add("@parceiro", [System.Data.SqlDbType]::BigInt); $par.Value = $parceiro
                        $par = $cmd.Parameters.Add("@dia", [System.Data.SqlDbType]::DateTime)
                        if ($null -eq $Script:XmlPedidoDia) { $par.Value = [System.DBNull]::Value } else { $par.Value = $Script:XmlPedidoDia }
                        for ($i = 0; $i -lt $bloco.Count; $i++) {
                            $par = $cmd.Parameters.Add("@n$i", [System.Data.SqlDbType]::BigInt)
                            $par.Value = [long]$bloco[$i]
                        }
                        [void](& $lerParaLista $cmd $achados)
                        & $setStatus "Consultando... $($achados.Count) notas lidas" $Script:UiAmarelo
                    }
                }
                else {
                    $chaves = @(& $lerChaves)
                    if ($chaves.Count -eq 0) {
                        & $setStatus "Informe ao menos uma chave de acesso válida (44 posições)." $Script:UiVermelho
                        return $false
                    }

                    # A chave ja diz de qual empresa e a nota: aqui o filtro de certificado nao entra,
                    # so a ligacao com a nota do certificado certo
                    $serv3 = ""; $servCol3 = ""; $servJun3 = ""
                    if ($Script:XmlTemServidor) {
                        $serv3 = "g.IDServidorFiscal, "
                        $servCol3 = "COALESCE(t.IDServidorFiscal, l.IDServidorFiscal) AS IDServidorFiscal, "
                        $servJun3 = " AND t.IDServidorFiscal = l.IDServidorFiscal"
                    }
                    $cte3 = "SELECT g.IDParceiro, " + $serv3 + "g.SerieTokenID, g.IDTokenID, g.Chave, g.nProtocolo, " +
                    "g.CodigoRetorno, g.DataEmissao AS LogDataEmissao, g.xmlEnvio, g.xmlResposta, " +
                    "g.xmlCancelamento, g.xmlRespostaCancelamento, g.DataEmissaoCancelamento, " +
                    "g.ChaveCancelamento, ROW_NUMBER() OVER (PARTITION BY g.Chave " +
                    "ORDER BY CASE WHEN g.CodigoRetorno = 100 THEN 0 ELSE 1 END, g.ID DESC) AS rn " +
                    "FROM NFCeTokenIDLog g"
                    $cols3 = $servCol3 + "COALESCE(t.Serie, l.SerieTokenID) AS Serie, COALESCE(t.ID, l.IDTokenID) AS ID, " +
                    "t.Usada, t.Inutilizada, t.Erro, t.Ignorada, t.OFFLine, t.DataEmissao, t.data, " +
                    "t.xmlEnvioOff, t.XmlInutilizada, t.MotivoInutilizada, l.Chave, l.nProtocolo, " +
                    "l.CodigoRetorno, l.LogDataEmissao, l.xmlEnvio, l.xmlResposta, l.xmlCancelamento, " +
                    "l.xmlRespostaCancelamento, l.DataEmissaoCancelamento, l.ChaveCancelamento"

                    for ($ini = 0; $ini -lt $chaves.Count; $ini += 500) {
                        $fim = [Math]::Min($ini + 499, $chaves.Count - 1)
                        $bloco = @($chaves[$ini..$fim])
                        $nomes = @()
                        for ($i = 0; $i -lt $bloco.Count; $i++) { $nomes += "@k$i" }
                        $inSql = ($nomes -join ",")

                        $sql = ";WITH logs AS (" + $cte3 + " WHERE RIGHT(g.Chave, 44) IN ($inSql)) SELECT " +
                        $cols3 + " FROM logs l LEFT JOIN NFCeTokenID t ON t.IDParceiro = l.IDParceiro " +
                        "AND t.Serie = l.SerieTokenID AND t.ID = l.IDTokenID" + $servJun3 + " WHERE l.rn = 1 ORDER BY l.Chave"

                        $cmd = $cn.CreateCommand()
                        $cmd.CommandTimeout = 120
                        $cmd.CommandText = $sql
                        for ($i = 0; $i -lt $bloco.Count; $i++) {
                            $par = $cmd.Parameters.Add("@k$i", [System.Data.SqlDbType]::VarChar, 44)
                            $par.Value = [string]$bloco[$i]
                        }
                        [void](& $lerParaLista $cmd $achados)
                    }
                }

                # Guarda o filtro desta busca: o nome do lote sai dele, mesmo que a tela
                # seja mexida antes de baixar
                if ($rbSerie.Checked) { $Script:XmlFiltro = @{ Modo = 'Serie'; Serie = "$($cmbSerie.Text)".Trim(); Notas = @($Script:XmlPedidas) } }
                elseif ($rbPeriodo.Checked) { $Script:XmlFiltro = @{ Modo = 'Periodo'; Serie = "$($cmbSerie2.Text)".Trim(); De = $dtIni.Value; Ate = $dtFim.Value } }
                elseif ($rbPedido.Checked) { $Script:XmlFiltro = @{ Modo = 'Pedido'; Serie = ''; Pedidos = @($Script:XmlPedidosBuscados); Dia = $Script:XmlPedidoDia; Texto = (& $textoPedido) } }
                else { $Script:XmlFiltro = @{ Modo = 'Chave'; Serie = ''; Texto = ((@(& $lerChaves) | Sort-Object) -join ',') } }

                # @() sobre uma List[object] quebra no PowerShell 5.1 ("Os tipos de
                # argumento nao correspondem"): vira array uma vez, aqui
                if ($achados -isnot [array]) { $achados = $achados.ToArray() }

                # Vale para todos os modos: linha sem numero de nota nao existe na
                # NFCeTokenID (a chave e IDParceiro + Serie + ID). Se sobrar alguma,
                # e leitura que deu errado - fora da lista, e registrada no log.
                $comNumero = @($achados | Where-Object { $null -ne $_.Nota -and [long]$_.Nota -gt 0 })
                if ($comNumero.Count -ne @($achados).Count) {
                    Log-Message "ERRO" "XMLs: $(@($achados).Count - $comNumero.Count) linha(s) sem número de nota foram descartadas da lista"
                    $achados = $comNumero
                }
                $Script:XmlResultados = @($achados)
                & $mostraCarregando ""
                $visiveis = & $repintaLista

                $semXmlAgora = @($achados | Where-Object { "$($_.Conteudo)" -eq "" } | ForEach-Object { [int]$_.Nota })
                $nOk = $achados.Count - $semXmlAgora.Count

                # Ja deixa os faltantes prontos: o COPIAR FALTANTES tem que funcionar
                # logo depois da busca, sem depender de clicar em CONFERIR SEQUENCIA
                $Script:XmlFaltantes = $semXmlAgora
                $Script:XmlFaltantesTexto = & $faltantesPorEmpresa @($achados | Where-Object { "$($_.Conteudo)" -eq "" })

                # Pedido sem NFC-e (venda nao fiscal, numero errado, outra loja): vai
                # para o aviso e para o COPIAR FALTANTES, que no modo pedido copia pedidos
                $pedidosSemNfce = @()
                if ($rbPedido.Checked) {
                    $comNota = @{}
                    foreach ($a in $achados) { if ($null -ne $a.Pedido) { $comNota["$($a.Pedido)"] = $true } }
                    $pedidosSemNfce = @($Script:XmlPedidosBuscados | Where-Object { -not $comNota.ContainsKey("$_") })
                    $Script:XmlFaltantes = @($pedidosSemNfce)
                    $Script:XmlFaltantesTexto = ""
                }

                if ($achados.Count -eq 0) {
                    & $setStatus "Nada encontrado para esse filtro." $Script:UiAmarelo
                    Log-Message "INFO" "XMLs: busca não encontrou nenhuma nota"
                    $avisoNada = "Nada encontrado para esse filtro.`r`n`r`nConfira a série, os números e o período informados."
                    if ($rbPedido.Checked) {
                        $noDia = ""
                        if ($null -ne $Script:XmlPedidoDia) { $noDia = " no dia " + $Script:XmlPedidoDia.ToString("dd/MM/yyyy") }
                        $avisoNada = "Nenhum desses pedidos tem NFC-e no banco$($noDia): " + (ConvertTo-FaixaTexto $Script:XmlPedidosBuscados) +
                        "`r`n`r`nPode ser venda não fiscal, pedido de outra loja (confira o Parceiro), outro dia ou número digitado errado."
                    }
                    [System.Windows.Forms.MessageBox]::Show($avisoNada, "Baixar XMLs NFC-e", "OK", "Information") | Out-Null
                }
                elseif ($pedidosSemNfce.Count -gt 0) {
                    $noDia = ""
                    if ($null -ne $Script:XmlPedidoDia) { $noDia = " no dia " + $Script:XmlPedidoDia.ToString("dd/MM/yyyy") }
                    & $setStatus ("$($achados.Count) nota(s) encontrada(s). Pedidos sem NFC-e$($noDia) (venda não fiscal ou número errado): " + (ConvertTo-FaixaTexto $pedidosSemNfce)) $Script:UiAmarelo
                }
                elseif ($visiveis -eq 0) {
                    & $setStatus "$($achados.Count) nota(s) encontrada(s), mas nenhuma se encaixa em ""$($cmbTipo.Text)""." $Script:UiAmarelo
                }
                elseif ($nOk -eq 0) {
                    # Avisa na hora, sem esperar o usuario clicar em BAIXAR a toa
                    $txtSem = ConvertTo-FaixaTexto $semXmlAgora
                    if ("$($Script:XmlFaltantesTexto)" -ne "") { $txtSem = $Script:XmlFaltantesTexto }
                    # Com a dica do diagnostico (parceiro/série errados, por exemplo), ela
                    # vale mais que a lista de números: e o que o técnico precisa fazer
                    if ("$($Script:XmlDicaBusca)" -ne "") {
                        & $setStatus $Script:XmlDicaBusca $Script:UiVermelho
                        [System.Windows.Forms.MessageBox]::Show($Script:XmlDicaBusca, "Baixar XMLs NFC-e", "OK", "Warning") | Out-Null
                    }
                    else { & $setStatus ("Nenhuma das $($achados.Count) notas tem XML no banco - " + $txtSem) $Script:UiVermelho }
                }
                elseif ($semXmlAgora.Count -gt 0) {
                    $txtSem = ConvertTo-FaixaTexto $semXmlAgora
                    if ("$($Script:XmlFaltantesTexto)" -ne "") { $txtSem = $Script:XmlFaltantesTexto }
                    & $setStatus ("$($achados.Count) linha(s): $nOk com XML. Sem XML: " + $txtSem) $Script:UiAmarelo
                }
                else {
                    & $setStatus "$($achados.Count) linha(s), todas com XML. Marque as que quer e clique em BAIXAR SELECIONADOS, ou BAIXAR TUDO." $Script:UiVerde
                }
                Log-Message "INFO" "XMLs: busca retornou $($achados.Count) linha(s), $nOk com XML"
                & $atualizaModo
                return $true
            }
            catch {
                $msg = $_.Exception.Message
                if ($Script:XmlCancelar) {
                    & $setStatus "Busca cancelada." $Script:UiAmarelo
                    Log-Message "CANCEL" "XMLs: busca cancelada pelo usuário"
                }
                else {
                    & $setStatus ("Erro na consulta: " + (& $explicaFalha $_.Exception)) $Script:UiVermelho
                    Log-Message "ERRO" "XMLs: falha na consulta - $msg"
                }
                return $false
            }
            finally {
                & $mostraCarregando ""
                if ($null -ne $cn) { try { $cn.Close() } catch {} }
                $btnCancelar.Enabled = $false
                $Script:XmlOcupado = $false
            }
        }

        # Nome do lote pelo filtro da ULTIMA BUSCA (guardado no $buscar), e nao pelo
        # que esta na tela na hora de baixar: mexer na tela entre buscar e baixar
        # fazia uma busca por periodo sair com o nome "Série 5" da caixa de serie.
        # Sem serie escolhida, entram as series das notas que vao ser gravadas.
        # -Empresa: banco com mais de um certificado, cada empresa sai no seu lote
        $nomeDoLote = {
            param($ItensLote, [string]$Titulo = "XML NFC-e", [string]$Empresa = "")
            $filtro = $Script:XmlFiltro
            if ($null -eq $filtro) { $filtro = @{ Modo = 'Chave'; Serie = '' } }
            $seriesLote = @($ItensLote | ForEach-Object { [int]$_.Serie } | Sort-Object -Unique)
            if ($filtro.Modo -eq 'Serie') {
                return (Get-XmlNomeLote -Modo Serie -Serie $filtro.Serie -Notas $filtro.Notas -Titulo $Titulo -Empresa $Empresa)
            }
            if ($filtro.Modo -eq 'Periodo') {
                return (Get-XmlNomeLote -Modo Periodo -Serie $filtro.Serie -Series $seriesLote -De $filtro.De -Ate $filtro.Ate -Titulo $Titulo -Empresa $Empresa)
            }
            if ($filtro.Modo -eq 'Pedido') {
                # Os pedidos que vao no lote, e nao todos os digitados: pedido sem NFC-e nao entra
                $pedidosLote = @($ItensLote | Where-Object { $null -ne $_.Pedido } | ForEach-Object { [int]$_.Pedido })
                if ($pedidosLote.Count -eq 0) { $pedidosLote = @($filtro.Pedidos) }
                if ($null -ne $filtro.Dia) {
                    return (Get-XmlNomeLote -Modo Pedido -Series $seriesLote -Notas $pedidosLote -Titulo $Titulo -De $filtro.Dia -Empresa $Empresa)
                }
                return (Get-XmlNomeLote -Modo Pedido -Series $seriesLote -Notas $pedidosLote -Titulo $Titulo -Empresa $Empresa)
            }
            return (Get-XmlNomeLote -Modo Chave -Series $seriesLote -Quantidade @($ItensLote).Count -Titulo $Titulo -Empresa $Empresa)
        }

        $baixar = {
            param($Itens)
            $lista = @($Itens)
            if ($lista.Count -eq 0) {
                & $setStatus "Nada para baixar: marque ao menos uma linha." $Script:UiAmarelo
                return
            }

            # Separa antes de criar qualquer coisa: nota sem XML no banco nao gera
            # arquivo, entao nao vale abrir pasta nem zip por causa dela.
            $comXml = @($lista | Where-Object { "$($_.Conteudo)" -ne "" })
            $semXml = @($lista | Where-Object { "$($_.Conteudo)" -eq "" })
            $faltaram = @($semXml | ForEach-Object { [int]$_.Nota })

            if ($comXml.Count -eq 0) {
                # Nenhuma tem XML: avisa e sai sem criar pasta e sem gerar zip
                $Script:XmlFaltantes = $faltaram
                & $atualizaModo
                $aviso = "Nenhuma das $($lista.Count) notas selecionadas tem XML no banco."
                if ($faltaram.Count -gt 0) { $aviso = $aviso + "`r`n`r`nSem XML: " + (ConvertTo-FaixaTexto $faltaram) }
                $aviso = $aviso + "`r`n`r`nNada foi baixado e nenhuma pasta foi criada."
                & $setStatus "Nenhuma das notas tem XML no banco - nada foi gravado." $Script:UiVermelho
                Log-Message "ERRO" "XMLs: nenhuma das $($lista.Count) notas tem XML no banco"
                [System.Windows.Forms.MessageBox]::Show($aviso, "Baixar XMLs NFC-e", "OK", "Warning") | Out-Null
                return
            }

            $Script:XmlCancelar = $false
            $btnCancelar.Enabled = $true
            $pb.Maximum = $comXml.Count
            $pb.Value = 0
            $Script:XmlUltimoZip = ""

            # Banco com mais de um certificado: um lote (pasta + zip) por empresa, com o nome
            # dela. Cada empresa costuma ter o seu contador e os arquivos de mesma serie e
            # numero nao se misturam. Com um certificado so e um lote, como sempre foi.
            $grupos = New-Object 'System.Collections.Generic.List[object]'
            if (@($Script:XmlServidores).Count -gt 1) {
                foreach ($grupoEmp in @($comXml | Group-Object { "$($_.Servidor)" } | Sort-Object Name)) {
                    $grupos.Add(@{ Empresa = (& $nomeEmpresa $grupoEmp.Group[0].Servidor); Itens = @($grupoEmp.Group) })
                }
            }
            else { $grupos.Add(@{ Empresa = ""; Itens = $comXml }) }

            $nNormal = 0; $nInut = 0; $nCorr = 0; $nCanc = 0; $nSemProt = 0
            $nFalta = $semXml.Count
            $baixadas = @()
            $baixadasPorServ = @{}
            $pastasLote = @()
            $zipsLote = @()
            $i = 0
            $interrompido = $false

            foreach ($grupo in $grupos) {
                if ($interrompido) { break }
                $pasta = New-XmlLotePasta (& $nomeDoLote $grupo.Itens "XML NFC-e" $grupo.Empresa)
                $pastasLote += $pasta
                $Script:XmlUltimoLote = $pasta
                $pastaInut = Join-Path $pasta "Inutilizadas"
                $pastaCanc = Join-Path $pasta "Cancelamentos"
                # Nota sem protocolo fica separada: a pasta principal e so do que vale
                $pastaSemProt = Join-Path $pasta "Sem protocolo"

                foreach ($it in $grupo.Itens) {
                    $i++
                    if ($Script:XmlCancelar) {
                        $interrompido = $true
                        Log-Message "CANCEL" "XMLs: lote interrompido em $i de $($comXml.Count)"
                        break
                    }
                    $lblProg.Text = "Baixando $i de $($comXml.Count)..."
                    $pb.Value = $i

                    try {
                        # XML que nao parseia ainda e gravado, so que marcado
                        $corrompido = $false
                        try { $null = [xml]$it.Conteudo } catch { $corrompido = $true }
                        if ($corrompido) { $nCorr++ }

                        # serie + numero + chave, e no fim _INUT / _CANC / _CORROMPIDO
                        $nomes = Get-XmlNomeArquivo -Item $it -Corrompido:$corrompido

                        # Guardado antes: o Status pode virar CORROMPIDO logo abaixo
                        $semProt = ("$($it.Status)" -eq "SEM PROTOCOLO")
                        $destino = $pasta
                        if ($it.Inutilizada) { $destino = $pastaInut }
                        elseif ($semProt) { $destino = $pastaSemProt }
                        if (-not (Test-Path $destino)) { New-Item -Path $destino -ItemType Directory -Force | Out-Null }

                        $caminho = Join-Path $destino ($nomes.Nota + ".xml")
                        [System.IO.File]::WriteAllText($caminho, $it.Conteudo, (New-Object System.Text.UTF8Encoding($false)))
                        $it.Arquivo = $nomes.Nota + ".xml"
                        $it.Caminho = $caminho
                        $it.Tamanho = (Get-Item -LiteralPath $caminho).Length
                        if ($corrompido) { $it.Status = "CORROMPIDO" }
                        if ($it.Inutilizada) { $nInut++ }
                        elseif ($semProt) { $nSemProt++ }
                        else { $nNormal++ }
                        $baixadas += [int]$it.Nota
                        if (-not $baixadasPorServ.ContainsKey("$($it.Servidor)")) { $baixadasPorServ["$($it.Servidor)"] = @{} }
                        $baixadasPorServ["$($it.Servidor)"]["$($it.Nota)"] = $true

                        if ("$($it.Cancelamento)" -ne "") {
                            if (-not (Test-Path $pastaCanc)) { New-Item -Path $pastaCanc -ItemType Directory -Force | Out-Null }
                            $nomeC = $nomes.Evento + ".xml"
                            [System.IO.File]::WriteAllText((Join-Path $pastaCanc $nomeC), $it.Cancelamento, (New-Object System.Text.UTF8Encoding($false)))
                            $nCanc++
                        }
                    }
                    catch {
                        $nFalta++
                        $it.Status = "ERRO"
                        $it.Aviso = $_.Exception.Message
                        Log-Message "ERRO" "XMLs: falha ao gravar a nota $($it.Nota) - $($_.Exception.Message)"
                    }

                    if ($null -ne $it.Linha -and -not $lv.IsDisposed) {
                        if ($it.Tamanho -gt 0) { $it.Linha.SubItems[5].Text = "{0:N0} B" -f $it.Tamanho }
                        $it.Linha.SubItems[6].Text = $it.Arquivo
                        # A situacao so muda quando a gravacao deu problema
                        if ($it.Status -eq "CORROMPIDO" -or $it.Status -eq "ERRO") {
                            $it.Linha.SubItems[3].Text = $it.Status
                            $it.Linha.ForeColor = $Script:UiVermelho
                            $it.Linha.ToolTipText = "$($it.Status) - $($it.Aviso)"
                        }
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                }

                # A pasta fica so com os XMLs: o resumo do lote vai para o log e para a
                # janela, e os faltantes saem pelo botao COPIAR FALTANTES.

                # Zip sempre ao final, mesmo com o lote interrompido
                try {
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    $zip = $pasta + ".zip"
                    if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                    [System.IO.Compression.ZipFile]::CreateFromDirectory($pasta, $zip)
                    $Script:XmlUltimoZip = $zip
                    $zipsLote += $zip
                    Log-Message "ZIP" "XMLs: pasta compactada em $zip"
                }
                catch {
                    Log-Message "ERRO" "XMLs: falha ao gerar o zip - $($_.Exception.Message). A pasta continua disponível."
                }
            }

            # Faltantes: so faz sentido no modo por serie, onde existe lista pedida. Com mais
            # de um certificado, confere a lista pedida em cada empresa buscada.
            $Script:XmlFaltantes = @()
            $Script:XmlFaltantesTexto = ""
            if ($rbSerie.Checked -and $Script:XmlPedidas.Count -gt 0) {
                if (@($Script:XmlServidores).Count -gt 1) {
                    $todasFaltas = @(); $partesFalta = @()
                    foreach ($servF in @($Script:XmlServidoresBusca)) {
                        $veioServ = $baixadasPorServ["$servF"]
                        if ($null -eq $veioServ) { $veioServ = @{} }
                        $faltaServ = @($Script:XmlPedidas | Where-Object { -not $veioServ.ContainsKey("$_") })
                        if ($faltaServ.Count -gt 0) {
                            $todasFaltas += $faltaServ
                            $partesFalta += "$(& $nomeEmpresa $servF): $(ConvertTo-FaixaTexto $faltaServ)"
                        }
                    }
                    $Script:XmlFaltantes = @($todasFaltas | Sort-Object -Unique)
                    $Script:XmlFaltantesTexto = ($partesFalta -join " | ")
                }
                else {
                    $veio = @{}
                    foreach ($n in $baixadas) { $veio["$n"] = $true }
                    $Script:XmlFaltantes = @($Script:XmlPedidas | Where-Object { -not $veio.ContainsKey("$_") })
                }
            }
            else {
                $Script:XmlFaltantes = $faltaram
                $Script:XmlFaltantesTexto = & $faltantesPorEmpresa $semXml
            }

            $btnCancelar.Enabled = $false
            $lblProg.Text = ""
            $pb.Value = 0
            & $atualizaModo

            $pedidas = $lista.Count
            if ($rbSerie.Checked -and $Script:XmlPedidas.Count -gt 0) { $pedidas = $Script:XmlPedidas.Count }
            $resumo = "$pedidas pedidas | $nNormal autorizadas | $nInut inutilizadas | $nFalta não encontradas"
            if ($nSemProt -gt 0) { $resumo = $resumo + " | $nSemProt sem protocolo" }
            if ($nCanc -gt 0) { $resumo = $resumo + " | $nCanc com cancelamento" }
            if ($nCorr -gt 0) { $resumo = $resumo + " | $nCorr corrompidas" }
            if ($nSemProt -gt 0 -or $nCorr -gt 0) { & $setStatus $resumo $Script:UiAmarelo }
            else { & $setStatus $resumo $Script:UiVerde }
            Log-Message "SUCESSO" "XMLs: $resumo"

            if ($pastasLote.Count -le 1) {
                $msg = $resumo + "`r`n`r`npasta: $pasta"
                if ($Script:XmlUltimoZip -ne "") { $msg = $msg + "`r`nzip: " + $Script:XmlUltimoZip }
            }
            else {
                # Um lote por empresa: lista cada pasta (o zip de cada uma fica ao lado)
                $msg = $resumo + "`r`n`r`n$($pastasLote.Count) lotes, um por empresa:`r`n" + (($pastasLote | ForEach-Object { "  - $_" }) -join "`r`n")
                if ($zipsLote.Count -gt 0) { $msg = $msg + "`r`n(o .zip de cada lote fica ao lado da pasta)" }
            }
            if ($Script:XmlFaltantes.Count -gt 0) {
                $txtFaltam = ConvertTo-FaixaTexto $Script:XmlFaltantes
                if ("$($Script:XmlFaltantesTexto)" -ne "") { $txtFaltam = $Script:XmlFaltantesTexto }
                $msg = $msg + "`r`n`r`nSem XML no banco (não baixadas): " + $txtFaltam
            }
            if ($nSemProt -gt 0) {
                $msg = $msg + "`r`n`r`nATENÇÃO: $nSemProt nota(s) sem protocolo de autorização, na subpasta ""Sem protocolo"". " +
                "Não valem como NFC-e autorizada: confira no PDV antes de enviar ao contador."
            }
            if ($interrompido) { $msg = "LOTE INTERROMPIDO`r`n`r`n" + $msg }
            [System.Windows.Forms.MessageBox]::Show($msg, "Baixar XMLs NFC-e", "OK", "Information") | Out-Null

            # Todo lote termina indo para a pasta: abre direto em vez de exigir mais um clique
            # Caminho entre aspas: o nome do lote pode ter virgula, que o explorer le como separador.
            # Varios lotes (um por empresa): abre a pasta de cima, com todos lado a lado.
            $abrirLote = $pasta
            if ($pastasLote.Count -gt 1) { $abrirLote = Split-Path $pasta -Parent; $Script:XmlUltimoLote = $abrirLote }
            try { if (Test-Path -LiteralPath $abrirLote) { Start-Process "explorer.exe" ("`"" + $abrirLote + "`"") } } catch {}
        }

        # Espelho fiscal (DANFE NFC-e) em PDF das notas marcadas. Por chave ou por
        # pedido basta digitar e clicar: se a lista ainda nao e dessa busca, busca
        # antes. Uma nota vai solta em "Arquivos Xmenu\Espelhos NFC-e" e o PDF abre
        # direto; varias ganham uma pasta de lote com zip, como os XMLs.
        $gerarPdf = {
            if ($Script:XmlOcupado) { return }
            $acabouDeBuscar = $false
            if ($rbChave.Checked -or $rbPedido.Checked) {
                $filtro = $Script:XmlFiltro
                $jaBuscou = $false
                if ($null -ne $filtro -and $lv.Items.Count -gt 0) {
                    if ($rbChave.Checked) { $jaBuscou = ($filtro.Modo -eq 'Chave' -and "$($filtro.Texto)" -eq ((@(& $lerChaves) | Sort-Object) -join ',')) }
                    else { $jaBuscou = ($filtro.Modo -eq 'Pedido' -and "$($filtro.Texto)" -eq (& $textoPedido)) }
                }
                if (-not $jaBuscou) {
                    if (-not (& $buscar)) { return }
                    $acabouDeBuscar = $true
                }
            }
            # A busca que acabou de rodar ja explicou na tela por que nao veio nada
            if ($lv.Items.Count -eq 0) {
                if (-not $acabouDeBuscar) { & $setStatus "Faça a busca antes de gerar o PDF." $Script:UiAmarelo }
                return
            }
            # Marcadas; sem nenhuma marcada vale a lista inteira, como no BAIXAR TUDO
            # (a busca vem desmarcada, e por chave ou pedido e digitar e gerar)
            $sel = @()
            foreach ($lvi in $lv.CheckedItems) { $sel += $lvi.Tag }
            if ($sel.Count -eq 0) {
                foreach ($lvi in $lv.Items) { if ($null -ne $lvi.Tag) { $sel += $lvi.Tag } }
            }

            # Numero de pedido que zera por dia: a busca direta pode trazer o mesmo
            # pedido em varias notas. Em vez de gerar todas, para e deixa escolher
            # pela data; no clique seguinte (mesma busca) gera o que ficou marcado.
            if ($acabouDeBuscar -and $rbPedido.Checked) {
                $repetidos = @($sel | Where-Object { $null -ne $_.Pedido } | Group-Object { "$($_.Pedido)" } | Where-Object { $_.Count -gt 1 })
                if ($repetidos.Count -gt 0) {
                    $detalhe = @($repetidos | Select-Object -First 10 | ForEach-Object { "Pedido $($_.Name): $($_.Count) notas" }) -join "`r`n"
                    & $setStatus "Pedido repetido em mais de uma nota: marque só a do dia certo e clique de novo em ESPELHO FISCAL (PDF)." $Script:UiAmarelo
                    [System.Windows.Forms.MessageBox]::Show(
                        "O número do pedido se repete (ele zera por dia), então a busca trouxe mais de uma nota:`r`n`r`n$detalhe`r`n`r`n" +
                        "A lista está da mais recente para a mais antiga. Confira a coluna Data, marque só a nota certa e clique de novo em ESPELHO FISCAL (PDF). " +
                        "Se quiser todas, é só clicar de novo sem marcar nenhuma.",
                        "Espelho fiscal (PDF)", "OK", "Information") | Out-Null
                    return
                }
            }

            # Espelho so existe para NFC-e autorizada; a cancelada sai com a tarja
            $temDanfe = { param($It) ("$($It.Conteudo)" -ne "" -and -not [bool]$It.Inutilizada -and "$($It.Status)" -eq "AUTORIZADA") }
            $podem = @($sel | Where-Object { & $temDanfe $_ })
            $fora = @($sel | Where-Object { -not (& $temDanfe $_) })
            $descreveFora = {
                $txtFora = @()
                foreach ($it in ($fora | Select-Object -First 15)) {
                    $motivo = "$($it.Status)".ToLower()
                    if ([bool]$it.Inutilizada) { $motivo = "inutilizada, não é nota emitida" }
                    elseif ("$($it.Conteudo)" -eq "") { $motivo = "sem XML no banco" }
                    elseif ("$($it.Status)" -eq "SEM PROTOCOLO") { $motivo = "sem protocolo de autorização" }
                    $txtFora += "Série $($it.Serie) nota $($it.Nota): $motivo"
                }
                if ($fora.Count -gt 15) { $txtFora += "... e mais $($fora.Count - 15)" }
                return ($txtFora -join "`r`n")
            }
            if ($podem.Count -eq 0) {
                & $setStatus "Nenhuma nota autorizada marcada - nenhum PDF gerado." $Script:UiAmarelo
                [System.Windows.Forms.MessageBox]::Show(
                    "Nenhuma das notas marcadas tem espelho para gerar. O espelho fiscal só existe para NFC-e autorizada (a cancelada sai com a tarja NOTA CANCELADA).`r`n`r`n" + (& $descreveFora),
                    "Espelho fiscal (PDF)", "OK", "Information") | Out-Null
                return
            }

            $Script:XmlOcupado = $true
            $Script:XmlCancelar = $false
            $btnCancelar.Enabled = $true
            $btnPdf.Enabled = $false
            $pb.Maximum = $podem.Count
            $pb.Value = 0
            $gerados = @()
            $falhasPdf = @()
            $interrompido = $false
            $pasta = ""
            $zip = ""
            try {
                & $setStatus "Gerando o espelho fiscal em PDF..." $Script:UiAmarelo
                $raizPdf = Join-Path $Script:DownloadFolder "Espelhos NFC-e"
                # Mesma regra dos XMLs: com mais de um certificado, um lote por empresa
                $gruposPdf = New-Object 'System.Collections.Generic.List[object]'
                if (@($Script:XmlServidores).Count -gt 1 -and $podem.Count -gt 1) {
                    foreach ($grupoEmp in @($podem | Group-Object { "$($_.Servidor)" } | Sort-Object Name)) {
                        $gruposPdf.Add(@{ Empresa = (& $nomeEmpresa $grupoEmp.Group[0].Servidor); Itens = @($grupoEmp.Group) })
                    }
                }
                else { $gruposPdf.Add(@{ Empresa = ""; Itens = $podem }) }
                $pastasPdf = @()

                $i = 0
                foreach ($grupoPdf in $gruposPdf) {
                    if ($interrompido) { break }
                    if ($podem.Count -eq 1) {
                        if (-not (Test-Path $raizPdf)) { New-Item -Path $raizPdf -ItemType Directory -Force | Out-Null }
                        $pasta = $raizPdf
                    }
                    else { $pasta = New-XmlLotePasta (& $nomeDoLote $grupoPdf.Itens "Espelho NFC-e" $grupoPdf.Empresa) -Subpasta "Espelhos NFC-e" }
                    $geradosGrupo = @()

                    foreach ($it in $grupoPdf.Itens) {
                        $i++
                        if ($Script:XmlCancelar) {
                            $interrompido = $true
                            Log-Message "CANCEL" "Espelho PDF:interrompido em $i de $($podem.Count)"
                            break
                        }
                        $lblProg.Text = "Gerando PDF $i de $($podem.Count)..."
                        $pb.Value = $i
                        [System.Windows.Forms.Application]::DoEvents()
                        try {
                            $nomes = Get-XmlNomeArquivo -Item $it
                            $destino = Join-Path $pasta ($nomes.Nota + ".pdf")
                            # O PDF da mesma nota aberto no leitor fica travado: grava ao lado com (2)
                            $copia = 1
                            while ($true) {
                                try {
                                    Export-DanfeNfcePdf -Xml $it.Conteudo -Caminho $destino -Cancelada:([bool]$it.Cancelada) -DataCancelamento $it.DataCancelamento
                                    break
                                }
                                catch {
                                    if ($_.Exception.GetBaseException() -isnot [System.IO.IOException] -or $copia -ge 5) { throw }
                                    $copia++
                                    $destino = Join-Path $pasta ($nomes.Nota + " ($copia).pdf")
                                }
                            }
                            $it.CaminhoPdf = $destino
                            $gerados += $destino
                            $geradosGrupo += $destino
                            if ($null -ne $it.Linha -and -not $lv.IsDisposed) {
                                if ("$($it.Arquivo)" -ne "") { $it.Linha.SubItems[6].Text = "$($it.Arquivo) + PDF" }
                                else { $it.Linha.SubItems[6].Text = (Split-Path $destino -Leaf) }
                            }
                        }
                        catch {
                            $falhasPdf += "Série $($it.Serie) nota $($it.Nota): $($_.Exception.Message)"
                            Log-Message "ERRO" "Espelho PDF:falha na nota $($it.Nota) - $($_.Exception.Message)"
                        }
                    }

                    if ($geradosGrupo.Count -eq 0 -and $pasta -ne $raizPdf) {
                        # Lote sem nenhum PDF: nao deixa pasta vazia para tras
                        try { [System.IO.Directory]::Delete($pasta) } catch {}
                    }
                    elseif ($geradosGrupo.Count -gt 0) {
                        $pastasPdf += $pasta
                        $Script:XmlUltimoLote = $pasta
                        if ($geradosGrupo.Count -gt 1) {
                            try {
                                Add-Type -AssemblyName System.IO.Compression.FileSystem
                                $zip = $pasta + ".zip"
                                if (Test-Path $zip) { Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue }
                                [System.IO.Compression.ZipFile]::CreateFromDirectory($pasta, $zip)
                                $Script:XmlUltimoZip = $zip
                            }
                            catch {
                                $zip = ""
                                Log-Message "ERRO" "Espelho PDF:falha ao gerar o zip - $($_.Exception.Message). A pasta continua disponível."
                            }
                        }
                    }
                }
                # Um lote por empresa: a pasta de cima mostra todos
                if ($pastasPdf.Count -gt 1) { $pasta = $raizPdf; $Script:XmlUltimoLote = $raizPdf; $zip = "" }

                $resumo = "$($gerados.Count) PDF(s) gerado(s)"
                if ($fora.Count -gt 0) { $resumo = $resumo + " | $($fora.Count) sem espelho" }
                if ($falhasPdf.Count -gt 0) { $resumo = $resumo + " | $($falhasPdf.Count) com erro" }
                if ($interrompido) { $resumo = "INTERROMPIDO - " + $resumo }
                Log-Message "SUCESSO" "Espelho PDF:$resumo em $pasta"
                if ($fora.Count -gt 0 -or $falhasPdf.Count -gt 0 -or $interrompido) { & $setStatus ($resumo + " - " + $pasta) $Script:UiAmarelo }
                else { & $setStatus ($resumo + " - " + $pasta) $Script:UiVerde }

                # Deu tudo certo: so abre o resultado. Aviso so quando algo ficou de fora.
                if ($fora.Count -gt 0 -or $falhasPdf.Count -gt 0 -or $interrompido) {
                    $msg = $resumo
                    if ($pastasPdf.Count -gt 1) { $msg = $msg + "`r`n`r`n$($pastasPdf.Count) lotes, um por empresa:`r`n" + (($pastasPdf | ForEach-Object { "  - $_" }) -join "`r`n") }
                    elseif ($gerados.Count -gt 0) { $msg = $msg + "`r`n`r`npasta: $pasta" }
                    if ($zip -ne "") { $msg = $msg + "`r`nzip: $zip" }
                    if ($fora.Count -gt 0) { $msg = $msg + "`r`n`r`nSem espelho (só NFC-e autorizada tem espelho fiscal):`r`n" + (& $descreveFora) }
                    if ($falhasPdf.Count -gt 0) { $msg = $msg + "`r`n`r`nNão deu para gerar:`r`n" + (($falhasPdf | Select-Object -First 15) -join "`r`n") }
                    [System.Windows.Forms.MessageBox]::Show($msg, "Espelho fiscal (PDF)", "OK", "Warning") | Out-Null
                }
                if ($gerados.Count -eq 1) {
                    try { Start-Process -FilePath $gerados[0] }
                    catch { try { Start-Process "explorer.exe" ("/select,`"" + $gerados[0] + "`"") } catch {} }
                }
                elseif ($gerados.Count -gt 1) {
                    try { Start-Process "explorer.exe" ("`"" + $pasta + "`"") } catch {}
                }
            }
            catch {
                & $setStatus ("Erro ao gerar o PDF: " + $_.Exception.Message) $Script:UiVermelho
                Log-Message "ERRO" "Espelho PDF:$($_.Exception.Message)"
            }
            finally {
                $btnCancelar.Enabled = $false
                $btnPdf.Enabled = $true
                $lblProg.Text = ""
                $pb.Value = 0
                $Script:XmlOcupado = $false
            }
        }

        # So consulta: aponta buracos na numeracao sem gravar nada
        $conferir = {
            if ($Script:XmlOcupado) { return }
            $Script:XmlOcupado = $true
            $cn = $null
            try {
                if ("$($cmbParceiro.Text)".Trim() -eq "") {
                    & $setStatus "Clique em TESTAR CONEXÃO antes de conferir." $Script:UiVermelho; return
                }
                if ("$($cmbSerie.Text)".Trim() -eq "") {
                    & $setStatus "Escolha a série." $Script:UiVermelho; return
                }
                $fx = ConvertFrom-FaixaNotas -Texto $txtNotas.Text
                if (-not $fx.Ok) { & $setStatus $fx.Erro $Script:UiVermelho; return }

                $parceiro = [long]("$($cmbParceiro.Text)".Trim())
                $serie = [int]("$($cmbSerie.Text)".Trim())
                $Script:XmlCancelar = $false
                $btnCancelar.Enabled = $true
                & $setStatus "Conferindo a sequência..." $Script:UiAmarelo
                & $mostraCarregando "Conferindo a sequência..."
                $cn = & $abrirConexao

                $existe = @{}
                $naoUsadas = @{}
                $inutil = @{}
                # Com mais de um certificado cada empresa tem a sua numeracao na mesma serie:
                # a conferencia e feita em cada uma (ou so na escolhida no filtro)
                $multiEmp = (@($Script:XmlServidores).Count -gt 1)
                $servSel = & $servidorEscolhido
                if (-not $multiEmp) { $servidoresConf = @("") }
                elseif ($null -eq $servSel) { $servidoresConf = @($Script:XmlServidores | ForEach-Object { "$($_.Id)" }) }
                else { $servidoresConf = @("$servSel") }
                $colServ = ""; $filtroServ = ""
                if ($Script:XmlTemServidor) {
                    $colServ = "IDServidorFiscal, "
                    $filtroServ = " AND (@servidor IS NULL OR IDServidorFiscal = @servidor)"
                }

                # Confere exatamente os numeros pedidos, em blocos de 500. Usar
                # BETWEEN do menor ao maior traria notas que ninguem perguntou:
                # digitar "1-15,2000" acabaria conferindo as 2000 da serie.
                for ($ini = 0; $ini -lt $fx.Notas.Count; $ini += 500) {
                    $fim = [Math]::Min($ini + 499, $fx.Notas.Count - 1)
                    $bloco = @($fx.Notas[$ini..$fim])
                    $nomes = @()
                    for ($i = 0; $i -lt $bloco.Count; $i++) { $nomes += "@n$i" }

                    $cmd = $cn.CreateCommand()
                    $cmd.CommandTimeout = 120
                    $cmd.CommandText = "SELECT " + $colServ + "ID, Usada, Inutilizada FROM NFCeTokenID " +
                    "WHERE IDParceiro = @p AND Serie = @s AND ID IN (" + ($nomes -join ",") + ")" + $filtroServ + " ORDER BY ID"
                    $par = $cmd.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = $parceiro
                    $par = $cmd.Parameters.Add("@s", [System.Data.SqlDbType]::Int); $par.Value = $serie
                    & $addServidor $cmd
                    for ($i = 0; $i -lt $bloco.Count; $i++) {
                        $par = $cmd.Parameters.Add("@n$i", [System.Data.SqlDbType]::BigInt)
                        $par.Value = [long]$bloco[$i]
                    }

                    $rd = & $executarLeitor $cmd -Cancelavel
                    if ($rd -is [System.Array]) { $rd = $rd[0] }
                    while ($rd.Read()) {
                        $sv = ""
                        if ($multiEmp) { $sv = "$(Get-XmlDbValor $rd 'IDServidorFiscal')" }
                        $id = [int]$rd["ID"]
                        $existe["$sv|$id"] = $true
                        if (-not [bool]$rd["Usada"]) { $naoUsadas[$sv] = @($naoUsadas[$sv]) + $id }
                        if (-not $rd.IsDBNull($rd.GetOrdinal("Inutilizada")) -and [bool]$rd["Inutilizada"]) { $inutil[$sv] = @($inutil[$sv]) + $id }
                    }
                    $rd.Close()
                    [System.Windows.Forms.Application]::DoEvents()
                }

                $linhas = @()
                $linhas += "Série $serie - $($fx.Total) nota(s) conferida(s): " + (ConvertTo-FaixaTexto $fx.Notas)
                $todasSem = @(); $partesSem = @(); $totalSem = 0
                foreach ($sv in $servidoresConf) {
                    $semRegistro = @($fx.Notas | Where-Object { -not $existe.ContainsKey("$sv|$_") })
                    $nUsadasSv = @($naoUsadas[$sv] | Where-Object { $null -ne $_ })
                    $inutSv = @($inutil[$sv] | Where-Object { $null -ne $_ })
                    $linhas += ""
                    if ($multiEmp) { $linhas += "$(& $nomeEmpresa $sv)".ToUpper() }
                    if ($semRegistro.Count -eq 0) { $linhas += "Numeração sem lacunas: todos os números têm registro." }
                    else {
                        $linhas += "SEM REGISTRO no banco ($($semRegistro.Count)): " + (ConvertTo-FaixaTexto $semRegistro)
                        $todasSem += $semRegistro
                        $totalSem += $semRegistro.Count
                        if ($multiEmp) { $partesSem += "$(& $nomeEmpresa $sv): $(ConvertTo-FaixaTexto $semRegistro)" }
                    }
                    if ($nUsadasSv.Count -gt 0) { $linhas += "Token gerado e NÃO USADO ($($nUsadasSv.Count)): " + (ConvertTo-FaixaTexto $nUsadasSv) }
                    if ($inutSv.Count -gt 0) { $linhas += "Inutilizadas ($($inutSv.Count)): " + (ConvertTo-FaixaTexto $inutSv) }
                }

                $Script:XmlFaltantes = @($todasSem | Sort-Object -Unique)
                $Script:XmlFaltantesTexto = ($partesSem -join " | ")
                & $atualizaModo
                if ($totalSem -eq 0) { & $setStatus "Numeração sem lacunas: todos os números têm registro." $Script:UiVerde }
                elseif ($multiEmp) { & $setStatus ("SEM REGISTRO no banco: " + $Script:XmlFaltantesTexto) $Script:UiAmarelo }
                else { & $setStatus ("SEM REGISTRO no banco ($totalSem): " + (ConvertTo-FaixaTexto $Script:XmlFaltantes)) $Script:UiAmarelo }
                Log-Message "INFO" "XMLs: conferência da série $serie - $totalSem sem registro"
                & $mostraCarregando ""
                [System.Windows.Forms.MessageBox]::Show(($linhas -join "`r`n"), "Conferir sequência", "OK", "Information") | Out-Null
            }
            catch {
                $msg = $_.Exception.Message
                if ($Script:XmlCancelar) { & $setStatus "Conferência cancelada." $Script:UiAmarelo }
                else {
                    & $setStatus ("Erro ao conferir: " + (& $explicaFalha $_.Exception)) $Script:UiVermelho
                    Log-Message "ERRO" "XMLs: falha ao conferir a sequência - $msg"
                }
            }
            finally {
                & $mostraCarregando ""
                if ($null -ne $cn) { try { $cn.Close() } catch {} }
                $btnCancelar.Enabled = $false
                $Script:XmlOcupado = $false
            }
        }

        # ---------------------------------------------------------------------
        # NOTAS PENDENTES
        # NFC-e sem autorizacao da SEFAZ e sem inutilizacao: a nota que "nao subiu".
        # A situacao sai das marcacoes do PDV na NFCeTokenID (ignorada, offline,
        # erro) e do ultimo envio gravado na log (sem resposta ou rejeitada).
        # ---------------------------------------------------------------------
        $consultarPendentes = {
            # -Dias 0 = todo o banco. Devolve as notas, da mais recente para a mais antiga.
            param([int]$Dias)
            $parceiroP = [long]("$($cmbParceiro.Text)".Trim())
            $cnP = & $abrirConexao
            try {
                $cmd = $cnP.CreateCommand()
                $cmd.CommandTimeout = 300
                # Com mais de um certificado a mesma serie e numero existem uma vez por empresa:
                # a ultima tentativa de envio tem que ser a do certificado da propria nota
                $svL = ""; $svT = ""; $svX = ""; $svJu = ""; $svJp = ""; $svJe = ""; $svF = ""
                if ($Script:XmlTemServidor) {
                    $svL = "l.IDServidorFiscal, "; $svT = "t.IDServidorFiscal, "; $svX = "x.IDServidorFiscal, "
                    $svJu = "AND u.IDServidorFiscal = t.IDServidorFiscal "
                    $svJp = "AND p.IDServidorFiscal = x.IDServidorFiscal "
                    $svJe = "AND e.IDServidorFiscal = p.IDServidorFiscal "
                    $svF = "AND (@servidor IS NULL OR t.IDServidorFiscal = @servidor) "
                }
                $cmd.CommandText = ";WITH ult AS (SELECT l.IDParceiro, " + $svL + "l.SerieTokenID, l.IDTokenID, l.CodigoRetorno, l.MotivoErro, l.Chave, l.DataEmissao, " +
                "ROW_NUMBER() OVER (PARTITION BY l.IDParceiro, " + $svL + "l.SerieTokenID, l.IDTokenID ORDER BY l.ID DESC) AS rn, " +
                "MAX(CASE WHEN l.CodigoRetorno IN (100, 150) THEN 1 ELSE 0 END) OVER (PARTITION BY l.IDParceiro, " + $svL + "l.SerieTokenID, l.IDTokenID) AS aut " +
                "FROM NFCeTokenIDLog l WHERE l.IDParceiro = @p), " +
                "pend AS (SELECT t.IDParceiro, " + $svT + "t.Serie, t.ID, COALESCE(t.DataEmissao, t.data, u.DataEmissao) AS Emissao, t.OFFLine, t.OFFLineOK, t.Erro, t.ErroResolvido, " +
                "t.MotivoErro AS MotivoToken, t.Ignorada, t.MotivoIgnorada, t.MotivoGerouOutra, t.IDDestinoTransferencia, " +
                "u.CodigoRetorno, u.MotivoErro AS MotivoLog, u.Chave, SUBSTRING(t.xmlEnvioOff, 1, 1000) AS InicioXmlOff " +
                "FROM NFCeTokenID t LEFT JOIN ult u ON u.IDParceiro = t.IDParceiro AND u.SerieTokenID = t.Serie AND u.IDTokenID = t.ID " + $svJu + "AND u.rn = 1 " +
                "WHERE t.IDParceiro = @p AND ISNULL(t.Inutilizada, 0) = 0 AND ISNULL(u.aut, 0) = 0 " + $svF +
                "AND (t.Usada = 1 OR t.OFFLine = 1 OR u.IDTokenID IS NOT NULL) " +
                "AND (@desde IS NULL OR COALESCE(t.DataEmissao, t.data, u.DataEmissao) >= @desde)), " +
                # Envio que falhou nao grava a chave na log: ela sai do comeco do XML enviado,
                # lido so das notas pendentes e so os primeiros 1000 caracteres
                "env AS (SELECT " + $svX + "x.SerieTokenID, x.IDTokenID, SUBSTRING(x.xmlEnvio, 1, 1000) AS InicioXml, " +
                "ROW_NUMBER() OVER (PARTITION BY " + $svX + "x.SerieTokenID, x.IDTokenID ORDER BY x.ID DESC) AS rn " +
                "FROM NFCeTokenIDLog x JOIN pend p ON p.IDParceiro = x.IDParceiro AND p.Serie = x.SerieTokenID AND p.ID = x.IDTokenID " + $svJp +
                "WHERE x.xmlEnvio IS NOT NULL) " +
                "SELECT p.*, e.InicioXml FROM pend p LEFT JOIN env e ON e.SerieTokenID = p.Serie AND e.IDTokenID = p.ID " + $svJe + "AND e.rn = 1 " +
                "ORDER BY p.Emissao DESC, p.Serie, p.ID"
                & $addServidor $cmd
                $par = $cmd.Parameters.Add("@p", [System.Data.SqlDbType]::BigInt); $par.Value = $parceiroP
                $par = $cmd.Parameters.Add("@desde", [System.Data.SqlDbType]::DateTime)
                if ($Dias -gt 0) { $par.Value = (Get-Date).Date.AddDays(-$Dias) } else { $par.Value = [System.DBNull]::Value }

                $lista = New-Object 'System.Collections.Generic.List[object]'
                $rd = & $executarLeitor $cmd
                if ($rd -is [System.Array]) { $rd = $rd[0] }
                $texto = { param($Coluna) $v = Get-XmlDbValor $rd $Coluna; if ($null -eq $v) { return "" }; return "$v".Trim() }
                $marcado = { param($Coluna) $v = Get-XmlDbValor $rd $Coluna; return ($null -ne $v -and [bool]$v) }
                try {
                    while ($rd.Read()) {
                        # Mensagem do envio sem o endereco do webservice, que so atrapalha a leitura
                        $motivoLog = (& $texto "MotivoLog") -replace '\s*-\s*URL:\S*.*$', ''
                        $codigo = Get-XmlDbValor $rd "CodigoRetorno"

                        if (& $marcado "Ignorada") {
                            $situacao = "IGNORADA"
                            $motivo = & $texto "MotivoIgnorada"
                            if ($motivo -eq "") { $motivo = "o PDV não registrou o motivo" }
                            $outra = & $texto "MotivoGerouOutra"
                            $destino = Get-XmlDbValor $rd "IDDestinoTransferencia"
                            if ($outra -ne "") { $motivo = $motivo + " | gerou outra nota: " + $outra }
                            elseif ($null -ne $destino -and [long]$destino -gt 0) { $motivo = $motivo + " | passou para a nota " + $destino }
                            $motivo = $motivo + " (número não inutilizado)"
                        }
                        elseif ((& $marcado "OFFLine") -and -not (& $marcado "OFFLineOK")) {
                            $situacao = "CONTINGÊNCIA NÃO ENVIADA"
                            $motivo = "emitida offline e ainda não transmitida para a SEFAZ"
                            if ($motivoLog -ne "") { $motivo = $motivo + " | último envio: " + $motivoLog }
                        }
                        elseif ((& $marcado "Erro") -and -not (& $marcado "ErroResolvido")) {
                            $situacao = "COM ERRO"
                            $motivo = & $texto "MotivoToken"
                            if ($motivo -eq "") { $motivo = $motivoLog }
                        }
                        elseif ($null -eq $codigo) {
                            $situacao = "SEM ENVIO"
                            $motivo = "número usado no PDV sem registro de envio para a SEFAZ"
                        }
                        elseif ([int]$codigo -le 0) {
                            $situacao = "SEM RESPOSTA DA SEFAZ"
                            $motivo = $motivoLog
                            if ($motivo -eq "") { $motivo = "a SEFAZ não respondeu ao envio" }
                        }
                        else {
                            $situacao = "REJEITADA (cStat $codigo)"
                            $motivo = $motivoLog
                        }

                        $chaveP = (& $texto "Chave") -replace '^.*(.{44})$', '$1'
                        if ($chaveP.Length -ne 44) {
                            $chaveP = ""
                            foreach ($inicio in @((& $texto "InicioXml"), (& $texto "InicioXmlOff"))) {
                                $achouChave = [regex]::Match($inicio, 'Id\s*=\s*"NFe(\d{6}[0-9A-Za-z]{12}\d{26})"')
                                if ($achouChave.Success) { $chaveP = $achouChave.Groups[1].Value.ToUpper(); break }
                            }
                        }
                        $lista.Add(@{
                                Serie = [int](Get-XmlDbValor $rd "Serie"); Nota = [long](Get-XmlDbValor $rd "ID")
                                Emissao = Get-XmlDbValor $rd "Emissao"; Situacao = $situacao; Motivo = $motivo; Chave = $chaveP
                                Empresa = (& $nomeEmpresa (Get-XmlDbValor $rd "IDServidorFiscal"))
                            })
                    }
                }
                finally { $rd.Close() }
                return , $lista.ToArray()
            }
            finally { try { $cnP.Close() } catch {} }
        }

        $mostrarPendentes = {
            if ($Script:XmlOcupado) { return }
            if ($cmbParceiro.Items.Count -eq 0 -or "$($cmbParceiro.Text)".Trim() -eq "") {
                & $setStatus "Clique em TESTAR CONEXÃO antes de ver as notas pendentes." $Script:UiVermelho
                return
            }
            $fp = New-ToolForm "Notas pendentes - NFC-e" 980 560
            $fp.MinimumSize = New-Object System.Drawing.Size(980, 560)
            New-ToolLabel $fp "NFC-e sem autorização da SEFAZ e que não foram inutilizadas (a nota que ""não subiu"")" 16 14 10 -Negrito -W 940 | Out-Null
            New-ToolLabel $fp "Período:" 16 47 9 -Cor $Script:UiSuave | Out-Null
            $cmbDias = & $novaCombo $fp 76 44 150
            foreach ($opcao in @("Últimos 7 dias", "Últimos 30 dias", "Últimos 90 dias", "Últimos 12 meses", "Tudo")) { [void]$cmbDias.Items.Add($opcao) }
            $cmbDias.SelectedIndex = 2
            $btnAtualizarP = New-ToolButton $fp "ATUALIZAR" 240 42 120 27 $Script:UiAzul $null "Consulta o banco de novo"
            $lblResumoP = New-ToolLabel $fp "" 376 47 9 -Cor $Script:UiSuave -W 580
            $lblResumoP.Anchor = 'Top,Left,Right'

            $lvP = New-Object System.Windows.Forms.ListView
            $lvP.Location = New-Object System.Drawing.Point(16, 80)
            $lvP.Size = New-Object System.Drawing.Size(940, 388)
            $lvP.Anchor = 'Top,Left,Right,Bottom'
            $lvP.ShowItemToolTips = $true
            Format-ToolListView $lvP
            [void]$lvP.Columns.Add("Série", 50)
            [void]$lvP.Columns.Add("Nota", 70)
            [void]$lvP.Columns.Add("Emissão", 120)
            [void]$lvP.Columns.Add("Situação", 190)
            [void]$lvP.Columns.Add("Motivo", 420)
            [void]$lvP.Columns.Add("Chave de acesso", 280)
            # Empresa do certificado: so tem largura quando o banco emite com mais de um
            $colCertP = $lvP.Columns.Add("Certificado", 0)
            if (@($Script:XmlServidores).Count -gt 1) { $colCertP.Width = 170 }
            [void]$fp.Controls.Add($lvP)

            $btnCopiarP = New-ToolButton $fp "COPIAR LISTA" 16 480 184 30 $Script:UiCinza $null "Copia a lista pronta para colar no WhatsApp ou no e-mail do suporte"
            $btnFecharP = New-ToolButton $fp "FECHAR" 772 480 184 30 $Script:UiCinza $null "Fecha esta janela"
            $btnCopiarP.Anchor = 'Bottom,Left'
            $btnFecharP.Anchor = 'Bottom,Right'
            $Script:PendentesLista = @()

            $carregarP = {
                if (-not $btnAtualizarP.Enabled) { return }
                $btnAtualizarP.Enabled = $false
                $lblResumoP.ForeColor = $Script:UiAmarelo
                $lblResumoP.Text = "Consultando o banco..."
                [System.Windows.Forms.Application]::DoEvents()
                try {
                    $dias = @(7, 30, 90, 365, 0)[$cmbDias.SelectedIndex]
                    # Sem @(): a rotina ja devolve o array inteiro como um objeto so
                    $lista = & $consultarPendentes $dias
                    if ($null -eq $lista) { $lista = @() }
                    $Script:PendentesLista = $lista
                    $lvP.BeginUpdate()
                    try {
                        $lvP.Items.Clear()
                        foreach ($p in $lista) {
                            $lvi = New-Object System.Windows.Forms.ListViewItem("$($p.Serie)")
                            [void]$lvi.SubItems.Add("$($p.Nota)")
                            $dtP = ""
                            if ($null -ne $p.Emissao) { try { $dtP = ([datetime]$p.Emissao).ToString("dd/MM/yyyy HH:mm") } catch { $dtP = "$($p.Emissao)" } }
                            [void]$lvi.SubItems.Add($dtP)
                            [void]$lvi.SubItems.Add($p.Situacao)
                            [void]$lvi.SubItems.Add($p.Motivo)
                            [void]$lvi.SubItems.Add($p.Chave)
                            [void]$lvi.SubItems.Add("$($p.Empresa)")
                            if ($p.Situacao -like "REJEITADA*" -or $p.Situacao -eq "COM ERRO") { $lvi.ForeColor = $Script:UiVermelho }
                            else { $lvi.ForeColor = $Script:UiAmarelo }
                            $lvi.ToolTipText = "$($p.Situacao) - $($p.Motivo)"
                            $lvi.Tag = $p
                            [void]$lvP.Items.Add($lvi)
                        }
                    }
                    finally { $lvP.EndUpdate() }

                    if ($lista.Count -eq 0) {
                        $lblResumoP.ForeColor = $Script:UiVerde
                        $lblResumoP.Text = "Nenhuma nota pendente em ""$($cmbDias.Text)"": tudo autorizado ou inutilizado."
                    }
                    else {
                        $grupos = @($lista | Group-Object { ($_.Situacao -replace ' \(cStat \d+\)$', '') } | Sort-Object Count -Descending | ForEach-Object { "$($_.Count) $($_.Name.ToLower())" })
                        $lblResumoP.ForeColor = $Script:UiAmarelo
                        $lblResumoP.Text = "$($lista.Count) pendente(s): " + ($grupos -join ", ")
                    }
                    Log-Message "INFO" "XMLs: $($lista.Count) nota(s) pendente(s) em $($cmbDias.Text)"
                }
                catch {
                    $lblResumoP.ForeColor = $Script:UiVermelho
                    $lblResumoP.Text = "Erro na consulta: " + (& $explicaFalha $_.Exception)
                    Log-Message "ERRO" "XMLs: falha ao listar notas pendentes - $($_.Exception.Message)"
                }
                finally { $btnAtualizarP.Enabled = $true }
            }

            $btnAtualizarP.Add_Click({ & $carregarP })
            $cmbDias.Add_SelectedIndexChanged({ & $carregarP })
            $btnCopiarP.Add_Click({
                    if (@($Script:PendentesLista).Count -eq 0) { $lblResumoP.Text = "Nada para copiar."; return }
                    $linhasP = @("Notas pendentes NFC-e - parceiro $("$($cmbParceiro.Text)".Trim()) - $($cmbDias.Text)")
                    foreach ($p in $Script:PendentesLista) {
                        $dtP = ""
                        if ($null -ne $p.Emissao) { try { $dtP = ([datetime]$p.Emissao).ToString("dd/MM/yyyy HH:mm") } catch {} }
                        $empP = ""
                        if ("$($p.Empresa)" -ne "") { $empP = "$($p.Empresa) - " }
                        $linhasP += "$($empP)Série $($p.Serie) nota $($p.Nota) - $dtP - $($p.Situacao) - $($p.Motivo)"
                    }
                    $txtP = $linhasP -join "`r`n"
                    try { Set-Clipboard -Value $txtP -ErrorAction Stop }
                    catch { [System.Windows.Forms.Clipboard]::SetText($txtP) }
                    $lblResumoP.ForeColor = $Script:UiVerde
                    $lblResumoP.Text = "Lista copiada: $(@($Script:PendentesLista).Count) nota(s)."
                })
            $btnFecharP.Add_Click({ $fp.Close() })
            $fp.Add_Shown({ & $carregarP })
            [void]$fp.ShowDialog($f)
            $fp.Dispose()
        }

        # ---------------------------------------------------------------------
        # LIGACAO DOS EVENTOS
        # ---------------------------------------------------------------------
        $rbSerie.Add_CheckedChanged($atualizaModo)
        $rbPeriodo.Add_CheckedChanged($atualizaModo)
        $rbChave.Add_CheckedChanged($atualizaModo)
        $rbPedido.Add_CheckedChanged($atualizaModo)
        $chkDiaPedido.Add_CheckedChanged($atualizaModo)
        $txtNotas.Add_TextChanged($contaNotas)
        $btnTestar.Add_Click({ & $testar })
        $btnPendentes.Add_Click({ & $mostrarPendentes })

        # Texto da ajuda montado como array para nao depender de here-string indentada
        $ajudaTexto = @(
            "COMO USAR ESTA JANELA",
            "=====================",
            "",
            "1) CONEXAO",
            "   A janela ja tenta conectar sozinha ao abrir, no servidor da ultima vez.",
            "   Se o SQL estiver em outra maquina, troque o servidor e clique em",
            "   TESTAR CONEXAO. Ele confirma a versao do SQL e carrega o parceiro e",
            "   as series que existem no banco.",
            "   Banco que emite com mais de um certificado (uma empresa em cada",
            "   caixa, mesma serie): aparece o campo Certificado. Escolha a empresa",
            "   ou deixe Todos, e cada empresa sai no seu proprio lote e zip.",
            "",
            "2) ESCOLHA UM DOS QUATRO MODOS",
            "   - Por serie + sequencia (o mais usado)",
            "       Escolha a serie do caixa e digite os numeros:",
            "         1-15            da 1 ate a 15",
            "         1,5,9           so essas tres",
            "         1-10,15,20-25   pode misturar intervalo e avulsas",
            "   - Por periodo",
            "       Data inicial e final, com serie opcional. Traz todas as notas do",
            "       periodo; acima de 10 mil ele pergunta antes de buscar.",
            "   - Por chave de acesso",
            "       Chaves de 44 posicoes, por virgula ou uma por linha. Aceita a",
            "       chave de CNPJ alfanumerico (com letras) e ignora o NFe da frente.",
            "   - Por numero do pedido",
            "       O numero que sai no cupom (""Pedido: 73432""). Aceita lista e",
            "       intervalo como as notas: 73432 | 73430,73432 | 73400-73432.",
            "       Pedido sem NFC-e (venda nao fiscal) aparece no aviso da busca.",
            "",
            "3) BUSCAR",
            "   So consulta, nao grava nada. A coluna Situacao diz o que e cada nota:",
            "       AUTORIZADA ......  verde, nota valida",
            "       CANCELADA .......  vermelho, foi cancelada depois de autorizada",
            "       INUTILIZADA .....  amarelo, o numero foi inutilizado",
            "       SEM PROTOCOLO ...  amarelo, tem a nota mas nao o protocolo de",
            "                          autorizacao (rejeitada, denegada ou nunca",
            "                          transmitida). O motivo aparece no balao.",
            "       NAO ENCONTRADA ..  cinza, nao existe XML no banco",
            "   Passe o mouse na linha para ver o detalhe.",
            "",
            "4) FILTRAR O QUE JA FOI BUSCADO",
            "   O campo Tipo de nota tambem funciona como filtro da tela. Busque",
            "   tudo uma vez e depois troque a opcao: a lista se ajusta na hora,",
            "   sem consultar o banco de novo.",
            "       Todas .................  mostra tudo que a busca trouxe",
            "       Somente autorizadas ...  so as que valem: esconde inutilizadas,",
            "                                sem protocolo e sem XML",
            "       Somente inutilizadas ..  so as inutilizadas",
            "       Somente canceladas ....  so as que tem XML de cancelamento",
            "",
            "5) BAIXAR",
            "   A busca vem com as notas desmarcadas. Marque as que quer e use",
            "   BAIXAR SELECIONADOS. MARCAR TODAS (ao lado do Tipo de nota) marca",
            "   a lista inteira de uma vez, e o contador ao lado mostra quantas",
            "   estao marcadas.",
            "   BAIXAR TUDO grava tudo que esta aparecendo na lista, marcado ou",
            "   nao; com o filtro ligado baixa so o que o filtro deixou a mostra.",
            "   Nota sem XML e pulada e aparece num aviso no fim.",
            "   CANCELAR interrompe tanto a busca quanto o download.",
            "",
            "6) ESPELHO FISCAL (PDF)",
            "   Gera o espelho fiscal da nota em PDF, no mesmo formato do cupom",
            "   (80 mm, com QR Code), das notas marcadas; sem nenhuma marcada, de",
            "   todas da lista. Por chave ou por pedido nem precisa buscar antes:",
            "   digite e clique em ESPELHO FISCAL (PDF).",
            "   O numero do pedido pode se repetir (zera por dia): se ele aparecer",
            "   em mais de uma nota, a lista mostra todas, da mais recente para a",
            "   mais antiga. Marque so a do dia certo e clique de novo.",
            "   Uma nota: o PDF abre sozinho. Varias: abre a pasta do lote.",
            "   So NFC-e autorizada tem espelho. A cancelada sai com a tarja",
            "   NOTA CANCELADA; inutilizada e sem protocolo ficam de fora e",
            "   aparecem no aviso do fim.",
            "",
            "ONDE OS ARQUIVOS FICAM",
            "   Area de Trabalho > Arquivos Xmenu > XMLs > <nome do lote>",
            "   O nome do lote diz o que tem dentro, pronto para mandar ao cliente:",
            "       XML NFC-e - Série 1 - Notas 1 a 15 e 2000",
            "       XML NFC-e - Série 1 - Agosto de 2026",
            "       XML NFC-e - 01-08-2026 a 12-09-2026",
            "       XML NFC-e - 3 chaves de acesso",
            "   Baixar o mesmo filtro de novo cria (2), (3), sem apagar o anterior.",
            "   Um .zip do mesmo lote fica ao lado, pronto para enviar.",
            "   Nome do arquivo: serie<serie>_nota<numero>_<chave>.xml",
            "   O fim do nome diz a situacao, para o caso de os arquivos saírem",
            "   da pasta e se misturarem:",
            "       _INUT ..........  nota inutilizada",
            "       _CANC ..........  nota cancelada depois de autorizada",
            "       _CANC_EVENTO ...  o XML do cancelamento em si",
            "       _SEM_PROTOCOLO .  nota sem protocolo de autorizacao, nao vale",
            "       _CORROMPIDO ....  o XML do banco nao abriu como documento valido",
            "   Subpastas: Inutilizadas, Cancelamentos (os _CANC_EVENTO) e",
            "   Sem protocolo. Na pasta principal fica so o que vale.",
            "   A pasta abre sozinha quando o lote termina.",
            "   Espelhos em PDF: Arquivos Xmenu > Espelhos NFC-e (uma nota fica",
            "   solta ali; varias ganham pasta de lote, ex. Espelho NFC-e - Pedido 73432).",
            "",
            "OUTROS BOTOES",
            "   CONFERIR SEQUENCIA  so consulta: mostra os buracos na numeracao da",
            "                       serie, util para saber se o cliente pulou nota",
            "                       antes de baixar qualquer coisa.",
            "   COPIAR FALTANTES    copia os numeros que nao tem XML no banco, ja",
            "                       formatados, para colar num e-mail ou WhatsApp",
            "                       para o cliente.",
            "   ABRIR PASTA / ZIP   reabrem o ultimo lote baixado.",
            "   NOTAS PENDENTES     (ao lado de TESTAR CONEXAO) lista as NFC-e que",
            "                       nao subiram: sem autorizacao da SEFAZ e sem",
            "                       inutilizacao. Mostra a situacao (sem resposta,",
            "                       rejeitada, contingencia nao enviada, ignorada)",
            "                       e o motivo; COPIAR LISTA leva tudo para o",
            "                       WhatsApp ou e-mail do suporte.",
            "",
            "ATALHOS",
            "   Enter no campo Notas ou Pedido ja faz a busca.",
            "   Enter no campo Servidor testa a conexao.",
            "   Clique no cabecalho da coluna para ordenar a lista.",
            "   Arraste o cabecalho da coluna para mudar a ordem (fica guardada).",
            "   Botao direito na lista: marcar todos, desmarcar todos, copiar chave.",
            "   Duplo clique numa linha ja baixada abre o XML."
        ) -join "`r`n"

        $btnAjuda.Add_Click({
                $fa = New-ToolForm "Como usar - Baixar XMLs NFC-e" 720 580
                $pad = New-Object System.Windows.Forms.Panel
                $pad.Dock = 'Fill'
                $pad.Padding = New-Object System.Windows.Forms.Padding(14, 14, 14, 14)
                $pad.BackColor = $Script:UiFundo
                $tb = New-Object System.Windows.Forms.TextBox
                $tb.Multiline = $true
                $tb.ReadOnly = $true
                $tb.ScrollBars = 'Vertical'
                $tb.Dock = 'Fill'
                $tb.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
                $tb.ForeColor = $Script:UiTexto
                $tb.BorderStyle = 'None'
                $tb.Font = New-Object System.Drawing.Font("Consolas", 9.5)
                $tb.Text = $ajudaTexto
                [void]$pad.Controls.Add($tb)
                [void]$fa.Controls.Add($pad)
                $fa.Add_Shown({ $tb.Select(0, 0) })
                [void]$fa.ShowDialog($f)
                $fa.Dispose()
            })
        $cmbParceiro.Add_SelectedIndexChanged({
                # Durante o TESTAR CONEXAO a propria rotina ja carrega as series
                if ($Script:XmlOcupado) { return }
                if ("$($cmbParceiro.Text)".Trim() -eq "") { return }
                $Script:XmlOcupado = $true
                $cn = $null
                try {
                    $cn = & $abrirConexao
                    & $carregarSeries $cn ("$($cmbParceiro.Text)".Trim())
                    & $carregarCertificados $cn ("$($cmbParceiro.Text)".Trim())
                }
                catch {}
                finally {
                    if ($null -ne $cn) { try { $cn.Close() } catch {} }
                    $Script:XmlOcupado = $false
                }
            })

        # Trocar o certificado muda o que a busca traz do banco: a lista antiga sai para nao
        # baixar notas de uma empresa achando que sao da outra
        $cmbCert.Add_SelectedIndexChanged({
                if ($Script:XmlOcupado -or @($Script:XmlResultados).Count -eq 0) { return }
                $Script:XmlResultados = @()
                $Script:XmlFaltantes = @()
                $Script:XmlFaltantesTexto = ""
                $lv.Items.Clear()
                & $atualizaMarcadas
                & $atualizaModo
                & $setStatus "Certificado trocado para ""$($cmbCert.Text)"": clique em BUSCAR para listar as notas." $Script:UiAmarelo
            })

        $btnBuscar.Add_Click({ [void](& $buscar) })

        $btnBaixarSel.Add_Click({
                $sel = @()
                foreach ($lvi in $lv.CheckedItems) { $sel += $lvi.Tag }
                if ($sel.Count -eq 0) {
                    & $setStatus "Marque ao menos uma linha na lista." $Script:UiAmarelo
                    return
                }
                & $baixar $sel
            })

        $btnBaixarTudo.Add_Click({
                # "Tudo" e tudo que esta na tela: se o tipo estiver filtrando,
                # baixa so o que o filtro deixou aparecer.
                if ($lv.Items.Count -eq 0) {
                    & $setStatus "Faça a busca antes de baixar." $Script:UiAmarelo
                    return
                }
                $todas = @()
                foreach ($lvi in $lv.Items) { $todas += $lvi.Tag }
                & $baixar $todas
            })

        $btnConferir.Add_Click($conferir)
        $btnPdf.Add_Click($gerarPdf)

        $btnCopiar.Add_Click({
                if ($Script:XmlFaltantes.Count -eq 0) {
                    & $setStatus "Não há faltantes para copiar." $Script:UiAmarelo
                    return
                }
                $txt = ConvertTo-FaixaTexto $Script:XmlFaltantes
                if ("$($Script:XmlFaltantesTexto)" -ne "") { $txt = $Script:XmlFaltantesTexto }
                try { Set-Clipboard -Value $txt -ErrorAction Stop }
                catch { [System.Windows.Forms.Clipboard]::SetText($txt) }
                & $setStatus "Copiado: $txt" $Script:UiVerde
            })

        $btnPasta.Add_Click({
                if ($Script:XmlUltimoLote -ne "" -and (Test-Path -LiteralPath $Script:XmlUltimoLote)) {
                    Start-Process "explorer.exe" ("`"" + $Script:XmlUltimoLote + "`"")
                }
                else { & $setStatus "Nenhum lote baixado ainda." $Script:UiAmarelo }
            })

        $btnZip.Add_Click({
                if ($Script:XmlUltimoZip -ne "" -and (Test-Path $Script:XmlUltimoZip)) {
                    Start-Process "explorer.exe" ("/select,`"" + $Script:XmlUltimoZip + "`"")
                }
                else { & $setStatus "Nenhum zip gerado ainda." $Script:UiAmarelo }
            })

        $btnCancelar.Add_Click({
                $Script:XmlCancelar = $true
                & $setStatus "Cancelando..." $Script:UiAmarelo
            })

        $btnFechar.Add_Click({ $f.Close() })

        $lv.Add_DoubleClick({
                if ($lv.SelectedItems.Count -eq 0) { return }
                $it = $lv.SelectedItems[0].Tag
                if ($null -ne $it -and "$($it.Caminho)" -ne "" -and (Test-Path $it.Caminho)) {
                    Start-Process -FilePath $it.Caminho
                }
                elseif ($null -ne $it -and "$($it.CaminhoPdf)" -ne "" -and (Test-Path -LiteralPath $it.CaminhoPdf)) {
                    Start-Process -FilePath $it.CaminhoPdf
                }
                else { & $setStatus "Baixe a nota ou gere o PDF antes de abrir o arquivo." $Script:UiAmarelo }
            })

        $miChave.Add_Click({
                if ($lv.SelectedItems.Count -eq 0) { return }
                $it = $lv.SelectedItems[0].Tag
                if ($null -eq $it -or "$($it.Chave)" -eq "") {
                    & $setStatus "Essa linha não tem chave de acesso." $Script:UiAmarelo
                    return
                }
                try { Set-Clipboard -Value $it.Chave -ErrorAction Stop }
                catch { [System.Windows.Forms.Clipboard]::SetText($it.Chave) }
                & $setStatus "Chave copiada: $($it.Chave)" $Script:UiVerde
            })

        $miPasta.Add_Click({
                if ($lv.SelectedItems.Count -eq 0) { return }
                $it = $lv.SelectedItems[0].Tag
                if ($null -ne $it -and "$($it.Caminho)" -ne "" -and (Test-Path $it.Caminho)) {
                    Start-Process "explorer.exe" ("/select,`"" + $it.Caminho + "`"")
                }
                elseif ($Script:XmlUltimoLote -ne "" -and (Test-Path -LiteralPath $Script:XmlUltimoLote)) {
                    Start-Process "explorer.exe" ("`"" + $Script:XmlUltimoLote + "`"")
                }
                else { & $setStatus "Nenhum arquivo gravado para essa linha." $Script:UiAmarelo }
            })

        # Clique no cabecalho reordena a lista. Repinta a partir dos resultados em
        # memoria, guardando antes o que estava marcado para nao perder a selecao.
        $lv.Add_ColumnClick({
                param($s, $e)
                if ($Script:XmlResultados.Count -eq 0) { return }
                foreach ($lvi in $lv.Items) { if ($null -ne $lvi.Tag) { $lvi.Tag.Marcado = $lvi.Checked } }

                if ($Script:XmlOrdemCol -eq $e.Column) { $Script:XmlOrdemAsc = -not $Script:XmlOrdemAsc }
                else { $Script:XmlOrdemCol = $e.Column; $Script:XmlOrdemAsc = $true }

                $expr = { [long]$_.Nota }
                switch ($e.Column) {
                    1 { $expr = { [int]$_.Serie } }
                    2 { $expr = { if ($null -ne $_.Data) { [datetime]$_.Data } else { [datetime]::MinValue } } }
                    3 { $expr = { if ([bool]$_.Cancelada) { "CANCELADA" } else { "$($_.Status)" } } }
                    4 { $expr = { "$($_.Chave)" } }
                    5 { $expr = { [long]$_.Tamanho } }
                    6 { $expr = { "$($_.Arquivo)" } }
                    7 { $expr = { if ($null -ne $_.Pedido) { [long]$_.Pedido } else { [long]-1 } } }
                    8 { $expr = { if ($null -ne $_.Valor) { [decimal]$_.Valor } else { [decimal]-1 } } }
                    9 { $expr = { "$(& $nomeEmpresa $_.Servidor)" } }
                }
                if ($Script:XmlOrdemAsc) { $ord = @($Script:XmlResultados | Sort-Object $expr) }
                else { $ord = @($Script:XmlResultados | Sort-Object $expr -Descending) }
                $Script:XmlResultados = $ord
                [void](& $repintaLista)
            })

        # Trocar o tipo depois da busca refiltra a tela na hora, sem nova consulta
        $cmbTipo.Add_SelectedIndexChanged({
                if ($Script:XmlResultados.Count -eq 0) { return }
                $vis = & $repintaLista
                if ($vis -eq 0) {
                    & $setStatus "Nenhuma das $($Script:XmlResultados.Count) notas se encaixa em ""$($cmbTipo.Text)""." $Script:UiAmarelo
                }
                elseif ($vis -eq $Script:XmlResultados.Count) {
                    & $setStatus "Mostrando todas as $vis notas da busca." $Script:UiVerde
                }
                else {
                    & $setStatus "Mostrando $vis de $($Script:XmlResultados.Count) notas - filtro: $($cmbTipo.Text)" $Script:UiVerde
                }
            })

        $miTodos.Add_Click({
                & $marcarTodas $true
                & $setStatus "$($lv.CheckedItems.Count) nota(s) com XML marcadas." $Script:UiSuave
            })

        $miNenhum.Add_Click({
                & $marcarTodas $false
                & $setStatus "Nenhuma nota marcada. Marque as que quer baixar e clique em BAIXAR SELECIONADOS." $Script:UiSuave
            })

        $btnMarcar.Add_Click({
                if ($lv.CheckedItems.Count -gt 0) {
                    & $marcarTodas $false
                    & $setStatus "Nenhuma nota marcada. Marque as que quer baixar e clique em BAIXAR SELECIONADOS." $Script:UiSuave
                }
                else {
                    & $marcarTodas $true
                    & $setStatus "$($lv.CheckedItems.Count) nota(s) com XML marcadas." $Script:UiSuave
                }
            })

        # Clique na caixinha de uma linha atualiza o contador e o botao. O delegate
        # fica guardado para a lista poder soltar e religar o mesmo evento.
        $aoMarcarLinha = [System.Windows.Forms.ItemCheckedEventHandler] { & $atualizaMarcadas }
        $lv.add_ItemChecked($aoMarcarLinha)

        # Enter nos campos principais evita ter que ir ate o botao
        $txtNotas.Add_KeyDown({
                param($s, $e)
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                    $e.SuppressKeyPress = $true
                    [void](& $buscar)
                }
            })

        $txtPedidos.Add_KeyDown({
                param($s, $e)
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                    $e.SuppressKeyPress = $true
                    [void](& $buscar)
                }
            })

        $txtServidor.Add_KeyDown({
                param($s, $e)
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
                    $e.SuppressKeyPress = $true
                    & $testar
                }
            })

        $f.Add_FormClosing({
                $Script:XmlCancelar = $true; $Script:XmlForm = $null
                # Ordem das colunas arrastadas: DisplayIndex de cada coluna, na ordem dos indices
                try {
                    $ordem = @(foreach ($col in $lv.Columns) { $col.DisplayIndex }) -join ','
                    Set-Content -Path $Script:XmlArqColunas -Value $ordem -ErrorAction Stop
                }
                catch {}
            })

        & $atualizaModo
        & $contaNotas
        Log-Message "INFO" "XMLs: janela de download aberta"

        # Uma unica tentativa de conexao, ja com a janela na tela e com timeout de
        # 3s: em PDV sem SQL a tela abre normal em vez de ficar presa esperando.
        $f.Add_Shown({ & $testar -Auto })
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch {
        Log-Message "ERRO" "Falha no download de XMLs: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir a janela: $($_.Exception.Message)", "Baixar XMLs NFC-e", "OK", "Error") | Out-Null
    }
}

# -----------------------------------------------------------------------------
# BACKUP DO BANCO (SQL SERVER)
# O mesmo backup "Cheio" do manual interno (SSMS > Tarefas > Backup), feito pelo
# proprio SQL: o banco fica online, sem parar o servico e sem desanexar. O .bak
# nasce no disco da maquina do SQL e quem grava e a conta do servico do SQL, por
# isso a janela roda no servidor e libera a pasta de destino para essa conta.
# -----------------------------------------------------------------------------

function New-SqlTextoConexao {
    # Texto de conexao com o usuario sa. Servidor remoto vai forcado por TCP: sem
    # protocolo, quando o TCP falha o SqlClient ainda tenta Named Pipes, que ignora
    # o Connect Timeout (IP errado levava ate 24 s para dar erro).
    param([string]$Servidor, [string]$Senha, [string]$Banco = "master", [int]$Timeout = 8)
    $srv = "$Servidor".Trim()
    if ($srv -eq "") { $srv = "127.0.0.1" }
    $local = '^(\.|\(local\)|localhost|127\.0\.0\.1|' + [regex]::Escape($env:COMPUTERNAME) + ')([\\,]|$)'
    if ($srv -notmatch ':' -and $srv -notmatch $local) { $srv = "tcp:" + $srv }
    # O builder cuida de senha com ; ou aspas. Pelas chaves: no PowerShell ele e um
    # dicionario, e $b.DataSource = ... viraria uma chave "DataSource" invalida.
    $b = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $b["Data Source"] = $srv
    $b["Initial Catalog"] = $Banco
    $b["User ID"] = "sa"
    $b["Password"] = $Senha
    $b["Connect Timeout"] = $Timeout
    $b["TrustServerCertificate"] = $true
    return $b.ConnectionString
}

function Wait-SqlTarefa {
    # Espera uma tarefa assincrona do SqlClient (OpenAsync, ExecuteNonQueryAsync...)
    # com a janela respondendo. -AoEsperar roda a cada -IntervaloMs durante a espera.
    # Se a tarefa falhou, lanca o erro original.
    param($Tarefa, [scriptblock]$AoEsperar, [int]$IntervaloMs = 250)
    $relogioEspera = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not $Tarefa.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 40
        if ($null -ne $AoEsperar -and $relogioEspera.ElapsedMilliseconds -ge $IntervaloMs) {
            $relogioEspera.Restart()
            $null = & $AoEsperar
        }
    }
    if ($Tarefa.IsFaulted) { throw $Tarefa.Exception.GetBaseException() }
    if ($Tarefa.IsCanceled) { throw (New-Object System.OperationCanceledException) }
}

function Format-BytesTexto {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return "{0:N1} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N0} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f [math]::Ceiling($Bytes / 1KB)
}

function Test-SqlLocal {
    # O backup so faz sentido na maquina do SQL: e no disco dela que o .bak nasce
    param([string]$MaquinaSql)
    return ("$MaquinaSql".Trim() -ieq "$env:COMPUTERNAME")
}

function Test-EspacoBackup {
    # Cabe o backup no disco da pasta de destino? Pede 10% de folga.
    # Devolve hashtable: Ok / Livre / Precisa / Texto
    param([string]$Pasta, [long]$Bytes)
    $raiz = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($Pasta))
    $livre = [long](New-Object System.IO.DriveInfo($raiz)).AvailableFreeSpace
    $precisa = [long]($Bytes * 1.1)
    $res = @{ Ok = ($livre -ge $precisa); Livre = $livre; Precisa = $precisa; Texto = "" }
    if (-not $res.Ok) {
        $res.Texto = "Não há espaço em {0} para o backup: precisa de {1} e há {2} livres." -f $raiz.TrimEnd('\'), (Format-BytesTexto $precisa), (Format-BytesTexto $livre)
    }
    return $res
}

function Get-SqlIdLoja {
    # ID da loja (IDParceiro do NetWebPDV), tirado da tabela de numeracao das NFC-e.
    # Mais de uma loja no mesmo banco vem junta ("1234-77"), a de mais notas
    # primeiro. Banco sem essa tabela devolve "".
    param($Conexao, [string]$Banco)
    $tabela = "[" + $Banco.Replace("]", "]]") + "].dbo.NFCeTokenID"
    try {
        $cmd = $Conexao.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = "IF OBJECT_ID(@t) IS NOT NULL SELECT TOP (3) CAST(IDParceiro AS nvarchar(40)) AS loja FROM " + $tabela +
        " GROUP BY IDParceiro ORDER BY COUNT(*) DESC"
        [void]$cmd.Parameters.AddWithValue("@t", $tabela)
        $tarefa = $cmd.ExecuteReaderAsync()
        Wait-SqlTarefa $tarefa
        $rd = $tarefa.Result
        $lojas = @()
        try { while ($rd.Read()) { $lojas += "$($rd['loja'])" } }
        finally { $rd.Close() }
        return ($lojas -join "-")
    }
    catch { return "" }
}

function Get-BackupNomeArquivo {
    # "NetWebPDV - Loja 1234 - 12-09-2026 15h30.bak": banco, ID da loja e data. A
    # hora vai junto para dois backups do mesmo dia nao se confundirem. Sem ID da
    # loja, entra o nome da maquina. Nunca repete um .bak ou .zip que ja esteja na
    # pasta: vira "(2)", "(3)".
    param([string]$Banco, [string]$Loja, [string]$Maquina, [datetime]$Data, [string]$Pasta)
    $nomeBanco = $Banco
    if ($Banco -ieq 'netwebpdv') { $nomeBanco = 'NetWebPDV' }
    $origem = $Maquina
    if ("$Loja".Trim() -ne "") { $origem = "Loja " + "$Loja".Trim() }
    $base = ($nomeBanco + " - " + $origem + " - " + $Data.ToString("dd-MM-yyyy HH'h'mm")) -replace '[\\/:*?"<>|]', '-'
    $caminho = Join-Path $Pasta ($base + ".bak")
    $n = 1
    while ((Test-Path -LiteralPath $caminho) -or (Test-Path -LiteralPath ([System.IO.Path]::ChangeExtension($caminho, ".zip")))) {
        $n++
        $caminho = Join-Path $Pasta ($base + " ($n).bak")
    }
    return $caminho
}

function Get-TextoErroSql {
    # Junta todas as mensagens do SqlException: o BACKUP manda o motivo real numa
    # mensagem e o "terminating abnormally" em outra
    param($Erro)
    $e = $Erro
    while ($null -ne $e -and $e -isnot [System.Data.SqlClient.SqlException]) { $e = $e.InnerException }
    if ($null -ne $e) { return (@($e.Errors | ForEach-Object { $_.Message }) -join " ") }
    return "$($Erro.Message)"
}

function Test-ErroSemPermissao {
    # "Operating system error 5(Access is denied.)" ou, com o SQL em portugues,
    # "Erro do sistema operacional 5(Acesso negado.)"
    param($Erro)
    return ((Get-TextoErroSql $Erro) -match '(error|erro)\D{0,30}\b5\s*\(')
}

function Get-BackupErroTexto {
    # Frase que diz o que fazer, no lugar da mensagem crua do SQL
    param($Erro, [string]$Pasta)
    $texto = Get-TextoErroSql $Erro
    if (Test-ErroSemPermissao $Erro) {
        return "O SQL Server não tem permissão para gravar em ""$Pasta"" nem na pasta de dados dele. Rode o Preparador como administrador e tente de novo."
    }
    if ($texto -match '\b112\s*\(') { return "Acabou o espaço no disco durante o backup. Libere espaço e tente de novo." }
    $sql = $Erro
    while ($null -ne $sql -and $sql -isnot [System.Data.SqlClient.SqlException]) { $sql = $sql.InnerException }
    if ($null -ne $sql) {
        if ($sql.Number -eq 18456) { return "O SQL Server recusou o usuário sa com essa senha." }
        if (@(-1, 2, 26, 40, 53, 64, 258, 1225, 10060, 10061, 10065, 11001) -contains $sql.Number) {
            return "Não achei o SQL Server nesta máquina. Confira em Serviços do SQL Server se ele está iniciado."
        }
    }
    return $texto
}

function Get-SqlContasServico {
    # Contas com que o servico do SQL grava no disco: a conta de logon do servico
    # (NETWORK SERVICE, conta de dominio...) e a conta virtual NT SERVICE\MSSQL...,
    # que o SQL 2008 em diante usa a partir do Windows 7 / Server 2008 R2
    param($Conexao)
    $contas = New-Object System.Collections.Generic.List[string]
    $instancia = ""
    try {
        $cmd = $Conexao.CreateCommand()
        $cmd.CommandTimeout = 30
        $cmd.CommandText = "SELECT CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128))"
        $v = $cmd.ExecuteScalar()
        if ($null -ne $v -and $v -isnot [System.DBNull]) { $instancia = "$v" }

        # sys.dm_server_services so existe do 2008 R2 SP1 em diante
        $cmd.CommandText = 'DECLARE @s TABLE (servico nvarchar(256), conta nvarchar(256)); ' +
        'BEGIN TRY INSERT @s EXEC (N''SELECT servicename, service_account FROM sys.dm_server_services''); END TRY BEGIN CATCH END CATCH; ' +
        'SELECT servico, conta FROM @s'
        $rd = $cmd.ExecuteReader()
        try {
            while ($rd.Read()) {
                if ("$($rd['servico'])" -like 'SQL Server (*' -and -not $rd.IsDBNull(1)) { $contas.Add("$($rd['conta'])") }
            }
        }
        finally { $rd.Close() }
    }
    catch {}

    $nomeServico = "MSSQLSERVER"
    if ($instancia -ne "") { $nomeServico = 'MSSQL$' + $instancia }
    $contas.Add('NT SERVICE\' + $nomeServico)
    try {
        $svc = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $nomeServico.Replace("'", "''") + "'") -ErrorAction Stop
        if ($null -ne $svc -and "$($svc.StartName)" -ne "") { $contas.Add("$($svc.StartName)") }
    }
    catch {}

    # ".\usuario" e conta local: o Windows so reconhece com o nome da maquina
    return @($contas | ForEach-Object { $_ -replace '^\.\\', ($env:COMPUTERNAME + '\') } | Select-Object -Unique)
}

function Grant-PastaBackupSql {
    # Cria a pasta e da permissao de alteracao as contas do servico do SQL, que e
    # quem grava o .bak. Conta que nao existe nesta maquina e so ignorada.
    # Devolve as contas que receberam a permissao.
    param([string]$Pasta, [string[]]$Contas)
    if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }
    $dir = New-Object System.IO.DirectoryInfo($Pasta)
    $dadas = New-Object System.Collections.Generic.List[string]
    foreach ($conta in @($Contas | Where-Object { "$_".Trim() -ne "" } | Select-Object -Unique)) {
        # LocalSystem ja tem acesso a tudo
        if ($conta -match '^(LocalSystem|NT AUTHORITY\\SYSTEM)$') { continue }
        try {
            $acl = $dir.GetAccessControl()
            $regra = New-Object System.Security.AccessControl.FileSystemAccessRule($conta, 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            $acl.AddAccessRule($regra)
            $dir.SetAccessControl($acl)
            $dadas.Add($conta)
        }
        catch {}
    }
    return $dadas.ToArray()
}

function Compress-ArquivoZip {
    # Compacta um arquivo sozinho num .zip, com progresso e cancelamento. O
    # ZipFile.CreateFromDirectory nao avisa progresso, e um .bak de alguns GB
    # deixaria a janela parada. Devolve $true se terminou; cancelado apaga o .zip.
    param([string]$Origem, [string]$Destino, [scriptblock]$AoProgredir, [scriptblock]$Cancelado)
    Add-Type -AssemblyName System.IO.Compression
    $zipTotal = (Get-Item -LiteralPath $Origem).Length
    $zipCancelou = $false
    $zipArquivo = [System.IO.File]::Open($Destino, [System.IO.FileMode]::Create)
    try {
        $zipPacote = New-Object System.IO.Compression.ZipArchive($zipArquivo, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            $zipEntrada = $zipPacote.CreateEntry([System.IO.Path]::GetFileName($Origem), [System.IO.Compression.CompressionLevel]::Optimal)
            $zipEntrada.LastWriteTime = [DateTimeOffset](Get-Item -LiteralPath $Origem).LastWriteTime
            $zipSaida = $zipEntrada.Open()
            $zipLeitura = [System.IO.File]::OpenRead($Origem)
            try {
                $zipBuffer = New-Object byte[] (4MB)
                $zipLidos = [long]0
                $zipRelogio = [System.Diagnostics.Stopwatch]::StartNew()
                while (($zipN = $zipLeitura.Read($zipBuffer, 0, $zipBuffer.Length)) -gt 0) {
                    $zipSaida.Write($zipBuffer, 0, $zipN)
                    $zipLidos += $zipN
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($null -ne $Cancelado -and (& $Cancelado)) { $zipCancelou = $true; break }
                    if ($null -ne $AoProgredir -and $zipRelogio.ElapsedMilliseconds -ge 250) {
                        $zipRelogio.Restart()
                        $null = & $AoProgredir ([math]::Round(100.0 * $zipLidos / [math]::Max($zipTotal, 1), 1))
                    }
                }
            }
            finally {
                $zipLeitura.Dispose()
                $zipSaida.Dispose()
            }
        }
        finally { $zipPacote.Dispose() }
    }
    finally { $zipArquivo.Dispose() }
    if ($zipCancelou) {
        Remove-Item -LiteralPath $Destino -Force -ErrorAction SilentlyContinue
        return $false
    }
    if ($null -ne $AoProgredir) { $null = & $AoProgredir 100 }
    return $true
}

function Invoke-BackupBanco {
    # Faz o backup completo do banco e confere o arquivo. Nao lanca excecao: o
    # resultado diz o que aconteceu, e a janela so cuida da tela.
    #   -AoProgredir { param($Etapa, $Pct) }   Pct -1 = etapa sem porcentagem
    #   -Cancelado { $true para parar }
    #   -SoPelaPastaDoSql: pula a gravacao direta no destino (testa a 2a tentativa)
    # Devolve hashtable: Ok / Cancelado / Verificado / Arquivo / Bytes / Zip / ZipBytes /
    #   Duracao / Erro / Aviso / PelaPastaDoSql / Loja
    param([string]$TextoConexao, [string]$Banco, [string]$Pasta, [switch]$Compactar,
        [scriptblock]$AoProgredir, [scriptblock]$Cancelado, [switch]$SoPelaPastaDoSql)

    $res = @{
        Ok = $false; Cancelado = $false; Verificado = $false; Arquivo = ""; Bytes = [long]0; Zip = ""; ZipBytes = [long]0
        Duracao = [timespan]::Zero; Erro = ""; Aviso = ""; PelaPastaDoSql = $false; Loja = ""
    }
    # Nomes proprios de proposito: estes blocos rodam de dentro de outras funcoes
    # (Wait-SqlTarefa, Compress-ArquivoZip), e um nome comum como $AoProgredir
    # seria achado primeiro la dentro, chamando a si mesmo
    $bkpAoProgredir = $AoProgredir
    $bkpCancelado = $Cancelado
    $bkpAvisa = { param($Etapa, $Pct) if ($null -ne $bkpAoProgredir) { $null = & $bkpAoProgredir $Etapa $Pct } }
    $bkpParar = { ($null -ne $bkpCancelado) -and [bool](& $bkpCancelado) }
    $bkpEstado = @{ PediuParar = $false }
    $bkpRelogio = [System.Diagnostics.Stopwatch]::StartNew()
    $bkpApagar = New-Object System.Collections.Generic.List[string]
    $cnBanco = $null
    $cnVigia = $null

    try {
        & $bkpAvisa "Conectando" -1
        $cnBanco = New-Object System.Data.SqlClient.SqlConnection($TextoConexao)
        Wait-SqlTarefa $cnBanco.OpenAsync()
        $cnVigia = New-Object System.Data.SqlClient.SqlConnection($TextoConexao)
        Wait-SqlTarefa $cnVigia.OpenAsync()

        $bkpValor = {
            param([string]$Sql, $Valor)
            $cmdValor = $cnBanco.CreateCommand()
            $cmdValor.CommandTimeout = 60
            $cmdValor.CommandText = $Sql
            if ($null -ne $Valor) { [void]$cmdValor.Parameters.AddWithValue("@v", $Valor) }
            $tarefaValor = $cmdValor.ExecuteScalarAsync()
            Wait-SqlTarefa $tarefaValor
            $v = $tarefaValor.Result
            if ($v -is [System.DBNull]) { return $null }
            return $v
        }

        $maquina = "$(& $bkpValor "SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(128))")"
        if (-not (Test-SqlLocal -MaquinaSql $maquina)) {
            throw "Esse SQL Server está na máquina $maquina, e o backup precisa ser feito nela: abra o Preparador no servidor."
        }
        if ($null -eq (& $bkpValor "SELECT DB_ID(@v)" $Banco)) { throw "O banco ""$Banco"" não existe nesse SQL Server." }
        $nomeSql = "[" + $Banco.Replace("]", "]]") + "]"

        # O backup ocupa mais ou menos as paginas de dados em uso
        $usado = [long](& $bkpValor ("SELECT ISNULL(SUM(CAST(used_pages AS bigint)), 0) * 8192 FROM " + $nomeSql + ".sys.allocation_units"))
        if (-not (Test-Path -LiteralPath $Pasta)) { New-Item -ItemType Directory -Path $Pasta -Force | Out-Null }
        $espaco = Test-EspacoBackup -Pasta $Pasta -Bytes $usado
        if (-not $espaco.Ok) { throw $espaco.Texto }

        # Maquina pelo nome do Windows (o do SQL pode vir com outra caixa), igual a
        # previa da janela; so entra no nome quando o banco nao tem ID de loja
        $res.Loja = Get-SqlIdLoja -Conexao $cnBanco -Banco $Banco
        $arquivo = Get-BackupNomeArquivo -Banco $Banco -Loja $res.Loja -Maquina $env:COMPUTERNAME -Data (Get-Date) -Pasta $Pasta
        $spid = [int](& $bkpValor "SELECT @@SPID")

        # Comando longo (BACKUP, RESTORE VERIFYONLY) sem travar a janela: a
        # porcentagem vem de outra conexao e o cancelamento e atendido na hora
        $bkpLongo = {
            param([string]$Sql, [string]$Etapa, [string]$Caminho)
            $cmdLongo = $cnBanco.CreateCommand()
            $cmdLongo.CommandTimeout = 0
            $cmdLongo.CommandText = $Sql
            [void]$cmdLongo.Parameters.AddWithValue("@arquivo", $Caminho)
            $cmdVigia = $cnVigia.CreateCommand()
            $cmdVigia.CommandTimeout = 10
            $cmdVigia.CommandText = "SELECT percent_complete FROM sys.dm_exec_requests WHERE session_id = @s"
            [void]$cmdVigia.Parameters.AddWithValue("@s", $spid)
            if (& $bkpParar) { $bkpEstado.PediuParar = $true; throw "Backup cancelado." }
            & $bkpAvisa $Etapa 0
            $tarefaLonga = $cmdLongo.ExecuteNonQueryAsync()
            Wait-SqlTarefa $tarefaLonga -IntervaloMs 500 -AoEsperar {
                if (-not $bkpEstado.PediuParar -and (& $bkpParar)) {
                    $bkpEstado.PediuParar = $true
                    try { $cmdLongo.Cancel() } catch {}
                }
                try {
                    $pctLido = $cmdVigia.ExecuteScalar()
                    if ($null -ne $pctLido -and $pctLido -isnot [System.DBNull] -and [double]$pctLido -gt 0) {
                        & $bkpAvisa $Etapa ([math]::Round([double]$pctLido, 1))
                    }
                }
                catch {}
            }
            if ($bkpEstado.PediuParar) { throw "Backup cancelado." }
            & $bkpAvisa $Etapa 100
        }

        # COPY_ONLY: nao mexe na sequencia de backups que o cliente ja tenha.
        # CHECKSUM: o SQL confere cada pagina enquanto grava.
        $sqlBackup = "BACKUP DATABASE " + $nomeSql + " TO DISK = @arquivo WITH COPY_ONLY, INIT, CHECKSUM, NAME = N'Preparador de Ambiente'"
        $gravarEm = $null
        if (-not $SoPelaPastaDoSql) {
            [void](Grant-PastaBackupSql -Pasta $Pasta -Contas (Get-SqlContasServico -Conexao $cnBanco))
            $bkpApagar.Add($arquivo)
            try {
                & $bkpLongo $sqlBackup "Fazendo backup" $arquivo
                $gravarEm = $arquivo
            }
            catch {
                if ($bkpEstado.PediuParar -or -not (Test-ErroSemPermissao $_.Exception)) { throw }
            }
        }
        if ($null -eq $gravarEm) {
            # Segunda tentativa: o SQL nao conseguiu gravar no destino (Area de
            # Trabalho no OneDrive, politica de rede...). Grava na pasta de dados
            # do proprio banco, onde ele sempre tem permissao, e depois move.
            $mdf = "$(& $bkpValor "SELECT TOP 1 physical_name FROM sys.master_files WHERE database_id = DB_ID(@v) AND type = 0 ORDER BY file_id" $Banco)"
            $gravarEm = Join-Path (Split-Path $mdf) (Split-Path $arquivo -Leaf)
            $bkpApagar.Add($gravarEm)
            & $bkpLongo $sqlBackup "Fazendo backup" $gravarEm
        }

        # RESTORE VERIFYONLY: confirma que o arquivo esta integro e restauravel
        & $bkpLongo "RESTORE VERIFYONLY FROM DISK = @arquivo WITH CHECKSUM" "Conferindo o arquivo" $gravarEm
        $res.Verificado = $true

        if ($gravarEm -ne $arquivo) {
            & $bkpAvisa "Movendo para a pasta de backups" -1
            $bkpApagar.Add($arquivo)
            Move-Item -LiteralPath $gravarEm -Destination $arquivo -Force
            # Larga as permissoes da pasta do SQL e herda as da pasta de destino,
            # como se o arquivo tivesse nascido la
            $seguranca = New-Object System.Security.AccessControl.FileSecurity
            $seguranca.SetAccessRuleProtection($false, $false)
            [System.IO.File]::SetAccessControl($arquivo, $seguranca)
            $res.PelaPastaDoSql = $true
        }

        $res.Arquivo = $arquivo
        $res.Bytes = (Get-Item -LiteralPath $arquivo).Length
        $bkpApagar.Clear()
        $res.Ok = $true

        if ($Compactar) {
            $zip = [System.IO.Path]::ChangeExtension($arquivo, ".zip")
            try {
                & $bkpAvisa "Compactando" 0
                $zipPronto = Compress-ArquivoZip -Origem $arquivo -Destino $zip -AoProgredir { param($pctZip) & $bkpAvisa "Compactando" $pctZip } -Cancelado $bkpCancelado
                if ($zipPronto) {
                    $res.Zip = $zip
                    $res.ZipBytes = (Get-Item -LiteralPath $zip).Length
                }
                else { $res.Aviso = "Compactação cancelada: o .bak ficou pronto, só não tem o .zip." }
            }
            catch {
                Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
                $res.Aviso = "Não deu para compactar ($($_.Exception.Message)). O .bak ficou pronto."
            }
        }
    }
    catch {
        if ($bkpEstado.PediuParar -or (& $bkpParar)) {
            $res.Cancelado = $true
            $res.Erro = "Backup cancelado."
        }
        else { $res.Erro = Get-BackupErroTexto -Erro $_.Exception -Pasta $Pasta }
        # Nada pela metade: o SQL ainda pode segurar o arquivo por um instante
        foreach ($parcial in $bkpApagar) {
            for ($tentativa = 0; $tentativa -lt 20 -and (Test-Path -LiteralPath $parcial); $tentativa++) {
                try { Remove-Item -LiteralPath $parcial -Force -ErrorAction Stop }
                catch { Start-Sleep -Milliseconds 250 }
            }
        }
    }
    finally {
        foreach ($conexaoAberta in @($cnBanco, $cnVigia)) {
            if ($null -ne $conexaoAberta) { try { $conexaoAberta.Close() } catch {} }
        }
        $res.Duracao = $bkpRelogio.Elapsed
    }
    return $res
}

function Show-BackupBanco {
    try {
        if ($null -ne $Script:BkpForm -and -not $Script:BkpForm.IsDisposed) {
            $Script:BkpForm.Activate(); return
        }

        $Script:BkpCancelar = $false
        $Script:BkpOcupado = $false
        $Script:BkpFecharAoTerminar = $false
        $Script:BkpBancos = @{}
        $Script:BkpLojas = @{}

        $f = New-ToolForm "Backup do Banco NetWebPDV" 780 540
        $f.MinimumSize = New-Object System.Drawing.Size(780, 540)
        $Script:BkpForm = $f

        $novoCartao = {
            param([int]$Y, [int]$H)
            $p = New-Object System.Windows.Forms.Panel
            $p.Location = New-Object System.Drawing.Point(20, $Y)
            $p.Size = New-Object System.Drawing.Size(724, $H)
            $p.BackColor = $Script:UiCartao
            $p.Anchor = 'Top,Left,Right'
            [void]$f.Controls.Add($p)
            return $p
        }
        $novoCampo = {
            param($Pai, [int]$X, [int]$Y, [int]$W, [string]$Valor)
            $t = New-Object System.Windows.Forms.TextBox
            $t.Location = New-Object System.Drawing.Point($X, $Y)
            $t.Size = New-Object System.Drawing.Size($W, 24)
            $t.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $t.ForeColor = $Script:UiTexto
            $t.BorderStyle = 'FixedSingle'
            $t.Text = $Valor
            [void]$Pai.Controls.Add($t)
            return $t
        }

        New-ToolLabel $f "BACKUP DO BANCO DE DADOS" 20 14 12 -Negrito | Out-Null
        New-ToolLabel $f "Backup completo pelo próprio SQL Server, com o banco online: sem parar o serviço e sem desanexar." 20 42 9 -Cor $Script:UiSuave -W 724 | Out-Null

        # CONEXAO
        $cardConn = & $novoCartao 70 86
        New-ToolLabel $cardConn "CONEXÃO" 14 8 10 -Negrito | Out-Null
        New-ToolLabel $cardConn "Servidor:" 14 38 9 -Cor $Script:UiSuave | Out-Null
        $txtBkpServidor = & $novoCampo $cardConn 80 35 150 "127.0.0.1"
        New-ToolLabel $cardConn "Senha:" 246 38 9 -Cor $Script:UiSuave | Out-Null
        $txtBkpSenha = & $novoCampo $cardConn 294 35 130 "netcontroll"
        $btnBkpTestar = New-ToolButton $cardConn "TESTAR CONEXÃO" 440 34 150 27 $Script:UiAzul $null "Conecta no SQL Server desta máquina e lista os bancos"
        $lblBkpConn = New-ToolLabel $cardConn "Conectando..." 14 64 9 -Cor $Script:UiSuave -W 700

        # O QUE SALVAR
        $cardBkp = & $novoCartao 166 146
        New-ToolLabel $cardBkp "O QUE SALVAR" 14 8 10 -Negrito | Out-Null
        New-ToolLabel $cardBkp "Banco:" 14 40 9 -Cor $Script:UiSuave | Out-Null
        $cmbBkpBanco = New-Object System.Windows.Forms.ComboBox
        $cmbBkpBanco.Location = New-Object System.Drawing.Point(90, 37)
        $cmbBkpBanco.Width = 220
        $cmbBkpBanco.DropDownStyle = 'DropDownList'
        $cmbBkpBanco.FlatStyle = 'Flat'
        $cmbBkpBanco.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
        $cmbBkpBanco.ForeColor = $Script:UiTexto
        [void]$cardBkp.Controls.Add($cmbBkpBanco)
        $lblBkpTamanho = New-ToolLabel $cardBkp "" 324 40 9 -Cor $Script:UiSuave -W 390
        New-ToolLabel $cardBkp "Salvar em:" 14 70 9 -Cor $Script:UiSuave | Out-Null
        $lblBkpPasta = New-ToolLabel $cardBkp $Script:BackupPasta 90 70 9 -W 620
        New-ToolLabel $cardBkp "Arquivo:" 14 94 9 -Cor $Script:UiSuave | Out-Null
        $lblBkpArquivo = New-ToolLabel $cardBkp "" 90 94 9 -Cor $Script:UiSuave -W 620
        $chkBkpZip = New-Object System.Windows.Forms.CheckBox
        $chkBkpZip.Text = "Compactar em .zip ao terminar (fica bem menor para enviar)"
        $chkBkpZip.Location = New-Object System.Drawing.Point(14, 118)
        $chkBkpZip.Size = New-Object System.Drawing.Size(600, 22)
        $chkBkpZip.ForeColor = $Script:UiTexto
        $chkBkpZip.BackColor = [System.Drawing.Color]::Transparent
        $chkBkpZip.Checked = $true
        [void]$cardBkp.Controls.Add($chkBkpZip)

        # PROGRESSO E BOTOES
        $lblBkpEtapa = New-ToolLabel $f "" 20 326 9.5 -Negrito -W 724
        $pbBkp = New-Object System.Windows.Forms.ProgressBar
        $pbBkp.Location = New-Object System.Drawing.Point(20, 350)
        $pbBkp.Size = New-Object System.Drawing.Size(724, 18)
        $pbBkp.Style = 'Continuous'
        $pbBkp.MarqueeAnimationSpeed = 30
        $pbBkp.Anchor = 'Top,Left,Right'
        [void]$f.Controls.Add($pbBkp)

        $btnBkpFazer = New-ToolButton $f "FAZER BACKUP" 20 384 200 34 $Script:UiVerde $null "Faz o backup completo, confere se o arquivo restaura e abre a pasta no fim"
        $btnBkpFazer.Enabled = $false
        $btnBkpCancelar = New-ToolButton $f "CANCELAR" 230 384 120 34 $Script:UiVermelho $null "Interrompe o backup e apaga o arquivo pela metade"
        $btnBkpCancelar.Enabled = $false
        $btnBkpPasta = New-ToolButton $f "ABRIR PASTA" 360 384 150 34 $Script:UiCinza $null "Abre a pasta dos backups"
        $btnBkpFechar = New-ToolButton $f "FECHAR" 624 384 120 34 $Script:UiCinza $null "Fecha esta janela"
        $btnBkpFechar.Anchor = 'Top,Right'
        $lblBkpStatus = New-ToolLabel $f "O banco continua no ar durante o backup: o PDV não trava e ninguém precisa parar de vender." 20 430 9 -Cor $Script:UiSuave -W 724

        if ($Script:ToolTip) {
            $Script:ToolTip.SetToolTip($txtBkpServidor, "Deixe 127.0.0.1: o backup é gravado no disco da máquina do SQL, então o Preparador precisa estar rodando nela.")
            $Script:ToolTip.SetToolTip($cmbBkpBanco, "Bancos de usuário desse SQL Server. O netwebpdv já vem escolhido quando existe.")
            $Script:ToolTip.SetToolTip($lblBkpPasta, "Pasta fixa dos backups, dentro de Arquivos Xmenu na Área de Trabalho.")
            $Script:ToolTip.SetToolTip($chkBkpZip, "O .bak tem o tamanho dos dados. Compactado costuma ficar 80 a 90% menor, bom para WeTransfer ou pendrive.")
        }

        # ---------------------------------------------------------------------
        # ROTINAS DA JANELA
        # ---------------------------------------------------------------------
        $atualizaArquivo = {
            $nomeBanco = "$($cmbBkpBanco.Text)"
            if ($nomeBanco -eq "") { $lblBkpTamanho.Text = ""; $lblBkpArquivo.Text = ""; return }
            if ($Script:BkpBancos.ContainsKey($nomeBanco)) {
                $lblBkpTamanho.Text = "ocupa " + (Format-BytesTexto ([long]$Script:BkpBancos[$nomeBanco])) + " no disco (dados + log)"
            }
            $lojaPrevia = ""
            if ($Script:BkpLojas.ContainsKey($nomeBanco)) { $lojaPrevia = $Script:BkpLojas[$nomeBanco] }
            $nomeArq = Split-Path (Get-BackupNomeArquivo -Banco $nomeBanco -Loja $lojaPrevia -Maquina $env:COMPUTERNAME -Data (Get-Date) -Pasta $Script:BackupPasta) -Leaf
            if ($chkBkpZip.Checked) { $nomeArq = $nomeArq + "   +   .zip" }
            $lblBkpArquivo.Text = $nomeArq
        }

        $testarBkp = {
            param([switch]$Auto)
            if ($Script:BkpOcupado) { return }
            $Script:BkpOcupado = $true
            $cnTeste = $null
            $btnBkpTestar.Enabled = $false
            $btnBkpFazer.Enabled = $false
            try {
                $lblBkpConn.ForeColor = $Script:UiAmarelo
                $lblBkpConn.Text = "Conectando..."
                $limite = 8
                if ($Auto) { $limite = 3 }
                $cnTeste = New-Object System.Data.SqlClient.SqlConnection((New-SqlTextoConexao -Servidor $txtBkpServidor.Text -Senha $txtBkpSenha.Text -Timeout $limite))
                Wait-SqlTarefa $cnTeste.OpenAsync()

                $cmdTeste = $cnTeste.CreateCommand()
                $cmdTeste.CommandTimeout = 30
                $cmdTeste.CommandText = "SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS maquina, " +
                "CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS edicao, CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(64)) AS versao; " +
                "SELECT d.name, SUM(CAST(mf.size AS bigint)) * 8192 AS bytes FROM sys.databases d " +
                "JOIN sys.master_files mf ON mf.database_id = d.database_id WHERE d.database_id > 4 AND d.state = 0 " +
                "GROUP BY d.name ORDER BY d.name"
                $tarefaTeste = $cmdTeste.ExecuteReaderAsync()
                Wait-SqlTarefa $tarefaTeste
                $rdTeste = $tarefaTeste.Result
                $maquinaSql = ""
                $versaoSql = ""
                try {
                    if ($rdTeste.Read()) {
                        $maquinaSql = "$($rdTeste['maquina'])"
                        $versaoSql = "$($rdTeste['edicao']) $($rdTeste['versao'])"
                    }
                    [void]$rdTeste.NextResult()
                    $Script:BkpBancos = @{}
                    $cmbBkpBanco.Items.Clear()
                    while ($rdTeste.Read()) {
                        $Script:BkpBancos["$($rdTeste['name'])"] = [long]$rdTeste['bytes']
                        [void]$cmbBkpBanco.Items.Add("$($rdTeste['name'])")
                    }
                }
                finally { $rdTeste.Close() }

                # ID da loja de cada banco, para a previa do nome do arquivo
                $Script:BkpLojas = @{}
                foreach ($nomeLista in @($Script:BkpBancos.Keys)) {
                    $Script:BkpLojas[$nomeLista] = Get-SqlIdLoja -Conexao $cnTeste -Banco $nomeLista
                }

                if (-not (Test-SqlLocal -MaquinaSql $maquinaSql)) {
                    $lblBkpConn.ForeColor = $Script:UiVermelho
                    $lblBkpConn.Text = "Esse SQL Server está na máquina $maquinaSql. O backup precisa ser feito nela: abra o Preparador no servidor."
                    return
                }
                if ($cmbBkpBanco.Items.Count -eq 0) {
                    $lblBkpConn.ForeColor = $Script:UiAmarelo
                    $lblBkpConn.Text = "Conectado ($versaoSql), mas esse SQL Server não tem bancos de usuário."
                    return
                }
                $cmbBkpBanco.SelectedIndex = 0
                for ($i = 0; $i -lt $cmbBkpBanco.Items.Count; $i++) {
                    if ("$($cmbBkpBanco.Items[$i])" -ieq 'netwebpdv') { $cmbBkpBanco.SelectedIndex = $i; break }
                }
                $lblBkpConn.ForeColor = $Script:UiVerde
                $lblBkpConn.Text = "OK - $versaoSql | máquina: $maquinaSql | bancos: $($cmbBkpBanco.Items.Count)"
                $btnBkpFazer.Enabled = $true
            }
            catch {
                $lblBkpConn.ForeColor = $Script:UiVermelho
                $lblBkpConn.Text = Get-BackupErroTexto -Erro $_.Exception -Pasta $Script:BackupPasta
                if (-not $Auto) { Log-Message "ERRO" "Backup: falha de conexão - $($_.Exception.Message)" }
            }
            finally {
                if ($null -ne $cnTeste) { try { $cnTeste.Close() } catch {} }
                $btnBkpTestar.Enabled = $true
                $Script:BkpOcupado = $false
                & $atualizaArquivo
            }
        }

        $fazerBkp = {
            if ($Script:BkpOcupado -or "$($cmbBkpBanco.Text)" -eq "") { return }
            $Script:BkpOcupado = $true
            $Script:BkpCancelar = $false
            $travados = @($btnBkpFazer, $btnBkpTestar, $cmbBkpBanco, $chkBkpZip, $txtBkpServidor, $txtBkpSenha)
            foreach ($ctl in $travados) { $ctl.Enabled = $false }
            $btnBkpCancelar.Enabled = $true
            $bancoEscolhido = "$($cmbBkpBanco.Text)"
            $lblBkpStatus.ForeColor = $Script:UiAmarelo
            $lblBkpStatus.Text = "Backup em andamento. O banco continua no ar e o PDV pode seguir vendendo."
            Log-Message "INFO" "Backup: iniciando o backup do banco $bancoEscolhido em $($Script:BackupPasta)"
            try {
                $argsBkp = @{
                    TextoConexao = (New-SqlTextoConexao -Servidor $txtBkpServidor.Text -Senha $txtBkpSenha.Text -Timeout 15)
                    Banco        = $bancoEscolhido
                    Pasta        = $Script:BackupPasta
                    Compactar    = $chkBkpZip.Checked
                    AoProgredir  = {
                        param($Etapa, $Pct)
                        if ($Pct -lt 0) {
                            $pbBkp.Style = 'Marquee'
                            $lblBkpEtapa.Text = "$Etapa..."
                        }
                        else {
                            $pbBkp.Style = 'Continuous'
                            $pbBkp.Value = [int][math]::Min(100, [math]::Max(0, $Pct))
                            $lblBkpEtapa.Text = "$Etapa... $([math]::Floor($Pct))%"
                        }
                    }
                    Cancelado    = { $Script:BkpCancelar }
                }
                $resBkp = Invoke-BackupBanco @argsBkp

                $pbBkp.Style = 'Continuous'
                if ($resBkp.Ok) {
                    $pbBkp.Value = 100
                    $duracao = "{0}min {1:00}s" -f [int][math]::Floor($resBkp.Duracao.TotalMinutes), $resBkp.Duracao.Seconds
                    $texto = "Backup pronto e conferido: " + (Split-Path $resBkp.Arquivo -Leaf) + " (" + (Format-BytesTexto $resBkp.Bytes) + ")"
                    if ($resBkp.Zip -ne "") { $texto = $texto + " | .zip com " + (Format-BytesTexto $resBkp.ZipBytes) }
                    $texto = $texto + " | " + $duracao
                    $lblBkpEtapa.Text = "Concluído"
                    if ($resBkp.Aviso -ne "") {
                        $lblBkpStatus.ForeColor = $Script:UiAmarelo
                        $texto = $texto + " | " + $resBkp.Aviso
                    }
                    else { $lblBkpStatus.ForeColor = $Script:UiVerde }
                    $lblBkpStatus.Text = $texto
                    Log-Message "SUCESSO" "Backup: $texto - $($resBkp.Arquivo)"

                    # Termina na pasta, com o arquivo pronto para enviar ja selecionado
                    $selecionar = $resBkp.Arquivo
                    if ($resBkp.Zip -ne "") { $selecionar = $resBkp.Zip }
                    try { Start-Process "explorer.exe" ("/select,`"" + $selecionar + "`"") } catch {}
                }
                elseif ($resBkp.Cancelado) {
                    $pbBkp.Value = 0
                    $lblBkpEtapa.Text = ""
                    $lblBkpStatus.ForeColor = $Script:UiAmarelo
                    $lblBkpStatus.Text = "Backup cancelado. Nenhum arquivo pela metade ficou na pasta."
                    Log-Message "CANCEL" "Backup: cancelado pelo usuário"
                }
                else {
                    $pbBkp.Value = 0
                    $lblBkpEtapa.Text = ""
                    $lblBkpStatus.ForeColor = $Script:UiVermelho
                    $lblBkpStatus.Text = "Não foi possível fazer o backup: $($resBkp.Erro)"
                    Log-Message "ERRO" "Backup: $($resBkp.Erro)"
                    [System.Windows.Forms.MessageBox]::Show($resBkp.Erro, "Backup do Banco", "OK", "Error") | Out-Null
                }
            }
            finally {
                foreach ($ctl in $travados) { $ctl.Enabled = $true }
                $btnBkpCancelar.Enabled = $false
                $Script:BkpOcupado = $false
                & $atualizaArquivo
                if ($Script:BkpFecharAoTerminar) { $f.Close() }
            }
        }

        # ---------------------------------------------------------------------
        # EVENTOS
        # ---------------------------------------------------------------------
        $btnBkpTestar.Add_Click({ & $testarBkp })
        $btnBkpFazer.Add_Click($fazerBkp)
        $btnBkpCancelar.Add_Click({
                $Script:BkpCancelar = $true
                $lblBkpStatus.ForeColor = $Script:UiAmarelo
                $lblBkpStatus.Text = "Cancelando o backup..."
            })
        $btnBkpPasta.Add_Click({
                try {
                    if (-not (Test-Path -LiteralPath $Script:BackupPasta)) { New-Item -ItemType Directory -Path $Script:BackupPasta -Force | Out-Null }
                    Start-Process "explorer.exe" ("`"" + $Script:BackupPasta + "`"")
                }
                catch { $lblBkpStatus.Text = "Não deu para abrir a pasta: $($_.Exception.Message)" }
            })
        $btnBkpFechar.Add_Click({ $f.Close() })
        $cmbBkpBanco.Add_SelectedIndexChanged($atualizaArquivo)
        $chkBkpZip.Add_CheckedChanged($atualizaArquivo)
        $txtBkpSenha.Add_KeyDown({
                param($s, $e)
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { $e.SuppressKeyPress = $true; & $testarBkp }
            })

        $f.Add_FormClosing({
                param($s, $e)
                # Fechar no meio do backup cancela primeiro, para nao sobrar arquivo pela metade
                if ($Script:BkpOcupado -and $btnBkpCancelar.Enabled) {
                    $r = [System.Windows.Forms.MessageBox]::Show("Há um backup em andamento.`r`n`r`nDeseja cancelar o backup e fechar a janela?",
                        "Backup do Banco", "YesNo", "Warning")
                    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                        $Script:BkpCancelar = $true
                        $Script:BkpFecharAoTerminar = $true
                    }
                    $e.Cancel = $true
                    return
                }
                $Script:BkpForm = $null
            })

        Log-Message "INFO" "Backup: janela aberta"
        $f.Add_Shown({ & $testarBkp -Auto })
        [void]$f.ShowDialog($Script:MainForm)
    }
    catch {
        Log-Message "ERRO" "Falha na janela de backup: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir a janela: $($_.Exception.Message)", "Backup do Banco", "OK", "Error") | Out-Null
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

# Roda do mouse: o Windows entrega a rolagem para o controle que esta com o foco,
# entao girar a roda sobre a lista de botoes ou sobre uma grade nao fazia nada sem
# clicar antes - e em tela pequena, onde tudo depende de rolar, a janela parecia
# travada. Este filtro entrega a rolagem para o controle que esta embaixo do
# ponteiro, como todo programa moderno faz. Compila so quando a janela abre, para
# nao atrasar a carga do script; se falhar, o programa segue sem isso.
function Enable-RodaDoMouse {
    if ($Script:RodaMouseLigada) { return $true }
    try {
        if (-not ("RodaDoMouse" -as [type])) {
            Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class RodaDoMouse : IMessageFilter
{
    [StructLayout(LayoutKind.Sequential)] private struct PONTO { public int X; public int Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out PONTO p);
    [DllImport("user32.dll")] private static extern IntPtr WindowFromPoint(PONTO p);
    [DllImport("user32.dll")] private static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr wp, IntPtr lp);

    public bool PreFilterMessage(ref Message m)
    {
        // WM_MOUSEWHEEL e WM_MOUSEHWHEEL
        if (m.Msg != 0x020A && m.Msg != 0x020E) { return false; }
        PONTO p;
        if (!GetCursorPos(out p)) { return false; }
        IntPtr alvo = WindowFromPoint(p);
        if (alvo == IntPtr.Zero || alvo == m.HWnd) { return false; }
        // So mexe em controle do proprio programa
        if (Control.FromHandle(alvo) == null) { return false; }
        SendMessage(alvo, m.Msg, m.WParam, m.LParam);
        return true;
    }

    public static void Instalar() { Application.AddMessageFilter(new RodaDoMouse()); }
}
"@
        }
        [RodaDoMouse]::Instalar()
        $Script:RodaMouseLigada = $true
        Log-Message "INFO" "Roda do mouse: rolagem segue o ponteiro (listas, abas e telas pequenas)"
        return $true
    }
    catch {
        Log-Message "ERRO" "Roda do mouse: não consegui ligar a rolagem pelo ponteiro ($($_.Exception.Message))"
        return $false
    }
}

# Ctrl+A nos campos de texto: o TextBox de uma linha do Windows Forms nao faz isso
# sozinho, entao selecionar tudo para apagar e colar outra lista nao funcionava.
$Script:CtrlASelecionaTudo = [System.Windows.Forms.KeyEventHandler] {
    param($s, $e)
    if ($e.Control -and -not $e.Alt -and $e.KeyCode -eq [System.Windows.Forms.Keys]::A) {
        $s.SelectAll()
        $e.SuppressKeyPress = $true
        $e.Handled = $true
    }
}
function Enable-SelecionarTudo {
    param($Pai)
    foreach ($c in $Pai.Controls) {
        if ($c -is [System.Windows.Forms.TextBoxBase]) { $c.add_KeyDown($Script:CtrlASelecionaTudo) }
        elseif ($c -is [System.Windows.Forms.ComboBox] -and $c.DropDownStyle -ne 'DropDownList') { $c.add_KeyDown($Script:CtrlASelecionaTudo) }
        if ($c.Controls.Count -gt 0) { Enable-SelecionarTudo $c }
    }
}

# Zoom da janela: reduz tudo junto - posicao, tamanho, fonte e coluna de lista - do
# jeito que o Windows faz quando muda a escala da tela. E o que faz uma janela
# desenhada para 1000 px caber num monitor de 800, sem cortar campo nem texto.
function Set-EscalaControles {
    # O cache de fontes e o layout suspenso sao o que mantem isso rapido: sem eles,
    # numa tela cheia de botoes, cada fonte nova refazia a conta de todo o layout.
    param($Pai, [single]$Fator, [single]$FonteMinima = 6.75, $Cache = $null)
    if ($null -eq $Cache) { $Cache = @{} }
    $Pai.SuspendLayout()
    try {
        foreach ($c in $Pai.Controls) {
            $c.SetBounds([int][Math]::Round($c.Left * $Fator), [int][Math]::Round($c.Top * $Fator),
                [int][Math]::Round($c.Width * $Fator), [int][Math]::Round($c.Height * $Fator))
            if ($null -ne $c.Font) {
                $novoTam = [Math]::Max($FonteMinima, [single]($c.Font.Size * $Fator))
                if ([Math]::Abs($novoTam - $c.Font.Size) -gt 0.05) {
                    $chave = "$($c.Font.FontFamily.Name)|$novoTam|$([int]$c.Font.Style)"
                    if (-not $Cache.ContainsKey($chave)) { $Cache[$chave] = New-Object System.Drawing.Font($c.Font.FontFamily, $novoTam, $c.Font.Style) }
                    $c.Font = $Cache[$chave]
                }
            }
            # Coluna de lista tem largura em pixel: sem isso a grade estoura a janela. Aqui
            # encolhe menos que o resto (meio caminho), senao o numero da nota sai como
            # "10..."; se faltar espaco, a propria lista tem barra de rolagem.
            if ($c -is [System.Windows.Forms.ListView]) {
                $fatorCol = (1 + $Fator) / 2
                foreach ($col in $c.Columns) { $col.Width = [int][Math]::Round($col.Width * $fatorCol) }
            }
            if ($c.Controls.Count -gt 0) { Set-EscalaControles $c $Fator $FonteMinima $Cache }
        }
    }
    finally { $Pai.ResumeLayout($false) }
}

# Tela pequena (PDV antigo em 800x600): a janela foi desenhada maior que o monitor,
# os botoes de baixo ficavam fora da tela e o tamanho minimo nao deixava diminuir.
# Aqui a janela encolhe ate a area util, libera o redimensionar e o minimizar, e o
# que nao couber vira rolagem (com a roda do mouse, por causa do filtro RodaDoMouse).
# Em tela normal nada muda: a funcao sai na primeira linha.
function Set-JanelaAdaptavel {
    param($Janela, [int]$Margem = 10, [int]$MinElastico = 110)
    try {
        $area = [System.Windows.Forms.Screen]::FromControl($Janela).WorkingArea
        $maxL = $area.Width - $Margem
        $maxA = $area.Height - $Margem
        if ($Janela.Width -le $maxL -and $Janela.Height -le $maxA) { return $false }

        # Onde o conteudo termina de verdade. Nao da para confiar so no tamanho da
        # janela: em monitor pequeno o Windows pode abri-la ja encolhida, e ai a conta
        # do rodape sairia errada e os botoes ficariam cortados.
        $limiteDir = 0; $limiteBaixo = 0
        foreach ($ctl in $Janela.Controls) {
            if ("$($ctl.Dock)" -ne 'None') { continue }
            if ($ctl.Right -gt $limiteDir) { $limiteDir = $ctl.Right }
            if ($ctl.Bottom -gt $limiteBaixo) { $limiteBaixo = $ctl.Bottom }
        }
        $desenho = New-Object System.Drawing.Size(
            [Math]::Max($Janela.ClientSize.Width, ($limiteDir + 12)),
            [Math]::Max($Janela.ClientSize.Height, ($limiteBaixo + 12)))
        $borda = $Janela.Height - $Janela.ClientSize.Height

        # Primeiro o zoom: tudo encolhe junto ate a janela caber no monitor (no maximo
        # 28% menor, senao a letra fica ilegivel). E o que evita campo e texto cortados.
        # A altura considera o que a lista do meio pode ceder: so o que nao couber nem
        # assim vira zoom, senao uma tela 1280x720 encolhia a janela sem precisar.
        # Desconta a barra de rolagem de pé: se ela aparecer e a largura tiver sido
        # calculada sem ela, sobra rolagem de lado justamente por causa da barra
        $clienteL = [Math]::Min($Janela.Width, $maxL) - ($Janela.Width - $Janela.ClientSize.Width) - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
        $clienteA = [Math]::Min($Janela.Height, $maxA) - $borda
        $cedeAltura = 0
        foreach ($ctl in $Janela.Controls) {
            $ancC = "$($ctl.Anchor)"
            if (("$($ctl.Dock)" -eq 'Fill') -or ($ancC -match 'Top' -and $ancC -match 'Bottom')) {
                $cedeAltura = [Math]::Max($cedeAltura, ($ctl.Height - $MinElastico))
            }
        }
        $alturaRigida = [Math]::Max(120, ($desenho.Height - [Math]::Max(0, $cedeAltura)))
        # 1.0 e nao 1: com inteiro, o PowerShell arredondaria o fator para 1 e o zoom
        # nunca aconteceria
        $fator = [Math]::Min(([double]$clienteL / $desenho.Width), ([double]$clienteA / $alturaRigida))
        $fator = [Math]::Max(0.72, [Math]::Min(1.0, $fator))
        if ($fator -lt 0.995) {
            Set-EscalaControles $Janela ([single]$fator) 6.0
            if ($null -ne $Janela.Font) {
                $Janela.Font = New-Object System.Drawing.Font($Janela.Font.FontFamily, [Math]::Max(6.0, [single]($Janela.Font.Size * $fator)), $Janela.Font.Style)
            }
            $desenho = New-Object System.Drawing.Size([int][Math]::Round($desenho.Width * $fator), [int][Math]::Round($desenho.Height * $fator))
            Log-Message "INFO" "Janela ""$($Janela.Text)"": tela de $($area.Width)x$($area.Height), tudo reduzido para $([int][Math]::Round($fator * 100))% para caber"
        }

        $novoCliente = [Math]::Min($Janela.Height, $maxA) - $borda
        # Se vai sobrar rolagem na largura, a barra de baixo come um pedaco da altura
        if ($desenho.Width -gt ([Math]::Min($Janela.Width, $maxL) - ($Janela.Width - $Janela.ClientSize.Width))) {
            $novoCliente = $novoCliente - [System.Windows.Forms.SystemInformation]::HorizontalScrollBarHeight
        }

        # Rodape sempre a vista: o que esta preso so embaixo (botoes de acao, barra de
        # progresso, status) sai da area de rolagem e fica fixo no pe da janela, e todo
        # o resto vai para dentro de um painel que rola. Assim o tecnico nunca precisa
        # rolar para achar BUSCAR ou BAIXAR. (O Dock sozinho nao resolve: num
        # formulario com rolagem, o painel de baixo rolaria junto com o conteudo.)
        $doRodape = @($Janela.Controls | Where-Object { "$($_.Dock)" -eq 'None' -and "$($_.Anchor)" -match 'Bottom' -and "$($_.Anchor)" -notmatch 'Top' })
        $conteudo = @($Janela.Controls | Where-Object { $doRodape -notcontains $_ })
        $painelRolavel = $null
        $Janela.SuspendLayout()
        try {
            if ($doRodape.Count -gt 0 -and $conteudo.Count -gt 0) {
                $topoRodape = ($doRodape | ForEach-Object { $_.Top } | Measure-Object -Minimum).Minimum
                $baseRodape = ($doRodape | ForEach-Object { $_.Bottom } | Measure-Object -Maximum).Maximum
                # Altura pelo proprio rodape (nao pela janela, que pode ter vindo encolhida)
                $alturaRodape = [Math]::Max(($baseRodape - $topoRodape + 10), ($desenho.Height - $topoRodape))
                $painelRodape = New-Object System.Windows.Forms.Panel
                $painelRodape.Size = New-Object System.Drawing.Size($desenho.Width, $alturaRodape)
                $painelRodape.BackColor = $Janela.BackColor
                # Faixa interna com a largura do desenho: quando a janela e estreita, ela
                # desliza junto com a rolagem de lado do conteudo, e nenhum botao some
                $faixaRodape = New-Object System.Windows.Forms.Panel
                # O tamanho vem antes dos controles: a ancora guarda a distancia ate as
                # bordas do pai na hora em que o controle entra. Com o painel do tamanho
                # certo, cada controle mantem exatamente a folga que tinha na janela.
                $faixaRodape.Size = New-Object System.Drawing.Size($desenho.Width, $alturaRodape)
                $faixaRodape.Location = New-Object System.Drawing.Point(0, 0)
                $faixaRodape.BackColor = $Janela.BackColor
                foreach ($ctl in $doRodape) {
                    $anc = "$($ctl.Anchor)" -replace 'Bottom', 'Top'
                    $novoTopo = $ctl.Top - $topoRodape
                    $Janela.Controls.Remove($ctl)
                    [void]$faixaRodape.Controls.Add($ctl)
                    $ctl.Top = $novoTopo
                    $ctl.Anchor = [System.Windows.Forms.AnchorStyles]$anc
                }
                [void]$painelRodape.Controls.Add($faixaRodape)

                # Painel do conteudo: mesma ordem de sobreposicao e mesmas posicoes
                $painelRolavel = New-Object System.Windows.Forms.Panel
                $painelRolavel.Size = New-Object System.Drawing.Size($desenho.Width, $topoRodape)
                $painelRolavel.BackColor = $Janela.BackColor
                foreach ($ctl in $conteudo) {
                    $pos = $ctl.Location
                    $Janela.Controls.Remove($ctl)
                    [void]$painelRolavel.Controls.Add($ctl)
                    $ctl.Location = $pos
                }
                $painelRodape.Dock = 'Bottom'
                $painelRolavel.Dock = 'Fill'
                # Rolou o conteudo para o lado: o rodape vai junto. A faixa vai no Tag do
                # painel porque o evento roda depois, quando as variaveis daqui ja sumiram
                $painelRolavel.Tag = $faixaRodape
                $painelRolavel.Add_Scroll({ if ($null -ne $this.Tag) { $this.Tag.Left = $this.AutoScrollPosition.X } })
                $painelRolavel.Add_ClientSizeChanged({ if ($null -ne $this.Tag) { $this.Tag.Left = $this.AutoScrollPosition.X } })
                [void]$Janela.Controls.Add($painelRodape)
                [void]$Janela.Controls.Add($painelRolavel)
                # Quem preenche o resto tem que ser encaixado por ultimo
                $painelRolavel.BringToFront()
                $desenho = New-Object System.Drawing.Size($desenho.Width, $topoRodape)
                $novoCliente = $novoCliente - $painelRodape.Height
            }

            # Antes de rolar, deixa encolher o que e elastico (a lista que ocupa o meio
            # da janela, presa em cima e embaixo, ou um painel que preenche tudo). Assim
            # sobra bem menos rolagem, e so na parte de cima.
            $onde = if ($null -ne $painelRolavel) { $painelRolavel } else { $Janela }
            $podeEncolher = 0
            foreach ($ctl in $onde.Controls) {
                $anc = "$($ctl.Anchor)"
                $estica = ("$($ctl.Dock)" -eq 'Fill') -or ($anc -match 'Top' -and $anc -match 'Bottom')
                if ($estica) { $podeEncolher = [Math]::Max($podeEncolher, $ctl.Height - $MinElastico) }
            }
            $alturaRolagem = [Math]::Max([Math]::Min($desenho.Height, $novoCliente), $desenho.Height - [Math]::Max(0, $podeEncolher))

            # Largura: telas montadas sobre um painel que preenche tudo (a inicial, com a
            # lista de botoes) se viram em qualquer largura, entao nem precisam de rolagem
            # de lado. Telas com campos em posicao fixa mantem a largura do desenho.
            $larguraRolagem = $desenho.Width
            if (@($onde.Controls | Where-Object { "$($_.Dock)" -eq 'Fill' }).Count -gt 0) {
                $clienteLargura = [Math]::Min($Janela.Width, $maxL) - ($Janela.Width - $Janela.ClientSize.Width)
                $larguraRolagem = [Math]::Max([Math]::Min($desenho.Width, $clienteLargura), 640)
            }

            $onde.AutoScroll = $true
            $onde.AutoScrollMinSize = New-Object System.Drawing.Size($larguraRolagem, $alturaRolagem)
        }
        finally { $Janela.ResumeLayout() }

        # Janela de tamanho fixo precisa virar ajustavel para caber na tela
        if ("$($Janela.FormBorderStyle)" -like 'Fixed*') { $Janela.FormBorderStyle = 'Sizable' }
        $Janela.MinimizeBox = $true
        $Janela.MaximizeBox = $true

        $novaL = [Math]::Min($Janela.Width, $maxL)
        $novaA = [Math]::Min($Janela.Height, $maxA)
        $minL = [Math]::Min($Janela.MinimumSize.Width, $novaL)
        $minA = [Math]::Min($Janela.MinimumSize.Height, $novaA)
        $Janela.MinimumSize = New-Object System.Drawing.Size($minL, $minA)
        $Janela.Size = New-Object System.Drawing.Size($novaL, $novaA)
        $Janela.Left = $area.Left + [Math]::Max(0, [int](($area.Width - $novaL) / 2))
        $Janela.Top = $area.Top + [Math]::Max(0, [int](($area.Height - $novaA) / 2))
        Log-Message "INFO" "Janela ""$($Janela.Text)"" ajustada para a tela de $($area.Width)x$($area.Height): $novaL x $novaA, com rolagem"
        return $true
    }
    catch { return $false }
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
    # Antes dos outros Shown da janela: primeiro ela cabe na tela, depois carrega
    $f.Add_Shown({
            Set-JanelaAdaptavel $this | Out-Null
            try { Enable-SelecionarTudo $this } catch {}
        })
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

# Nome do fabricante em formato curto: a base publica devolve a razao social inteira
# ("Xiamen Hanin Electronic Technology Co., Ltd"), que nao cabe na coluna e nao diz
# nada ao tecnico. Os apelidos sao os nomes que aparecem na nota fiscal do cliente.
function Format-NomeFabricante {
    param([string]$Nome)
    $t = "$Nome".Trim()
    if ($t -eq "") { return "" }
    # Quem fabrica para as marcas do PDV brasileiro
    $apelidos = [ordered]@{
        'hanin|hprt'                  = 'HPRT / ELGIN'
        'elgin'                       = 'ELGIN'
        'bematech|logic\s*controls'   = 'BEMATECH'
        'epson|seiko'                 = 'EPSON'
        'daruma|urano'                = 'DARUMA'
        'tanca'                       = 'TANCA'
        'sweda'                       = 'SWEDA'
        'gertec'                      = 'GERTEC'
        'control\s*id'                = 'CONTROL ID'
        'zebra'                       = 'ZEBRA'
        'star micronics'              = 'STAR'
        'xprinter|xiamen rongta|rongta' = 'XPRINTER / RONGTA'
        'hewlett|hp inc'              = 'HP'
        'brother'                     = 'BROTHER'
        'canon'                       = 'CANON'
        'ricoh'                       = 'RICOH'
        'lexmark'                     = 'LEXMARK'
        'kyocera'                     = 'KYOCERA'
        'samsung'                     = 'SAMSUNG'
        'intelbras'                   = 'INTELBRAS'
        'tp-?link'                    = 'TP-LINK'
        'd-?link'                     = 'D-LINK'
        'mercusys'                    = 'MERCUSYS'
        'ubiquiti'                    = 'UBIQUITI'
        'mikrotik|routerboard'        = 'MIKROTIK'
        'huawei'                      = 'HUAWEI'
        'zte'                         = 'ZTE'
        'askey|arris|technicolor|sagemcom|fiberhome' = 'MODEM DA OPERADORA'
        'realtek'                     = 'REALTEK (rede)'
        'intel'                       = 'INTEL (rede)'
        'asrock'                      = 'ASROCK (placa-mãe)'
        'asustek|asus'                = 'ASUS'
        'gigabyte'                    = 'GIGABYTE'
        'micro-?star|msi'             = 'MSI'
        'dell'                        = 'DELL'
        'lenovo'                      = 'LENOVO'
        'apple'                       = 'APPLE'
        'xiaomi'                      = 'XIAOMI'
        'raspberry'                   = 'RASPBERRY PI'
        'vmware|virtualbox|oracle|microsoft corp' = 'MÁQUINA VIRTUAL'
    }
    foreach ($k in $apelidos.Keys) { if ($t -match "(?i)$k") { return $apelidos[$k] } }

    # Sem apelido: tira o juridiques e fica com as duas primeiras palavras
    $t = $t -replace '(?i),?\s*\b(co\.?|company|corp\.?|corporation|inc\.?|incorporated|ltda?\.?|limited|technolog(y|ies)|electronics?|systems?|s\.?a\.?|gmbh|llc|group|international)\b', ' '
    $t = ($t -replace '[,\.]', ' ' -replace '\s{2,}', ' ').Trim()
    $palavras = @($t -split ' ' | Where-Object { $_ -ne '' })
    if ($palavras.Count -gt 2) { $t = ($palavras[0..1] -join ' ') }
    if ($t -eq "") { return "" }
    return $t.ToUpper()
}

# Fabricante pelo MAC na base publica (api.macvendors.com), so quando o OUI nao esta
# na lista de baixo. Guarda o que ja perguntou e desiste rapido: sem internet, ou com
# o site fora do ar, o scan continua igual, so sem o nome.
function Get-FabricanteOnline {
    param([string]$Oui)
    if ($null -eq $Script:CacheOui) { $Script:CacheOui = @{} }
    if ($Script:CacheOui.ContainsKey($Oui)) { return $Script:CacheOui[$Oui] }
    if ($Script:OuiSemInternet) { return "" }
    $nome = ""
    try {
        $req = [System.Net.HttpWebRequest]::Create("https://api.macvendors.com/$Oui")
        $req.Timeout = 2500
        $req.ReadWriteTimeout = 2500
        $req.UserAgent = "PreparadorXMenu"
        $resp = $req.GetResponse()
        $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $nome = Format-NomeFabricante ($sr.ReadToEnd())
        $sr.Close(); $resp.Close()
    }
    catch {
        # 404 = OUI sem dono conhecido (nao adianta insistir); falha de rede desliga a consulta
        if ("$($_.Exception.Message)" -notmatch '404') { $Script:OuiSemInternet = $true }
    }
    $Script:CacheOui[$Oui] = $nome
    return $nome
}

function Get-VendorName {
    param($IP, $ArpTable, $Mac = $null, [switch]$SemInternet)
    try {
        $macAddr = if ($Mac) { $Mac } else { Get-MacDeIP $IP $ArpTable }
        if ($macAddr -match '([0-9a-fA-F:]{17})') {
            $oui = $macAddr.Substring(0, 8).ToUpper()
            $vendors = @{
                # Impressoras que a Elgin, a Bematech e as revendas vendem como termicas
                "6C:C1:47" = "HPRT / ELGIN"; "00:15:32" = "HPRT / ELGIN"; "AC:8F:F8" = "HPRT / ELGIN"
                "00:19:0F" = "XPRINTER / RONGTA"; "00:1B:5B" = "XPRINTER / RONGTA"
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
                # Placas de rede e placas-mae que aparecem nos PDVs
                "00:E0:4C" = "REALTEK (rede)"; "52:54:00" = "MÁQUINA VIRTUAL"
                "9C:6B:00" = "ASROCK (placa-mãe)"; "5C:CD:5B" = "INTEL (rede)"
                "00:1B:21" = "INTEL (rede)"; "A0:36:9F" = "INTEL (rede)"; "3C:97:0E" = "INTEL (rede)"
                "D8:CB:8A" = "MSI"; "1C:1B:0D" = "GIGABYTE"; "50:E5:49" = "GIGABYTE"
                "2C:F0:5D" = "ASUS"; "AC:22:0B" = "ASUS"; "08:62:66" = "ASUS"
                "F4:8E:38" = "D-LINK"; "C4:E9:84" = "TP-LINK"; "AC:84:C6" = "TP-LINK"
                "D8:47:32" = "TP-LINK"; "00:31:92" = "TP-LINK"; "9C:53:22" = "MERCUSYS"
                "4C:5E:0C" = "MIKROTIK"; "18:FD:74" = "MIKROTIK"; "24:A4:3C" = "UBIQUITI"
                "E8:DE:27" = "INTELBRAS"; "58:10:8C" = "INTELBRAS"; "9C:A5:13" = "INTELBRAS"
            }
            if ($vendors.ContainsKey($oui)) { return $vendors[$oui] }
            # Fora da lista: pergunta a base publica uma vez por fabricante
            if (-not $SemInternet) {
                $online = Get-FabricanteOnline $oui
                if ("$online" -ne "") { return $online }
            }
        }
        return "Desconhecido"
    }
    catch { return "Desconhecido" }
}

# Modelo do equipamento na rede, sem imprimir nada. Duas fontes seguras:
#   SNMP (UDP 161): a maioria das impressoras de rede responde com marca e modelo
#   Pagina web (porta 80): o titulo costuma trazer o modelo
# De proposito NAO usa a porta 9100: mandar PJL para uma termica ESC/POS sai
# impresso em papel, e o tecnico ia varrer a rede e imprimir lixo em toda impressora.
function Get-ModeloDeRede {
    param([string]$IP, $PortasAbertas = @(), [int]$TimeoutMs = 900)
    # sysDescr (1.3.6.1.2.1.1.1.0): o que a maioria responde
    $descr = Get-SnmpDescricao -IP $IP -TimeoutMs $TimeoutMs
    if ("$descr" -ne "") { return $descr }
    # hrDeviceDescr (1.3.6.1.2.1.25.3.2.1.3.1): impressora ligada em placa de rede
    # externa costuma responder aqui com o modelo verdadeiro
    $descr = Get-SnmpDescricao -IP $IP -TimeoutMs $TimeoutMs -Oid ([byte[]]@(0x2B, 0x06, 0x01, 0x02, 0x01, 0x19, 0x03, 0x02, 0x01, 0x03, 0x01))
    if ("$descr" -ne "") { return $descr }
    if (@($PortasAbertas) -contains 80) {
        try {
            $req = [System.Net.HttpWebRequest]::Create("http://$IP/")
            $req.Timeout = $TimeoutMs + 600
            $req.ReadWriteTimeout = $TimeoutMs + 600
            $req.AllowAutoRedirect = $true
            $req.UserAgent = "PreparadorXMenu"
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream())
            $html = $sr.ReadToEnd()
            $sr.Close(); $resp.Close()
            $m = [regex]::Match($html, '(?is)<title[^>]*>(.*?)</title>')
            if ($m.Success) {
                $titulo = ($m.Groups[1].Value -replace '\s+', ' ').Trim()
                # Titulo generico nao ajuda ninguem ("Success", "Login", "Index")
                $generico = '(?i)^(index|home|login|logon|bem.vindo|welcome|untitled|success|ok|error|erro|404|redirect|document|page|p.gina|admin|configura..o|settings|status|web|server|servidor|dispositivo|device|printer|impressora)\.?$'
                $temNumero = ($titulo -match '\d')
                $duasPalavras = (@($titulo -split '\s+' | Where-Object { $_ -ne '' }).Count -ge 2)
                if ($titulo -ne "" -and $titulo.Length -le 60 -and $titulo -notmatch $generico -and ($temNumero -or $duasPalavras)) { return $titulo }
            }
        }
        catch {}
    }
    return ""
}

# SNMP v1 GET do sysDescr (1.3.6.1.2.1.1.1.0), community "public". O pacote e montado
# na mao porque o Windows nao tem cliente SNMP; se o equipamento nao responder, o
# socket fecha no timeout e a varredura segue.
function Get-SnmpDescricao {
    param([string]$IP, [int]$TimeoutMs = 900, [byte[]]$Oid = $null)
    $udp = $null
    try {
        $comunidade = [System.Text.Encoding]::ASCII.GetBytes("public")
        $oid = if ($null -ne $Oid -and $Oid.Length -gt 0) { $Oid } else { [byte[]]@(0x2B, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00) }
        $varbind = [byte[]]@(0x30, ($oid.Length + 4), 0x06, $oid.Length) + $oid + [byte[]]@(0x05, 0x00)
        $varbinds = [byte[]]@(0x30, $varbind.Length) + $varbind
        $pduCorpo = [byte[]]@(0x02, 0x01, 0x01, 0x02, 0x01, 0x00, 0x02, 0x01, 0x00) + $varbinds
        $pdu = [byte[]]@(0xA0, $pduCorpo.Length) + $pduCorpo
        $corpo = [byte[]]@(0x02, 0x01, 0x00, 0x04, $comunidade.Length) + $comunidade + $pdu
        $msg = [byte[]]@(0x30, $corpo.Length) + $corpo

        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $udp.Client.SendTimeout = $TimeoutMs
        [void]$udp.Send($msg, $msg.Length, $IP, 161)
        $ep = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)

        # Acha o OID na resposta e le o valor logo depois (0x04 = texto)
        for ($i = 0; $i -lt ($resp.Length - $oid.Length - 4); $i++) {
            if ($resp[$i] -ne 0x06 -or $resp[$i + 1] -ne $oid.Length) { continue }
            $bate = $true
            for ($j = 0; $j -lt $oid.Length; $j++) { if ($resp[$i + 2 + $j] -ne $oid[$j]) { $bate = $false; break } }
            if (-not $bate) { continue }
            $p = $i + 2 + $oid.Length
            if ($resp[$p] -ne 0x04) { break }
            $tam = $resp[$p + 1]; $ini = $p + 2
            # Comprimento longo vem em 1 ou 2 bytes extras
            if ($tam -band 0x80) {
                $qtd = $tam -band 0x7F
                $tam = 0
                for ($k = 0; $k -lt $qtd; $k++) { $tam = ($tam * 256) + $resp[$p + 2 + $k] }
                $ini = $p + 2 + $qtd
            }
            if ($tam -le 0 -or ($ini + $tam) -gt $resp.Length) { break }
            $texto = [System.Text.Encoding]::UTF8.GetString($resp, $ini, $tam)
            return (($texto -replace '[\r\n\t]+', ' ') -replace '\s{2,}', ' ').Trim()
        }
        return ""
    }
    catch { return "" }
    finally { if ($null -ne $udp) { try { $udp.Close() } catch {} } }
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
        [void]$lv.Columns.Add("Fabricante / Modelo", 230)
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

                            # Impressora e equipamento de rede costumam dizer o modelo por SNMP
                            # ou no titulo da pagina web. Quando diz, o modelo vale mais que a
                            # marca solta: "TM-T20X" ajuda mais o tecnico que "EPSON".
                            $modelo = ""
                            if (-not $ehLocal -and ($ehImp -or $ehWeb -or $ehGw)) {
                                $modelo = Get-ModeloDeRede -IP $ip -PortasAbertas $abertas -TimeoutMs 700
                            }
                            $fabTexto = $fab
                            if ("$modelo" -ne "") {
                                if ($fab -ne "Desconhecido" -and $modelo -notmatch "(?i)$([regex]::Escape(($fab -split ' ')[0]))") { $fabTexto = "$modelo ($fab)" }
                                else { $fabTexto = $modelo }
                            }
                            elseif ($ehImp -and $fab -ne "Desconhecido") {
                                # Sem resposta do equipamento, o nome vem do MAC - e o MAC e da
                                # placa de rede, nao da impressora: uma Epson com placa HPRT
                                # aparece como HPRT. O "(pelo MAC)" avisa que e so um palpite.
                                $fabTexto = "$fab (pelo MAC)"
                            }

                            $servicos = (($abertas | ForEach-Object { Get-NomePorta $_ }) -join ", ")

                            $Script:ScannerTodos += [PSCustomObject]@{
                                IP         = $ip
                                Tipo       = $tipo
                                Fabricante = $fabTexto
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

# -----------------------------------------------------------------------------
# CATALOGO DE DRIVERS
# Uma lista so para a aba Drivers e para o BAIXAR DRIVER da nova impressora LPR
# -----------------------------------------------------------------------------

function Get-CatalogoDrivers {
    # Devolve Secao / CorSecao / Tipo (Download ou Site) / Texto / Url / Arquivo / Cor, na ordem da aba
    $baseUrl = "https://raw.githubusercontent.com/Delutto/thermal_printers/main"
    $xtagBaseUrl = "https://raw.githubusercontent.com/ElginDeveloperCommunity/Impressoras/master/Impressoras%20de%20Etiqueta"
    $lista = New-Object System.Collections.Generic.List[object]
    $secao = ""; $corSecao = $null
    $baixar = { param([string]$Texto, [string]$Url, [string]$Arquivo, $Cor) $lista.Add([PSCustomObject]@{ Secao = $secao; CorSecao = $corSecao; Tipo = 'Download'; Texto = $Texto; Url = $Url; Arquivo = $Arquivo; Cor = $Cor }) }
    $site = { param([string]$Texto, [string]$Url, $Cor) $lista.Add([PSCustomObject]@{ Secao = $secao; CorSecao = $corSecao; Tipo = 'Site'; Texto = $Texto; Url = $Url; Arquivo = ""; Cor = $Cor }) }
    $rgb = { param($R, $G, $B) [System.Drawing.Color]::FromArgb($R, $G, $B) }

    $colorElgin = & $rgb 25 80 140; $colorBema = & $rgb 30 100 60; $colorEpson = & $rgb 80 40 120; $colorTanca = & $rgb 140 70 20
    $colorElginUtil = & $rgb 15 60 110; $colorBemaUtil = & $rgb 20 80 45; $colorEpsonUtil = & $rgb 60 25 95; $colorTancaUtil = & $rgb 110 50 15

    $secao = "ELGIN"; $corSecao = & $rgb 80 160 255
    & $baixar "  [DRIVER] Elgin i9 / i7  (v1.7.3)" "$baseUrl/Elgin/Elgin_i7_i9_v1.7.3.exe" "Elgin_i7_i9_v1.7.3.exe" $colorElgin
    & $baixar "  [DRIVER] Elgin i8  (v7.1.7)" "$baseUrl/Elgin/Elgin_i8_v7.1.7.exe" "Elgin_i8_v7.1.7.exe" $colorElgin
    & $baixar "  [UTILITÁRIO] Elgin i9 Utility  (v1.2.2.24)" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/UTILITY.ELGIN.I9.E.I7.1.exe" "UTILITY.ELGIN.I9.E.I7.1.exe" $colorElginUtil
    & $baixar "  [UTILITÁRIO] Elgin i7 / i8 Utility  (v3.2)" "$baseUrl/Utilities/Elgin_i7-i8_Utility_v3.2.exe" "Elgin_i7-i8_Utility_v3.2.exe" $colorElginUtil

    $secao = "BEMATECH"; $corSecao = & $rgb 80 200 120
    & $baixar "  [DRIVER] Bematech MP-4200 TH / MP-2500 / MP-4000  (Spooler x64 v4.4.0.3)" "$baseUrl/Bematech/BematechSpoolerDrivers_x64_v4.4.0.3.exe" "BematechSpoolerDrivers_x64_v4.4.0.3.exe" $colorBema
    & $baixar "  [DRIVER] Bematech MP-4200 HS  (v1.7.7)" "$baseUrl/Bematech/Bematech%20MP-4200-HS_Driver_v1.7.7.exe" "Bematech_MP-4200-HS_Driver_v1.7.7.exe" $colorBema
    & $baixar "  [DRIVER] Bematech MP-2800 TH  (Spooler v1.3)" "$baseUrl/Bematech/Bematech_MP_2800_SpoolerDrivers_v1.3.exe" "Bematech_MP_2800_SpoolerDrivers_v1.3.exe" $colorBema
    & $baixar "  [UTILITÁRIO] Bematech Utility  (v2.10.04 x64)" "$baseUrl/Utilities/Bematech_Utility_v2.10.04_x64.exe" "Bematech_Utility_v2.10.04_x64.exe" $colorBemaUtil
    & $baixar "  [UTILITÁRIO] Bematech MP-2800 TH Utility  (v1.4)" "$baseUrl/Utilities/Bematech_MP-2800_TH_Utility_v1.4.exe" "Bematech_MP-2800_TH_Utility_v1.4.exe" $colorBemaUtil

    $secao = "EPSON"; $corSecao = & $rgb 180 120 255
    & $baixar "  [DRIVER] Epson TM-T20  (APD v5.6.0.0)" "$baseUrl/Epson/Epson_TM-T20_v5.6.0.0.exe" "Epson_TM-T20_v5.6.0.0.exe" $colorEpson
    & $baixar "  [DRIVER] Epson TM-T20X  (APD v6.1.0.0)" "$baseUrl/Epson/Epson_TM-T20X_v6.1.0.0.exe" "Epson_TM-T20X_v6.1.0.0.exe" $colorEpson
    & $baixar "  [DRIVER] Epson TM-T20X II  (APD v6.9.1.0)" "$baseUrl/Epson/Epson_TM-20X-II_Driver_v6.9.1.0.exe" "Epson_TM-20X-II_Driver_v6.9.1.0.exe" $colorEpson
    & $baixar "  [UTILITÁRIO] Epson NetConfig  (v4.9.5)" "$baseUrl/Utilities/Epson_NetConfig_v4_9_5.exe" "Epson_NetConfig_v4_9_5.exe" $colorEpsonUtil

    $secao = "TANCA"; $corSecao = & $rgb 255 160 60
    & $baixar "  [DRIVER] Tanca TP-620  (v6.1.0)" "$baseUrl/Tanca/Tanca_TP-620_Driver_v6.1.0.exe" "Tanca_TP-620_Driver_v6.1.0.exe" $colorTanca
    & $baixar "  [DRIVER] Tanca TP-650  (v2.11)" "$baseUrl/Tanca/Tanca_TP-650_DriverInstall_v2.11.exe" "Tanca_TP-650_DriverInstall_v2.11.exe" $colorTanca
    & $baixar "  [UTILITÁRIO] Tanca TP-620 Utility  (v3.2.0.1)" "$baseUrl/Utilities/Tanca_TP-620_Utility_v3.2.0.1.exe" "Tanca_TP-620_Utility_v3.2.0.1.exe" $colorTancaUtil
    & $baixar "  [UTILITÁRIO] Tanca TP-650 Printer Tool  (v1.48E)" "$baseUrl/Utilities/Tanca_TP-650_PrinterTool_1.48E.exe" "Tanca_TP-650_PrinterTool_1.48E.exe" $colorTancaUtil

    $colorDaruma = & $rgb 130 20 50; $colorSweda = & $rgb 100 100 30; $colorCtrlID = & $rgb 60 60 80
    $secao = "DARUMA / SWEDA / CONTROL ID"; $corSecao = & $rgb 220 220 220
    & $baixar "  [DRIVER] Daruma DR800  (Spooler v2.0.1.7)" "$baseUrl/Daruma/Daruma_800_Spooler_Driver_v2.0.1.7.exe" "Daruma_800_Spooler_Driver_v2.0.1.7.exe" $colorDaruma
    & $baixar "  [DRIVER] Sweda SI-300 / SI-300E / SI-300W  (v1.2.0)" "$baseUrl/Sweda/Sweda_SI-300_SI-300E_SI-300W_v1.2.0.exe" "Sweda_SI-300_SI-300E_SI-300W_v1.2.0.exe" $colorSweda
    & $baixar "  [DRIVER] Control iD Print iD / Print iD Touch  (v1.1.10.2)" "$baseUrl/PrintID/Print_iD_%26_Print_iD_Touch_v1.1.10.2.exe" "Print_iD_v1.1.10.2.exe" $colorCtrlID
    & $baixar "  [UTILITÁRIO] Daruma Utility  (v2.20.9)" "$baseUrl/Utilities/Daruma_Utility_v2.20.9.exe" "Daruma_Utility_v2.20.9.exe" $colorDaruma
    & $baixar "  [UTILITÁRIO] Sweda Utility  (v2.03)" "$baseUrl/Utilities/Sweda_Utility_v2.03.exe" "Sweda_Utility_v2.03.exe" $colorSweda
    & $baixar "  [UTILITÁRIO] Control iD Utility  (v1.0)" "$baseUrl/Utilities/PrintID_Utility_v1.0.exe" "PrintID_Utility_v1.0.exe" $colorCtrlID

    # Tomate MDK, Knup, Kmex, Evadin e a maioria das 80mm chinesas usam
    # o mesmo "POS Printer Driver" generico.
    $colorPos = & $rgb 150 45 30; $colorPosUtil = & $rgb 115 30 20; $colorC3 = & $rgb 20 85 115
    $secao = "TOMATE / C3TECH / GENÉRICAS 80mm"; $corSecao = & $rgb 255 130 100
    & $baixar "  [DRIVER] Tomate MDK-006 / 007 / 008 / 080 / 081  (POS-80 genérico v11.3)" "$baseUrl/POS/POS_Printer_Driver_Setup_v11.3.0.0.exe" "POS_Printer_Driver_Setup_v11.3.0.0.exe" $colorPos
    & $baixar "  [DRIVER] Knup / Kmex / Evadin / demais POS-58 e POS-80  (mesmo driver v11.3)" "$baseUrl/POS/POS_Printer_Driver_Setup_v11.3.0.0.exe" "POS_Printer_Driver_Setup_v11.3.0.0.exe" $colorPos
    & $baixar "  [UTILITÁRIO] POS Utilities  (teste, autoteste e configuração POS-80)" "$baseUrl/Utilities/POS_Utilities.exe" "POS_Utilities.exe" $colorPosUtil
    & $baixar "  [DRIVER] C3Tech IT-100  (pacote oficial C3Tech - RAR, ~87 MB)" "https://c3technology.com.br/download/DRIVES%20IT-100.rar" "C3Tech_IT-100_Drivers.rar" $colorC3
    & $baixar "  [DRIVER] C3Tech IT-110  (drivers + utilitários oficiais - ZIP, ~103 MB)" "https://c3technology.com.br/download/DRIVES%20E%20UTILITARIOS%20IT-110.zip" "C3Tech_IT-110_Drivers_Utilitarios.zip" $colorC3
    & $site "  [SITE] Tomate - suporte oficial (tutoriais e drivers por modelo)" "https://tomate.tv/support" $colorPosUtil

    $colorFeasso = & $rgb 120 60 130; $colorJetway = & $rgb 35 95 105
    $secao = "FEASSO / JETWAY"; $corSecao = & $rgb 200 150 255
    & $baixar "  [DRIVER] Feasso F-IMTER-01  (v1.7)" "$baseUrl/Feasso/Feasso_F-IMTER-01_Driver_v1.7.exe" "Feasso_F-IMTER-01_Driver_v1.7.exe" $colorFeasso
    & $baixar "  [DRIVER] Feasso F-IMTER-02  (v2.0)" "$baseUrl/Feasso/Feasso_F-IMTER-02_Driver_v2.0.exe" "Feasso_F-IMTER-02_Driver_v2.0.exe" $colorFeasso
    & $baixar "  [DRIVER] Feasso F-IMTER-03  (v1.5)" "$baseUrl/Feasso/Feasso_F-IMTER-03_Driver_v1.5.exe" "Feasso_F-IMTER-03_Driver_v1.5.exe" $colorFeasso
    & $baixar "  [DRIVER] Jetway JP-500  (v7.17)" "$baseUrl/Jetway/Jetway_JP-500_Printer_Driver_v7.17.exe" "Jetway_JP-500_Printer_Driver_v7.17.exe" $colorJetway
    & $baixar "  [DRIVER] Jetway JP-800  (v2.38E)" "$baseUrl/Jetway/Jetway_JP-800_PrinterDriver_v2.38E.exe" "Jetway_JP-800_PrinterDriver_v2.38E.exe" $colorJetway
    & $baixar "  [DRIVER] Jetway JMP-100  (v2.61J)" "$baseUrl/Jetway/Jetway_JMP-100_Driver_v2.61J.exe" "Jetway_JMP-100_Driver_v2.61J.exe" $colorJetway

    $colorGertec = & $rgb 150 100 20; $colorDiebold = & $rgb 45 70 130; $colorPerto = & $rgb 90 45 60
    $secao = "GERTEC / DIEBOLD / DIMEP / PERTO"; $corSecao = & $rgb 255 200 90
    & $baixar "  [DRIVER] Gertec G250  (v1.0)" "$baseUrl/Gertec/Gertec_G250_Driver_v1.0.exe" "Gertec_G250_Driver_v1.0.exe" $colorGertec
    & $baixar "  [UTILITÁRIO] Gertec G250 Utility  (v2.57)" "$baseUrl/Utilities/Gertec_G250_Utility_v2.57.exe" "Gertec_G250_Utility_v2.57.exe" $colorGertec
    & $baixar "  [DRIVER] Diebold Mecaf / Perfecta  (v1.34 drv 1.9)" "$baseUrl/Diebold/Diebold_Printers_v1.34_drv_1.9.exe" "Diebold_Printers_v1.34_drv_1.9.exe" $colorDiebold
    & $baixar "  [DRIVER] Diebold IM113ID  (v1.2.0.10 x64)" "$baseUrl/Diebold/Diebold_IM113ID_v1.2.0.10_x64.exe" "Diebold_IM113ID_v1.2.0.10_x64.exe" $colorDiebold
    & $baixar "  [DRIVER] Dimep D-PRINT DUAL  (v2.1.4.4)" "$baseUrl/Dimep/Dimep_D-PRINT_DUAL_v2.1.4.4.exe" "Dimep_D-PRINT_DUAL_v2.1.4.4.exe" $colorPerto
    & $baixar "  [DRIVER] Perto PertoPrinter  (v2.5)" "$baseUrl/PertoPrinter/PertoPrinter_Driver_2.5.exe" "PertoPrinter_Driver_2.5.exe" $colorPerto

    $colorStar = & $rgb 25 70 95; $colorWaytec = & $rgb 70 90 40; $colorMenno = & $rgb 100 55 25
    $secao = "STAR / WAYTEC / MENNO / DASCOM"; $corSecao = & $rgb 140 210 255
    & $baixar "  [DRIVER] Star (todos os modelos)  (x64 v3.7.2)" "$baseUrl/Star/Star_PrinterDrivers_x64_v3.7.2.exe" "Star_PrinterDrivers_x64_v3.7.2.exe" $colorStar
    & $baixar "  [DRIVER] Waytec WP-100  (v7.17)" "$baseUrl/Waytec/Waytec_WP-100_Driver_v7.17.exe" "Waytec_WP-100_Driver_v7.17.exe" $colorWaytec
    & $baixar "  [DRIVER] Waytec WP-50  (v7.17.50)" "$baseUrl/Waytec/WayTec_WP-50_Driver_v7.17.50.exe" "WayTec_WP-50_Driver_v7.17.50.exe" $colorWaytec
    & $baixar "  [UTILITÁRIO] Waytec Utility  (v3.2.0.1)" "$baseUrl/Utilities/Waytec_Utility_v3.2.0.1.exe" "Waytec_Utility_v3.2.0.1.exe" $colorWaytec
    & $baixar "  [DRIVER] Menno  (v2.52)" "$baseUrl/Menno/Menno_Printer_Driver_v2.52.exe" "Menno_Printer_Driver_v2.52.exe" $colorMenno
    & $baixar "  [UTILITÁRIO] Menno Printer Tool  (v1.56)" "$baseUrl/Utilities/Menno_PrinterTool_v1.56.exe" "Menno_PrinterTool_v1.56.exe" $colorMenno
    & $baixar "  [DRIVER] Dascom DT-210 / DT-230  (v1.0.0.7)" "$baseUrl/Dascom/Dascom_DT-210_DT-230_Driver_v1.0.0.7.exe" "Dascom_DT-210_DT-230_Driver_v1.0.0.7.exe" $colorStar

    $colorXtag = & $rgb 0 140 130; $colorXtagUtil = & $rgb 0 95 90
    $secao = "IMPRESSORAS XTAG (ETIQUETA)"; $corSecao = & $rgb 100 220 210
    & $baixar "  [DRIVER] Elgin L42 PRO  (ZIP - contem instalador, v2020.4)" "$xtagBaseUrl/Elgin/L42PRO/Drivers/Windows_DriverL42PRO_V2020.4.zip" "Windows_DriverL42PRO_V2020.4.zip" $colorXtag
    & $baixar "  [DRIVER] Elgin L42 PRO FULL  (v2022.1)" "$xtagBaseUrl/Elgin/L42PRO%20FULL/Drivers/L42PRO%20FULL_Windows_driver_2022.1.exe" "Elgin_L42PRO_FULL_Windows_driver_2022.1.exe" $colorXtag
    & $baixar "  [DRIVER] Elgin L42 DT  (v7.4.3)" "$xtagBaseUrl/Elgin/L42DT/Drivers/Windows_DriverL42DT_7.4.3_M-5.exe" "Elgin_L42DT_Windows_driver_7.4.3.exe" $colorXtag
    & $baixar "  [DRIVER] Zebra ZD220 / ZD230  (ZIP - contem instalador)" "https://www.zebra.com/content/dam/support-dam/en/driver/unrestricted/0002/zddriver-v1062628275-certified.zip" "Zebra_ZD220_ZD230_Driver.zip" $colorXtag
    & $baixar "  [DRIVER] Argox  (Todos os modelos, v2022.1)" "$baseUrl/Argox/Argox_PrinterDrivers_v2022.1.exe" "Argox_PrinterDrivers_v2022.1.exe" $colorXtag
    & $baixar "  [DRIVER] Gainscha  (Todos os modelos, v2020.1)" "$baseUrl/Gainscha/Gainscha_GPrinterDrivers_v2020.1.exe" "Gainscha_GPrinterDrivers_v2020.1.exe" $colorXtag
    & $baixar "  [DRIVER] Zetex Z60XT  (ZIP - Drive, ~225 MB)" "https://drive.usercontent.google.com/download?id=1wWLiTWrtHCBRP9L0P9GG2eRKGEgfo2HJ&export=download&confirm=t" "Zetex_Z60XT_Driver.zip" $colorXtag
    & $baixar "  [UTILITÁRIO] Gerenciador Elgin L42 PRO FULL  (v1.5.1)" "$xtagBaseUrl/Elgin/L42PRO%20FULL/Utilit%C3%A1rios/GerenciadorL42PRO_Full_1.5.1.exe" "GerenciadorL42PRO_Full_1.5.1.exe" $colorXtagUtil
    & $baixar "  [UTILITÁRIO] Gerenciador Elgin L42 DT  (v1.5.6)" "$xtagBaseUrl/Elgin/L42DT/Utilit%C3%A1rios/GerenciadorL42DT_Full_1.5.6.exe" "GerenciadorL42DT_Full_1.5.6.exe" $colorXtagUtil

    return $lista.ToArray()
}

function Invoke-BaixarDriver {
    # Baixa um driver do catalogo com o progresso no texto de $Progresso (botao ou
    # label), confere o arquivo e abre: instalador roda, ZIP extrai e abre a pasta,
    # RAR abre no programa associado. Erro sobe para quem chamou.
    # Devolve hashtable: Caminho / Acao (instalador, pasta ou rar)
    param([string]$Url, [string]$Arquivo, $Progresso = $null, [string]$Prefixo = "")
    $dest = Join-Path $Script:DownloadFolder $Arquivo
    if (-not (Test-Path -LiteralPath $Script:DownloadFolder)) { New-Item -ItemType Directory -Path $Script:DownloadFolder -Force | Out-Null }
    Log-Message "INFO" "Baixando driver: $Arquivo"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if ($null -ne $Progresso) { $Progresso.Text = "$Prefixo  Iniciando download..." }

    # Download assincrono com a barra de progresso no texto do controle
    $Script:DrvProgresso = $Progresso
    $Script:DrvPrefixo = $Prefixo
    $Script:DrvComplete = $false
    $Script:DrvError = $null
    $wc = New-Object System.Net.WebClient
    $wc.Add_DownloadProgressChanged({
            param($s, $e)
            if ($null -eq $Script:DrvProgresso) { return }
            $pct = $e.ProgressPercentage
            $barSize = 14
            $filled = [Math]::Floor($pct / (100 / $barSize))
            $bar = ("|" * $filled) + ("." * ($barSize - $filled))
            $mb = [Math]::Round($e.BytesReceived / 1MB, 1)
            $totMb = [Math]::Round($e.TotalBytesToReceive / 1MB, 1)
            $Script:DrvProgresso.Text = "$($Script:DrvPrefixo)  [$bar] $pct%   ($mb / $totMb MB)"
        })
    $wc.Add_DownloadFileCompleted({
            param($s, $e)
            if ($e.Error) { $Script:DrvError = $e.Error }
            $Script:DrvComplete = $true
        })
    try {
        $wc.DownloadFileAsync((New-Object Uri($Url.Replace(" ", "%20"))), $dest)
        while (-not $Script:DrvComplete) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 15
        }
    }
    finally { $wc.Dispose() }
    if ($Script:DrvError) { throw $Script:DrvError }

    if (-not (Test-DownloadIntegrity -Path $dest)) {
        Remove-Item $dest -Force -ErrorAction SilentlyContinue
        throw "Arquivo baixado esta corrompido ou invalido (link quebrado ou pagina de erro)."
    }
    Log-Message "SUCESSO" "Download concluido: $Arquivo"
    Unblock-File -Path $dest -ErrorAction SilentlyContinue

    if ($Arquivo.EndsWith(".zip")) {
        # ZIP nao e instalador: extrai e abre a pasta com o conteudo.
        Log-Message "ZIP" "Extraindo arquivo: $Arquivo"
        if ($null -ne $Progresso) { $Progresso.Text = "$Prefixo  Extraindo $Arquivo ..." }
        [System.Windows.Forms.Application]::DoEvents()

        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $folderName = [System.IO.Path]::GetFileNameWithoutExtension($Arquivo)
        $finalPath = Join-Path $Script:DownloadFolder $folderName
        $tempPath = Join-Path $Script:DownloadFolder "temp_$folderName"

        if (Test-Path $tempPath) { Remove-Item $tempPath -Recurse -Force | Out-Null }
        if (Test-Path $finalPath) { Remove-Item $finalPath -Recurse -Force | Out-Null }
        [System.Windows.Forms.Application]::DoEvents()

        [System.IO.Compression.ZipFile]::ExtractToDirectory($dest, $tempPath)
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

        Invoke-Item $finalPath
        Log-Message "SUCESSO" "Extraido com sucesso para: $folderName"
        return @{ Caminho = $finalPath; Acao = 'pasta' }
    }
    if ($Arquivo.EndsWith(".rar")) {
        # RAR nao tem suporte nativo no Windows: abre com o programa associado.
        if ($null -ne $Progresso) { $Progresso.Text = "$Prefixo  Abrindo $Arquivo ..." }
        Invoke-Item $dest
        Log-Message "SUCESSO" "Arquivo RAR aberto: $Arquivo"
        return @{ Caminho = $dest; Acao = 'rar' }
    }
    if ($null -ne $Progresso) { $Progresso.Text = "$Prefixo  Instalando $Arquivo ..." }
    # WorkingDirectory na pasta de downloads: instaladores auto-extraiveis (WinRAR SFX)
    # passam a sugerir essa pasta em vez de C:\WINDOWS\system32.
    Start-Process -FilePath $dest -WorkingDirectory $Script:DownloadFolder
    Log-Message "SUCESSO" "Instalador iniciado: $Arquivo"
    return @{ Caminho = $dest; Acao = 'instalador' }
}

function Show-ErroDownloadDriver {
    param($Erro, [string]$Arquivo, $Dono = $null)
    $errMsg = "$($Erro.Exception.Message)"
    if ($errMsg -match 'v[ií]rus|software.*indesejado|potentially unwanted|unwanted software') {
        Log-Message "ERRO" "Windows Defender bloqueou o arquivo (provavel falso positivo): $Arquivo"
        [System.Windows.Forms.MessageBox]::Show($Dono,
            "O Windows Defender bloqueou este driver.`n`n" +
            "Isso costuma ser um FALSO POSITIVO em instaladores de driver (o arquivo vem de fonte oficial).`n`n" +
            "A pasta 'Arquivos Xmenu' ja foi adicionada as excecoes do Defender - tente baixar novamente.`n`n" +
            "Se ainda assim bloquear, restaure o arquivo em: Seguranca do Windows > Protecao contra virus > Historico de protecao (Quarentena).",
            "Bloqueado pelo Windows Defender", "OK", "Warning") | Out-Null
    }
    else {
        Log-Message "ERRO" "Falha ao baixar driver: $Erro"
        [System.Windows.Forms.MessageBox]::Show($Dono, "Erro ao baixar o driver: $Erro", "Erro", "OK", "Error") | Out-Null
    }
}

# -----------------------------------------------------------------------------
# FILTRO DA ABA DE DRIVERS
# -----------------------------------------------------------------------------

function ConvertTo-TextoBusca {
    # Texto so com letras e numeros, minusculo e sem acento: "TM-T20" vira "tmt20"
    # e "UTILITARIO" com acento vira "utilitario"
    param([string]$Texto)
    if ([string]::IsNullOrEmpty($Texto)) { return "" }
    $decomposto = $Texto.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $decomposto.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return ($sb.ToString().ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function Test-CombinaBusca {
    # Cada palavra da busca precisa aparecer no indice (ja normalizado)
    param([string]$Indice, [string]$Busca)
    foreach ($palavra in ("$Busca" -split '\s+')) {
        $n = ConvertTo-TextoBusca $palavra
        if ($n -ne "" -and $Indice.IndexOf($n) -lt 0) { return $false }
    }
    return $true
}

function Initialize-IndiceDrivers {
    # Guarda em cada botao o texto de busca (marca + texto + nome do arquivo). O
    # texto do botao vira barra de progresso durante o download, entao a busca nao
    # pode depender dele. Cria tambem o aviso de "nenhum driver encontrado".
    param($Painel)
    $secao = ""
    foreach ($c in @($Painel.Controls)) {
        if ("$($c.Tag)" -eq 'vazio') { continue }
        if ($c -is [System.Windows.Forms.Label]) {
            $c.Tag = 'secao'
            $secao = $c.Text
        }
        elseif ($c -is [System.Windows.Forms.Button]) {
            $arquivo = ""
            if ("$($c.Tag)" -match '\|([^|]*)$') { $arquivo = $matches[1] }
            $c.AccessibleDescription = ConvertTo-TextoBusca ($secao + " " + $c.Text + " " + $arquivo)
        }
    }
    if (@($Painel.Controls | Where-Object { "$($_.Tag)" -eq 'vazio' }).Count -eq 0) {
        $aviso = New-Object System.Windows.Forms.Label
        $aviso.Text = "Nenhum driver encontrado. Tente só a marca ou o modelo (ex.: elgin, 4200, tm-t20)."
        $aviso.AutoSize = $true
        $aviso.Tag = 'vazio'
        $aviso.Visible = $false
        $aviso.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        $aviso.ForeColor = [System.Drawing.Color]::Gray
        $aviso.Location = New-Object System.Drawing.Point(15, 10)
        [void]$Painel.Controls.Add($aviso)
    }
}

function Update-FiltroDrivers {
    # Mostra so os botoes que combinam com a busca, esconde as marcas que ficaram
    # vazias e refaz as posicoes (a lista usa posicao fixa, sem layout automatico).
    # Devolve hashtable: Visiveis / Total
    param($Painel, [string]$Busca)
    $visiveis = 0
    $total = 0
    $Painel.SuspendLayout()
    try {
        # Posicao e relativa ao que esta rolado: volta ao topo antes de reposicionar
        $Painel.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
        $grupos = New-Object System.Collections.Generic.List[object]
        $aviso = $null
        $grupo = $null
        foreach ($c in @($Painel.Controls)) {
            if ("$($c.Tag)" -eq 'vazio') { $aviso = $c; continue }
            if ($c -is [System.Windows.Forms.Label]) {
                $grupo = @{ Titulo = $c; Botoes = New-Object System.Collections.Generic.List[object] }
                $grupos.Add($grupo)
            }
            elseif ($c -is [System.Windows.Forms.Button] -and $null -ne $grupo) { $grupo.Botoes.Add($c) }
        }

        $y = 10
        $primeiro = $true
        foreach ($g in $grupos) {
            $mostrar = New-Object System.Collections.Generic.List[object]
            foreach ($b in $g.Botoes) {
                $total++
                if (Test-CombinaBusca -Indice "$($b.AccessibleDescription)" -Busca $Busca) { $mostrar.Add($b) }
                else { $b.Visible = $false }
            }
            if ($mostrar.Count -eq 0) { $g.Titulo.Visible = $false; continue }
            # Mesmo espacamento da montagem original: 8 entre marcas, 28 do titulo, 47 por botao
            if (-not $primeiro) { $y += 8 }
            $primeiro = $false
            $g.Titulo.Location = New-Object System.Drawing.Point(15, $y)
            $g.Titulo.Visible = $true
            $y += 28
            foreach ($b in $mostrar) {
                $b.Location = New-Object System.Drawing.Point(15, $y)
                $b.Visible = $true
                $y += 47
                $visiveis++
            }
        }
        if ($null -ne $aviso) { $aviso.Visible = ($visiveis -eq 0) }
    }
    finally { $Painel.ResumeLayout() }
    return @{ Visiveis = $visiveis; Total = $total }
}

# -----------------------------------------------------------------------------
# PORTAS LPR (PC DE DESTINO)
# A porta LPR guarda o IP do PC que tem a impressora USB. Clientes com DHCP
# trocam esse IP e a impressao para. O MAC da placa de rede nao muda: guardado
# enquanto a porta funciona, ele acha o PC de novo quando o IP mudar.
# -----------------------------------------------------------------------------

function Get-PortasLpr {
    # Portas do monitor LPR do Windows, lidas do registro (e de la que o spooler le)
    param([string]$Hive = 'LocalMachine', [string]$Caminho = 'SYSTEM\CurrentControlSet\Control\Print\Monitors\LPR Port\Ports')
    $lista = @()
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $chave = $base.OpenSubKey($Caminho)
        if ($null -eq $chave) { return $lista }
        try {
            foreach ($nome in $chave.GetSubKeyNames()) {
                $sub = $chave.OpenSubKey($nome)
                if ($null -eq $sub) { continue }
                $lista += [PSCustomObject]@{ Porta = $nome; Servidor = "$($sub.GetValue('Server Name'))"; Fila = "$($sub.GetValue('Printer Name'))" }
                $sub.Close()
            }
        }
        finally { $chave.Close() }
    }
    finally { $base.Close() }
    return $lista
}

function Set-PortaLprServidor {
    # Cria a porta "IP:FILA" com o servidor novo, copiando a configuracao da porta
    # atual (SNMP, compatibilidade). -ManterNome so troca o IP da propria porta.
    # Devolve o nome da porta que ficou com o IP novo. Nao mexe no spooler.
    param([string]$Porta, [string]$Servidor, [switch]$ManterNome,
        [string]$Hive = 'LocalMachine', [string]$Caminho = 'SYSTEM\CurrentControlSet\Control\Print\Monitors\LPR Port\Ports')
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $chave = $base.OpenSubKey($Caminho, $true)
        if ($null -eq $chave) { throw "O monitor LPR não está instalado neste PC." }
        try {
            $velha = $chave.OpenSubKey($Porta, $true)
            if ($null -eq $velha) { throw "A porta $Porta não existe mais neste PC." }
            try {
                $novoNome = $Servidor + ":" + "$($velha.GetValue('Printer Name'))"
                if ($ManterNome -or $novoNome -eq $Porta) {
                    $velha.SetValue('Server Name', $Servidor, [Microsoft.Win32.RegistryValueKind]::String)
                    return $Porta
                }
                $nova = $chave.CreateSubKey($novoNome)
                try {
                    foreach ($v in $velha.GetValueNames()) {
                        $valor = $velha.GetValue($v, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        $nova.SetValue($v, $valor, $velha.GetValueKind($v))
                    }
                    $nova.SetValue('Server Name', $Servidor, [Microsoft.Win32.RegistryValueKind]::String)
                }
                finally { $nova.Close() }
                return $novoNome
            }
            finally { $velha.Close() }
        }
        finally { $chave.Close() }
    }
    finally { $base.Close() }
}

function Remove-PortaLprRegistro {
    param([string]$Porta, [string]$Hive = 'LocalMachine', [string]$Caminho = 'SYSTEM\CurrentControlSet\Control\Print\Monitors\LPR Port\Ports')
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive, [Microsoft.Win32.RegistryView]::Registry64)
    try {
        $chave = $base.OpenSubKey($Caminho, $true)
        if ($null -ne $chave) {
            try { $chave.DeleteSubKeyTree($Porta, $false) }
            finally { $chave.Close() }
        }
    }
    finally { $base.Close() }
}

function Get-NomesPortasMonitor {
    # Nomes das portas de um monitor do spooler ("LPR Port", "Standard TCP/IP Port"), pelo registro
    param([string]$Monitor, [string]$Hive = 'LocalMachine')
    $nomes = @()
    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::$Hive, [Microsoft.Win32.RegistryView]::Registry64)
        try {
            $chave = $base.OpenSubKey("SYSTEM\CurrentControlSet\Control\Print\Monitors\$Monitor\Ports")
            if ($null -ne $chave) { $nomes = @($chave.GetSubKeyNames()); $chave.Close() }
        }
        finally { $base.Close() }
    }
    catch {}
    return $nomes
}

function Get-TipoPortaImpressora {
    # Tipo da porta para a lista de impressoras locais
    param([string]$Porta, [string[]]$PortasLpr = @(), [string[]]$PortasTcp = @())
    $p = "$Porta".Trim()
    if ($p -eq "") { return "" }
    if ($PortasLpr -contains $p) { return "LPR" }
    if ($PortasTcp -contains $p) { return "Rede (IP)" }
    if ($p.StartsWith('\\')) { return "Compartilhada" }
    if ($p -match '^USB\d+$') { return "USB" }
    if ($p -match '^WSD-') { return "WSD" }
    if ($p -match '^(COM|LPT)\d+:?$') { return "Serial" }
    if ($p -match '^(PORTPROMPT|nul|FILE|SHRFAX|XPSPort):$') { return "Virtual" }
    return "Outra"
}

function Remove-PortasLpr {
    # Remove portas LPR que nenhuma impressora usa, pelo spooler (sem reiniciar nada).
    # A que o Windows recusar volta em Recusadas: o chamador decide se apaga pelo
    # registro com Remove-PortasLprRegistro, que reinicia o spooler.
    # Devolve hashtable: Removidas / EmUso / Recusadas
    param([string[]]$Portas)
    $res = @{ Removidas = @(); EmUso = @(); Recusadas = @() }
    # Sem a lista de impressoras nao da para saber o que esta em uso: melhor nao apagar nada
    $usadas = @(Get-Printer -ErrorAction Stop | ForEach-Object { $_.PortName })
    foreach ($p in @($Portas | Where-Object { "$_" -ne "" } | Select-Object -Unique)) {
        if ($usadas -contains $p) { $res.EmUso += $p; continue }
        try { Remove-PrinterPort -Name $p -ErrorAction Stop; $res.Removidas += $p }
        catch { $res.Recusadas += $p }
    }
    if ($res.Removidas.Count -gt 0) { Remove-LprMac -Portas $res.Removidas }
    return $res
}

function Remove-PortasLprRegistro {
    # Apaga as portas pelo registro e reinicia o spooler. Confere de novo se nenhuma
    # impressora passou a usar a porta. Devolve as portas apagadas.
    param([string[]]$Portas)
    $usadas = @(Get-Printer -ErrorAction Stop | ForEach-Object { $_.PortName })
    $apagadas = @()
    foreach ($p in $Portas) {
        if ("$p" -eq "" -or $usadas -contains $p) { continue }
        Remove-PortaLprRegistro -Porta $p
        $apagadas += $p
    }
    if ($apagadas.Count -gt 0) {
        Restart-Service -Name Spooler -Force -ErrorAction Stop
        Remove-LprMac -Portas $apagadas
    }
    return $apagadas
}

function Update-PortaLprCompleto {
    # Troca o servidor de uma porta LPR de verdade: porta nova "IP:FILA", spooler
    # reiniciado, impressoras movidas e a porta antiga removida. Se o Windows nao
    # deixar mover alguma impressora, desfaz e so troca o IP da porta antiga, que
    # imprime do mesmo jeito com o nome velho.
    # Devolve hashtable: Porta / Impressoras / Aviso
    param([string]$Porta, [string]$Servidor)
    $impressoras = @()
    try { $impressoras = @(Get-Printer -ErrorAction Stop | Where-Object { $_.PortName -eq $Porta } | ForEach-Object { $_.Name }) } catch {}
    $nova = Set-PortaLprServidor -Porta $Porta -Servidor $Servidor
    Restart-Service -Name Spooler -Force -ErrorAction Stop
    $res = @{ Porta = $nova; Impressoras = $impressoras; Aviso = "" }
    if ($nova -eq $Porta) { return $res }

    $movidas = @()
    $falhou = $false
    foreach ($imp in $impressoras) {
        try { Set-Printer -Name $imp -PortName $nova -ErrorAction Stop; $movidas += $imp }
        catch { $falhou = $true; break }
    }
    if (-not $falhou) {
        try { Remove-PrinterPort -Name $Porta -ErrorAction Stop }
        catch { $res.Aviso = "A porta antiga $Porta ficou na lista, sem uso." }
        return $res
    }

    foreach ($imp in $movidas) { try { Set-Printer -Name $imp -PortName $Porta -ErrorAction Stop } catch {} }
    [void](Set-PortaLprServidor -Porta $Porta -Servidor $Servidor -ManterNome)
    Remove-PortaLprRegistro -Porta $nova
    Restart-Service -Name Spooler -Force -ErrorAction Stop
    $res.Porta = $Porta
    $res.Aviso = "O Windows não deixou renomear a porta: ela manteve o nome $Porta, mas já aponta para $Servidor."
    return $res
}

function Get-LprMacs {
    # MAC do PC da impressora de cada porta, guardado entre uma abertura e outra
    param([string]$Arquivo = "C:\Arquivos Xmenu\lpr_mac_portas.json")
    $macs = @{}
    try {
        if (Test-Path -LiteralPath $Arquivo) {
            $obj = [System.IO.File]::ReadAllText($Arquivo) | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $macs[$p.Name] = "$($p.Value)" }
        }
    }
    catch {}
    return $macs
}

function Save-LprMac {
    # -PortaAntiga: a porta foi renomeada para o IP novo e o MAC vai junto
    param([string]$Porta, [string]$Mac, [string]$PortaAntiga = "", [string]$Arquivo = "C:\Arquivos Xmenu\lpr_mac_portas.json")
    $macs = Get-LprMacs -Arquivo $Arquivo
    if ($PortaAntiga -ne "" -and $PortaAntiga -ne $Porta) { $macs.Remove($PortaAntiga) }
    $macs[$Porta] = $Mac
    $pasta = Split-Path $Arquivo
    if (-not (Test-Path -LiteralPath $pasta)) { New-Item -ItemType Directory -Path $pasta -Force | Out-Null }
    [System.IO.File]::WriteAllText($Arquivo, ($macs | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
}

function Remove-LprMac {
    # Esquece o MAC das portas apagadas
    param([string[]]$Portas, [string]$Arquivo = "C:\Arquivos Xmenu\lpr_mac_portas.json")
    if (-not (Test-Path -LiteralPath $Arquivo)) { return }
    $macs = Get-LprMacs -Arquivo $Arquivo
    $mudou = $false
    foreach ($p in $Portas) { if ($macs.ContainsKey($p)) { $macs.Remove($p); $mudou = $true } }
    if ($mudou) { [System.IO.File]::WriteAllText($Arquivo, ($macs | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false))) }
}

function ConvertFrom-TabelaArp {
    # Linhas do "arp -a" -> IP e MAC (AA:BB:CC:DD:EE:FF). Ignora multicast e broadcast.
    param([string[]]$Linhas)
    $lista = @()
    foreach ($linha in $Linhas) {
        if ("$linha" -match '^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-fA-F]{2}(?:[-:][0-9a-fA-F]{2}){5})\s') {
            $ip = $matches[1]
            $mac = $matches[2].Replace('-', ':').ToUpper()
            if ($mac -eq 'FF:FF:FF:FF:FF:FF' -or $mac.StartsWith('01:00:5E') -or $ip -like '224.*' -or $ip -like '239.*' -or $ip -like '*.255') { continue }
            $lista += [PSCustomObject]@{ IP = $ip; Mac = $mac }
        }
    }
    return $lista
}

function Find-IpPorMac {
    # Todos os IPs com esse MAC: a tabela ARP ainda pode lembrar o IP antigo
    param([string]$Mac, $Tabela)
    $alvo = ("$Mac" -replace '[^0-9a-fA-F]', '').ToUpper()
    if ($alvo.Length -ne 12) { return @() }
    return @($Tabela | Where-Object { ("$($_.Mac)" -replace '[^0-9A-Fa-f]', '').ToUpper() -eq $alvo } | ForEach-Object { $_.IP } | Select-Object -Unique)
}

function Test-PortaVarios {
    # Testa uma porta TCP em varios IPs ao mesmo tempo, com a janela respondendo.
    # Devolve os IPs (ou nomes) que aceitaram a conexao.
    param([string[]]$Ips, [int]$Porta = 515, [int]$TimeoutMs = 700)
    $tentativas = New-Object System.Collections.Generic.List[object]
    foreach ($ip in @($Ips | Where-Object { "$_".Trim() -ne "" } | Select-Object -Unique)) {
        $cli = New-Object System.Net.Sockets.TcpClient
        try { $tentativas.Add([PSCustomObject]@{ Ip = $ip; Cliente = $cli; Tarefa = $cli.ConnectAsync($ip, $Porta) }) }
        catch { try { $cli.Close() } catch {} }
    }
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    while ($relogio.ElapsedMilliseconds -lt $TimeoutMs) {
        $pendentes = 0
        foreach ($t in $tentativas) { if (-not $t.Tarefa.IsCompleted) { $pendentes++ } }
        if ($pendentes -eq 0) { break }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    $abertos = @()
    foreach ($t in $tentativas) {
        try { if ($t.Tarefa.IsCompleted -and -not $t.Tarefa.IsFaulted -and $t.Cliente.Connected) { $abertos += $t.Ip } } catch {}
        try { $t.Cliente.Close() } catch {}
    }
    return $abertos
}

function ConvertFrom-RespostaNbstat {
    # Resposta do NBSTAT (RFC 1002): devolve o nome do PC (sufixo 00 que nao e grupo)
    param([byte[]]$Resp)
    try {
        if ($null -eq $Resp -or $Resp.Length -lt 57) { return "" }
        $pos = 12
        if (($Resp[$pos] -band 0xC0) -eq 0xC0) { $pos += 2 }
        else { while ($pos -lt $Resp.Length -and $Resp[$pos] -ne 0) { $pos += $Resp[$pos] + 1 }; $pos++ }
        $pos += 10
        if ($pos -ge $Resp.Length) { return "" }
        $qtd = $Resp[$pos]; $pos++
        for ($n = 0; $n -lt $qtd -and ($pos + 18) -le $Resp.Length; $n++) {
            $nome = [System.Text.Encoding]::ASCII.GetString($Resp, $pos, 15).Trim()
            $sufixo = $Resp[$pos + 15]
            $ehGrupo = (($Resp[$pos + 16] -band 0x80) -ne 0)
            $pos += 18
            if ($sufixo -eq 0x00 -and -not $ehGrupo -and $nome -ne "") { return $nome }
        }
    }
    catch {}
    return ""
}

function Get-NomesPcs {
    # Nome de varios PCs ao mesmo tempo, com a janela respondendo. Pergunta direto
    # ao PC pelo NetBIOS (o mesmo do "nbtstat -A"): o DNS reverso do roteador quase
    # nunca conhece os PCs da loja. O DNS fica de reserva. Devolve hashtable IP -> nome.
    param([string[]]$Ips, [int]$TimeoutMs = 2500, [int]$PortaNb = 137)
    $nomes = @{}
    $lista = @($Ips | Where-Object { "$_".Trim() -ne "" } | Select-Object -Unique)
    if ($lista.Count -eq 0) { return $nomes }

    $dns = @{}
    foreach ($ip in $lista) { try { $dns[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch {} }

    # Consulta NBSTAT pelo nome "*"
    $pacote = [byte[]](0x58, 0x4D, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x20, 0x43, 0x4B) +
    [byte[]](@(0x41) * 30) + [byte[]](0x00, 0x00, 0x21, 0x00, 0x01)
    $udp = $null
    try {
        $udp = New-Object System.Net.Sockets.UdpClient(0)
        # Sem isso o "porta inalcancavel" de um PC derruba a leitura dos outros
        try { [void]$udp.Client.IOControl(-1744830452, [byte[]](0, 0, 0, 0), $null) } catch {}
        foreach ($ip in $lista) { try { [void]$udp.Send($pacote, $pacote.Length, $ip, $PortaNb) } catch {} }
    }
    catch { $udp = $null }

    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    while ($relogio.ElapsedMilliseconds -lt $TimeoutMs) {
        while ($null -ne $udp -and $udp.Available -gt 0) {
            try {
                $origem = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                $resp = $udp.Receive([ref]$origem)
                $nomeNb = ConvertFrom-RespostaNbstat $resp
                if ($nomeNb -ne "") { $nomes[$origem.Address.ToString()] = $nomeNb }
            }
            catch {}
        }
        # DNS que falhou nao encerra a espera: o NetBIOS ainda pode responder
        $faltam = @($lista | Where-Object { -not $nomes.ContainsKey($_) -and -not ($dns.ContainsKey($_) -and $dns[$_].IsCompleted -and -not $dns[$_].IsFaulted) })
        if ($faltam.Count -eq 0) { break }
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 30
    }
    if ($null -ne $udp) { try { $udp.Close() } catch {} }

    foreach ($ip in $lista) {
        if ($nomes.ContainsKey($ip) -or -not $dns.ContainsKey($ip)) { continue }
        try {
            $t = $dns[$ip]
            if ($t.IsCompleted -and -not $t.IsFaulted -and "$($t.Result.HostName)" -ne "" -and $t.Result.HostName -ne $ip) { $nomes[$ip] = $t.Result.HostName }
        }
        catch {}
    }
    return $nomes
}

function Get-SubredesLocais {
    # Prefixo /24 de cada placa de rede ligada ("192.168.3"): e o que a varredura cobre
    $subs = @()
    try {
        foreach ($placa in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($placa.OperationalStatus -ne 'Up' -or $placa.NetworkInterfaceType -eq 'Loopback') { continue }
            foreach ($end in $placa.GetIPProperties().UnicastAddresses) {
                if ($end.Address.AddressFamily -ne 'InterNetwork') { continue }
                $txt = $end.Address.ToString()
                if ($txt -like '127.*' -or $txt -like '169.254.*') { continue }
                if ($txt -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.\d{1,3}$') { $subs += $matches[1] }
            }
        }
    }
    catch {}
    return @($subs | Select-Object -Unique)
}

function Invoke-AcordarRede {
    # Ping rapido em cada /24: mesmo PC que bloqueia ping responde ao ARP, e o
    # Windows guarda o MAC dele na tabela
    param([string[]]$Subredes, [int]$EsperaMs = 1500)
    $pings = New-Object System.Collections.Generic.List[object]
    foreach ($sub in $Subredes) {
        for ($i = 1; $i -le 254; $i++) {
            $pg = New-Object System.Net.NetworkInformation.Ping
            $pings.Add($pg)
            try { [void]$pg.SendPingAsync("$sub.$i", 500) } catch {}
        }
    }
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    while ($relogio.ElapsedMilliseconds -lt $EsperaMs) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }
    foreach ($pg in $pings) { try { $pg.Dispose() } catch {} }
}

function Get-DadosOrigemLpr {
    # O que o tecnico anota no PC da impressora para configurar o PC de destino.
    # Devolve hashtable: Ips / Macs / Filas / Texto
    $ips = @()
    $macs = @()
    try {
        # Placas pela API do .NET: o Get-NetIPConfiguration dava o mesmo resultado,
        # mas levava uns 4 s na primeira chamada e travava a abertura da janela
        $placas = @()
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            if ($ni.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $props = $ni.GetIPProperties()
            $ipv4 = @($props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.Address.ToString() })
            if ($ipv4.Count -eq 0) { continue }
            $temGateway = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0
            $placas += @{ Ips = $ipv4; Mac = $ni.GetPhysicalAddress().ToString(); Gateway = $temGateway }
        }
        # Placa com gateway primeiro: e a da rede da loja (evita adaptador virtual)
        $comGateway = @($placas | Where-Object { $_.Gateway })
        if ($comGateway.Count -gt 0) { $placas = $comGateway }
        foreach ($placa in $placas) {
            foreach ($ip in $placa.Ips) {
                if ($ip -notlike '127.*' -and $ip -notlike '169.254.*') { $ips += $ip }
            }
            if ($placa.Mac.Length -eq 12) { $macs += ((($placa.Mac -split '(.{2})') | Where-Object { $_ -ne '' }) -join ':').ToUpper() }
        }
    }
    catch {}
    $filas = @()
    # Win32_Printer e nao Get-Printer: o Get-Printer carrega o modulo de impressao do
    # Windows (mais 1,4 s na primeira vez) so para listar as filas compartilhadas
    try { $filas = @(Get-WmiObject Win32_Printer -Filter "Shared=True" -ErrorAction Stop | Where-Object { "$($_.ShareName)" -ne "" } | ForEach-Object { $_.ShareName }) } catch {}
    $ips = @($ips | Select-Object -Unique)
    $macs = @($macs | Select-Object -Unique)
    $textoFilas = "nenhuma impressora compartilhada"
    if ($filas.Count -gt 0) { $textoFilas = $filas -join ", " }
    $texto = "PC da impressora: $env:COMPUTERNAME`r`nIP: " + ($ips -join ", ") + "`r`nMAC: " + ($macs -join ", ") + "`r`nFila (compartilhamento): " + $textoFilas
    return @{ Ips = $ips; Macs = $macs; Filas = $filas; Texto = $texto }
}

function New-ImpressoraLpr {
    # Porta LPR "IP:FILA" e a impressora usando ela, sem passar pelo assistente do
    # Windows. Add-PrinterPort cria a porta LPR sem reiniciar o spooler.
    # Devolve hashtable: Porta / Impressora / PortaJaExistia / DriverInstalado
    param([string]$Servidor, [string]$Fila, [string]$Nome, [string]$Driver)
    if ($null -ne (Get-Printer -Name $Nome -ErrorAction SilentlyContinue)) {
        throw "Já existe uma impressora chamada ""$Nome"" neste PC. Escolha outro nome."
    }
    # Driver antes da porta: se nao instalar, nao sobra porta sem impressora
    $driverInstalado = Install-DriverWindows -Driver $Driver
    $porta = $Servidor + ":" + $Fila
    $jaExistia = ($null -ne (Get-PrinterPort -Name $porta -ErrorAction SilentlyContinue))
    if (-not $jaExistia) { Add-PrinterPort -Name $porta -LprHostAddress $Servidor -LprQueueName $Fila -ErrorAction Stop }
    Add-Printer -Name $Nome -DriverName $Driver -PortName $porta -ErrorAction Stop
    return @{ Porta = $porta; Impressora = $Nome; PortaJaExistia = $jaExistia; DriverInstalado = $driverInstalado }
}

function Install-DriverWindows {
    # Driver que vem com o Windows mas nao fica instalado ("Generic / Text Only"):
    # instala do repositorio de drivers do proprio Windows. Devolve $true se instalou.
    param([string]$Driver)
    if ($null -ne (Get-PrinterDriver -Name $Driver -ErrorAction SilentlyContinue)) { return $false }
    try { Add-PrinterDriver -Name $Driver -ErrorAction Stop }
    catch {
        $erroDriver = $_.Exception.Message
        # O Generic / Text Only fica no prnge001.inf; pelo nome sozinho alguns Windows nao acham
        $infGenerico = Join-Path $env:windir "INF\prnge001.inf"
        if ($Driver -ne "Generic / Text Only" -or -not (Test-Path -LiteralPath $infGenerico)) {
            throw "Não foi possível instalar o driver ""$Driver"": $erroDriver"
        }
        try { Add-PrinterDriver -Name $Driver -InfPath $infGenerico -ErrorAction Stop }
        catch { throw "Não foi possível instalar o driver ""$Driver"": $($_.Exception.Message)" }
    }
    return $true
}

function Send-TesteImpressao {
    # Folha curta em vez da pagina de teste do Windows, que gasta meio metro de bobina
    param([string]$Impressora, [string]$Detalhe = "")
    $linhas = @("*** TESTE XMENU ***", "", "Impressora: $Impressora")
    if ($Detalhe -ne "") { $linhas += $Detalhe }
    $linhas += @("Enviado de: $env:COMPUTERNAME", ("Em: " + (Get-Date).ToString("dd/MM/yyyy HH:mm:ss")), "", "Se esta folha saiu, a impressao esta OK.", "", "", "")
    $linhas | Out-Printer -Name $Impressora
}

function Test-EnderecoIpv4 {
    param([string]$Texto)
    $t = "$Texto".Trim()
    if ($t -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') { return $false }
    foreach ($i in 1..4) { if ([int]$matches[$i] -gt 255) { return $false } }
    return $true
}

function Show-PortasLpr {
    # Janela do PC de destino: lista as portas LPR, testa se o PC da impressora
    # responde e corrige a porta quando o IP dele mudou.
    # -AbrirNova: ja abre a tela de nova impressora (vindo do ATIVAR MONITOR LPR)
    # -SelecionarPorta: abre com essa porta selecionada (vindo da lista de impressoras locais)
    param($Dono = $null, [switch]$AbrirNova, [string]$SelecionarPorta = "")
    try {
        $Script:LprOcupado = $false
        # Porta do LPD: sempre 515 no uso real; $Script:LprPorta existe para o teste
        $portaLpd = 515
        if ($Script:LprPorta) { $portaLpd = [int]$Script:LprPorta }
        $f = New-ToolForm "Portas LPR deste PC" 880 590
        $f.MinimumSize = New-Object System.Drawing.Size(880, 590)

        New-ToolLabel $f "PORTAS LPR DESTE COMPUTADOR" 20 14 12 -Negrito | Out-Null
        New-ToolLabel $f "Quando o IP do PC com a impressora USB muda, a porta para de imprimir. Aqui você acha o PC de novo e corrige a porta, sem refazer a impressora." 20 42 9 -Cor $Script:UiSuave -W 830 | Out-Null

        $lvLpr = New-Object System.Windows.Forms.ListView
        $lvLpr.Location = New-Object System.Drawing.Point(20, 74)
        $lvLpr.Size = New-Object System.Drawing.Size(824, 264)
        $lvLpr.Anchor = 'Top,Left,Right,Bottom'
        $lvLpr.MultiSelect = $false
        Format-ToolListView $lvLpr
        [void]$lvLpr.Columns.Add("Porta", 190)
        [void]$lvLpr.Columns.Add("PC da impressora (IP)", 140)
        [void]$lvLpr.Columns.Add("Fila", 110)
        [void]$lvLpr.Columns.Add("Situação", 110)
        [void]$lvLpr.Columns.Add("MAC do PC", 130)
        [void]$lvLpr.Columns.Add("Impressoras", 140)
        [void]$f.Controls.Add($lvLpr)

        $btnLprMac = New-ToolButton $f "ATUALIZAR IP PELO MAC" 20 350 220 34 $Script:UiVerde $null "Procura na rede o PC da impressora pelo MAC guardado e corrige a porta para o IP atual dele"
        $btnLprTrocar = New-ToolButton $f "TROCAR IP..." 250 350 140 34 $Script:UiAzul $null "Digitar o IP novo do PC da impressora"
        $btnLprProcurar = New-ToolButton $f "PROCURAR NA REDE" 400 350 180 34 $Script:UiCinza $null "Lista os PCs da rede com o LPD ativo (porta 515) para escolher"
        $btnLprRecarregar = New-ToolButton $f "RECARREGAR" 590 350 130 34 $Script:UiCinza $null "Lê as portas de novo e testa se cada PC responde"
        $btnLprFechar = New-ToolButton $f "FECHAR" 744 350 100 34 $Script:UiCinza $null "Fecha esta janela"
        $btnLprNova = New-ToolButton $f "NOVA IMPRESSORA LPR" 20 392 220 34 $Script:UiAzul $null "Cria a porta LPR e a impressora neste PC de uma vez, sem o assistente do Windows"
        $btnLprTeste = New-ToolButton $f "IMPRIMIR TESTE" 250 392 140 34 $Script:UiCinza $null "Manda uma folha curta de teste pela impressora que usa a porta selecionada"
        $corRemoverLpr = [System.Drawing.Color]::FromArgb(150, 40, 40)
        $btnLprRemover = New-ToolButton $f "REMOVER PORTA" 400 392 180 34 $corRemoverLpr $null "Apaga a porta selecionada. Só vale para porta que nenhuma impressora usa"
        $btnLprLimpar = New-ToolButton $f "LIMPAR SEM USO" 590 392 130 34 $corRemoverLpr $null "Apaga de uma vez as portas LPR que nenhuma impressora usa (as que sobraram das trocas de IP)"
        foreach ($b in @($btnLprMac, $btnLprTrocar, $btnLprProcurar, $btnLprRecarregar, $btnLprNova, $btnLprTeste, $btnLprRemover, $btnLprLimpar)) { $b.Anchor = 'Bottom,Left' }
        $btnLprFechar.Anchor = 'Bottom,Right'
        $lblLprStatus = New-ToolLabel $f "" 20 436 9.5 -Negrito -W 824
        $lblLprStatus.Height = 40
        $lblLprStatus.Anchor = 'Bottom,Left,Right'
        $lblLprAjuda = New-ToolLabel $f "Como usar: selecione a porta que parou e clique em ATUALIZAR IP PELO MAC. O MAC do PC da impressora é guardado sozinho sempre que a porta está funcionando; se ainda não tiver MAC guardado, use PROCURAR NA REDE ou TROCAR IP. A troca reinicia o spooler de impressão deste PC. Portas que sobraram de trocas antigas (sem impressora) saem com LIMPAR SEM USO." 20 478 8.5 -Cor $Script:UiSuave -W 824
        $lblLprAjuda.Height = 44
        $lblLprAjuda.Anchor = 'Bottom,Left,Right'

        # ---------------------------------------------------------------------
        # ROTINAS
        # ---------------------------------------------------------------------
        $statusLpr = {
            param([string]$Texto, $Cor = $null)
            if ($null -ne $Cor) { $lblLprStatus.ForeColor = $Cor } else { $lblLprStatus.ForeColor = $Script:UiSuave }
            $lblLprStatus.Text = $Texto
            [System.Windows.Forms.Application]::DoEvents()
        }

        $atualizaBotoesLpr = {
            $selLpr = $null
            if ($lvLpr.SelectedItems.Count -gt 0) { $selLpr = $lvLpr.SelectedItems[0].Tag }
            $btnLprMac.Enabled = ($null -ne $selLpr -and "$($selLpr.Mac)" -ne "" -and -not $Script:LprOcupado)
            $btnLprTrocar.Enabled = ($null -ne $selLpr -and -not $Script:LprOcupado)
            $btnLprTeste.Enabled = ($null -ne $selLpr -and -not $Script:LprOcupado)
            $btnLprRemover.Enabled = ($null -ne $selLpr -and -not $Script:LprOcupado)
            $btnLprLimpar.Enabled = ($lvLpr.Items.Count -gt 0 -and -not $Script:LprOcupado)
            $btnLprProcurar.Enabled = (-not $Script:LprOcupado)
            $btnLprRecarregar.Enabled = (-not $Script:LprOcupado)
            $btnLprNova.Enabled = (-not $Script:LprOcupado)
        }

        $travarLpr = {
            param([bool]$Sim)
            $Script:LprOcupado = $Sim
            $f.UseWaitCursor = $Sim
            & $atualizaBotoesLpr
        }

        # -Selecionar: porta que fica selecionada depois de carregar, se ainda existir
        $carregarLpr = {
            param([string]$Selecionar = "")
            & $travarLpr $true
            try {
                & $statusLpr "Lendo as portas LPR e testando se cada PC responde..." $Script:UiAmarelo
                $portasLidas = @(Get-PortasLpr)
                $macsGuardados = Get-LprMacs
                $servidores = @($portasLidas | ForEach-Object { $_.Servidor } | Where-Object { "$_" -ne "" } | Select-Object -Unique)
                $noArLista = @()
                if ($servidores.Count -gt 0) { $noArLista = @(Test-PortaVarios -Ips $servidores -Porta $portaLpd -TimeoutMs 1200) }
                $impressorasPc = @()
                try { $impressorasPc = @(Get-Printer -ErrorAction Stop) } catch {}
                $tabelaArp = @(ConvertFrom-TabelaArp -Linhas (arp -a))

                $lvLpr.BeginUpdate()
                $lvLpr.Items.Clear()
                foreach ($pl in $portasLidas) {
                    $noAr = ($noArLista -contains $pl.Servidor)
                    $macPorta = ""
                    if ($macsGuardados.ContainsKey($pl.Porta)) { $macPorta = "$($macsGuardados[$pl.Porta])" }
                    if ($noAr) {
                        # Porta funcionando: guarda o MAC do PC para achar ele quando o IP mudar
                        $macVisto = @($tabelaArp | Where-Object { $_.IP -eq $pl.Servidor } | ForEach-Object { $_.Mac })
                        if ($macVisto.Count -gt 0 -and $macVisto[0] -ne $macPorta) {
                            $macPorta = $macVisto[0]
                            Save-LprMac -Porta $pl.Porta -Mac $macPorta
                        }
                    }
                    $nomesImp = @($impressorasPc | Where-Object { $_.PortName -eq $pl.Porta } | ForEach-Object { $_.Name })
                    $item = New-Object System.Windows.Forms.ListViewItem($pl.Porta)
                    [void]$item.SubItems.Add($pl.Servidor)
                    [void]$item.SubItems.Add($pl.Fila)
                    if ($noAr) { [void]$item.SubItems.Add("RESPONDENDO") } else { [void]$item.SubItems.Add("SEM RESPOSTA") }
                    if ($macPorta -ne "") { [void]$item.SubItems.Add($macPorta) } else { [void]$item.SubItems.Add("ainda não guardado") }
                    if ($nomesImp.Count -gt 0) { [void]$item.SubItems.Add(($nomesImp -join ", ")) } else { [void]$item.SubItems.Add("nenhuma (sem uso)") }
                    if ($noAr) { $item.ForeColor = $Script:UiVerde } else { $item.ForeColor = $Script:UiVermelho }
                    # Porta sem impressora nao imprime nada: apagada para nao parecer impressora parada
                    if ($nomesImp.Count -eq 0) { $item.ForeColor = $Script:UiSuave }
                    $item.Tag = [PSCustomObject]@{ Porta = $pl.Porta; Servidor = $pl.Servidor; Fila = $pl.Fila; Mac = $macPorta; NoAr = $noAr; Impressoras = $nomesImp }
                    [void]$lvLpr.Items.Add($item)
                }
                $lvLpr.EndUpdate()

                # So conta como parada a porta que tem impressora; a sem uso tem aviso proprio
                $semResposta = @($lvLpr.Items | Where-Object { -not $_.Tag.NoAr -and @($_.Tag.Impressoras).Count -gt 0 })
                $semUso = @($lvLpr.Items | Where-Object { @($_.Tag.Impressoras).Count -eq 0 })
                $avisoSemUso = ""
                if ($semUso.Count -gt 0) { $avisoSemUso = " $($semUso.Count) porta(s) sem impressora: LIMPAR SEM USO apaga." }
                $pedida = @($lvLpr.Items | Where-Object { $Selecionar -ne "" -and $_.Tag.Porta -eq $Selecionar })
                if ($lvLpr.Items.Count -eq 0) {
                    & $statusLpr "Nenhuma porta LPR neste PC. Primeiro adicione a impressora pelo ABRIR ASSISTENTE DO WINDOWS." $Script:UiAmarelo
                }
                elseif ($semResposta.Count -gt 0) {
                    $semResposta[0].Selected = $true
                    & $statusLpr ("$($semResposta.Count) porta(s) com impressora sem resposta. Selecione e clique em ATUALIZAR IP PELO MAC." + $avisoSemUso) $Script:UiVermelho
                }
                else {
                    $lvLpr.Items[0].Selected = $true
                    & $statusLpr ("Todas as portas com impressora estão respondendo. O MAC de cada PC já ficou guardado para quando o IP mudar." + $avisoSemUso) $Script:UiVerde
                }
                if ($pedida.Count -gt 0) {
                    $lvLpr.SelectedItems.Clear()
                    $pedida[0].Selected = $true
                    $pedida[0].EnsureVisible()
                }
            }
            catch { & $statusLpr "Erro ao ler as portas LPR: $($_.Exception.Message)" $Script:UiVermelho }
            finally { & $travarLpr $false }
        }

        $aplicarLpr = {
            param($SelPorta, [string]$NovoIp, [string]$MacNovo)
            $mensagemFim = $null
            $portaFinal = $SelPorta.Porta
            & $travarLpr $true
            try {
                & $statusLpr "Trocando a porta para $NovoIp e reiniciando o spooler..." $Script:UiAmarelo
                $resTroca = Update-PortaLprCompleto -Porta $SelPorta.Porta -Servidor $NovoIp
                $portaFinal = $resTroca.Porta
                $macFica = $MacNovo
                if ("$macFica" -eq "") { $macFica = $SelPorta.Mac }
                if ("$macFica" -ne "") { Save-LprMac -Porta $resTroca.Porta -Mac $macFica -PortaAntiga $SelPorta.Porta }
                Log-Message "SUCESSO" "LPR: porta $($SelPorta.Porta) agora aponta para $NovoIp ($($resTroca.Porta))"
                $mensagemFim = "Porta corrigida: agora imprime em $NovoIp (porta $($resTroca.Porta))."
                if ($resTroca.Aviso -ne "") { $mensagemFim = $mensagemFim + " " + $resTroca.Aviso }
            }
            catch {
                Log-Message "ERRO" "LPR: falha ao trocar a porta $($SelPorta.Porta) - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show($f, "Não foi possível trocar a porta: $($_.Exception.Message)", "Portas LPR", "OK", "Error") | Out-Null
            }
            finally { & $travarLpr $false }
            & $carregarLpr $portaFinal
            if ($null -ne $mensagemFim) { & $statusLpr $mensagemFim $Script:UiVerde }
        }

        # Remove as portas pelo spooler; a que o Windows recusar pode sair pelo registro
        $removerPortasLpr = {
            param([string[]]$Portas)
            $resRem = $null
            & $travarLpr $true
            try {
                & $statusLpr "Removendo $($Portas.Count) porta(s)..." $Script:UiAmarelo
                $resRem = Remove-PortasLpr -Portas $Portas
            }
            catch {
                Log-Message "ERRO" "LPR: falha ao remover portas - $($_.Exception.Message)"
                [System.Windows.Forms.MessageBox]::Show($f, "Não foi possível remover: $($_.Exception.Message)", "Portas LPR", "OK", "Error") | Out-Null
            }
            finally { & $travarLpr $false }
            if ($null -eq $resRem) { return }

            if ($resRem.Recusadas.Count -gt 0) {
                $r = [System.Windows.Forms.MessageBox]::Show($f,
                    "O Windows não deixou remover com o spooler ligado:`r`n`r`n" + (($resRem.Recusadas | ForEach-Object { "  - $_" }) -join "`r`n") + "`r`n`r`nRemover pelo registro? O spooler de impressão deste PC será reiniciado.",
                    "Portas LPR", "YesNo", "Warning")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                    & $travarLpr $true
                    try {
                        & $statusLpr "Removendo pelo registro e reiniciando o spooler..." $Script:UiAmarelo
                        $apagadas = @(Remove-PortasLprRegistro -Portas $resRem.Recusadas)
                        $resRem.Removidas += $apagadas
                        $resRem.Recusadas = @($resRem.Recusadas | Where-Object { $apagadas -notcontains $_ })
                    }
                    catch {
                        Log-Message "ERRO" "LPR: falha ao remover portas pelo registro - $($_.Exception.Message)"
                        [System.Windows.Forms.MessageBox]::Show($f, "Não foi possível remover pelo registro: $($_.Exception.Message)", "Portas LPR", "OK", "Error") | Out-Null
                    }
                    finally { & $travarLpr $false }
                }
            }

            if ($resRem.Removidas.Count -gt 0) { Log-Message "SUCESSO" ("LPR: porta(s) removida(s): " + ($resRem.Removidas -join ", ")) }
            & $carregarLpr
            $partes = @()
            if ($resRem.Removidas.Count -gt 0) { $partes += "$($resRem.Removidas.Count) porta(s) removida(s)." }
            if ($resRem.EmUso.Count -gt 0) { $partes += "Ficaram as que uma impressora passou a usar: $($resRem.EmUso -join ', ')." }
            if ($resRem.Recusadas.Count -gt 0) { $partes += "Não removidas: $($resRem.Recusadas -join ', ')." }
            $corRem = $Script:UiVerde
            if ($resRem.Removidas.Count -eq 0) { $corRem = $Script:UiAmarelo }
            if ($partes.Count -gt 0) { & $statusLpr ($partes -join " ") $corRem }
        }

        $pedirIpLpr = {
            param([string]$Atual)
            $dlg = New-ToolForm "Trocar IP da porta" 420 210
            $dlg.FormBorderStyle = 'FixedDialog'
            $dlg.MaximizeBox = $false
            $dlg.MinimizeBox = $false
            New-ToolLabel $dlg "IP novo do PC que tem a impressora USB:" 20 20 9.5 | Out-Null
            $txtIpNovo = New-Object System.Windows.Forms.TextBox
            $txtIpNovo.Location = New-Object System.Drawing.Point(20, 50)
            $txtIpNovo.Size = New-Object System.Drawing.Size(360, 26)
            $txtIpNovo.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $txtIpNovo.ForeColor = $Script:UiTexto
            $txtIpNovo.BorderStyle = 'FixedSingle'
            $txtIpNovo.Font = New-Object System.Drawing.Font("Consolas", 11)
            $txtIpNovo.Text = $Atual
            [void]$dlg.Controls.Add($txtIpNovo)
            $btnOkIp = New-ToolButton $dlg "TROCAR" 170 104 110 32 $Script:UiVerde $null ""
            $btnCancIp = New-ToolButton $dlg "CANCELAR" 290 104 90 32 $Script:UiCinza $null ""
            $btnOkIp.Add_Click({ $dlg.Tag = $txtIpNovo.Text.Trim(); $dlg.DialogResult = 'OK'; $dlg.Close() })
            $btnCancIp.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() })
            $dlg.AcceptButton = $btnOkIp
            $dlg.CancelButton = $btnCancIp
            $dlg.Add_Shown({ $txtIpNovo.Focus(); $txtIpNovo.SelectAll() })
            $ipDigitado = $null
            if ($dlg.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK) { $ipDigitado = "$($dlg.Tag)" }
            $dlg.Dispose()
            return $ipDigitado
        }

        $escolherPcLpr = {
            param($Achados, $DonoDlg = $null)
            if ($null -eq $DonoDlg) { $DonoDlg = $f }
            $dlg = New-ToolForm "PCs com o LPD ativo" 580 370
            New-ToolLabel $dlg "Escolha o PC que tem a impressora USB:" 20 16 10 -Negrito | Out-Null
            $lvPcs = New-Object System.Windows.Forms.ListView
            $lvPcs.Location = New-Object System.Drawing.Point(20, 46)
            $lvPcs.Size = New-Object System.Drawing.Size(524, 214)
            $lvPcs.MultiSelect = $false
            Format-ToolListView $lvPcs
            [void]$lvPcs.Columns.Add("IP", 130)
            [void]$lvPcs.Columns.Add("Nome", 230)
            [void]$lvPcs.Columns.Add("MAC", 150)
            foreach ($a in $Achados) {
                $it = New-Object System.Windows.Forms.ListViewItem($a.IP)
                [void]$it.SubItems.Add($a.Nome)
                [void]$it.SubItems.Add($a.Mac)
                $it.Tag = $a
                [void]$lvPcs.Items.Add($it)
            }
            if ($lvPcs.Items.Count -gt 0) { $lvPcs.Items[0].Selected = $true }
            [void]$dlg.Controls.Add($lvPcs)
            $btnUsar = New-ToolButton $dlg "USAR ESTE PC" 314 274 130 32 $Script:UiVerde $null ""
            $btnCancPc = New-ToolButton $dlg "CANCELAR" 454 274 90 32 $Script:UiCinza $null ""
            $usarPc = {
                if ($lvPcs.SelectedItems.Count -eq 0) { return }
                $dlg.Tag = $lvPcs.SelectedItems[0].Tag
                $dlg.DialogResult = 'OK'
                $dlg.Close()
            }
            $btnUsar.Add_Click($usarPc)
            $lvPcs.Add_DoubleClick($usarPc)
            $btnCancPc.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() })
            $pcEscolhido = $null
            if ($dlg.ShowDialog($DonoDlg) -eq [System.Windows.Forms.DialogResult]::OK) { $pcEscolhido = $dlg.Tag }
            $dlg.Dispose()
            return $pcEscolhido
        }

        # ---------------------------------------------------------------------
        # EVENTOS
        # ---------------------------------------------------------------------
        $btnLprMac.Add_Click({
                if ($Script:LprOcupado -or $lvLpr.SelectedItems.Count -eq 0) { return }
                $selLpr = $lvLpr.SelectedItems[0].Tag
                if ("$($selLpr.Mac)" -eq "") { return }
                $ipAchado = $null
                & $travarLpr $true
                try {
                    & $statusLpr "Procurando na rede o PC com o MAC $($selLpr.Mac)..." $Script:UiAmarelo
                    Invoke-AcordarRede -Subredes (Get-SubredesLocais)
                    $candidatos = @(Find-IpPorMac -Mac $selLpr.Mac -Tabela (ConvertFrom-TabelaArp -Linhas (arp -a)))
                    if ($candidatos.Count -gt 0) {
                        # A tabela ARP pode lembrar o IP antigo: vale o que responde no LPD
                        $respondem = @(Test-PortaVarios -Ips $candidatos -Porta $portaLpd -TimeoutMs 1200)
                        $outros = @($candidatos | Where-Object { $_ -ne $selLpr.Servidor })
                        if ($respondem.Count -gt 0) { $ipAchado = $respondem[0] }
                        elseif ($outros.Count -gt 0) { $ipAchado = $outros[0] }
                        else { $ipAchado = $candidatos[0] }
                    }
                }
                catch { & $statusLpr "Erro ao procurar na rede: $($_.Exception.Message)" $Script:UiVermelho; return }
                finally { & $travarLpr $false }

                if ($null -eq $ipAchado) {
                    & $statusLpr "Não encontrei o PC com o MAC $($selLpr.Mac) na rede. Confira se ele está ligado e na mesma rede, ou use PROCURAR NA REDE." $Script:UiVermelho
                    return
                }
                if ($ipAchado -eq $selLpr.Servidor) {
                    & $statusLpr "O PC da impressora continua no IP $ipAchado. Se não imprime, confira nele se o LPD está ativo (Etapa 1) e se a impressora está compartilhada como $($selLpr.Fila)." $Script:UiAmarelo
                    return
                }
                $r = [System.Windows.Forms.MessageBox]::Show($f,
                    "Encontrei o PC da impressora (MAC $($selLpr.Mac)) no IP $ipAchado.`r`n`r`nA porta $($selLpr.Porta) ainda aponta para $($selLpr.Servidor).`r`n`r`nTrocar a porta para $ipAchado agora? O spooler de impressão deste PC será reiniciado.",
                    "Portas LPR", "YesNo", "Question")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { & $aplicarLpr $selLpr $ipAchado $selLpr.Mac }
            })

        $btnLprTrocar.Add_Click({
                if ($Script:LprOcupado -or $lvLpr.SelectedItems.Count -eq 0) { return }
                $selLpr = $lvLpr.SelectedItems[0].Tag
                $ipNovo = & $pedirIpLpr $selLpr.Servidor
                if ($null -eq $ipNovo) { return }
                if (-not (Test-EnderecoIpv4 $ipNovo)) {
                    [System.Windows.Forms.MessageBox]::Show($f, "Digite um IP válido, por exemplo 192.168.0.25.", "Portas LPR", "OK", "Warning") | Out-Null
                    return
                }
                if ($ipNovo -eq $selLpr.Servidor) { & $statusLpr "A porta já aponta para $ipNovo." $Script:UiAmarelo; return }
                $responde = $false
                & $travarLpr $true
                try {
                    & $statusLpr "Testando o LPD em $ipNovo..." $Script:UiAmarelo
                    $responde = (@(Test-PortaVarios -Ips @($ipNovo) -Porta $portaLpd -TimeoutMs 1500).Count -gt 0)
                }
                finally { & $travarLpr $false }
                if (-not $responde) {
                    $r = [System.Windows.Forms.MessageBox]::Show($f,
                        "O IP $ipNovo não respondeu na porta 515 (LPD).`r`n`r`nPode ser o IP errado, o PC desligado ou o LPD parado nele. Trocar a porta mesmo assim?",
                        "Portas LPR", "YesNo", "Warning")
                    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
                # So guarda o MAC quando o IP respondeu: senao poderia ser outro aparelho
                $macIp = ""
                if ($responde) { $macIp = Get-MacDeIP $ipNovo (arp -a) }
                & $aplicarLpr $selLpr $ipNovo $macIp
            })

        # Varre a rede atras de PCs com o LPD ativo; usada pelo PROCURAR NA REDE e
        # pela tela de nova impressora. Devolve IP / Nome / Mac de cada um.
        $procurarPcsLpr = {
                if ($Script:LprOcupado) { return }
                $achados = @()
                & $travarLpr $true
                try {
                    $subs = @(Get-SubredesLocais)
                    & $statusLpr ("Varrendo a rede " + (($subs | ForEach-Object { "$_.x" }) -join ", ") + "...") $Script:UiAmarelo
                    Invoke-AcordarRede -Subredes $subs
                    $tabela = @(ConvertFrom-TabelaArp -Linhas (arp -a))
                    $meusIps = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString })
                    $todos = @(foreach ($s in $subs) { for ($i = 1; $i -le 254; $i++) { "$s.$i" } })
                    $todos = @($todos | Where-Object { $meusIps -notcontains $_ })
                    & $statusLpr "Procurando PCs com o LPD ativo (porta 515)..." $Script:UiAmarelo
                    $ipsAbertos = @(Test-PortaVarios -Ips $todos -Porta $portaLpd -TimeoutMs 1500)
                    $nomesPcs = @{}
                    if ($ipsAbertos.Count -gt 0) {
                        & $statusLpr "Buscando o nome de $($ipsAbertos.Count) PC(s)..." $Script:UiAmarelo
                        $nomesPcs = Get-NomesPcs -Ips $ipsAbertos
                    }
                    foreach ($ipAberto in $ipsAbertos) {
                        $nomePc = ""
                        if ($nomesPcs.ContainsKey($ipAberto)) { $nomePc = $nomesPcs[$ipAberto] }
                        $macPc = @($tabela | Where-Object { $_.IP -eq $ipAberto } | ForEach-Object { $_.Mac }) | Select-Object -First 1
                        $achados += [PSCustomObject]@{ IP = $ipAberto; Nome = $nomePc; Mac = "$macPc" }
                    }
                }
                catch { & $statusLpr "Erro ao procurar na rede: $($_.Exception.Message)" $Script:UiVermelho; return }
                finally { & $travarLpr $false }

                if ($achados.Count -eq 0) {
                    & $statusLpr "Nenhum PC com o LPD ativo foi encontrado na rede. Confira se o PC da impressora está ligado e se o LPD foi ativado nele (Etapa 1)." $Script:UiVermelho
                    return
                }
                & $statusLpr "$($achados.Count) PC(s) com o LPD ativo encontrado(s)." $Script:UiVerde
                return $achados
            }

        $btnLprProcurar.Add_Click({
                $achados = @(& $procurarPcsLpr)
                if ($achados.Count -eq 0) { return }
                $pc = & $escolherPcLpr $achados
                if ($null -eq $pc) { return }
                # Sem porta para corrigir (PC ainda sem impressora LPR): cria a impressora com o PC escolhido
                if ($lvLpr.SelectedItems.Count -eq 0) { & $criarNovaLpr $pc.IP; return }
                $selLpr = $lvLpr.SelectedItems[0].Tag
                if ($pc.IP -eq $selLpr.Servidor) { & $statusLpr "A porta $($selLpr.Porta) já aponta para $($pc.IP)." $Script:UiAmarelo; return }
                $r = [System.Windows.Forms.MessageBox]::Show($f,
                    "Trocar a porta $($selLpr.Porta) para o PC $($pc.IP)$(if ($pc.Nome) { " ($($pc.Nome))" })?`r`n`r`nO spooler de impressão deste PC será reiniciado.",
                    "Portas LPR", "YesNo", "Question")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { & $aplicarLpr $selLpr $pc.IP $pc.Mac }
            })

        # Drivers do catalogo (os mesmos da aba Drivers) para baixar. Devolve o item escolhido ou $null.
        $escolherDriverBaixar = {
            param($DonoDlg)
            $dlgDrv = New-ToolForm "Baixar driver" 640 480
            $dlgDrv.MinimumSize = New-Object System.Drawing.Size(640, 480)
            New-ToolLabel $dlgDrv "Pesquise a marca ou o modelo da impressora:" 20 16 10 -Negrito | Out-Null
            $txtBuscaDrv = New-Object System.Windows.Forms.TextBox
            $txtBuscaDrv.Location = New-Object System.Drawing.Point(20, 46)
            $txtBuscaDrv.Size = New-Object System.Drawing.Size(584, 26)
            $txtBuscaDrv.Anchor = 'Top,Left,Right'
            $txtBuscaDrv.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $txtBuscaDrv.ForeColor = $Script:UiTexto
            $txtBuscaDrv.BorderStyle = 'FixedSingle'
            $txtBuscaDrv.Font = New-Object System.Drawing.Font("Segoe UI", 10)
            [void]$dlgDrv.Controls.Add($txtBuscaDrv)
            $lvDrv = New-Object System.Windows.Forms.ListView
            $lvDrv.Location = New-Object System.Drawing.Point(20, 82)
            $lvDrv.Size = New-Object System.Drawing.Size(584, 290)
            $lvDrv.Anchor = 'Top,Left,Right,Bottom'
            $lvDrv.MultiSelect = $false
            Format-ToolListView $lvDrv
            [void]$lvDrv.Columns.Add("Marca", 190)
            [void]$lvDrv.Columns.Add("Driver", 370)
            [void]$dlgDrv.Controls.Add($lvDrv)
            $lblContaDrv = New-ToolLabel $dlgDrv "" 20 392 9 -Cor $Script:UiSuave -W 290
            $lblContaDrv.Anchor = 'Bottom,Left'
            $btnDrvOk = New-ToolButton $dlgDrv "BAIXAR E INSTALAR" 334 386 170 32 $Script:UiVerde $null ""
            $btnDrvCanc = New-ToolButton $dlgDrv "CANCELAR" 514 386 90 32 $Script:UiCinza $null ""
            $btnDrvOk.Anchor = 'Bottom,Right'; $btnDrvCanc.Anchor = 'Bottom,Right'

            $catalogoDrv = @(Get-CatalogoDrivers | Where-Object { $_.Tipo -eq 'Download' -and $_.Texto -match '\[DRIVER\]' })
            $mostrarDrv = {
                $lvDrv.BeginUpdate()
                $lvDrv.Items.Clear()
                foreach ($drvCat in $catalogoDrv) {
                    $indiceDrv = ConvertTo-TextoBusca ($drvCat.Secao + " " + $drvCat.Texto + " " + $drvCat.Arquivo)
                    if (-not (Test-CombinaBusca -Indice $indiceDrv -Busca $txtBuscaDrv.Text)) { continue }
                    $itDrv = New-Object System.Windows.Forms.ListViewItem($drvCat.Secao)
                    [void]$itDrv.SubItems.Add(($drvCat.Texto.Trim() -replace '^\[DRIVER\]\s*', ''))
                    $itDrv.Tag = $drvCat
                    [void]$lvDrv.Items.Add($itDrv)
                }
                $lvDrv.EndUpdate()
                if ($lvDrv.Items.Count -gt 0) { $lvDrv.Items[0].Selected = $true }
                $lblContaDrv.Text = "$($lvDrv.Items.Count) de $($catalogoDrv.Count) drivers"
                $btnDrvOk.Enabled = ($lvDrv.Items.Count -gt 0)
            }
            $usarDrv = {
                if ($lvDrv.SelectedItems.Count -eq 0) { return }
                $dlgDrv.Tag = $lvDrv.SelectedItems[0].Tag
                $dlgDrv.DialogResult = 'OK'
                $dlgDrv.Close()
            }
            $btnDrvOk.Add_Click($usarDrv)
            $lvDrv.Add_DoubleClick($usarDrv)
            $btnDrvCanc.Add_Click({ $dlgDrv.DialogResult = 'Cancel'; $dlgDrv.Close() })
            $txtBuscaDrv.Add_TextChanged($mostrarDrv)
            # Seta para baixo sai da pesquisa e vai para a lista
            $txtBuscaDrv.Add_KeyDown({
                    param($s, $e)
                    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Down -and $lvDrv.Items.Count -gt 0) { $e.SuppressKeyPress = $true; $lvDrv.Focus() | Out-Null }
                })
            $dlgDrv.AcceptButton = $btnDrvOk
            $dlgDrv.CancelButton = $btnDrvCanc
            & $mostrarDrv
            $dlgDrv.Add_Shown({ $txtBuscaDrv.Focus() | Out-Null })
            $drvEscolhido = $null
            if ($dlgDrv.ShowDialog($DonoDlg) -eq [System.Windows.Forms.DialogResult]::OK) { $drvEscolhido = $dlgDrv.Tag }
            $dlgDrv.Dispose()
            return $drvEscolhido
        }

        # Formulario da nova impressora LPR. Devolve Ip / Fila / Nome / Driver ou $null.
        $pedirNovaLpr = {
            param([string]$IpInicial = "")
            $dlg = New-ToolForm "Nova impressora LPR" 540 430
            $dlg.FormBorderStyle = 'FixedDialog'
            $dlg.MaximizeBox = $false
            $dlg.MinimizeBox = $false
            $campoNova = {
                param([int]$Y, [int]$W, [string]$Valor)
                $t = New-Object System.Windows.Forms.TextBox
                $t.Location = New-Object System.Drawing.Point(20, $Y)
                $t.Size = New-Object System.Drawing.Size($W, 26)
                $t.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
                $t.ForeColor = $Script:UiTexto
                $t.BorderStyle = 'FixedSingle'
                $t.Font = New-Object System.Drawing.Font("Segoe UI", 10)
                $t.Text = $Valor
                [void]$dlg.Controls.Add($t)
                return $t
            }
            New-ToolLabel $dlg "IP do PC que tem a impressora USB:" 20 18 9.5 | Out-Null
            $txtNovaIp = & $campoNova 42 320 $IpInicial
            $btnNovaAchar = New-ToolButton $dlg "PROCURAR NA REDE" 350 40 150 30 $Script:UiCinza $null "Lista os PCs com o LPD ativo para escolher"
            New-ToolLabel $dlg "Nome do compartilhamento no PC da impressora (fila):" 20 82 9.5 | Out-Null
            $txtNovaFila = & $campoNova 106 320 "IMPRESSORA"
            New-ToolLabel $dlg "Nome da impressora neste PC:" 20 146 9.5 | Out-Null
            $txtNovaNome = & $campoNova 170 480 "LPR - IMPRESSORA"
            New-ToolLabel $dlg "Driver (o mesmo instalado no PC da impressora):" 20 210 9.5 | Out-Null
            $cmbNovaDriver = New-Object System.Windows.Forms.ComboBox
            $cmbNovaDriver.Location = New-Object System.Drawing.Point(20, 234)
            $cmbNovaDriver.Width = 320
            $cmbNovaDriver.DropDownStyle = 'DropDownList'
            $cmbNovaDriver.FlatStyle = 'Flat'
            $cmbNovaDriver.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 34)
            $cmbNovaDriver.ForeColor = $Script:UiTexto
            $driversPc = @()
            try { $driversPc = @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object { $_.Name }) } catch {}
            # O Generic / Text Only vem com o Windows mas so fica instalado quando alguem usa:
            # aparece sempre e e instalado na hora de criar a impressora
            $driversPc = @(@($driversPc) + "Generic / Text Only" | Sort-Object -Unique)
            foreach ($d in $driversPc) { [void]$cmbNovaDriver.Items.Add($d) }
            $cmbNovaDriver.SelectedIndex = $cmbNovaDriver.Items.IndexOf("Generic / Text Only")
            [void]$dlg.Controls.Add($cmbNovaDriver)
            $btnNovaBaixar = New-ToolButton $dlg "BAIXAR DRIVER..." 350 232 150 30 $Script:UiCinza $null "Baixa o instalador do driver pela mesma lista da aba Drivers. Quando a instalação terminar e você voltar para esta tela, o driver novo já fica selecionado"
            $textoDicaNova = "Generic / Text Only vem com o Windows e é instalado na hora, se precisar. Para outro modelo use BAIXAR DRIVER: ao terminar a instalação e voltar para esta tela, o driver novo já aparece selecionado."
            $lblNovaDica = New-ToolLabel $dlg $textoDicaNova 20 266 8.5 -Cor $Script:UiSuave -W 480
            $lblNovaDica.Height = 50
            $btnNovaCriar = New-ToolButton $dlg "CRIAR IMPRESSORA" 270 324 140 34 $Script:UiVerde $null ""
            $btnNovaCanc = New-ToolButton $dlg "CANCELAR" 420 324 80 34 $Script:UiCinza $null ""

            # Ao voltar para a tela (depois do instalador do fabricante), o driver que apareceu fica selecionado
            $Script:LprBaixandoDriver = $false
            $recarregarDriversNova = {
                if ($Script:LprBaixandoDriver) { return }
                $atuaisDrv = @()
                try { $atuaisDrv = @(Get-PrinterDriver -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { return }
                $novosDrv = @($atuaisDrv | Where-Object { -not $cmbNovaDriver.Items.Contains($_) } | Sort-Object -Unique)
                if ($novosDrv.Count -eq 0) { return }
                $todosDrv = @(@($cmbNovaDriver.Items) + $novosDrv | Sort-Object -Unique)
                $cmbNovaDriver.BeginUpdate()
                $cmbNovaDriver.Items.Clear()
                foreach ($nomeDrv in $todosDrv) { [void]$cmbNovaDriver.Items.Add($nomeDrv) }
                $cmbNovaDriver.EndUpdate()
                $cmbNovaDriver.SelectedItem = $novosDrv[0]
                $lblNovaDica.ForeColor = $Script:UiVerde
                if ($novosDrv.Count -eq 1) { $lblNovaDica.Text = "Driver novo instalado e já selecionado: $($novosDrv[0])." }
                else { $lblNovaDica.Text = "$($novosDrv.Count) drivers novos instalados ($($novosDrv -join ', ')). O primeiro já está selecionado: confira na lista se é o do modelo." }
                Log-Message "INFO" ("LPR: driver(s) novo(s) na lista: " + ($novosDrv -join ", "))
            }
            $dlg.Add_Activated($recarregarDriversNova)
            $dlg.Add_FormClosing({
                    param($s, $e)
                    if ($Script:LprBaixandoDriver) { $e.Cancel = $true }
                })
            $btnNovaBaixar.Add_Click({
                    if ($Script:LprBaixandoDriver) { return }
                    $drvBaixar = & $escolherDriverBaixar $dlg
                    if ($null -eq $drvBaixar) { return }
                    $nomeBaixar = ($drvBaixar.Texto.Trim() -replace '^\[DRIVER\]\s*', '')
                    $Script:LprBaixandoDriver = $true
                    foreach ($b in @($btnNovaBaixar, $btnNovaAchar, $btnNovaCriar, $btnNovaCanc)) { $b.Enabled = $false }
                    $lblNovaDica.ForeColor = $Script:UiAmarelo
                    try {
                        $baixado = Invoke-BaixarDriver -Url $drvBaixar.Url -Arquivo $drvBaixar.Arquivo -Progresso $lblNovaDica -Prefixo "Baixando $($nomeBaixar):"
                        $lblNovaDica.ForeColor = $Script:UiAmarelo
                        switch ($baixado.Acao) {
                            'pasta' { $lblNovaDica.Text = "O driver $nomeBaixar veio em ZIP e a pasta foi aberta. Instale o driver por ela e volte para esta tela: ele aparece selecionado." }
                            'rar' { $lblNovaDica.Text = "O driver $nomeBaixar veio em RAR e o arquivo foi aberto. Extraia, instale o driver e volte para esta tela: ele aparece selecionado." }
                            default { $lblNovaDica.Text = "Instalador do $nomeBaixar aberto. Conclua a instalação e volte para esta tela: o driver novo aparece selecionado." }
                        }
                    }
                    catch {
                        Show-ErroDownloadDriver -Erro $_ -Arquivo $drvBaixar.Arquivo -Dono $dlg
                        $lblNovaDica.ForeColor = $Script:UiSuave
                        $lblNovaDica.Text = $textoDicaNova
                    }
                    finally {
                        $Script:LprBaixandoDriver = $false
                        foreach ($b in @($btnNovaBaixar, $btnNovaAchar, $btnNovaCriar, $btnNovaCanc)) { $b.Enabled = $true }
                    }
                })

            # O nome acompanha a fila enquanto ninguem mexeu nele
            $Script:LprNomeEditado = $false
            $txtNovaFila.Add_TextChanged({ if (-not $Script:LprNomeEditado) { $txtNovaNome.Text = "LPR - " + $txtNovaFila.Text.Trim() } })
            $txtNovaNome.Add_KeyPress({ $Script:LprNomeEditado = $true })
            $btnNovaAchar.Add_Click({
                    $pcsRede = @(& $procurarPcsLpr)
                    if ($pcsRede.Count -eq 0) {
                        [System.Windows.Forms.MessageBox]::Show($dlg, "Nenhum PC com o LPD ativo foi encontrado. Confira se o LPD foi ativado no PC da impressora (Etapa 1).", "Nova impressora LPR", "OK", "Warning") | Out-Null
                        return
                    }
                    $pcRede = & $escolherPcLpr $pcsRede $dlg
                    if ($null -ne $pcRede) { $txtNovaIp.Text = $pcRede.IP }
                })
            $btnNovaCriar.Add_Click({
                    $erroNova = ""
                    if (-not (Test-EnderecoIpv4 $txtNovaIp.Text)) { $erroNova = "Digite o IP do PC da impressora, por exemplo 192.168.0.25." }
                    elseif ($txtNovaFila.Text.Trim() -notmatch '^[A-Za-z0-9_.-]+$') { $erroNova = "A fila é o nome do compartilhamento, sem espaços (ex.: IMPRESSORA)." }
                    elseif ($txtNovaNome.Text.Trim() -eq "") { $erroNova = "Dê um nome para a impressora neste PC." }
                    elseif ($cmbNovaDriver.SelectedIndex -lt 0) { $erroNova = "Escolha o driver. Se a lista está vazia, instale o driver pela aba Drivers de Impressoras." }
                    if ($erroNova -ne "") {
                        [System.Windows.Forms.MessageBox]::Show($dlg, $erroNova, "Nova impressora LPR", "OK", "Warning") | Out-Null
                        return
                    }
                    $dlg.Tag = [PSCustomObject]@{ Ip = $txtNovaIp.Text.Trim(); Fila = $txtNovaFila.Text.Trim(); Nome = $txtNovaNome.Text.Trim(); Driver = "$($cmbNovaDriver.SelectedItem)" }
                    $dlg.DialogResult = 'OK'
                    $dlg.Close()
                })
            $btnNovaCanc.Add_Click({ $dlg.DialogResult = 'Cancel'; $dlg.Close() })
            $dlg.CancelButton = $btnNovaCanc
            $dlg.Add_Shown({
                    if ($txtNovaIp.Text -ne "") { $txtNovaFila.Focus() | Out-Null; $txtNovaFila.SelectAll() }
                    else { $txtNovaIp.Focus() | Out-Null }
                })
            $dadosNova = $null
            if ($dlg.ShowDialog($f) -eq [System.Windows.Forms.DialogResult]::OK) { $dadosNova = $dlg.Tag }
            $dlg.Dispose()
            return $dadosNova
        }

        # Cria porta + impressora; usada pelo NOVA IMPRESSORA LPR e pelo PROCURAR NA REDE
        # quando nao ha porta para corrigir.
        $criarNovaLpr = {
                param([string]$IpInicial = "")
                if ($Script:LprOcupado) { return }
                $nova = & $pedirNovaLpr $IpInicial
                if ($null -eq $nova) { return }
                $responde = $false
                & $travarLpr $true
                try {
                    & $statusLpr "Testando o LPD em $($nova.Ip)..." $Script:UiAmarelo
                    $responde = (@(Test-PortaVarios -Ips @($nova.Ip) -Porta $portaLpd -TimeoutMs 1500).Count -gt 0)
                }
                finally { & $travarLpr $false }
                if (-not $responde) {
                    $r = [System.Windows.Forms.MessageBox]::Show($f,
                        "O PC $($nova.Ip) não respondeu na porta 515 (LPD).`r`n`r`nPode ser o IP errado, o PC desligado ou o LPD ainda não ativado nele. Criar a impressora mesmo assim?",
                        "Nova impressora LPR", "YesNo", "Warning")
                    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
                }
                $criada = $null
                & $travarLpr $true
                try {
                    & $statusLpr "Criando a porta $($nova.Ip):$($nova.Fila) e a impressora $($nova.Nome)..." $Script:UiAmarelo
                    $criada = New-ImpressoraLpr -Servidor $nova.Ip -Fila $nova.Fila -Nome $nova.Nome -Driver $nova.Driver
                    if ($responde) {
                        $macNova = Get-MacDeIP $nova.Ip (arp -a)
                        if ("$macNova" -ne "") { Save-LprMac -Porta $criada.Porta -Mac $macNova }
                    }
                    if ($criada.DriverInstalado) { Log-Message "INFO" "LPR: driver $($nova.Driver) instalado do repositório do Windows" }
                    Log-Message "SUCESSO" "LPR: impressora $($nova.Nome) criada na porta $($criada.Porta) com o driver $($nova.Driver)"
                }
                catch {
                    $msgErro = $_.Exception.Message
                    if ($msgErro -match 'LPR|monitor|porta|port') { $msgErro = $msgErro + "`r`n`r`nConfira se o Monitor LPR está ativo (botão ATIVAR MONITOR LPR) e se o Preparador está aberto como administrador." }
                    Log-Message "ERRO" "LPR: falha ao criar a impressora $($nova.Nome) - $($_.Exception.Message)"
                    [System.Windows.Forms.MessageBox]::Show($f, "Não foi possível criar a impressora:`r`n`r`n$msgErro", "Nova impressora LPR", "OK", "Error") | Out-Null
                }
                finally { & $travarLpr $false }
                if ($null -eq $criada) { return }
                & $carregarLpr $criada.Porta
                & $statusLpr "Impressora $($criada.Impressora) criada na porta $($criada.Porta)." $Script:UiVerde
                $r = [System.Windows.Forms.MessageBox]::Show($f, "Impressora $($criada.Impressora) criada.`r`n`r`nImprimir uma folha de teste agora?", "Nova impressora LPR", "YesNo", "Question")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                    try {
                        Send-TesteImpressao -Impressora $criada.Impressora -Detalhe "Porta: $($criada.Porta)"
                        & $statusLpr "Teste enviado para $($criada.Impressora). Se não sair, confira no PC $($nova.Ip) se a impressora está ligada e compartilhada como $($nova.Fila)." $Script:UiVerde
                    }
                    catch { & $statusLpr "Não foi possível enviar o teste: $($_.Exception.Message)" $Script:UiVermelho }
                }
            }

        $btnLprNova.Add_Click({ & $criarNovaLpr })

        $btnLprTeste.Add_Click({
                if ($Script:LprOcupado -or $lvLpr.SelectedItems.Count -eq 0) { return }
                $selLpr = $lvLpr.SelectedItems[0].Tag
                $impsPorta = @()
                try { $impsPorta = @(Get-Printer -ErrorAction Stop | Where-Object { $_.PortName -eq $selLpr.Porta } | ForEach-Object { $_.Name }) } catch {}
                if ($impsPorta.Count -eq 0) {
                    & $statusLpr "Nenhuma impressora deste PC usa a porta $($selLpr.Porta). Crie uma com NOVA IMPRESSORA LPR." $Script:UiAmarelo
                    return
                }
                & $travarLpr $true
                try {
                    & $statusLpr "Enviando teste para $($impsPorta[0])..." $Script:UiAmarelo
                    Send-TesteImpressao -Impressora $impsPorta[0] -Detalhe "Porta: $($selLpr.Porta)"
                    Log-Message "INFO" "LPR: teste enviado para $($impsPorta[0]) ($($selLpr.Porta))"
                    & $statusLpr "Teste enviado para $($impsPorta[0]). Se não sair em alguns segundos, confira no PC $($selLpr.Servidor) se a impressora está ligada, com papel e compartilhada como $($selLpr.Fila)." $Script:UiVerde
                }
                catch { & $statusLpr "Não foi possível enviar o teste: $($_.Exception.Message)" $Script:UiVermelho }
                finally { & $travarLpr $false }
            })

        $btnLprRemover.Add_Click({
                if ($Script:LprOcupado -or $lvLpr.SelectedItems.Count -eq 0) { return }
                $selLpr = $lvLpr.SelectedItems[0].Tag
                if (@($selLpr.Impressoras).Count -gt 0) {
                    & $statusLpr "A porta $($selLpr.Porta) é usada pela impressora $(@($selLpr.Impressoras) -join ', '). Para corrigir o IP use ATUALIZAR IP PELO MAC ou TROCAR IP." $Script:UiAmarelo
                    return
                }
                $r = [System.Windows.Forms.MessageBox]::Show($f,
                    "Remover a porta $($selLpr.Porta)?`r`n`r`nNenhuma impressora deste PC usa essa porta.",
                    "Portas LPR", "YesNo", "Question")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { & $removerPortasLpr @($selLpr.Porta) }
            })

        $btnLprLimpar.Add_Click({
                if ($Script:LprOcupado) { return }
                $portasSemUso = @($lvLpr.Items | Where-Object { @($_.Tag.Impressoras).Count -eq 0 } | ForEach-Object { $_.Tag.Porta })
                if ($portasSemUso.Count -eq 0) {
                    & $statusLpr "Nenhuma porta sem uso: todas as portas LPR deste PC têm impressora." $Script:UiVerde
                    return
                }
                $listaSemUso = ($portasSemUso | Select-Object -First 15 | ForEach-Object { "  - $_" }) -join "`r`n"
                if ($portasSemUso.Count -gt 15) { $listaSemUso += "`r`n  ... e mais $($portasSemUso.Count - 15)" }
                $r = [System.Windows.Forms.MessageBox]::Show($f,
                    "Remover $($portasSemUso.Count) porta(s) LPR que nenhuma impressora usa?`r`n`r`n$listaSemUso`r`n`r`nAs portas com impressora não são mexidas.",
                    "Portas LPR", "YesNo", "Question")
                if ($r -eq [System.Windows.Forms.DialogResult]::Yes) { & $removerPortasLpr $portasSemUso }
            })

        $btnLprRecarregar.Add_Click({ if (-not $Script:LprOcupado) { & $carregarLpr } })
        $btnLprFechar.Add_Click({ $f.Close() })
        $lvLpr.Add_SelectedIndexChanged($atualizaBotoesLpr)
        $f.Add_FormClosing({
                param($s, $e)
                if ($Script:LprOcupado) { $e.Cancel = $true }
            })
        $f.Add_Shown({
                & $carregarLpr $SelecionarPorta
                if ($AbrirNova) { $btnLprNova.PerformClick() }
            })
        Log-Message "INFO" "LPR: janela de portas aberta"
        [void]$f.ShowDialog($Dono)
    }
    catch {
        Log-Message "ERRO" "Falha na janela de portas LPR: $_"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir a janela: $($_.Exception.Message)", "Portas LPR", "OK", "Error") | Out-Null
    }
}

function Show-PrinterManager {
    try {
        if ($null -ne $Script:PrinterManagerForm -and $Script:PrinterManagerForm.Visible) {
            $Script:PrinterManagerForm.Activate(); return
        }

        $Script:PrinterManagerForm = New-Object System.Windows.Forms.Form
        $Script:PrinterManagerForm.Text = "Impressoras: Compartilhamento, LPR e Drivers"; $Script:PrinterManagerForm.Size = "780,650"; $Script:PrinterManagerForm.StartPosition = 'CenterParent'
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
        # Pesquisa fixa no topo, fora do painel que rola, para nao sumir ao descer a lista
        $pnlDrvBusca = New-Object System.Windows.Forms.Panel
        $pnlDrvBusca.Size = New-Object System.Drawing.Size(735, 42); $pnlDrvBusca.Location = New-Object System.Drawing.Point(15, 65)
        $pnlDrvBusca.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
        $pnlDrvBusca.Visible = $false
        [void]$Script:PrinterManagerForm.Controls.Add($pnlDrvBusca)

        $lblDrvBusca = New-Object System.Windows.Forms.Label
        $lblDrvBusca.Text = "Pesquisar driver:"; $lblDrvBusca.AutoSize = $true; $lblDrvBusca.Location = '12,12'
        $lblDrvBusca.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold); $lblDrvBusca.ForeColor = 'WhiteSmoke'
        [void]$pnlDrvBusca.Controls.Add($lblDrvBusca)

        $txtDrvBusca = New-Object System.Windows.Forms.TextBox
        $txtDrvBusca.Location = '140,9'; $txtDrvBusca.Width = 380
        $txtDrvBusca.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 25); $txtDrvBusca.ForeColor = 'White'
        $txtDrvBusca.BorderStyle = 'FixedSingle'; $txtDrvBusca.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        [void]$pnlDrvBusca.Controls.Add($txtDrvBusca)

        $btnDrvLimpar = New-Object System.Windows.Forms.Button
        $btnDrvLimpar.Text = "✕"; $btnDrvLimpar.Location = '526,8'; $btnDrvLimpar.Size = '30,27'
        $btnDrvLimpar.FlatStyle = 'Flat'; $btnDrvLimpar.FlatAppearance.BorderSize = 0; $btnDrvLimpar.Cursor = 'Hand'
        $btnDrvLimpar.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65); $btnDrvLimpar.ForeColor = 'White'
        $btnDrvLimpar.Visible = $false
        [void]$pnlDrvBusca.Controls.Add($btnDrvLimpar)

        $lblDrvConta = New-Object System.Windows.Forms.Label
        $lblDrvConta.AutoSize = $true; $lblDrvConta.Location = '566,12'
        $lblDrvConta.Font = New-Object System.Drawing.Font("Segoe UI", 9); $lblDrvConta.ForeColor = 'Gray'
        [void]$pnlDrvBusca.Controls.Add($lblDrvConta)

        $btnDrvInstalados = New-Object System.Windows.Forms.Button
        $btnDrvInstalados.Text = "INSTALADOS"; $btnDrvInstalados.Location = '635,7'; $btnDrvInstalados.Size = '92,28'
        $btnDrvInstalados.FlatStyle = 'Flat'; $btnDrvInstalados.FlatAppearance.BorderSize = 0; $btnDrvInstalados.Cursor = 'Hand'
        $btnDrvInstalados.BackColor = [System.Drawing.Color]::FromArgb(25, 90, 120); $btnDrvInstalados.ForeColor = 'White'
        $btnDrvInstalados.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
        $btnDrvInstalados.Add_Click({
                # Evita reinstalar o que o PC ja tem
                $instalados = @()
                try { $instalados = @(Get-PrinterDriver -ErrorAction Stop | Sort-Object Name | ForEach-Object { "- $($_.Name)" }) } catch {}
                $textoInst = "Nenhum driver de impressora encontrado neste PC."
                if ($instalados.Count -gt 0) { $textoInst = "Drivers de impressora já instalados neste PC ($($instalados.Count)):`r`n`r`n" + ($instalados -join "`r`n") }
                [System.Windows.Forms.MessageBox]::Show($Script:PrinterManagerForm, $textoInst, "Drivers instalados", "OK", "Information") | Out-Null
            })
        [void]$pnlDrvBusca.Controls.Add($btnDrvInstalados)
        if ($Script:ToolTip) {
            $Script:ToolTip.SetToolTip($btnDrvInstalados, "Mostra os drivers de impressora que este PC já tem, para não reinstalar à toa.")
            $Script:ToolTip.SetToolTip($txtDrvBusca, "Digite a marca, o modelo ou o tipo: elgin, bematech 4200, tm-t20, utilitario, etiqueta... Não precisa de acento nem hífen. Esc limpa.")
        }

        $pnlDrivers = New-Object System.Windows.Forms.Panel
        $pnlDrivers.Size = New-Object System.Drawing.Size(735, 476); $pnlDrivers.Location = New-Object System.Drawing.Point(15, 109)
        $pnlDrivers.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35)
        $pnlDrivers.AutoScroll = $true
        $pnlDrivers.Visible = $false
        [void]$Script:PrinterManagerForm.Controls.Add($pnlDrivers)
        # Sem refazer o layout a cada um dos ~70 botoes: volta a desenhar no fim da montagem
        $pnlDrivers.SuspendLayout()
        # IP, MAC e fila deste PC (aba LPR) so carregam quando a aba abre
        $Script:LprDadosCarregados = $false

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
            $pnlLocal.Visible = $true; $pnlLpr.Visible = $false; $pnlDrivers.Visible = $false; $pnlDrvBusca.Visible = $false
            $btnTabLocal.BackColor = $tabActiveColor; $btnTabLocal.ForeColor = 'White'
            $btnTabLpr.BackColor = $tabInactiveColor; $btnTabLpr.ForeColor = 'LightGray'
            $btnTabDrivers.BackColor = $tabInactiveColor; $btnTabDrivers.ForeColor = 'LightGray'
        })

        $btnTabLpr.Add_Click({
            # IP, MAC e fila deste PC so na primeira vez que a aba abre: consultar a
            # rede antes de mostrar a janela deixava a abertura lenta
            if (-not $Script:LprDadosCarregados) {
                $Script:LprDadosCarregados = $true
                $Script:PrinterManagerForm.UseWaitCursor = $true
                try {
                    & $preencheIpSrv
                    [void](& $mostraDadosOrigem)
                }
                finally { $Script:PrinterManagerForm.UseWaitCursor = $false }
            }
            $pnlLocal.Visible = $false; $pnlLpr.Visible = $true; $pnlDrivers.Visible = $false; $pnlDrvBusca.Visible = $false
            $btnTabLocal.BackColor = $tabInactiveColor; $btnTabLocal.ForeColor = 'LightGray'
            $btnTabLpr.BackColor = $tabActiveColor; $btnTabLpr.ForeColor = 'White'
            $btnTabDrivers.BackColor = $tabInactiveColor; $btnTabDrivers.ForeColor = 'LightGray'
        })

        $btnTabDrivers.Add_Click({
            $pnlLocal.Visible = $false; $pnlLpr.Visible = $false; $pnlDrivers.Visible = $true; $pnlDrvBusca.Visible = $true
            $btnTabLocal.BackColor = $tabInactiveColor; $btnTabLocal.ForeColor = 'LightGray'
            $btnTabLpr.BackColor = $tabInactiveColor; $btnTabLpr.ForeColor = 'LightGray'
            $btnTabDrivers.BackColor = $tabActiveColor; $btnTabDrivers.ForeColor = 'White'
            # Cursor ja na pesquisa: o tecnico abre a aba e digita o modelo direto.
            # Select (e nao Focus) vale mesmo com a janela ainda sem foco.
            $txtDrvBusca.Select()
        })

        [void]$Script:PrinterManagerForm.Controls.Add($btnTabLocal)
        [void]$Script:PrinterManagerForm.Controls.Add($btnTabLpr)
        [void]$Script:PrinterManagerForm.Controls.Add($btnTabDrivers)

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL DRIVERS (ABA 3)
        # -------------------------------------------------------------
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
                $origText = $this.Text
                try {
                    $this.Enabled = $false
                    [void](Invoke-BaixarDriver -Url $parts[0] -Arquivo $parts[1] -Progresso $this)
                    $this.Text = "✔ $origText"
                } catch {
                    Show-ErroDownloadDriver -Erro $_ -Arquivo $parts[1]
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

        # A lista vem do catalogo (Get-CatalogoDrivers), a mesma do BAIXAR DRIVER da nova impressora LPR
        $secaoDrv = $null
        foreach ($drv in @(Get-CatalogoDrivers)) {
            if ($drv.Secao -ne $secaoDrv) {
                if ($null -ne $secaoDrv) { $drvY += 8 }
                Add-DriverSection $pnlDrivers ([ref]$drvY) $drv.Secao $drv.CorSecao
                $secaoDrv = $drv.Secao
            }
            if ($drv.Tipo -eq 'Site') { Add-DriverLinkButton $pnlDrivers ([ref]$drvY) $drv.Texto $drv.Url $drv.Cor }
            else { Add-DriverButton $pnlDrivers ([ref]$drvY) $drv.Texto $drv.Url $drv.Arquivo $drv.Cor }
        }

        # Pesquisa: indexa o texto original de cada botao e refaz a lista a cada letra
        Initialize-IndiceDrivers -Painel $pnlDrivers
        $aplicaFiltroDrv = {
            $rf = Update-FiltroDrivers -Painel $pnlDrivers -Busca $txtDrvBusca.Text
            if ("$($txtDrvBusca.Text)".Trim() -eq "") { $lblDrvConta.Text = "$($rf.Total) drivers" }
            else { $lblDrvConta.Text = "$($rf.Visiveis) de $($rf.Total)" }
            $btnDrvLimpar.Visible = ("$($txtDrvBusca.Text)" -ne "")
        }
        $txtDrvBusca.Add_TextChanged($aplicaFiltroDrv)
        $txtDrvBusca.Add_KeyDown({
                param($s, $e)
                if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $e.SuppressKeyPress = $true; $txtDrvBusca.Text = "" }
            })
        $btnDrvLimpar.Add_Click({ $txtDrvBusca.Text = ""; $txtDrvBusca.Focus() | Out-Null })
        & $aplicaFiltroDrv
        $pnlDrivers.ResumeLayout()

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL LOCAL (ABA 1)
        # -------------------------------------------------------------
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = '15,15'; $lv.Size = '705,300'
        $lv.View = 'Details'; $lv.FullRowSelect = $true; $lv.GridLines = $false
        $lv.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 25); $lv.ForeColor = 'WhiteSmoke'
        $lv.BorderStyle = 'None'; $lv.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
        
        $lv.Columns.Add("Impressora", 210) | Out-Null
        $lv.Columns.Add("Tipo", 95) | Out-Null
        $lv.Columns.Add("Porta", 150) | Out-Null
        $lv.Columns.Add("Compartilhada?", 110) | Out-Null
        $lv.Columns.Add("Nome Compart.", 135) | Out-Null
        [void]$pnlLocal.Controls.Add($lv)

        $LoadPrinters = {
            $lv.Items.Clear()
            try {
                $printers = Get-WmiObject Win32_Printer
                $portasLprPc = @(Get-NomesPortasMonitor -Monitor "LPR Port")
                $portasTcpPc = @(Get-NomesPortasMonitor -Monitor "Standard TCP/IP Port")
                foreach ($p in $printers) {
                    $pName = if ($p.Name) { $p.Name } else { "Sem Nome" }
                    $pPort = if ($p.PortName) { $p.PortName } else { "" }
                    $pShareName = if ($p.ShareName) { $p.ShareName } else { "" }
                    $isShared = if ($p.Shared) { "Sim" } else { "Não" }
                    $pTipo = Get-TipoPortaImpressora -Porta $pPort -PortasLpr $portasLprPc -PortasTcp $portasTcpPc

                    $item = New-Object System.Windows.Forms.ListViewItem($pName)
                    $item.SubItems.Add($pTipo) | Out-Null
                    $item.SubItems.Add($pPort) | Out-Null
                    $item.SubItems.Add($isShared) | Out-Null
                    $item.SubItems.Add($pShareName) | Out-Null
                    $item.Tag = [PSCustomObject]@{ Nome = $pName; Porta = $pPort; Tipo = $pTipo }

                    if ($p.Shared) {
                        $item.ForeColor = [System.Drawing.Color]::PaleGreen
                    }
                    elseif ($pTipo -eq "LPR") {
                        $item.ForeColor = [System.Drawing.Color]::LightSkyBlue
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
            
            $fInput.Add_Shown({ try { Set-JanelaAdaptavel $this | Out-Null } catch {} })
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

        # Atalho para a janela das portas LPR, ja com a impressora selecionada
        $abrirPortasLprLocal = {
            $portaLocal = ""
            if ($lv.SelectedItems.Count -gt 0 -and "$($lv.SelectedItems[0].Tag.Tipo)" -eq "LPR") { $portaLocal = $lv.SelectedItems[0].Tag.Porta }
            Show-PortasLpr -Dono $Script:PrinterManagerForm -SelecionarPorta $portaLocal
            # A troca de IP pode renomear a porta
            &$LoadPrinters
        }
        $btnLprLocal = New-Object System.Windows.Forms.Button
        $btnLprLocal.Text = "PORTAS LPR (TROCAR IP)"; $btnLprLocal.Location = '15,420'; $btnLprLocal.Size = '345,45'
        $btnLprLocal.BackColor = [System.Drawing.Color]::FromArgb(25, 90, 120); $btnLprLocal.FlatStyle = 'Flat'; $btnLprLocal.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $btnLprLocal.Cursor = 'Hand'; $btnLprLocal.ForeColor = 'White'; $btnLprLocal.FlatAppearance.BorderSize = 0
        $btnLprLocal.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 110, 145)
        $btnLprLocal.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(15, 70, 95)
        $btnLprLocal.Add_Click($abrirPortasLprLocal)
        $lv.Add_DoubleClick({
            if ($lv.SelectedItems.Count -gt 0 -and "$($lv.SelectedItems[0].Tag.Tipo)" -eq "LPR") { & $abrirPortasLprLocal }
        })
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($btnLprLocal, "Abre as portas LPR já com a impressora LPR selecionada: troca o IP, acha o PC pelo MAC, imprime teste e remove portas sem uso. Dois cliques numa impressora LPR fazem o mesmo.") }
        [void]$pnlLocal.Controls.Add($btnLprLocal)

        $btnSpool = New-Object System.Windows.Forms.Button
        $btnSpool.Text = "REINICIAR SPOOLER DE IMPRESSÃO"; $btnSpool.Location = '375,420'; $btnSpool.Size = '345,45'
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
        # Preenchido quando a aba LPR abre (ver o clique da aba)
        $preencheIpSrv = {
            try {
                $activeIps = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
                $txtIpSrv.Text = $activeIps -join ", "
            } catch { $txtIpSrv.Text = "IP não encontrado" }
        }
        [void]$pnlServerCard.Controls.Add($txtIpSrv)

        # MAC e fila junto do IP: e o que se digita no PC de destino, e o MAC
        # permite achar este PC de novo quando o IP mudar
        $lblDadosOrigem = New-Object System.Windows.Forms.Label
        $lblDadosOrigem.Location = '15,372'; $lblDadosOrigem.Size = '315,36'
        $lblDadosOrigem.Font = New-Object System.Drawing.Font("Consolas", 8.5); $lblDadosOrigem.ForeColor = 'LightGray'
        [void]$pnlServerCard.Controls.Add($lblDadosOrigem)
        $mostraDadosOrigem = {
            $dadosPc = Get-DadosOrigemLpr
            $filasTxt = "nenhuma compartilhada ainda"
            if ($dadosPc.Filas.Count -gt 0) { $filasTxt = $dadosPc.Filas -join ", " }
            $lblDadosOrigem.Text = "MAC : " + ($dadosPc.Macs -join ", ") + "`nFila: " + $filasTxt
            return $dadosPc
        }

        $btnCopiarOrigem = New-Object System.Windows.Forms.Button
        $btnCopiarOrigem.Text = "COPIAR IP, MAC E FILA"; $btnCopiarOrigem.Location = '15,412'; $btnCopiarOrigem.Size = '315,30'
        $btnCopiarOrigem.BackColor = [System.Drawing.Color]::FromArgb(25, 90, 120); $btnCopiarOrigem.FlatStyle = 'Flat'; $btnCopiarOrigem.FlatAppearance.BorderSize = 0
        $btnCopiarOrigem.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold); $btnCopiarOrigem.ForeColor = 'White'; $btnCopiarOrigem.Cursor = 'Hand'
        $btnCopiarOrigem.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 110, 145)
        $btnCopiarOrigem.Add_Click({
                $dadosPc = & $mostraDadosOrigem
                try { [System.Windows.Forms.Clipboard]::SetText($dadosPc.Texto) } catch {}
                Log-Message "INFO" "LPR: dados deste PC copiados (IP, MAC e fila)"
                [System.Windows.Forms.MessageBox]::Show($Script:PrinterManagerForm, "Copiado para colar no outro PC ou mandar no WhatsApp:`r`n`r`n$($dadosPc.Texto)", "Dados do PC da impressora", "OK", "Information") | Out-Null
            })
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($btnCopiarOrigem, "Copia IP, MAC e nome da fila deste PC, para configurar o PC de destino.") }
        [void]$pnlServerCard.Controls.Add($btnCopiarOrigem)


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
            $abrirNovaLpr = $false
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

                if ($reinicioPendente) {
                    # Sem reiniciar, o Windows ainda nao deixa criar a porta LPR
                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:PrinterManagerForm,
                        "Monitor LPR instalado, mas o Windows pediu REINICIO para ele valer.`n`nReinicie o computador e depois clique em 'PORTAS LPR: CRIAR, TESTAR E TROCAR IP' para criar a porta e a impressora.",
                        "LPR Configurado", "OK", "Warning") | Out-Null
                }
                else {
                    [System.Windows.Forms.MessageBox]::Show(
                        $Script:PrinterManagerForm,
                        "Monitor LPR ativado!`n`nAgora é só criar a porta e a impressora: a tela de nova impressora LPR abre em seguida.",
                        "LPR Configurado", "OK", "Information") | Out-Null
                    # Abre depois do finally, com o botao ja liberado
                    $abrirNovaLpr = $true
                }
            }
            catch {
                Log-Message "ERRO" "Falha ao configurar Cliente LPR: $_"
                [System.Windows.Forms.MessageBox]::Show($Script:PrinterManagerForm, "Erro na configuracao do Cliente LPR: $_", "Erro LPR", "OK", "Error") | Out-Null
            }
            finally {
                $btnActClient.Enabled = $true
                $btnActClient.Text = "ATIVAR MONITOR LPR"
            }
            # Proximo passo natural: criar a porta e a impressora, sem o assistente do Windows
            if ($abrirNovaLpr) { Show-PortasLpr -Dono $Script:PrinterManagerForm -AbrirNova }
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

        # IP do PC da impressora mudou: lista as portas LPR e corrige sem refazer a impressora
        $btnPortasLpr = New-Object System.Windows.Forms.Button
        $btnPortasLpr.Text = "PORTAS LPR: CRIAR, TESTAR E TROCAR IP"; $btnPortasLpr.Location = '15,235'; $btnPortasLpr.Size = '315,45'
        $btnPortasLpr.BackColor = [System.Drawing.Color]::FromArgb(25, 90, 120); $btnPortasLpr.FlatStyle = 'Flat'; $btnPortasLpr.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnPortasLpr.Cursor = 'Hand'; $btnPortasLpr.ForeColor = 'White'; $btnPortasLpr.FlatAppearance.BorderSize = 0
        $btnPortasLpr.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(40, 110, 145)
        $btnPortasLpr.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(15, 70, 95)
        $btnPortasLpr.Add_Click({ Show-PortasLpr -Dono $Script:PrinterManagerForm })
        if ($Script:ToolTip) { $Script:ToolTip.SetToolTip($btnPortasLpr, "Lista as portas LPR deste PC, mostra quais pararam de responder e corrige a porta para o IP novo do PC da impressora (pelo MAC, varrendo a rede ou digitando o IP).") }
        [void]$pnlClientCard.Controls.Add($btnPortasLpr)

        $txtInstLpr = New-Object System.Windows.Forms.RichTextBox
        $txtInstLpr.Location = '15,292'; $txtInstLpr.Size = '315,143'
        $txtInstLpr.ReadOnly = $true; $txtInstLpr.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 30); $txtInstLpr.ForeColor = 'LightYellow'
        $txtInstLpr.BorderStyle = 'None'; $txtInstLpr.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $txtInstLpr.Text = "AJUDA DE INSTALAÇÃO (LPR):`n1. Criar nova porta -> LPR Port`n2. Servidor: [IP do PC com o cabo USB]`n3. Nome da fila: [Nome Compartilhado] (ex: IMPRESSORA)`n4. Escolha o driver correspondente.`n`nMAIS RÁPIDO: PORTAS LPR > NOVA IMPRESSORA LPR`n(cria a porta e a impressora de uma vez).`n`nSE O IP DO PC DA IMPRESSORA MUDAR:`nPORTAS LPR > ATUALIZAR IP PELO MAC."
        [void]$pnlClientCard.Controls.Add($txtInstLpr)

        $Script:PrinterManagerForm.Add_FormClosing({ $Script:PrinterManagerForm = $null })
        $Script:PrinterManagerForm.Add_Shown({ $this.ActiveControl = $null; try { Set-JanelaAdaptavel $this | Out-Null } catch {} })
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

                    # Arquivos que vao junto na pasta extraida (so algumas versoes, como a
                    # Concentrador 1.3.68.0 com o AjustesInstalacao.exe), antes de abrir a pasta
                    if ($null -ne $Script:DownloadExtras) {
                        $Button.Text = "Baixando ajustes..."
                        [System.Windows.Forms.Application]::DoEvents()
                        $falhasExtras = @(Save-DownloadExtras -Pasta $finalPath -Extras $Script:DownloadExtras)
                        if ($falhasExtras.Count -gt 0) {
                            $linksExtras = (@($Script:DownloadExtras) | ForEach-Object { $_.Url }) -join "`n"
                            [System.Windows.Forms.MessageBox]::Show("A pasta foi extraída, mas não deu para baixar o arquivo de ajuste:`n`n$($falhasExtras -join "`n")`n`nBaixe manualmente e coloque na pasta $folderName :`n$linksExtras", "Arquivo de ajuste", "OK", "Warning") | Out-Null
                        }
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

    # Copiar o link do ZIP: as vezes a revenda baixa direto, sem o preparador. So no
    # NetPDV e no Link XMenu, que ficam no site oficial. Concentrador, Tablet e Totem
    # moram no repositorio interno: nao ha link para repassar, entao nem aparece botao.
    $temLink = ($Type -eq "PDV" -or $Type -eq "LinkXMenu")

    $cb = New-Object System.Windows.Forms.ComboBox
    $cb.Location = '20,45'; $cb.Width = $(if ($temLink) { 265 } else { 340 }); $cb.DropDownStyle = 'DropDownList'; $cb.FlatStyle = 'Flat'
    $cb.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60); $cb.ForeColor = 'White'

    $btnLink = $null
    if ($temLink) {
        $btnLink = New-Object System.Windows.Forms.Button
        $btnLink.Text = "copiar link"; $btnLink.Location = '291,44'; $btnLink.Size = '69,24'
        $btnLink.FlatStyle = 'Flat'; $btnLink.FlatAppearance.BorderSize = 1
        $btnLink.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(70, 70, 80)
        $btnLink.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 52); $btnLink.ForeColor = [System.Drawing.Color]::FromArgb(190, 190, 195)
        $btnLink.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)
        $btnLink.Cursor = 'Hand'
        [void]$fSel.Controls.Add($btnLink)
    }

    $versions = @()
    if ($Type -eq "PDV") {
        $versions += @{Name = "NetPDV v1.3.67.0"; Url = "https://netcontroll.com.br/util/instaladores/netpdv/1.3/67/0/NetPDV.zip"; File = "NetPDV_1.3.67.0.zip" }
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
        # A 1.3.68.0 precisa do AjustesInstalacao.exe dentro da pasta extraida
        $versions += @{Name = "Concentrador v1.3.68.0"; Url = "https://netcontroll.com.br/util/instaladores/Concentrador/1.3.68.0/Concentrador.zip"; File = "Concentrador.1.3.68.0.zip"
            Extras = @(@{ Url = "https://netcontroll.com.br/util/instaladores/Concentrador/1.3.68.0/AjustesInstalacao.exe"; File = "AjustesInstalacao.exe" })
        }
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
            $fSel.Tag = @{ Url = $selected.Url; File = $selected.File; Name = $selected.Name; Deploy = $deployFlag; Extras = $selected.Extras }
            $fSel.DialogResult = 'OK'
            $fSel.Close()
        })
    [void]$fSel.Controls.Add($btn)

    if ($null -ne $btnLink) {
        $btnLink.Add_Click({
                $sel = $versions[$cb.SelectedIndex]
                $url = "$($sel.Url)"
                # Trava de seguranca: link do repositorio interno nunca vai para a area
                # de transferencia, mesmo que um dia entre na lista de um tipo com botao
                if ($url -match '(?i)github\.com|githubusercontent\.com') {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Esta versão fica no repositório interno do preparador, e esse link não pode ser repassado.`r`n`r`nBaixe aqui e mande o arquivo.",
                        "Copiar link", "OK", "Information") | Out-Null
                    return
                }
                try { Set-Clipboard -Value $url -ErrorAction Stop }
                catch { [System.Windows.Forms.Clipboard]::SetText($url) }
                Log-Message "INFO" "Link copiado: $($sel.Name)"
                $btnLink.Text = "copiado!"
                $volta = New-Object System.Windows.Forms.Timer
                $volta.Interval = 1500
                $volta.Tag = $btnLink
                $volta.Add_Tick({ $this.Stop(); $this.Tag.Text = "copiar link"; $this.Dispose() })
                $volta.Start()
            })
    }

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

    $fSel.Add_Shown({ try { Set-JanelaAdaptavel $this | Out-Null } catch {} })
    [void]$fSel.ShowDialog()
    if ($fSel.DialogResult -eq 'OK' -and $fSel.Tag) {
        # Ativa modo deploy para nao abrir pasta automaticamente
        $Script:DeployMode = $fSel.Tag.Deploy -and ($Type -eq "PDV" -or $Type -eq "LinkXMenu")
        
        # Extras da versao escolhida (so algumas tem): o Start-Download coloca na pasta extraida
        $Script:DownloadExtras = $fSel.Tag.Extras
        try { Start-Download $fSel.Tag.Url $fSel.Tag.File $Button }
        finally { $Script:DownloadExtras = $null }

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
        if (-not ('XMenuTools.WinAPI' -as [type])) {
            Add-Type -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int SystemParametersInfo (UInt32 uiAction, UInt32 uiParam, string pvParam, UInt32 fWinIni);' -Name "WinAPI" -Namespace "XMenuTools"
        }
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

        $finalForm.Add_Shown({ try { Set-JanelaAdaptavel $this | Out-Null } catch {} })
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
$form.Text = "Preparador XMenu – Suporte Técnico v5.9"
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
Add-CtxLink "Universidade XMenu" "https://netcontroll.gitbook.io/xmenu-universidade"
Add-CtxLink "ADM Master" "https://netcontroll.com.br/adm/"
Add-CtxLink "Portal Xmenu" "https://portal.netcontroll.com.br/#/auth/login"
# ============================================

# HEADER
# Faixa fixa de 58 px para sobrar tela em notebook: titulo com o "Desenvolvido por"
# embaixo, dados do PC em duas linhas ao lado e LINKS UTEIS a direita.
if ($null -eq $Script:ToolTip) {
    $Script:ToolTip = New-Object System.Windows.Forms.ToolTip
    $Script:ToolTip.InitialDelay = 500
    $Script:ToolTip.AutoPopDelay = 10000
}

$head = New-Object System.Windows.Forms.Panel; $head.Dock = 'Top'; $head.Height = 58
$head.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $head.Padding = '20,10,20,10'
[void]$form.Controls.Add($head)

# Ordem importa no Dock: o Fill entra primeiro e as laterais (titulo e botao) depois
$hInfo = New-Object System.Windows.Forms.Panel; $hInfo.Dock = 'Fill'; $hInfo.BackColor = 'Transparent'
[void]$head.Controls.Add($hInfo)
$hTitulo = New-Object System.Windows.Forms.Panel; $hTitulo.Dock = 'Left'; $hTitulo.Width = 250; $hTitulo.BackColor = 'Transparent'
[void]$head.Controls.Add($hTitulo)
$lT = New-Object System.Windows.Forms.Label; $lT.Text = "Preparador XMenu"; $lT.AutoSize = $true
$lT.ForeColor = [System.Drawing.Color]::White
$lT.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Bold); $lT.Location = '0,-3'
[void]$hTitulo.Controls.Add($lT)
$lS = New-Object System.Windows.Forms.Label; $lS.Text = "Desenvolvido por Vinicius Mazaroski"; $lS.AutoSize = $true
$lS.ForeColor = [System.Drawing.Color]::Gold
$lS.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lS.Location = '2,23'
[void]$hTitulo.Controls.Add($lS)

# Os dados de hardware sao lidos logo depois que a janela aparece (no Shown, la no fim):
# a janela abre com "..." e o cabecalho se completa em uns 0,3 s.
# Pede so os campos usados no cabecalho. O Win32_Processor inteiro levava 1 s (ele mede
# a carga de cada nucleo), o Get-PhysicalDisk mais 1 a 2 s (carrega o modulo Storage) e o
# Get-NetIPAddress meio segundo: a janela demorava uns 3 s a mais para aparecer.
$preencheHardware = {
    $os = Get-CimInstance Win32_OperatingSystem -Property Caption
    $cpu = Get-CimInstance Win32_Processor -Property Name | Select-Object -First 1
    $ram = Get-CimInstance Win32_ComputerSystem -Property TotalPhysicalMemory
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -Property Size
    $gpu = Get-CimInstance Win32_VideoController -Property Name | Select-Object -First 1
    $gpuName = if ($gpu) { $gpu.Name } else { "N/A" }

    # IPv4 pela API do .NET, preferindo a placa com gateway (a da rede da loja)
    $localIP = $null
    try {
        $ipsSemGateway = @()
        foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($ni.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up) { continue }
            $props = $ni.GetIPProperties()
            $temGateway = @($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.Address.ToString() -ne '0.0.0.0' }).Count -gt 0
            foreach ($u in $props.UnicastAddresses) {
                if ($u.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) { continue }
                $ip = $u.Address.ToString()
                if ($ip -match '^127\.|^169\.254\.') { continue }
                if ($temGateway) { if (-not $localIP) { $localIP = $ip } }
                else { $ipsSemGateway += $ip }
            }
        }
        if (-not $localIP -and $ipsSemGateway.Count -gt 0) { $localIP = $ipsSemGateway[0] }
    }
    catch {}
    if (-not $localIP) { $localIP = "Offline" }

    # SSD ou HD direto no WMI de armazenamento (MediaType 3 = HD, 4 = SSD): mesmo disco
    # que o Get-PhysicalDisk mostrava, sem carregar o modulo Storage
    $diskType = "Disco"
    try {
        $physDisk = Get-CimInstance -Namespace root\Microsoft\Windows\Storage -ClassName MSFT_PhysicalDisk -Property MediaType -ErrorAction Stop | Select-Object -First 1
        if ("$($physDisk.MediaType)" -eq '4') { $diskType = "SSD" }
        elseif ("$($physDisk.MediaType)" -eq '3') { $diskType = "HD" }
    }
    catch {}

    # Processador sem (R), (TM), "CPU", "@ 2.90GHz" e "Six-Core Processor" para caber na grade;
    # o texto copiado continua com o nome completo
    $cpuCompleto = "$($cpu.Name)".Trim()
    $cpuCurto = ($cpuCompleto -replace '\((R|TM)\)|®|™', '' -replace '\s+CPU\b', '' -replace '\s+@.*$', '' -replace '\s+\S+-Core Processor$', '' -replace '\s+Processor$', '' -replace '\s{2,}', ' ').Trim()
    $gpuCurto = ("$gpuName" -replace '\((R|TM)\)|®|™', '' -replace '\s{2,}', ' ').Trim()
    $sistemaPc = "$($os.Caption -replace 'Microsoft ','')".Trim()
    $ramPc = "$([Math]::Round($ram.TotalPhysicalMemory / 1GB)) GB"
    $discoPc = "$([Math]::Round($disk.Size / 1GB)) GB"
    $Script:InfoPc = @(
        [PSCustomObject]@{ Linha = 0; Col = 0; Nome = 'Host'; Valor = $env:COMPUTERNAME },
        [PSCustomObject]@{ Linha = 0; Col = 1; Nome = 'IP'; Valor = $localIP },
        [PSCustomObject]@{ Linha = 0; Col = 2; Nome = 'Usuário'; Valor = $env:USERNAME },
        [PSCustomObject]@{ Linha = 0; Col = 3; Nome = 'Sistema'; Valor = $sistemaPc },
        [PSCustomObject]@{ Linha = 1; Col = 0; Nome = 'CPU'; Valor = $cpuCurto },
        [PSCustomObject]@{ Linha = 1; Col = 1; Nome = 'RAM'; Valor = $ramPc },
        [PSCustomObject]@{ Linha = 1; Col = 2; Nome = "$diskType (C:)"; Valor = $discoPc },
        [PSCustomObject]@{ Linha = 1; Col = 3; Nome = 'Vídeo'; Valor = $gpuCurto }
    )
    $Script:InfoPcTexto = "Host: $env:COMPUTERNAME | IP Local: $localIP | Usuário: $env:USERNAME | Sistema: $sistemaPc`r`nCPU: $cpuCompleto | RAM: $ramPc | $diskType (C:): $discoPc | Vídeo: $gpuName"
    $Script:ToolTip.SetToolTip($hInfo, "$($Script:InfoPcTexto)`r`n(clique para copiar os dados do PC)")
    $hInfo.Invalidate()
}

# Dados do PC em grade: nome do campo apagado e valor em branco, colunas alinhadas entre
# as duas linhas. Desenhado no Paint para, em janela estreita, so o fim dos valores mais
# longos virar "..." (label com AutoSize cortaria no meio da palavra).
$fonteInfoNome = New-Object System.Drawing.Font("Segoe UI", 8)
$fonteInfoValor = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
$corInfoNome = [System.Drawing.Color]::FromArgb(160, 205, 185)
$altLinhaInfo = [Math]::Max($fonteInfoNome.Height, $fonteInfoValor.Height) + 2
$Script:InfoPc = @(
    [PSCustomObject]@{ Linha = 0; Col = 0; Nome = 'Host'; Valor = $env:COMPUTERNAME },
    [PSCustomObject]@{ Linha = 0; Col = 1; Nome = 'IP'; Valor = '...' },
    [PSCustomObject]@{ Linha = 0; Col = 2; Nome = 'Usuário'; Valor = $env:USERNAME },
    [PSCustomObject]@{ Linha = 0; Col = 3; Nome = 'Sistema'; Valor = '...' },
    [PSCustomObject]@{ Linha = 1; Col = 0; Nome = 'CPU'; Valor = '...' },
    [PSCustomObject]@{ Linha = 1; Col = 1; Nome = 'RAM'; Valor = '...' },
    [PSCustomObject]@{ Linha = 1; Col = 2; Nome = 'Disco (C:)'; Valor = '...' },
    [PSCustomObject]@{ Linha = 1; Col = 3; Nome = 'Vídeo'; Valor = '...' }
)
$Script:InfoPcTexto = ""
$hInfo.Cursor = [System.Windows.Forms.Cursors]::Hand
# Sem piscar ao redimensionar a janela
$hInfo.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic').SetValue($hInfo, $true, $null)
$hInfo.Add_Resize({ $hInfo.Invalidate() })
# Largura de cada coluna da grade (nome e valor) e o total que ela pede. Usada no
# Paint e ao abrir, para alargar a janela quando a grade nao cabe.
$gapNomeInfo = 5; $gapColInfo = 22; $x0Info = 14
$medirInfoPc = {
    param($g)
    # Medir sem EndEllipsis: com ele e sem tamanho limite o MeasureText devolve quase zero
    $flagsMedida = [System.Windows.Forms.TextFormatFlags]'NoPadding, SingleLine'
    $larNome = @(0, 0, 0, 0); $larValor = @(0, 0, 0, 0)
    foreach ($it in $Script:InfoPc) {
        $larNome[$it.Col] = [Math]::Max($larNome[$it.Col], [System.Windows.Forms.TextRenderer]::MeasureText($g, $it.Nome, $fonteInfoNome, [System.Drawing.Size]::Empty, $flagsMedida).Width + 2)
        $larValor[$it.Col] = [Math]::Max($larValor[$it.Col], [System.Windows.Forms.TextRenderer]::MeasureText($g, "$($it.Valor)", $fonteInfoValor, [System.Drawing.Size]::Empty, $flagsMedida).Width + 2)
    }
    $usado = $x0Info + 4 * $gapNomeInfo + 3 * $gapColInfo
    for ($c = 0; $c -lt 4; $c++) { $usado += $larNome[$c] + $larValor[$c] }
    return @{ Nome = $larNome; Valor = $larValor; Usado = $usado }
}
# Ao abrir: se a grade nao coube (escala do Windows em 125%, nome de processador
# comprido), alarga a janela o que faltar, centralizada e sem passar da tela
$ajustarJanelaAoCabecalho = {
    $gMed = $hInfo.CreateGraphics()
    try { $med = & $medirInfoPc $gMed } finally { $gMed.Dispose() }
    $falta = $med.Usado - $hInfo.ClientSize.Width
    if ($falta -le 0) { return }
    $areaTela = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $novaLargura = [Math]::Min($form.Width + $falta + 12, $areaTela.Width - 20)
    if ($novaLargura -le $form.Width) { return }
    $form.Left = $areaTela.Left + [int](($areaTela.Width - $novaLargura) / 2)
    $form.Width = $novaLargura
}
$hInfo.Add_Paint({
        param($s, $e)
        $g = $e.Graphics
        $flags = [System.Windows.Forms.TextFormatFlags]'Left, VerticalCenter, EndEllipsis, NoPadding, SingleLine'
        $gapNome = $gapNomeInfo; $gapCol = $gapColInfo; $x0 = $x0Info
        $med = & $medirInfoPc $g
        $larNome = $med.Nome; $larValor = $med.Valor
        # Janela estreita: tira o que falta da coluna de valor mais larga (ate 60 px), depois da seguinte
        $sobra = $s.ClientSize.Width - $med.Usado
        for ($volta = 0; $volta -lt 4 -and $sobra -lt 0; $volta++) {
            $maior = 0
            for ($c = 1; $c -lt 4; $c++) { if ($larValor[$c] -gt $larValor[$maior]) { $maior = $c } }
            $corte = [Math]::Min(-$sobra, $larValor[$maior] - 60)
            if ($corte -le 0) { break }
            $larValor[$maior] -= $corte
            $sobra += $corte
        }
        $y0 = [int](($s.ClientSize.Height - 2 * $altLinhaInfo) / 2)
        # Filete separando do titulo
        $caneta = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(70, 255, 255, 255), 1)
        $g.DrawLine($caneta, 0, $y0 + 2, 0, $y0 + 2 * $altLinhaInfo - 2)
        $caneta.Dispose()
        foreach ($it in $Script:InfoPc) {
            $x = $x0
            for ($c = 0; $c -lt $it.Col; $c++) { $x += $larNome[$c] + $gapNome + $larValor[$c] + $gapCol }
            $y = $y0 + $it.Linha * $altLinhaInfo
            [System.Windows.Forms.TextRenderer]::DrawText($g, $it.Nome, $fonteInfoNome, (New-Object System.Drawing.Rectangle($x, $y, $larNome[$it.Col], $altLinhaInfo)), $corInfoNome, $flags)
            [System.Windows.Forms.TextRenderer]::DrawText($g, "$($it.Valor)", $fonteInfoValor, (New-Object System.Drawing.Rectangle(($x + $larNome[$it.Col] + $gapNome), $y, $larValor[$it.Col], $altLinhaInfo)), [System.Drawing.Color]::White, $flags)
        }
    })
$hInfo.Add_Click({
        if ("$($Script:InfoPcTexto)" -eq "") { return }
        [System.Windows.Forms.Clipboard]::SetText($Script:InfoPcTexto)
        Log-Message "SUCESSO" "Informações de hardware copiadas para a área de transferência."
    })

$hRight = New-Object System.Windows.Forms.FlowLayoutPanel; $hRight.Dock = 'Right'; $hRight.Width = 116
$hRight.FlowDirection = 'LeftToRight'; $hRight.BackColor = 'Transparent'; $hRight.WrapContents = $false
$hRight.Padding = '0,2,0,0'
[void]$head.Controls.Add($hRight)

# O diagnostico de rede agora fica na grade de SUPORTE E DIAGNOSTICO,
# junto com as outras ferramentas (nao precisa mais de botao no cabecalho).

# --- NOVO BOTAO LINKS NO HEADER ---
$btnLinks = New-Object System.Windows.Forms.Button; $btnLinks.Text = "LINKS ÚTEIS ▼"; $btnLinks.Size = '116,28'
$btnLinks.BackColor = 'White'; $btnLinks.ForeColor = [System.Drawing.Color]::FromArgb(12, 78, 55)
$btnLinks.FlatStyle = 'Flat'; $btnLinks.FlatAppearance.BorderSize = 0; $btnLinks.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnLinks.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnLinks.Margin = '0,0,0,0'
$btnLinks.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$btnLinks.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnLinks.Add_Click({ 
        $linkMenu.Show($btnLinks, 0, $btnLinks.Height) 
    })
[void]$hRight.Controls.Add($btnLinks)
# ----------------------------------

# Posicoes pelo tamanho real das letras: com a escala do Windows em 125% ou 150% a
# fonte cresce e posicao fixa em pixel cortava o "Desenvolvido por". A faixa acompanha.
$altTituloBloco = $lT.PreferredHeight - 3 + $lS.PreferredHeight
$altUtilCab = [Math]::Max([Math]::Max($altTituloBloco, 2 * $altLinhaInfo), $btnLinks.Height)
$head.Padding = New-Object System.Windows.Forms.Padding(20, 8, 20, 8)
$head.Height = $altUtilCab + 16
$topoTitulo = [int](($altUtilCab - $altTituloBloco) / 2)
$lT.Location = New-Object System.Drawing.Point(0, $topoTitulo)
$lS.Location = New-Object System.Drawing.Point(2, ($topoTitulo + $lT.PreferredHeight - 3))
$hTitulo.Width = [Math]::Max($lT.PreferredWidth, $lS.PreferredWidth + 2) + 24
$hRight.Padding = New-Object System.Windows.Forms.Padding(0, [int](($altUtilCab - $btnLinks.Height) / 2), 0, 0)

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
# Log com 3 linhas e o resto da altura para os botoes, que e o que o tecnico usa.
# Altura pela fonte real para acompanhar a escala do Windows (125%, 150%).
$fonteLog = New-Object System.Drawing.Font("Consolas", 9)
$altLog = $fonteLog.Height * 3 + $form.Font.Height + 24
$layout.Padding = '10'; $layout.RowCount = 3
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, $altLog)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 60)))
[void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$form.Controls.Add($layout); $layout.BringToFront()

$gLog = New-Object System.Windows.Forms.GroupBox; $gLog.Text = "Log"; $gLog.ForeColor = 'Gray'; $gLog.Dock = 'Fill'
[void]$layout.Controls.Add($gLog, 0, 0)
$tLog = New-Object System.Windows.Forms.RichTextBox; $tLog.Dock = 'Fill'; $tLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$tLog.ForeColor = 'White'; $tLog.BorderStyle = 'None'; $tLog.ReadOnly = $true; $tLog.Font = $fonteLog
[void]$gLog.Controls.Add($tLog); $Script:LogBox = $tLog

$bCfg = New-Object System.Windows.Forms.Button; $bCfg.Text = "PREPARAR AMBIENTE WINDOWS"
$bCfg.Dock = 'Fill'; $bCfg.BackColor = [System.Drawing.Color]::FromArgb(14, 88, 62); $bCfg.ForeColor = 'White'
$bCfg.FlatStyle = 'Flat'; $bCfg.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$bCfg.Margin = '0,6,0,6'; $bCfg.Cursor = 'Hand'
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
$bPrintMgr.Text = "Impressoras: Compartilhamento, LPR e Drivers"; $bPrintMgr.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$bPrintMgr.Cursor = 'Hand'
Format-SupportBtn $bPrintMgr $colorCyan
$Script:ToolTip.SetToolTip($bPrintMgr, "Gerencia impressoras locais, compartilhamentos e configura rede via protocolo LPR/LPD para corrigir erros no Windows 11.")
$bPrintMgr.Add_Click({ Show-PrinterManager })
[void]$tbl.Controls.Add($bPrintMgr)
Add-SupportSpacer   # fecha a linha do grupo azul

# --- BANCO DE DADOS (AMARELO) ---
# Mostarda no mesmo tom fechado do verde e do vermelho, para o texto branco seguir legivel
$colorSql = [System.Drawing.Color]::FromArgb(125, 95, 15)

$bXml = New-Object System.Windows.Forms.Button; $bXml.Height = 50; $bXml.Dock = 'Top'
$bXml.Text = "Baixar XMLs NFC-e"
$bXml.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bXml.Cursor = 'Hand'
Format-SupportBtn $bXml $colorSql
$Script:ToolTip.SetToolTip($bXml, "Conecta no banco netwebpdv e baixa em lote os XMLs das NFC-e por série e sequência, por período, por chave de acesso ou pelo número do pedido. Já monta a pasta organizada e o .zip pronto para enviar ao cliente, avisa quais notas não estão no banco e gera o espelho fiscal da nota em PDF, igual ao cupom.")
$bXml.Add_Click({ Show-XmlDownloader })
[void]$tbl.Controls.Add($bXml)

$bBkp = New-Object System.Windows.Forms.Button; $bBkp.Height = 50; $bBkp.Dock = 'Top'
$bBkp.Text = "Backup do Banco NetWebPDV"
$bBkp.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bBkp.Cursor = 'Hand'
Format-SupportBtn $bBkp $colorSql
$Script:ToolTip.SetToolTip($bBkp, "Faz o backup completo do banco pelo próprio SQL Server, com o banco online: sem parar o serviço e sem desanexar. Confere o arquivo, pode compactar em .zip e salva em Arquivos Xmenu\Backup NetWebPDV. Rode no servidor.")
$bBkp.Add_Click({ Show-BackupBanco })
[void]$tbl.Controls.Add($bBkp)

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
$bUsb.Text = "Corrigir Impressora USB (MP-4200 e outras)"; $bUsb.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bUsb.Cursor = 'Hand'
Format-SupportBtn $bUsb $colorGray
$Script:ToolTip.SetToolTip($bUsb, "Para impressora térmica USB que fica offline depois de mexer no cabo, para depois de um tempo parada ou não imprime ao ligar o PC. Acha a porta USB conectada e aponta a impressora para ela, desliga a economia de energia (USB, impressora e PC), desliga a inicialização rápida e mostra o que foi feito.")
$bUsb.Add_Click({ Invoke-CorrigirImpressoraUsb })
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

# Mensagem de abertura: explica o programa para quem abre pela primeira vez
Log-Message "INFO" "Preparador XMenu v5.9 - preparo e suporte de computadores com XMenu e NetPDV"
Log-Message "LOG" "==============================================================="
Log-Message "LOG" "COMO USAR"
Log-Message "LOG" "  PREPARAR AMBIENTE WINDOWS .. ajusta energia, UAC e desempenho do PC num clique"
Log-Message "LOG" "  BANCO DE DADOS ............. instaladores do SQL Server"
Log-Message "LOG" "  PROGRAMAS NETCONTROLL ...... NetPDV, Concentrador, Link XMenu, XBot, XTag, Tablet e Totem"
Log-Message "LOG" "  EXTERNOS ................... acesso remoto, Chrome, TEF HUB, balança e ferramentas de rede"
Log-Message "LOG" "  SUPORTE E DIAGNÓSTICO ...... impressoras, rede, SQL, backup, XMLs e reparos do Windows"
Log-Message "LOG" "  Passe o mouse sobre um botão para ver o que ele faz antes de clicar."
Log-Message "LOG" "---------------------------------------------------------------"
Log-Message "LOG" "NOVO NA v5.9"
Log-Message "SUCESSO" "  XMLs NFC-e: busca sem resultado registra no log o que a conexão está vendo no banco"
Log-Message "SUCESSO" "  XMLs NFC-e: em PC antigo, a busca refaz a consulta sem parâmetros quando não vem nada"
Log-Message "SUCESSO" "  Corrigido: arquivo do último servidor ilegível deixava o campo Servidor com lixo"
Log-Message "SUCESSO" "  Zoom só em monitor pequeno de verdade (até 1024x640); nos demais nada muda"
Log-Message "SUCESSO" "  XMLs NFC-e: busca com segunda tentativa, para SQL antigo (2008 R2) que não trazia as notas"
Log-Message "SUCESSO" "  XMLs NFC-e: busca vazia agora diz onde as notas estão (parceiro e série certos)"
Log-Message "SUCESSO" "  Scanner de rede: mostra a marca e, quando o aparelho responde, o modelo da impressora"
Log-Message "SUCESSO" "  Lista de notas aceita colar separado por espaço, TAB ou uma por linha (planilha)"
Log-Message "SUCESSO" "  Em tela pequena o programa inteiro encolhe junto e cabe mais botão sem rolar"
Log-Message "LOG" "---------------------------------------------------------------"
Log-Message "LOG" "Downloads, XMLs, espelhos em PDF e backups ficam em: Área de Trabalho > Arquivos Xmenu"
Log-Message "LOG" "O registro de cada sessão fica em: C:\Arquivos Xmenu\Logs"
$ehAdmin = $false
try { $ehAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch {}
if ($ehAdmin) { Log-Message "SUCESSO" "Pronto para usar (aberto como administrador)." }
else {
    Log-Message "ERRO" "Aberto SEM permissão de administrador: o preparo, os reparos e as impressoras podem falhar."
    Log-Message "ERRO" "Feche e abra de novo com o botão direito > Executar como administrador."
}

# Monitor pequeno: o miolo do programa (Log, botao grande e a lista de botoes)
# encolhe junto, para caber mais botao sem precisar rolar. O cabecalho fica de fora:
# ele ja tem o proprio ajuste e o texto dele e desenhado na mao, com fonte propria.
$ajustarEscalaPrincipal = {
    # Roda antes de a janela aparecer, para ela ja abrir pronta: $screen e a area util
    # da tela, medida no inicio do programa
    $areaTela = $screen
    # So em monitor pequeno de verdade. Antes a conta usava 1200x900 como referencia, e
    # entao qualquer tela com menos de 900 px de altura util (1366x768, 1600x900, que
    # sao a maioria dos PDVs) encolhia o programa sem precisar.
    if ($areaTela.Width -ge 1024 -and $areaTela.Height -ge 640) { return }
    # 1200x900 e o tamanho em que a tela foi desenhada
    $fator = [Math]::Min(([double]$areaTela.Width / 1200), ([double]$areaTela.Height / 900))
    $fator = [Math]::Max(0.72, [Math]::Min(1.0, $fator))
    if ($fator -ge 0.995) { return }
    $form.SuspendLayout()
    try {
        Set-EscalaControles $layout ([single]$fator) 7.0
        foreach ($rs in $layout.RowStyles) {
            if ($rs.SizeType -eq [System.Windows.Forms.SizeType]::Absolute) { $rs.Height = [single][Math]::Round($rs.Height * $fator) }
        }
        $foot.Height = [int][Math]::Round($foot.Height * $fator)
        Set-EscalaControles $foot ([single]$fator) 7.0
    }
    finally { $form.ResumeLayout() }
    Log-Message "INFO" "Tela de $($areaTela.Width)x$($areaTela.Height): programa ajustado para $([int][Math]::Round($fator * 100))%, com botões menores"
}

$form.Add_Shown({
        $this.ActiveControl = $null
        # Desenha a janela primeiro e so depois le o hardware do cabecalho
        $this.Refresh()
        # A roda do mouse compila uma classe pequena e, em PC fraco, isso custa quase um
        # segundo: entra logo depois que a janela ja esta na tela, e nao antes dela
        $tRoda = New-Object System.Windows.Forms.Timer
        $tRoda.Interval = 900
        $tRoda.Add_Tick({ $this.Stop(); $this.Dispose(); try { Enable-RodaDoMouse | Out-Null } catch {} })
        $tRoda.Start()
        try { Set-JanelaAdaptavel $this | Out-Null } catch {}
        try { Enable-SelecionarTudo $this } catch {}
        try { & $preencheHardware } catch {}
        try { & $ajustarJanelaAoCabecalho } catch {}
    })

# Tela pequena: encolhe o miolo antes de mostrar a janela
try { & $ajustarEscalaPrincipal } catch {}
[void]$form.ShowDialog()
