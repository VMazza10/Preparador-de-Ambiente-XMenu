# =============================================================================
# XMENU SYSTEM MANAGER - VERSAO REVENDA
# Baseado na v17.59
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
            $logFile = Join-Path $logPath "log_preparar_ambiente_revenda_$((Get-Date).ToString('yyyy-MM-dd')).txt"
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

function Show-IPs {
    try {
        $activeAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }
        if ($activeAdapters) {
            $ips = $activeAdapters | Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
            
            $netConfig = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } | Select-Object -First 1
            $gateway = if ($netConfig) { $netConfig.IPv4DefaultGateway.NextHop } else { "Nao detectado" }
            $dnsServers = if ($netConfig) { $netConfig.DNSServer.ServerAddresses -join ", " } else { "Nao detectado" }
            
            $pingObj = New-Object System.Net.NetworkInformation.Ping
            $internetStatus = try { if (($pingObj.Send("8.8.8.8", 1500)).Status -eq "Success") { "Conectado (Online)" } else { "Sem Acesso (Offline)" } } catch { "Sem Acesso (Offline)" }
            $pingAdm2 = try { if (($pingObj.Send("adm2.netcontroll.com.br", 1500)).Status -eq "Success") { "OK (Acessivel)" } else { "FALHA (Inacessivel)" } } catch { "FALHA (Inacessivel)" }
            
            if ($ips) {
                if ($ips -is [string]) { $ips = @($ips) }
                $txtIPs = $ips -join ", "
                $txtClipboard = $ips -join "`r`n"
                
                Clear-DnsClientCache
                
                Log-Message "INFO" "XMenu Manager v17.59 Carregado!"
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
            }
            else {
                [System.Windows.Forms.MessageBox]::Show("Nenhum IP valido encontrado.", "Rede", "OK", "Warning") | Out-Null
            }
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Sem adaptadores de rede conectados.", "Rede", "OK", "Warning") | Out-Null
        }
    }
    catch { Log-Message "ERRO" "Falha ao ler IPs: $_" }
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

function Show-ResourceMonitor {
    try {
        $fMon = New-Object System.Windows.Forms.Form
        $fMon.Text = "Monitor de Recursos (Top 5)"; $fMon.Size = "450,480"; $fMon.StartPosition = 'CenterParent'
        $fMon.BackColor = [System.Drawing.Color]::FromArgb(35, 35, 40); $fMon.ForeColor = 'White'
        $fMon.FormBorderStyle = 'FixedDialog'; $fMon.MaximizeBox = $false

        $lblHeader = New-Object System.Windows.Forms.Label; $lblHeader.Text = "PROCESSOS MAIS PESADOS AGORA"; $lblHeader.Location = '20,20'; $lblHeader.AutoSize = $true
        $lblHeader.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        [void]$fMon.Controls.Add($lblHeader)

        $txtBox = New-Object System.Windows.Forms.RichTextBox; $txtBox.Location = '20,60'; $txtBox.Size = '395,300'
        $txtBox.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 50); $txtBox.ForeColor = 'PaleGreen'; $txtBox.ReadOnly = $true
        $txtBox.Font = New-Object System.Drawing.Font("Consolas", 10); $txtBox.BorderStyle = 'None'
        [void]$fMon.Controls.Add($txtBox)

        $update = {
            $cpu = Get-Process | Where-Object { $_.CPU -ne $null } | Sort-Object CPU -Descending | Select-Object -First 5
            $ram = Get-Process | Sort-Object WorkingSet64 -Descending | Select-Object -First 5
            $text = "--- TOP CPU ---`n"
            foreach ($p in $cpu) { $text += "$($p.ProcessName.PadRight(15)) : $([Math]::Round($p.CPU,1)) %`n" }
            $text += "`n--- TOP RAM (Memória) ---`n"
            foreach ($p in $ram) { $text += "$($p.ProcessName.PadRight(15)) : $([Math]::Round($p.WorkingSet64 / 1MB,1)) MB`n" }
            $txtBox.Text = $text
        }
        &$update

        $btnRefresh = New-Object System.Windows.Forms.Button; $btnRefresh.Text = "ATUALIZAR AGORA"; $btnRefresh.Location = '20,380'; $btnRefresh.Size = '395,40'
        $btnRefresh.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnRefresh.FlatStyle = 'Flat'; $btnRefresh.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnRefresh.Add_Click({ &$update })
        [void]$fMon.Controls.Add($btnRefresh)
        [void]$fMon.ShowDialog()
    }
    catch { Log-Message "ERRO" "Monitor falhou: $_" }
}

function Show-SystemInfo {
    Log-Message "INFO" "Iniciando Avaliação de Hardware..."
    try {
        $os = Get-WmiObject Win32_OperatingSystem
        $cpu = Get-WmiObject Win32_Processor
        $ram = Get-WmiObject Win32_ComputerSystem
        $drive = Get-WmiObject Win32_LogicalDisk -Filter "DeviceID='C:'"
        
        $ramGB = [Math]::Round($ram.TotalPhysicalMemory / 1GB, 1)
        $diskGB = [Math]::Round($drive.Size / 1GB, 1)
        $freeGB = [Math]::Round($drive.FreeSpace / 1GB, 1)
        $cpuName = $cpu.Name.Trim()

        $benchTable = @{
            "AMD Ryzen 3 3200GE"  = 7309
            "AMD Ryzen 3 3200G"   = 7131
            "Intel Core i5-8500"  = 9548
            "Intel Core i5-8400"  = 9205
            "Intel Core i3-10100" = 8645
        }
        
        $score = "N/A"
        foreach ($key in $benchTable.Keys) {
            if ($cpuName -match [regex]::Escape($key)) { $score = $benchTable[$key]; break }
        }

        $passRAM = $ramGB -ge 15.5
        $passDisk = $diskGB -ge 210
        $passOS = $os.Caption -match "Windows 10|Windows 11"

        $fEval = New-Object System.Windows.Forms.Form
        $fEval.Text = "Avaliacao de Hardware XMenu"; $fEval.Size = "550,500"; $fEval.StartPosition = 'CenterParent'
        $fEval.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 35); $fEval.ForeColor = 'White'
        $fEval.FormBorderStyle = 'FixedDialog'; $fEval.MaximizeBox = $false

        $title = New-Object System.Windows.Forms.Label; $title.Text = "RELATORIO DE COMPATIBILIDADE"; $title.Location = '20,20'; $title.AutoSize = $true
        $title.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
        [void]$fEval.Controls.Add($title)

        $AddLabel = {
            param($txt, $val, $pass, $y)
            $lblT = New-Object System.Windows.Forms.Label; $lblT.Text = $txt; $lblT.Location = "25,$y"; $lblT.AutoSize = $true
            $lblV = New-Object System.Windows.Forms.Label; $lblV.Text = $val; $lblV.Location = "180,$y"; $lblV.AutoSize = $true
            $lblV.Width = 330
            $lblV.ForeColor = if ($pass) { [System.Drawing.Color]::PaleGreen } else { [System.Drawing.Color]::Salmon }
            $lblV.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            [void]$fEval.Controls.Add($lblT); [void]$fEval.Controls.Add($lblV)
        }

        &$AddLabel "Sistema Op.:" "$($os.Caption)" $passOS 70
        &$AddLabel "Memoria RAM:" "$ramGB GB" $passRAM 110
        &$AddLabel "Disco C: (SSD):" "$diskGB GB" $passDisk 150
        &$AddLabel "Processador:" "$cpuName" $true 190
        &$AddLabel "Benchmark Est.:" "$score" ($score -ge 3500) 235

        $cleanCpu = $cpuName -replace '\s+', '+'
        $benchUrl = "https://www.cpubenchmark.net/cpu.php?cpu=$cleanCpu"

        $note = New-Object System.Windows.Forms.Label; $note.Text = "* Benchmark minimo recomendado: 3500"; $note.Location = '20,280'; $note.ForeColor = 'Gray'; $note.AutoSize = $true
        [void]$fEval.Controls.Add($note)

        $btnVisit = New-Object System.Windows.Forms.Button; $btnVisit.Text = "VER BENCHMARK ONLINE"; $btnVisit.Location = '20,310'; $btnVisit.Size = '495,40'
        $btnVisit.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 55); $btnVisit.FlatStyle = 'Flat'; $btnVisit.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnVisit.Add_Click({ Start-Process $benchUrl })
        [void]$fEval.Controls.Add($btnVisit)

        $btnCopy = New-Object System.Windows.Forms.Button; $btnCopy.Text = "COPIAR RELATORIO E FECHAR"; $btnCopy.Location = '20,370'; $btnCopy.Size = '495,50'
        $btnCopy.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnCopy.FlatStyle = 'Flat'; $btnCopy.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
        $btnCopy.Cursor = 'Hand'
        
        $passBench = if ($score -is [int]) { $score -ge 3500 } else { $true }

        $infoText = @"
Processador:
$cpuName $(if($passBench){"✔️"}else{"❌"})

Memória
Ram: $($ramGB)GB $(if($passRAM){"✔️"}else{"❌"})

Disco
Sólido: $($diskGB)GB $(if($passDisk){"✔️"}else{"❌"})

Pontuação:
 $score $(if($passBench){"✔️"}else{"❌"})

Benchmark: $benchUrl
"@
        Set-Clipboard -Value $infoText

        $btnCopy.Add_Click({ $fEval.Close() })
        [void]$fEval.Controls.Add($btnCopy)

        [void]$fEval.ShowDialog()
        Log-Message "SUCESSO" "Avaliacao concluida e copiada."
    }
    catch {
        Log-Message "ERRO" "Falha na avaliacao: $_"
    }
}

function Get-VendorName {
    param($IP, $ArpTable)
    try {
        $mac = ""
        $targetTable = if ($null -ne $ArpTable) { $ArpTable } else { arp -a }
        foreach ($line in $targetTable) {
            if ($line -match "^\s+$IP\s+([0-9a-fA-F-]+)") {
                $mac = $matches[1].Replace('-', ':').ToUpper()
                break
            }
        }
        if ($mac -match '([0-9a-fA-F:]{17})') {
            $oui = $mac.Substring(0, 8)
            $vendors = @{
                "00:26:AB" = "EPSON"; "00:00:48" = "EPSON"; "FC:BA:B1" = "EPSON"
                "00:0B:AB" = "ELGIN"; "00:00:5E" = "ELGIN"; "00:0B:E0" = "DIEXA"
                "00:13:21" = "BEMATECH"; "00:21:40" = "BEMATECH"
                "00:1C:18" = "DARUMA"; "00:1E:E3" = "TANCA"
                "00:50:C2" = "CONTROL ID"; "FC:1A:11" = "CONTROL ID"
                "00:07:4D" = "ZEBRA"; "00:05:9A" = "ZEBRA"; "8C:11:CB" = "ZEBRA"
                "00:11:0A" = "HP"; "00:1E:0B" = "HP"; "30:8D:99" = "HP"; "00:15:99" = "SAMSUNG"
                "00:21:29" = "TP-LINK"; "B0:4E:26" = "TP-LINK"; "00:1D:AA" = "D-LINK"
                "00:22:3F" = "NETGEAR"; "C8:3A:35" = "Tenda"; "E0:43:DB" = "VIVO"
            }
            if ($vendors.ContainsKey($oui)) { return $vendors[$oui] }
        }
        return "Desconhecido"
    }
    catch { return "Erro API" }
}

function Show-PrinterScanner {
    try {
        if ($null -ne $Script:ScannerForm -and $Script:ScannerForm.Visible) {
            $Script:ScannerForm.Activate(); return
        }

        $Script:ScannerForm = New-Object System.Windows.Forms.Form
        $Script:ScannerForm.Text = "Scanner de Rede XMenu"; $Script:ScannerForm.Size = "700,550"; $Script:ScannerForm.StartPosition = 'CenterParent'
        $Script:ScannerForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $Script:ScannerForm.ForeColor = 'White'
        $Script:ScannerForm.FormBorderStyle = 'FixedDialog'; $Script:ScannerForm.MaximizeBox = $false

        $Script:ScannerBtnScan = New-Object System.Windows.Forms.Button; $Script:ScannerBtnScan.Text = "INICIAR SCAN"; $Script:ScannerBtnScan.Location = '20,20'; $Script:ScannerBtnScan.Width = 140
        $Script:ScannerBtnScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $Script:ScannerBtnScan.FlatStyle = 'Flat'; $Script:ScannerBtnScan.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerBtnScan)

        $Script:ScannerBtnPing = New-Object System.Windows.Forms.Button; $Script:ScannerBtnPing.Text = "TESTAR PING"; $Script:ScannerBtnPing.Location = '170,20'; $Script:ScannerBtnPing.Width = 110
        $Script:ScannerBtnPing.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 65); $Script:ScannerBtnPing.FlatStyle = 'Flat'; $Script:ScannerBtnPing.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerBtnPing)

        $Script:ScannerLblStat = New-Object System.Windows.Forms.Label; $Script:ScannerLblStat.Text = "Pronto."; $Script:ScannerLblStat.Location = '300,25'; $Script:ScannerLblStat.AutoSize = $true
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerLblStat)

        $Script:ScannerProgress = New-Object System.Windows.Forms.ProgressBar; $Script:ScannerProgress.Location = '20,50'; $Script:ScannerProgress.Size = '600,10'; $Script:ScannerProgress.Style = 'Continuous'
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerProgress)

        $Script:ScannerLblPct = New-Object System.Windows.Forms.Label; $Script:ScannerLblPct.Text = "0%"; $Script:ScannerLblPct.Location = '625,48'; $Script:ScannerLblPct.AutoSize = $true; $Script:ScannerLblPct.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerLblPct)

        $Script:ScannerLV = New-Object System.Windows.Forms.ListView; $Script:ScannerLV.Location = '20,70'; $Script:ScannerLV.Size = '640,420'
        $Script:ScannerLV.View = 'Details'; $Script:ScannerLV.FullRowSelect = $true; $Script:ScannerLV.GridLines = $false; $Script:ScannerLV.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 28); $Script:ScannerLV.ForeColor = 'WhiteSmoke'
        $Script:ScannerLV.BorderStyle = 'None'; $Script:ScannerLV.Font = New-Object System.Drawing.Font("Segoe UI", 10)
        
        $Script:ScannerLV.Columns.Add("IP", 100) | Out-Null
        $Script:ScannerLV.Columns.Add("Fabricante", 120) | Out-Null
        $Script:ScannerLV.Columns.Add("Nome/Host", 150) | Out-Null
        $Script:ScannerLV.Columns.Add("Tipo", 100) | Out-Null
        $Script:ScannerLV.Columns.Add("Portas", 120) | Out-Null
        [void]$Script:ScannerForm.Controls.Add($Script:ScannerLV)

        $DoPing = {
            if ($Script:ScannerLV.SelectedItems.Count -gt 0) {
                Show-PingTester -InitialIP $Script:ScannerLV.SelectedItems[0].Text
            }
        }
        $Script:ScannerBtnPing.Add_Click($DoPing)
        $Script:ScannerLV.Add_DoubleClick($DoPing)

        $Script:ScannerBtnScan.Add_Click({
                $Script:ScannerBtnScan.Enabled = $false; $Script:ScannerBtnScan.Text = "Escaneando..."
                $Script:ScannerLV.Items.Clear(); $Script:ScannerLblStat.Text = "Buscando IPs (ARP)..."
                $Script:ScannerProgress.Value = 0; $Script:ScannerProgress.Maximum = 255
                [System.Windows.Forms.Application]::DoEvents()

                try {
                    $myIps = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
                    $localIP = $myIps[0]
                    
                    # Detecta IP do Gateway (Roteador principal)
                    $gwIP = $null
                    try {
                        $netConfig = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null } | Select-Object -First 1
                        if ($netConfig) { $gwIP = $netConfig.IPv4DefaultGateway.NextHop }
                    } catch {}

                    if ($localIP -match '^(\d{1,3}\.\d{1,3}\.\d{1,3})\.') {
                        $subnet = $matches[1]
                        $Script:ScannerLblStat.Text = "Descoberta Ativa ($subnet.0/24)..."
                        $ping = New-Object System.Net.NetworkInformation.Ping
                        foreach ($i in 1..255) {
                            try { $ping.SendAsync("$subnet.$i", 85, $null) | Out-Null } catch {}
                            $Script:ScannerProgress.Value = $i
                            $Script:ScannerLblPct.Text = "$([Math]::Round(($i / 255) * 100))%"
                            if ($i % 25 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
                        }
                        Start-Sleep -Seconds 2.5
                    }

                    $arpOutput = arp -a
                    $ips = @()
                    foreach ($line in $arpOutput) {
                        if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})') {
                            $fIP = $matches[1]
                            if ($fIP -notlike "224.*" -and $fIP -ne "255.255.255.255" -and $fIP -ne "0.0.0.0") {
                                $ips += $fIP
                            }
                        }
                    }
                    $ips = $ips | Select-Object -Unique

                    if ($ips.Count -eq 0) {
                        $Script:ScannerLblStat.Text = "Nada encontrado. Tente novamente."
                        $Script:ScannerProgress.Value = 0
                    }
                    else {
                        $count = 0; $processed = 0
                        $Script:ScannerProgress.Maximum = $ips.Count
                        $Script:ScannerProgress.Value = 0
                        
                        foreach ($ip in $ips) {
                            $processed++
                            try {
                                $Script:ScannerLblStat.Text = "Identificando $ip... ($count encontradas)"
                                $Script:ScannerProgress.Value = $processed
                                $Script:ScannerLblPct.Text = "$([Math]::Round(($processed / $ips.Count) * 100))%"
                                [System.Windows.Forms.Application]::DoEvents()
                                
                                $hn = "Desconhecido"
                                try { $hn = [System.Net.Dns]::GetHostEntry($ip).HostName } catch {}
                                
                                $ports = @()
                                $ipAddr = [System.Net.IPAddress]::Parse($ip)
                                
                                foreach ($p in @(9100, 515, 631, 80, 443, 445, 135, 3389)) {
                                    $socket = New-Object System.Net.Sockets.TcpClient
                                    try {
                                        $res = $socket.BeginConnect($ipAddr, $p, $null, $null)
                                        if ($res.AsyncWaitHandle.WaitOne(120, $false)) {
                                            $socket.EndConnect($res)
                                            $ports += $p
                                        }
                                    }
                                    catch {}
                                    $socket.Close()
                                }

                                $vendor = Get-VendorName $ip $arpOutput
                                
                                # Classificação Inteligente de Dispositivo
                                $isLocal = ($ip -in $myIps)
                                $isGateway = ($null -ne $gwIP -and $ip -eq $gwIP)
                                $isPrinter = ($ports -contains 9100 -or $ports -contains 515 -or $ports -contains 631 -or $vendor -in @("EPSON", "ELGIN", "BEMATECH", "DARUMA", "TANCA", "ZEBRA"))
                                $isPC = ($ports -contains 445 -or $ports -contains 135 -or $ports -contains 3389 -or $hn -match "pc|note|desktop|laptop|workstation|server")
                                $isWeb = ($ports -contains 80 -or $ports -contains 443)
                                
                                $type = "Dispositivo"
                                if ($isLocal) {
                                    $type = "MAQUINA ATUAL"
                                } elseif ($isGateway) {
                                    $type = "ROTEADOR (GATEWAY)"
                                } elseif ($isPrinter) {
                                    $type = "IMPRESSORA"
                                } elseif ($isPC) {
                                    $type = "COMPUTADOR"
                                } elseif ($isWeb) {
                                    $type = "ROTEADOR/DISP. WEB"
                                }
                                
                                $row = New-Object System.Windows.Forms.ListViewItem($ip)
                                $row.SubItems.Add($vendor) | Out-Null
                                $row.SubItems.Add($hn) | Out-Null
                                $row.SubItems.Add($type) | Out-Null
                                $row.SubItems.Add(($ports -join ", ")) | Out-Null
                                
                                if ($isLocal) { 
                                    $row.ForeColor = [System.Drawing.Color]::Yellow
                                    $row.Font = New-Object System.Drawing.Font($Script:ScannerLV.Font, [System.Drawing.FontStyle]::Bold) 
                                }
                                elseif ($type -eq "IMPRESSORA") { 
                                    $row.ForeColor = [System.Drawing.Color]::PaleGreen
                                    $count++ 
                                }
                                elseif ($type -eq "ROTEADOR (GATEWAY)" -or $type -eq "ROTEADOR/DISP. WEB") { 
                                    $row.ForeColor = [System.Drawing.Color]::LightSkyBlue 
                                }
                                elseif ($type -eq "COMPUTADOR") { 
                                    $row.ForeColor = [System.Drawing.Color]::Wheat 
                                }
                                
                                [void]$Script:ScannerLV.Items.Add($row)
                            }
                            catch {}
                        }
                        $Script:ScannerLblStat.Text = "Scan completo. $count impressoras encontradas."
                        $Script:ScannerProgress.Value = $Script:ScannerProgress.Maximum
                    }
                }
                catch { $Script:ScannerLblStat.Text = "Erro: $_" }
                finally { $Script:ScannerBtnScan.Enabled = $true; $Script:ScannerBtnScan.Text = "INICIAR SCAN" }
            })

        $Script:ScannerForm.Add_FormClosing({ $Script:ScannerForm = $null })
        $Script:ScannerForm.ShowDialog($Script:MainForm)
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Erro ao abrir Scanner: $_", "XMenu Error") | Out-Null
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
        $tabActiveColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
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

        function Add-DriverSection {
            param($Panel, [ref]$Y, $Title, $Color)
            $lbl = New-Object System.Windows.Forms.Label
            $lbl.Text = $Title; $lbl.AutoSize = $true
            $lbl.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
            $lbl.ForeColor = $Color; $lbl.Location = New-Object System.Drawing.Point(15, $Y.Value)
            [void]$Panel.Controls.Add($lbl)
            $Y.Value += 28
        }

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
                    $this.Enabled = $false; $this.Text = "  Baixando $dlFile ..."
                    Log-Message "INFO" "Baixando driver: $dlFile"
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri $dlUrl -OutFile $dest -UseBasicParsing
                    if (-not (Test-DownloadIntegrity -Path $dest)) {
                        Remove-Item $dest -Force -ErrorAction SilentlyContinue
                        throw "Arquivo baixado esta corrompido ou invalido (link quebrado ou pagina de erro)."
                    }
                    Log-Message "SUCESSO" "Download concluido: $dlFile"
                    $this.Text = "  Instalando $dlFile ..."
                    Start-Process -FilePath $dest
                    Log-Message "SUCESSO" "Instalador iniciado: $dlFile"
                    $this.Text = "✔ $origText"
                } catch {
                    Log-Message "ERRO" "Falha ao baixar driver: $_"
                    [System.Windows.Forms.MessageBox]::Show("Erro ao baixar o driver: $_", "Erro", "OK", "Error") | Out-Null
                    $this.Text = $origText
                } finally {
                    $this.Enabled = $true
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

        # -------------------------------------------------------------
        # CONTEÚDO DO PAINEL LOCAL (ABA 1)
        # -------------------------------------------------------------
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
        $btnShare.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnShare.FlatStyle = 'Flat'; $btnShare.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnShare.Cursor = 'Hand'; $btnShare.ForeColor = 'White'; $btnShare.FlatAppearance.BorderSize = 0
        $btnShare.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 240)
        $btnShare.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 100, 190)
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
            $btnOk.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnOk.FlatStyle = 'Flat'; $btnOk.Cursor = 'Hand'; $btnOk.ForeColor = 'White'; $btnOk.FlatAppearance.BorderSize = 0
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
                        
                        Log-Message "INFO" "Reiniciando spooler para aplicar registros..."
                        Restart-Service -Name Spooler -Force
                        Log-Message "SUCESSO" "Registros RPC aplicados e Spooler reiniciado com sucesso!"
                        
                        $netPath = "\\$env:COMPUTERNAME\$shareName"
                        [System.Windows.Forms.Clipboard]::SetText($netPath)
                        [System.Windows.Forms.MessageBox]::Show(
                            "Impressora compartilhada com sucesso e registros aplicados!`n`nCaminho da impressora para o portal:`n$netPath`n`n(Este caminho ja foi copiado para sua Area de Transferencia!)",
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
        $btnCopyPath.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnCopyPath.FlatStyle = 'Flat'; $btnCopyPath.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $btnCopyPath.Cursor = 'Hand'; $btnCopyPath.ForeColor = 'White'; $btnCopyPath.FlatAppearance.BorderSize = 0
        $btnCopyPath.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 240)
        $btnCopyPath.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 100, 190)
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
                if ($proc.ExitCode -ne 0) { throw "Falha no DISM. Codigo: $($proc.ExitCode)" }
                
                Log-Message "INFO" "Configurando e iniciando o servico LPDSVC..."
                sc.exe config LPDSVC start= auto | Out-Null
                net start LPDSVC | Out-Null
                
                Log-Message "INFO" "Adicionando regra de Firewall..."
                netsh advfirewall firewall add rule name="LPD Porta 515" dir=in action=allow protocol=TCP localport=515 | Out-Null
                
                Log-Message "INFO" "Reiniciando spooler..."
                Restart-Service -Name Spooler -Force
                
                $ips = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.*" } | Select-Object -ExpandProperty IPAddress -Unique
                $txtIps = $ips -join " ou "
                if (-not $txtIps) { $txtIps = "Não detectado" }
                
                Log-Message "SUCESSO" "LPD configurado com sucesso no PC local! Porta 515 ativa."
                Log-Message "INFO" ">>> IP DESTE COMPUTADOR: $txtIps <<<"
                Log-Message "INFO" "IMPORTANTE: Agora compartilhe a impressora na Aba 1 com nome simples."
                
                [System.Windows.Forms.MessageBox]::Show(
                    $Script:PrinterManagerForm,
                    "LPD Ativado com sucesso!`n`nIP da Máquina: $txtIps`n`nProximos Passos:`n1. Compartilhe a impressora USB na Aba 1 (ex: IMPRESSORA).`n2. Fixe o IP deste computador no roteador.`n3. Vá para o outro PC e configure como Cliente LPR.",
                    "LPD Configurado", "OK", "Information") | Out-Null
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
        $btnGoShare.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnGoShare.FlatStyle = 'Flat'; $btnGoShare.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnGoShare.Cursor = 'Hand'; $btnGoShare.ForeColor = 'White'; $btnGoShare.FlatAppearance.BorderSize = 0
        $btnGoShare.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 240)
        $btnGoShare.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 100, 190)
        $btnGoShare.Add_Click({
            $pnlLocal.Visible = $true
            $pnlLpr.Visible = $false
            $btnTabLocal.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnTabLocal.ForeColor = 'White'
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
                if ($proc.ExitCode -ne 0) { throw "Falha no DISM. Codigo: $($proc.ExitCode)" }
                
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
                    "Cliente LPR Ativado com sucesso!`n`nO passo a passo foi copiado para sua Área de Transferência!`n`nAgora clique no botao 'ABRIR ASSISTENTE' para adicionar a impressora no Windows.",
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
        $btnWizard.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btnWizard.FlatStyle = 'Flat'; $btnWizard.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $btnWizard.Cursor = 'Hand'; $btnWizard.ForeColor = 'White'; $btnWizard.FlatAppearance.BorderSize = 0
        $btnWizard.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 240)
        $btnWizard.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 100, 190)
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
    if ($null -ne $Script:PingForm -and $Script:PingForm.Visible) {
        if ($InitialIP) { $Script:PingTxtIP.Text = $InitialIP }
        $Script:PingForm.Activate(); return
    }

    $Script:PingForm = New-Object System.Windows.Forms.Form
    $Script:PingForm.Text = "Teste de Ping Contínuo"; $Script:PingForm.Size = "450,480"; $Script:PingForm.StartPosition = 'CenterParent'
    $Script:PingForm.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30); $Script:PingForm.ForeColor = 'White'
    $Script:PingForm.FormBorderStyle = 'FixedDialog'; $Script:PingForm.MaximizeBox = $false; $Script:PingForm.MinimizeBox = $true

    $lbl = New-Object System.Windows.Forms.Label; $lbl.Text = "IP ou Hostname:"; $lbl.Location = '20,20'; $lbl.AutoSize = $true
    [void]$Script:PingForm.Controls.Add($lbl)

    $Script:PingTxtIP = New-Object System.Windows.Forms.TextBox; $Script:PingTxtIP.Location = '120,18'; $Script:PingTxtIP.Width = 200
    $Script:PingTxtIP.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 60); $Script:PingTxtIP.ForeColor = 'White'; $Script:PingTxtIP.BorderStyle = 'FixedSingle'
    if ($InitialIP) { $Script:PingTxtIP.Text = $InitialIP }
    [void]$Script:PingForm.Controls.Add($Script:PingTxtIP)

    $Script:PingChkLog = New-Object System.Windows.Forms.CheckBox; $Script:PingChkLog.Text = "Salvar log na Área de Trabalho"; $Script:PingChkLog.Location = '20,50'
    $Script:PingChkLog.AutoSize = $true; [void]$Script:PingForm.Controls.Add($Script:PingChkLog)

    $Script:PingBtnRun = New-Object System.Windows.Forms.Button; $Script:PingBtnRun.Text = "INICIAR"; $Script:PingBtnRun.Location = '330,17'; $Script:PingBtnRun.Width = 80
    $Script:PingBtnRun.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $Script:PingBtnRun.FlatStyle = 'Flat'
    [void]$Script:PingForm.Controls.Add($Script:PingBtnRun)

    $Script:PingRtb = New-Object System.Windows.Forms.RichTextBox; $Script:PingRtb.Location = '20,80'; $Script:PingRtb.Size = '390,320'
    $Script:PingRtb.BackColor = [System.Drawing.Color]::Black; $Script:PingRtb.ForeColor = 'Lime'; $Script:PingRtb.ReadOnly = $true; $Script:PingRtb.BorderStyle = 'None'
    [void]$Script:PingForm.Controls.Add($Script:PingRtb)

    $Script:PingTimerObj = New-Object System.Windows.Forms.Timer; $Script:PingTimerObj.Interval = 1000

    $Script:PingTimerObj.Add_Tick({
            $target = $Script:PingTxtIP.Text.Trim()
            if ([string]::IsNullOrEmpty($target)) { return }

            # Usa Ping .NET com timeout fixo de 800ms para nao travar a UI
            $pingObj = New-Object System.Net.NetworkInformation.Ping
            $pingReply = $null
            try { $pingReply = $pingObj.Send($target, 800) } catch {}
            $time = Get-Date -Format "HH:mm:ss"
            $msg = ""

            if ($pingReply -ne $null -and $pingReply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $msg = "[$time] Resposta de ${target}: tempo=$($pingReply.RoundtripTime)ms`n"
                $Script:PingRtb.SelectionColor = [System.Drawing.Color]::Lime
            }
            else {
                $statusDesc = if ($pingReply -ne $null) { $pingReply.Status } else { "Timeout" }
                $msg = "[$time] FALHA ($statusDesc): Host inacessivel.`n"
                $Script:PingRtb.SelectionColor = [System.Drawing.Color]::Salmon
            }

            $Script:PingRtb.AppendText($msg); $Script:PingRtb.ScrollToCaret()
            if ($Script:PingChkLog.Checked -and $Script:PingLogPath -ne "") {
                $msg.Trim() | Out-File $Script:PingLogPath -Append -Encoding utf8
            }
        })

    $Script:PingBtnRun.Add_Click({
            if ($Script:PingTimerObj.Enabled) {
                $Script:PingTimerObj.Stop()
                $Script:PingBtnRun.Text = "INICIAR"; $Script:PingBtnRun.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
                $Script:PingTxtIP.Enabled = $true; $Script:PingChkLog.Enabled = $true
            }
            else {
                $target = $Script:PingTxtIP.Text.Trim()
                if ([string]::IsNullOrEmpty($target)) { return }
                $Script:PingBtnRun.Text = "PARAR"; $Script:PingBtnRun.BackColor = [System.Drawing.Color]::Salmon
                $Script:PingTxtIP.Enabled = $false; $Script:PingChkLog.Enabled = $false
                if ($Script:PingChkLog.Checked) {
                    $Script:PingLogPath = Join-Path $Script:DesktopPath "PingLog_$($target.Replace('.', '_')).txt"
                    "--- Iniciando Log de Ping: $(Get-Date) Target: $target ---" | Out-File $Script:PingLogPath -Encoding utf8
                    $Script:PingRtb.AppendText(">> Logging em: $Script:PingLogPath`n")
                }
                else { $Script:PingLogPath = "" }
                $Script:PingTimerObj.Start()
            }
        })

    $Script:PingForm.Add_FormClosing({
            param($s, $e)
            $res = [System.Windows.Forms.MessageBox]::Show("O teste de ping sera interrompido. Deseja realmente fechar?", "Confirmar Saida", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($res -eq [System.Windows.Forms.DialogResult]::No) { $e.Cancel = $true }
            else { $Script:PingTimerObj.Stop(); $Script:PingTimerObj.Dispose(); $Script:PingForm = $null }
        })

    $Script:PingForm.Add_Shown({ if ($InitialIP) { $Script:PingBtnRun.PerformClick() } })
    $Script:PingForm.Show()
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
        
        # Remove backup antigo se existir
        if (Test-Path $backupPath) {
            Log-Message "LOG" "Removendo backup antigo: $backupPath"
            Remove-Item $backupPath -Recurse -Force -ErrorAction SilentlyContinue
            [System.Windows.Forms.Application]::DoEvents()
        }
        
        # Faz backup usando robocopy /MIR /MT:8 (multithread)
        if (Test-Path $destPath) {
            Log-Message "INFO" "Criando backup (robocopy): $destPath -> $backupPath"
            [System.Windows.Forms.Application]::DoEvents()
            $roboBackup = Start-Process "robocopy.exe" -ArgumentList "`"$destPath`" `"$backupPath`" /MIR /MT:8 /NFL /NDL /NJH /NJS" -NoNewWindow -Wait -PassThru
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

function Cancel-Download {
    if ($Script:CurrentWebClient -ne $null -and $Global:XM_DOWNLOAD_IN_PROGRESS) {
        $Script:CancelRequested = $true
        try { $Script:CurrentWebClient.CancelAsync() } catch {}
        Log-Message "CANCEL" "Solicitacao de cancelamento enviada..."
        [System.Windows.Forms.Application]::DoEvents()
    }
}

function Start-Download {
    param($Url, $FileName, $Button)
    
    if ($Global:XM_DOWNLOAD_IN_PROGRESS) { 
        [System.Windows.Forms.MessageBox]::Show("Já existe um download ou tarefa em andamento. Aguarde a conclusão ou cancele o atual.", "Sistema Ocupado", "OK", "Warning") | Out-Null
        return 
    }
    
    if ($Button.Text -like "*Instalado" -or $Button.Text -like "*Aberto" -or $Button.Text -like "*Extraido") { return }

    $originalText = $Button.Text
    $Global:XM_DOWNLOAD_IN_PROGRESS = $true
    $Script:CancelRequested = $false
    
    # Bloqueio visual de toda a tabela para evitar cliques fantasmas
    try { if ($tbl) { $tbl.Enabled = $false } } catch {}

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
                        if ($Script:ProgressBar) { $Script:ProgressBar.Value = $e.ProgressPercentage }
                        
                        $pct = $e.ProgressPercentage
                        $barSize = 10
                        $filled = [Math]::Floor($pct / (100 / $barSize))
                        $bar = ("=" * $filled) + (" " * ($barSize - $filled))
                        
                        if ($Script:CancelRequested) { try { $s.CancelAsync() } catch {} }
                        else {
                            $Button.Text = "[$bar] $pct%"
                            # Color animation: Transitions from Orange/Amber to Green
                            if ($pct -gt 90) { $Button.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113) }
                            elseif ($pct -gt 20) { $Button.BackColor = [System.Drawing.Color]::FromArgb(211, 84, 0) }
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
            
        }
        elseif ($downloadSuccessful) {
            
            # Verificacao de integridade basica (tamanho minimo + assinatura binaria)
            if (-not (Test-DownloadIntegrity -Path $destPath -MinBytes 50000)) {
                Log-Message "ERRO" "Arquivo corrompido ou link invalido (Tamanho: $((Get-Item $destPath).Length) bytes)."
                Remove-Item $destPath -Force -ErrorAction SilentlyContinue
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
                    # Usa ZipFile do .NET diretamente - mais rapido que Expand-Archive
                    Add-Type -AssemblyName System.IO.Compression.FileSystem
                    
                    $folderName = [System.IO.Path]::GetFileNameWithoutExtension($FileName)
                    $finalPath = Join-Path $Script:DownloadFolder $folderName
                    $tempPath  = Join-Path $Script:DownloadFolder "temp_$folderName"
                    
                    if (Test-Path $tempPath)  { Remove-Item $tempPath  -Recurse -Force | Out-Null }
                    if (Test-Path $finalPath) { Remove-Item $finalPath -Recurse -Force | Out-Null }
                    [System.Windows.Forms.Application]::DoEvents()
                    
                    # Extrai com ZipFile (nativo .NET)
                    [System.IO.Compression.ZipFile]::ExtractToDirectory($destPath, $tempPath)
                    [System.Windows.Forms.Application]::DoEvents()
                    
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
                }
                catch {
                    Log-Message "ERRO" "Falha ao extrair ZIP: $($_.Exception.Message)"
                    $Button.Text = "Erro ZIP"
                    $Button.BackColor = [System.Drawing.Color]::Salmon
                }

            }
            elseif ($FileName.EndsWith(".rar")) {
                $Button.Text = "Baixado (RAR)"
                Invoke-Item $destPath
                Wait-UI 1.5
                $Button.Text = "✔ $originalText"
            }
            else {
                Log-Message "EXEC" "Executando instalador..."
                Start-Process $destPath
                $Button.Text = "Executado"
                Wait-UI 1.5
                $Button.Text = "✔ $originalText"
            }
        }
        else {
            if (-not $Script:CancelRequested) {
                Log-Message "ERRO" "Falha definitiva no download."
                $Button.BackColor = [System.Drawing.Color]::Salmon
                $Button.Text = "Erro"
                Wait-UI 2
                $Button.BackColor = [System.Drawing.Color]::FromArgb(40, 40, 45)
                $Button.Text = $originalText
            }
        }

    }
    catch {
        Log-Message "ERRO" "Erro Fatal de Script: $($_.Exception.Message)"
        $Button.Text = "Erro Fatal"
        $Button.BackColor = [System.Drawing.Color]::Red
    }
    finally {
        $Global:XM_DOWNLOAD_IN_PROGRESS = $false
        $Script:CurrentWebClient = $null
        $Script:CancelRequested = $false
        
        try { if ($tbl) { $tbl.Enabled = $true } } catch {}
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
    $btn.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $btn.ForeColor = 'White'; $btn.FlatStyle = 'Flat'
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
    
    Log-Message "LOG" "--- INICIANDO CONFIGURACAO ---"
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
    Log-Message "LOG" "     Desativando hibernação para um boot mais rápido e limpo..."
    Log-Message "CMD" "COMANDO: powercfg /h off"
    powercfg /h off | Out-Null
    Log-Message "CMD" "COMANDO: reg ADD HKLM\...\Power /v HiberbootEnabled /t REG_DWORD /d 0 /f"
    Start-Process "reg.exe" -ArgumentList "ADD ""HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power"" /v HiberbootEnabled /t REG_DWORD /d 0 /f" -NoNewWindow -Wait
    $Script:ProgressBar.Value = 30
    [System.Windows.Forms.Application]::DoEvents()
    
    Log-Message "LOG" "3. EXPLORER E AJUSTES VISUAIS:"
    Log-Message "LOG" "     Padronizando Data (DD/MM/AAAA) e Extensões de Arquivos..."
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... sShortDate dd/MM/yyyy"
    Set-ItemProperty -Path "HKCU:\Control Panel\International" -Name "sShortDate" -Value "dd/MM/yyyy" -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... LaunchTo 1"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "LaunchTo" -Value 1 -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... HideFileExt 0"
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "HideFileExt" -Value 0 -Force -ErrorAction SilentlyContinue
    
    Log-Message "LOG" "     Otimizacoes visuais preparadas (Ajuste Final Manual)."
    $Script:ProgressBar.Value = 45
    
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
    
    Log-Message "LOG" "4. REDE E SEGURANÇA:"
    Log-Message "LOG" "     Preparando registros de rede para ajuste manual..."
    
    # Pre-sets de Registro (Ajudam o Windows a aceitar a mudanca manual)
    $lsa = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    Set-ItemProperty -Path $lsa -Name "everyoneincludesanonymous" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $lsa -Name "LimitBlankPasswordUse" -Value 0 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $lsa -Name "ForceGuest" -Value 1 -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "restrictnullsessaccess" -Value 0 -Force -ErrorAction SilentlyContinue
    
    Log-Message "SUCESSO" "Registros de rede aplicados. Ajuste final sera manual."
    
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
    Log-Message "LOG" "     Limpando aplicativos inúteis que pesam no PC (Bloatware)..."
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... ShowCortanaButton 0"
    $advKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
    Set-ItemProperty -Path $advKey -Name "ShowCortanaButton" -Value 0 -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... ShowTaskViewButton 0"
    Set-ItemProperty -Path $advKey -Name "ShowTaskViewButton" -Value 0 -Force -ErrorAction SilentlyContinue
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... TaskbarMn 0"
    Set-ItemProperty -Path $advKey -Name "TaskbarMn" -Value 0 -Force -ErrorAction SilentlyContinue
    $searchKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"
    if (!(Test-Path $searchKey)) { New-Item -Path $searchKey -Force | Out-Null }
    Log-Message "CMD" "COMANDO: Set-ItemProperty ... SearchboxTaskbarMode 0"
    Set-ItemProperty -Path $searchKey -Name "SearchboxTaskbarMode" -Value 0 -Force -ErrorAction SilentlyContinue
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
    
    Log-Message "LOG" "     Eliminando lixo digital e arquivos temporários..."
    Log-Message "CMD" "COMANDO: Remove-Item $env:TEMP\*"
    Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Log-Message "CMD" "COMANDO: Remove-Item $env:windir\Temp\*"
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
    }
    catch { Log-Message "ERRO" "Falha no Wallpaper: $($_.Exception.Message)" }
    
    # --- MODIFICACAO REVENDA: BLOCO DE CRIACAO DE ATALHO SUPORTE REMOVIDO ---
    
    Log-Message "LOG" "--- TUDO PRONTO! ---"
    
    # Limpa cliques anteriores e configura o novo texto (solicitacao usuario)
    $Btn.remove_Click( { Invoke-Preparo }.GetNewClosure() ) 
    $Btn.Text = "REALIZAR AJUSTES MANUAIS"; $Btn.BackColor = [System.Drawing.Color]::FromArgb(46, 204, 113); $Btn.Enabled = $true
    $Script:ProgressBar.Value = 100
    
    $Script:MainForm.Activate()
    
    # --- FUNCAO PARA CRIAR JANELA DE INSTRUCOES INDEPENDENTE ---
    function Show-ManualGuide {
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
$formWidth = if ($screen.Width -lt 1000) { 900 } else { 1000 }
$formHeight = if ($screen.Height -lt 800) { 700 } else { 800 }

$form = New-Object System.Windows.Forms.Form
$form.Text = "XMenu System Manager v17.59 - REVENDA"
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
$head.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $head.Padding = '20,20,20,0'
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

$btnIP = New-Object System.Windows.Forms.Button; $btnIP.Text = "DIAG. REDE"; $btnIP.Size = '140,40'
$btnIP.BackColor = 'White'; $btnIP.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
$btnIP.FlatStyle = 'Flat'; $btnIP.FlatAppearance.BorderSize = 0; $btnIP.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnIP.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnIP.Margin = '0,0,0,10'
$btnIP.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
$btnIP.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$btnIP.Add_Click({ Show-IPs })
[void]$hRight.Controls.Add($btnIP)

# --- NOVO BOTAO LINKS NO HEADER ---
$btnLinks = New-Object System.Windows.Forms.Button; $btnLinks.Text = "LINKS ÚTEIS ▼"; $btnLinks.Size = '140,40'
$btnLinks.BackColor = 'White'; $btnLinks.ForeColor = [System.Drawing.Color]::FromArgb(0, 100, 200)
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
$tLog = New-Object System.Windows.Forms.RichTextBox; $tLog.Dock = 'Fill'; $tLog.BackColor = [System.Drawing.Color]::FromArgb(20, 20, 20)
$tLog.ForeColor = 'White'; $tLog.BorderStyle = 'None'; $tLog.ReadOnly = $true; $tLog.Font = New-Object System.Drawing.Font("Consolas", 9)
[void]$gLog.Controls.Add($tLog); $Script:LogBox = $tLog

$bCfg = New-Object System.Windows.Forms.Button; $bCfg.Text = "PREPARAR AMBIENTE WINDOWS"
$bCfg.Dock = 'Fill'; $bCfg.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215); $bCfg.ForeColor = 'White'
$bCfg.FlatStyle = 'Flat'; $bCfg.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$bCfg.Margin = '0,10,0,10'; $bCfg.Cursor = 'Hand'
$bCfg.FlatAppearance.BorderSize = 0
$bCfg.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(0, 140, 240)
$bCfg.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(0, 100, 190)

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
$tbl = New-Object System.Windows.Forms.TableLayoutPanel; $tbl.Dock = 'Top'; $tbl.AutoSize = $true
$tbl.ColumnCount = 2; [void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$tbl.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$pScroll.Controls.Add($tbl)

function Add-Title {
    param($T) 
    $l = New-Object System.Windows.Forms.Label; $l.Text = $T; $l.AutoSize = $true
    $l.ForeColor = [System.Drawing.Color]::FromArgb(0, 150, 255); $l.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $l.Margin = '5,15,0,5'; [void]$tbl.Controls.Add($l, 0, -1); $tbl.SetColumnSpan($l, 2)
    $null = $l
}

function Add-Btn {
    param($T, $D, $U, $F, $Sel = $false, $Type = "", $Color = $null, $Help = "") 
    $b = New-Object System.Windows.Forms.Button; $b.Height = 60; $b.Dock = 'Top'
    $b.ForeColor = 'WhiteSmoke'
    $b.FlatStyle = 'Flat'
    $b.TextAlign = 'MiddleLeft'; $b.Padding = '10,0,0,0'; $b.Margin = '5'
    $b.Text = $T; $b.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $b.Cursor = 'Hand'
    $b.FlatAppearance.BorderSize = 0

    $baseColor = if ($Color) { $Color } else { [System.Drawing.Color]::FromArgb(30, 45, 75) }
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
    else {
        $b.Tag = "$U|$F"; $b.Add_Click({ $d = $this.Tag.Split('|'); Start-Download $d[0] $d[1] $this })
    }
    [void]$tbl.Controls.Add($b)
    $null = $b
}

$colorBlue = [System.Drawing.Color]::FromArgb(30, 45, 75)

Add-Title "BANCO DE DADOS"
Add-Btn "SQL Server 2008 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2008x64_DESCONTINUADO.exe" "SQL2008x64.exe" -Color $colorBlue -Help "Instalador clássico do SQL 2008 R2 (Padrão NetControll)"
Add-Btn "SQL Server 2019 (Instalador)" "" "https://www.netcontroll.com.br/util/instaladores/netpdv/SQL2019.exe" "SQL2019.exe" -Color $colorBlue -Help "Instalador automático do SQL Server 2019 Express."

$bSqlMan = New-Object System.Windows.Forms.Button; $bSqlMan.Height = 60; $bSqlMan.Dock = 'Top'
$bSqlMan.BackColor = [System.Drawing.Color]::FromArgb(30, 45, 75); $bSqlMan.ForeColor = 'WhiteSmoke'
$bSqlMan.FlatStyle = 'Flat'; $bSqlMan.FlatAppearance.BorderSize = 0; $bSqlMan.TextAlign = 'MiddleLeft'; $bSqlMan.Padding = '10,0,0,0'; $bSqlMan.Margin = '5'
$bSqlMan.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(50, 65, 95)
$bSqlMan.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(15, 30, 60)
$bSqlMan.Text = "SQL 2019 + SSMS (Manual)"; $bSqlMan.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bSqlMan.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bSqlMan, "Baixa o instalador do SQL 2019 e a ferramenta de gerenciamento SSMS separadamente.")
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
$bTecno.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(50, 65, 95)
$bTecno.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(15, 30, 60)
$bTecno.Text = "TecnoSpeed NFCe (11.1.7.27)"; $bTecno.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bTecno.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bTecno, "Fecha todo o sistema NetControll (NetPDV, LinkXMenu, XMenu, Concentrador, XBot, XTag) e instala o componente TecnoSpeed para NFC-e.")
$bTecno.Add_Click({
        Close-NetControllSystem
        Start-Download "https://netcontroll.com.br/util/instaladores/NFCE/11.1.7.27/InstaladorNFCe.exe" "InstaladorNFCe.exe" $this
    })
[void]$tbl.Controls.Add($bTecno)

$bVspe = New-Object System.Windows.Forms.Button; $bVspe.Height = 60; $bVspe.Dock = 'Top'
$bVspe.BackColor = [System.Drawing.Color]::FromArgb(30, 45, 75); $bVspe.ForeColor = 'WhiteSmoke'
$bVspe.FlatStyle = 'Flat'; $bVspe.FlatAppearance.BorderSize = 0; $bVspe.TextAlign = 'MiddleLeft'; $bVspe.Padding = '10,0,0,0'; $bVspe.Margin = '5'
$bVspe.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(50, 65, 95)
$bVspe.FlatAppearance.MouseDownBackColor = [System.Drawing.Color]::FromArgb(15, 30, 60)
$bVspe.Text = "VSPE + Epson Virtual Port"; $bVspe.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bVspe.Cursor = 'Hand'
$Script:ToolTip.SetToolTip($bVspe, "Instala o emulador de porta serial VSPE e os drivers de porta virtual da Epson.")
$bVspe.Add_Click({ Install-VSPE-Combined $this })
[void]$tbl.Controls.Add($bVspe)

Add-Btn "TeamViewer Full" "" "https://download.teamviewer.com/download/TeamViewer_Setup_x64.exe" "Teamviewer.exe" -Help "Cliente completo para acesso remoto TeamViewer."
Add-Btn "AnyDesk" "" "https://download.anydesk.com/AnyDesk.exe" "AnyDesk.exe" -Help "Ferramenta de acesso remoto AnyDesk."
Add-Btn "Google Chrome" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/ChromeSetup.exe" "ChromeSetup.exe" -Help "Instalador online do navegador Google Chrome."
Add-Btn "Revo Uninstaller" "" "https://download.revouninstaller.com/download/revosetup.exe" "revosetup.exe" -Help "Utilitário para desinstalação completa de programas e limpeza de restos."
Add-Btn "TEF HUB Windows" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/TEF.HUB.WINDOWS.exe" "TefHub_Windows.exe" -Help "Instalador Tefhub Windows."
Add-Btn "Advanced IP Scanner" "" "https://download.advanced-ip-scanner.com/download/files/Advanced_IP_Scanner_2.5.4594.1.exe" "Advanced_IP_Scanner.exe" -Help "Ferramenta de varredura de rede local Advanced IP Scanner."
Add-Btn "Balança Teste" "" "https://github.com/VMazza10/Preparador-de-Ambiente-XMenu/releases/download/Chrome/BalancaTeste.exe" "BalancaTeste.exe" -Help "Aplicativo para testar o funcionamento e comunicação da balança."

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
# Placeholder vazio na coluna direita (reservado para botão futuro)
$lblPrintPlaceholder = New-Object System.Windows.Forms.Label; $lblPrintPlaceholder.Text = ""; $lblPrintPlaceholder.Dock = 'Fill'
[void]$tbl.Controls.Add($lblPrintPlaceholder)

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

$bPingT = New-Object System.Windows.Forms.Button; $bPingT.Height = 50; $bPingT.Dock = 'Top'
$bPingT.Text = "Teste de Ping Contínuo (com Log)"; $bPingT.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bPingT.Cursor = 'Hand'
Format-SupportBtn $bPingT $colorDiag
$Script:ToolTip.SetToolTip($bPingT, "Executa 'Test-Connection' continuamente para o IP alvo, permitindo monitorar perdas de pacotes com log local.")
$bPingT.Add_Click({ Show-PingTester })
[void]$tbl.Controls.Add($bPingT)

$bRes = New-Object System.Windows.Forms.Button; $bRes.Height = 50; $bRes.Dock = 'Top'
$bRes.Text = "Monitorar CPU e RAM"; $bRes.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bRes.Cursor = 'Hand'
Format-SupportBtn $bRes $colorDiag
$Script:ToolTip.SetToolTip($bRes, "Utiliza 'Get-Process' para listar os 5 processos com maior consumo de CPU e Memória RAM em tempo real.")
$bRes.Add_Click({ Show-ResourceMonitor })
[void]$tbl.Controls.Add($bRes)

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

$bNetR = New-Object System.Windows.Forms.Button; $bNetR.Height = 50; $bNetR.Dock = 'Top'
$bNetR.Text = "Reset de Rede e DNS"; $bNetR.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$bNetR.Cursor = 'Hand'
Format-SupportBtn $bNetR $colorGray
$Script:ToolTip.SetToolTip($bNetR, "Executa 'ipconfig /flushdns', 'netsh winsock reset' e 'netsh int ip reset' para restaurar toda a pilha de rede.")
$bNetR.Add_Click({ Invoke-NetworkReset })
[void]$tbl.Controls.Add($bNetR)

Log-Message "INFO" "XMenu System Manager v17.59 - REVENDA"
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
