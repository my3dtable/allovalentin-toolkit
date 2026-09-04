<#
.SYNOPSIS
    Diagnostic complet Windows 11 gaming - Allo Valentin
.DESCRIPTION
    Detecte et rapporte TOUT l'etat de la machine dans un seul rapport HTML :
      - Materiel (CPU, GPU, carte mere, RAM, disques)
      - Tous les pilotes tries par anciennete
      - Temperatures (via LibreHardwareMonitor, installe par winget)
      - Sante disque SMART (via CrystalDiskInfo, installe par winget)
      - Sante OS (sfc + DISM)
      - Programmes au demarrage (+ desactivation interactive)
      - Residus d'apps desinstallees (+ suppression sur validation)
      - Windows Update en attente
      - Evenements critiques recents
      - Test reseau
    Le script DETECTE et SIGNALE. Les actions destructives restent sous controle humain.
.PARAMETER Install
    Cree la tache planifiee mensuelle (diagnostic seul, sans interaction).
.PARAMETER ReportOnly
    Diagnostic sans les etapes interactives (utilise par la tache planifiee).
.PARAMETER SkipTools
    Ne tente pas d'installer/utiliser les outils tiers (diagnostic natif seul).
.NOTES
    A executer en Administrateur. Prevoir 3-8 min (sfc/DISM sont longs).
#>

param(
    [switch]$Install,
    [switch]$ReportOnly,
    [switch]$SkipTools,
    [switch]$Undo,
    [switch]$Fast,    # saute sfc + DISM : passage de 3-8 min a < 1 min
    [string]$Cle = "" # cle d'intervention Allo Valentin : debloque l'optimisation (sinon diagnostic seul)
)

# --- Auto-elevation : si pas admin, on relance le script en admin automatiquement ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement en mode Administrateur..." -ForegroundColor Yellow
    # On retransmet les parametres au script relance
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Install)    { $argList += " -Install" }
    if ($ReportOnly) { $argList += " -ReportOnly" }
    if ($SkipTools)  { $argList += " -SkipTools" }
    if ($Undo)       { $argList += " -Undo" }
    if ($Fast)       { $argList += " -Fast" }
    if ($Cle)        { $argList += " -Cle `"$Cle`"" }
    try {
        Start-Process powershell.exe -ArgumentList $argList -Verb RunAs
    } catch {
        Write-Host "Elevation refusee ou annulee. Le script a besoin des droits admin pour fonctionner." -ForegroundColor Red
    }
    exit
}

$AppDir    = "$env:ProgramData\AlloValentin"
$ReportDir = "$AppDir\Reports"
$LogDir    = "$AppDir\Logs"
$ToolsDir  = "$AppDir\Tools"
New-Item -ItemType Directory -Path $ReportDir, $LogDir, $ToolsDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$LogDir\Diagnostic-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $color = switch ($Level) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} "ASK"{"Cyan"} default{"White"} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}
# Conversion sure d'une date WMI : renvoie [datetime] ou $null, sans jamais planter.
# ATTENTION aux deux formats : Get-WmiObject rend une chaine DMTF ("20240125...")
# tandis que Get-CimInstance rend deja un [datetime]. Passer un [datetime] au
# convertisseur DMTF echoue et fait perdre la date de TOUS les pilotes.
function ConvertTo-SafeDate {
    param($Valeur)
    if ($null -eq $Valeur) { return $null }
    if ($Valeur -is [datetime]) { return $Valeur }
    if ([string]::IsNullOrWhiteSpace([string]$Valeur)) { return $null }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Valeur) }
    catch { return $null }
}
function Confirm-Action { param([string]$Prompt) return ((Read-Host "$Prompt (o/N)") -match '^[OoYy]') }
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# ============================================================
#  INSTALL : tache planifiee mensuelle
# ============================================================
if ($Install) {
    Write-Log "Installation tache planifiee..."
    $sp = $MyInvocation.MyCommand.Path
    $action  = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$sp`" -ReportOnly"
    $trigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 4 -DaysOfWeek Monday -At 10am
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
    Register-ScheduledTask -TaskName "AlloValentin-Diagnostic" -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force
    Write-Log "Tache creee : AlloValentin-Diagnostic." "OK"
    return
}

# ============================================================
#  UNDO : annule les tweaks (restaure le backup .reg + services)
# ============================================================
if ($Undo) {
    Write-Log "=== Mode annulation des tweaks ==="
    $backupDir = "$AppDir\Backups"
    if (-not (Test-Path $backupDir)) {
        Write-Host "Aucun dossier de sauvegarde trouve ($backupDir). Rien a annuler." -ForegroundColor Yellow
        return
    }
    # Trouve le backup .reg le plus recent
    $lastBackup = Get-ChildItem $backupDir -Filter "Tweaks-Backup-*.reg" -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $lastBackup) {
        Write-Host "Aucun fichier de sauvegarde .reg trouve. Utilise un point de restauration Windows si besoin." -ForegroundColor Yellow
        return
    }

    Write-Host "`n=== Annulation des tweaks Allo Valentin ===" -ForegroundColor Cyan
    Write-Host "Dernier backup trouve : $($lastBackup.Name)" -ForegroundColor White
    Write-Host "Date : $($lastBackup.LastWriteTime)" -ForegroundColor Gray
    Write-Host "`nCela va :" -ForegroundColor White
    Write-Host "  - Restaurer les cles registre a leur valeur d'origine" -ForegroundColor Gray
    Write-Host "  - Supprimer les valeurs de registre CREEES par les tweaks" -ForegroundColor Gray
    Write-Host "  - Reactiver les services SysMain et DiagTrack" -ForegroundColor Gray
    Write-Host "  - Reactiver les taches de telemetrie" -ForegroundColor Gray
    Write-Host "  - Remettre le plan d'alimentation Equilibre" -ForegroundColor Gray

    if (-not (Confirm-Action "`nConfirmer l'annulation de tous les tweaks ?")) {
        Write-Host "Annulation abandonnee." -ForegroundColor Yellow
        return
    }

    # 1) Restaure les cles registre depuis le .reg de backup
    try {
        reg import "$($lastBackup.FullName)" 2>$null
        Write-Log "Cles registre restaurees depuis $($lastBackup.Name)." "OK"
    } catch { Write-Log "Echec import registre : $_" "ERROR" }

    # 1bis) Supprime les valeurs et cles CREEES par les tweaks.
    # Etape indispensable : "reg import" fusionne, il ne supprime rien. Sans elle,
    # tout tweak ayant cree une valeur absente du Windows d'origine restait applique
    # apres l'Undo (TcpAckFrequency, TCPNoDelay, HwSchMode, MSISupported...).
    $stampBackup  = $lastBackup.BaseName -replace '^Tweaks-Backup-', ''
    $manifest     = Get-Item (Join-Path $backupDir "Tweaks-Manifest-$stampBackup.json") -EA SilentlyContinue
    if ($manifest) {
        $entries = @()
        try {
            # PS 5.1 : "... | ConvertFrom-Json" emet le tableau comme UN SEUL objet,
            # donc @(pipeline) rend un tableau de 1 contenant un Object[]. On passe
            # par une assignation avant @() pour recuperer les vrais elements.
            $parsed  = ConvertFrom-Json (Get-Content $manifest.FullName -Raw -Encoding UTF8)
            $entries = @($parsed)
        } catch { Write-Log "Manifeste illisible ($($manifest.Name)) : $_" "ERROR" }

        # a) Les valeurs qui n'existaient pas avant les tweaks
        $nbVal = 0
        foreach ($e in $entries) {
            if ($e.ValeurExistait) { continue }
            if (-not (Test-Path $e.Path)) { continue }
            try {
                Remove-ItemProperty -Path $e.Path -Name $e.Name -Force -EA Stop
                $nbVal++
                Write-Log "Valeur creee supprimee : $($e.Path)\$($e.Name)" "OK"
            } catch { Write-Log "Suppression $($e.Path)\$($e.Name) : $_" "WARN" }
        }

        # b) Les cles qui n'existaient pas, des plus profondes aux moins profondes,
        #    et uniquement si elles sont vides (aucune valeur, aucune sous-cle).
        $nbCle = 0
        $clesCreees = $entries | Where-Object { -not $_.CleExistait } |
                      Select-Object -ExpandProperty Path -Unique |
                      Sort-Object -Property { ($_ -split '\\').Count } -Descending
        foreach ($c in $clesCreees) {
            if (-not (Test-Path $c)) { continue }
            try {
                $k = Get-Item $c -EA Stop
                if ($k.ValueCount -eq 0 -and $k.SubKeyCount -eq 0) {
                    Remove-Item $c -Force -EA Stop
                    $nbCle++
                    Write-Log "Cle creee supprimee : $c" "OK"
                }
            } catch { Write-Log "Suppression cle $c : $_" "WARN" }
        }
        Write-Log "Manifeste $($manifest.Name) : $nbVal valeur(s) et $nbCle cle(s) creees supprimees." "OK"
    } else {
        Write-Host "Aucun manifeste associe a ce backup : les valeurs CREEES par les tweaks" -ForegroundColor Yellow
        Write-Host "ne peuvent pas etre supprimees automatiquement (tweaks poses par une version" -ForegroundColor Yellow
        Write-Host "anterieure du script). Utilise le point de restauration si besoin." -ForegroundColor DarkGray
        Write-Log "Aucun manifeste pour $($lastBackup.Name) : suppression des valeurs creees impossible." "WARN"
    }

    # 2) Reactive les services coupes (etat par defaut de Windows)
    foreach ($svc in @("SysMain","DiagTrack")) {
        try {
            Set-Service -Name $svc -StartupType Automatic -EA SilentlyContinue
            Start-Service -Name $svc -EA SilentlyContinue
            Write-Log "Service reactive : $svc" "OK"
        } catch { Write-Log "Service $svc : $_" "WARN" }
    }

    # 3) Reactive les taches de telemetrie
    $tachesTelemetrie = @(
        "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
        "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
        "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
    )
    foreach ($task in $tachesTelemetrie) {
        try { Enable-ScheduledTask -TaskPath (Split-Path $task) -TaskName (Split-Path $task -Leaf) -EA SilentlyContinue | Out-Null } catch {}
    }
    Write-Log "Taches de telemetrie reactivees." "OK"

    # 4) Remet le plan d'alimentation Equilibre (par defaut)
    try { powercfg -setactive SCHEME_BALANCED 2>$null; Write-Log "Plan d'alimentation Equilibre restaure." "OK" } catch {}

    # 5) Reactive l'inactivite CPU (annule le Processor Idle Disable)
    try {
        powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad 0 2>$null
        powercfg -setactive SCHEME_CURRENT 2>$null
    } catch {}

    # 6) Reactive le LSO reseau (annule le tweak anti-jitter)
    try {
        Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
            Enable-NetAdapterLso -Name $_.Name -IPv4 -EA SilentlyContinue
        }
        Write-Log "LSO reseau reactive." "OK"
    } catch {}

    # 7) Etat non-registre (carte reseau, tache d'optimisation) : relit NonReg-<stamp>.json
    $nonReg = Get-Item (Join-Path $backupDir "NonReg-$stampBackup.json") -EA SilentlyContinue
    if ($nonReg) {
        try {
            $nr = ConvertFrom-Json (Get-Content $nonReg.FullName -Raw -Encoding UTF8)
            # 'autoriser a eteindre' (PnPCapabilities) est deja remis par le reg import.
            # Ici on ne restaure que les proprietes avancees "eco" a leur valeur d'origine.
            foreach ($ad in @($nr.netAdapters)) {
                foreach ($p in @($ad.AdvProps)) {
                    try { Set-NetAdapterAdvancedProperty -Name $ad.Name -RegistryKeyword $p.Keyword -RegistryValue $p.OldValue -NoRestart -EA Stop } catch {}
                }
                Write-Log "Proprietes d'economie d'energie reseau restaurees : $($ad.Name)." "OK"
            }
            if ($nr.scheduledDefragWasDisabled) {
                try { Disable-ScheduledTask -TaskName 'ScheduledDefrag' -EA SilentlyContinue | Out-Null; Write-Log "Tache ScheduledDefrag remise sur Disabled (etat d'origine)." "OK" } catch {}
            }
        } catch { Write-Log "Restauration NonReg : $_" "WARN" }
    }

    Write-Host "`nAnnulation terminee." -ForegroundColor Green
    Write-Host "REDEMARRE la machine pour finaliser (certains reglages ne reviennent qu'au reboot)." -ForegroundColor Yellow
    Write-Host "Si besoin, un point de restauration 'AlloValentin-AvantTweaks' est aussi disponible (rstrui.exe)." -ForegroundColor Gray
    Write-Log "=== Fin annulation ==="
    return
}

# ============================================================
#  CLE D'INTERVENTION
#  L'optimisation (nettoyage + reglages, reversible) est reservee aux
#  interventions Allo Valentin. Sans cle valide, le script produit
#  uniquement le diagnostic (gratuit, lecture seule).
# ============================================================
if (-not $ReportOnly -and -not $Install) {
    if (-not $Cle) {
        $cleFile = Join-Path (Split-Path -Parent $PSCommandPath) 'cle.txt'
        if (Test-Path $cleFile) {
            try { $Cle = ([string](Get-Content $cleFile -Raw -ErrorAction Stop)).Trim() } catch {}
        }
    }
    $cleOK = $false
    if ($Cle) {
        try {
            $u = "https://allovalentin.fr/api/check?cle=" + [uri]::EscapeDataString($Cle)
            $rep = Invoke-RestMethod -Uri $u -TimeoutSec 12 -UseBasicParsing
            $cleOK = [bool]$rep.ok
        } catch {
            $cleOK = $false
            Write-Host "`n  Verification de la cle impossible (pas de connexion Internet ?)." -ForegroundColor Yellow
        }
    }
    if (-not $cleOK) {
        Write-Host "`n===============================================" -ForegroundColor Yellow
        Write-Host "  PAS DE CLE VALIDE -> diagnostic seul (niveau FAIBLE force)" -ForegroundColor Yellow
        Write-Host "===============================================" -ForegroundColor Yellow
        Write-Host "  Le diagnostic complet ci-dessous est GRATUIT." -ForegroundColor Gray
        Write-Host "  Sans cle, le menu de choix du niveau (Faible/Gaming/Extreme/Competition)" -ForegroundColor Gray
        Write-Host "  ne s'affiche PAS : aucun tweak ne peut de toute facon etre applique." -ForegroundColor Gray
        Write-Host "  L'optimisation se debloque avec la cle remise lors d'une intervention :" -ForegroundColor Gray
        Write-Host "    Allo Valentin  -  https://allovalentin.fr  -  07 55 53 08 67" -ForegroundColor White
        Write-Host "  Pour tester toi-meme en local, relance avec : -Cle `"TA_CLE`"" -ForegroundColor Cyan
        Write-Host ""
        Read-Host "  Appuie sur Entree pour continuer en diagnostic seul (ou Ctrl+C pour annuler et relancer avec -Cle)" | Out-Null
        $ReportOnly = $true
        Write-Log "Pas de cle d'intervention valide -> diagnostic seul (ReportOnly force)." "WARN"
    } else {
        Write-Log "Cle d'intervention validee -> optimisation autorisee." "OK"
    }
}

$Interactive = -not $ReportOnly
Write-Log "=== Debut diagnostic complet (Interactive: $Interactive) ==="

# ============================================================
#  NIVEAU D'OPTIMISATION (menu interactif, defaut = Faible)
# ============================================================
# Faible      : diagnostic + actions 100% sures (nettoyage, demarrage, residus, doublons). AUCUN tweak systeme.
# Gaming      : Faible + tweaks reversibles surs (plan alim, Game DVR, HAGS, MSI Mode, effets visuels).
# Extreme     : Gaming + tweaks agressifs (core parking, reseau Nagle/throttling).
# Competition : Extreme + desactivation d'une protection de securite Windows (VBS/Memory Integrity)
#               pour un gain FPS mesurable sur certains PC. PAS un tweak de confort : ca reduit la
#               protection contre les rootkits. Reserve a un client informe et volontaire (esport/
#               competitif). Confirmation ecrite obligatoire, tracee dans le log. Voir DECHARGE-CLIENT.md.
$niveau = "Faible"   # defaut si non interactif ou choix vide
if ($Interactive) {
    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "  ALLO VALENTIN - Niveau d'optimisation" -ForegroundColor Cyan
    Write-Host "===============================================" -ForegroundColor Cyan
    Write-Host "  1. FAIBLE      - Diagnostic + nettoyage sur (aucune modif systeme)" -ForegroundColor Green
    Write-Host "  2. GAMING      - Faible + tweaks surs et reversibles (plan alim, Game DVR, HAGS, MSI)" -ForegroundColor Yellow
    Write-Host "  3. EXTREME     - Gaming + tweaks agressifs en plus (core parking, reseau)" -ForegroundColor Red
    Write-Host "  4. COMPETITION - Extreme + desactive une protection de securite Windows (VBS/Memory" -ForegroundColor Magenta
    Write-Host "                   Integrity) pour un gain FPS mesurable. Reduit la securite. Client" -ForegroundColor Magenta
    Write-Host "                   informe et consentant uniquement - confirmation ecrite exigee." -ForegroundColor Magenta
    Write-Host "  (Entree = FAIBLE par defaut)`n" -ForegroundColor Gray
    $choix = Read-Host "Choix (1/2/3/4)"
    switch ($choix) {
        "2" { $niveau = "Gaming" }
        "3" { $niveau = "Extreme" }
        "4" { $niveau = "Competition" }
        default { $niveau = "Faible" }
    }
    Write-Host "Niveau selectionne : $($niveau.ToUpper())`n" -ForegroundColor Cyan
}
Write-Log "Niveau d'optimisation : $($niveau.ToUpper())" "OK"
# Aides de decision : quel niveau autorise quoi
$tweaksGamingAutorises      = ($niveau -eq "Gaming" -or $niveau -eq "Extreme" -or $niveau -eq "Competition")
$tweaksExtremeAutorises     = ($niveau -eq "Extreme" -or $niveau -eq "Competition")
$tweaksCompetitionAutorises = ($niveau -eq "Competition")

# ============================================================
#  OUTILS TIERS via winget (portables/fiables)
# ============================================================
$toolStatus = @{ LHM = "Non disponible"; CDI = "Non disponible" }
$wingetAvailable = $null -ne (Get-Command winget -ErrorAction SilentlyContinue)

function Ensure-WingetPackage {
    param([string]$Id, [string]$FriendlyName)
    if (-not $wingetAvailable) { return $false }
    $listed = winget list --id $Id --accept-source-agreements 2>$null | Out-String
    if ($listed -match [regex]::Escape($Id)) { Write-Log "$FriendlyName deja installe." "OK"; return $true }
    Write-Log "Installation de $FriendlyName via winget..."
    winget install --id $Id --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
    $listed2 = winget list --id $Id 2>$null | Out-String
    if ($listed2 -match [regex]::Escape($Id)) { Write-Log "$FriendlyName installe." "OK"; return $true }
    Write-Log "Echec installation $FriendlyName." "WARN"; return $false
}

if (-not $SkipTools -and $wingetAvailable) {
    # LibreHardwareMonitor (temperatures) et CrystalDiskInfo (SMART)
    if (Ensure-WingetPackage -Id "LibreHardwareMonitor.LibreHardwareMonitor" -FriendlyName "LibreHardwareMonitor") { $toolStatus.LHM = "OK" }
    if (Ensure-WingetPackage -Id "CrystalDewWorld.CrystalDiskInfo" -FriendlyName "CrystalDiskInfo") { $toolStatus.CDI = "OK" }
} elseif (-not $wingetAvailable) {
    Write-Log "winget indisponible : diagnostic natif seul." "WARN"
}

# ============================================================
#  1. MATERIEL
# ============================================================
Write-Log "Collecte materiel..."
$cs   = Get-CimInstance Win32_ComputerSystem
$cpu  = Get-CimInstance Win32_Processor | Select-Object -First 1
$bb   = Get-CimInstance Win32_BaseBoard        # carte mere
$bios = Get-CimInstance Win32_BIOS
$os   = Get-CimInstance Win32_OperatingSystem

$ramSticks = Get-CimInstance Win32_PhysicalMemory
$ramTotalGB = [math]::Round(($ramSticks | Measure-Object Capacity -Sum).Sum /1GB, 0)
$ramSpeed  = ($ramSticks | Select-Object -First 1).Speed          # vitesse configuree (reelle)
$ramSlotsUsed = $ramSticks.Count
$ramSlotsTotal = (Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1).MemoryDevices
# Vitesse max supportee par la barrette (pour comparer et detecter XMP non actif).
# ConfiguredClockSpeed = vitesse actuelle ; Speed = souvent la vitesse nominale/max selon le BIOS.
$ramConfigured = ($ramSticks | Select-Object -First 1).ConfiguredClockSpeed
$ramMax = ($ramSticks | Measure-Object -Property Speed -Maximum).Maximum

# Canal reel de chaque barrette. Compter les barrettes NE SUFFIT PAS : deux
# barrettes dans A1 et A2 sont sur le meme canal, donc en single channel.
# C'est l'erreur de montage la plus frequente apres un ajout de RAM.
function Get-CanalRam {
    param($Barrette)
    foreach ($src in @($Barrette.DeviceLocator, $Barrette.BankLabel)) {
        if ([string]::IsNullOrWhiteSpace($src)) { continue }
        $s = [string]$src
        # "Controller0-ChannelA", "Controller0ChannelAMemModule0"
        $m = [regex]::Match($s, '(?i)Controller\s*(\d+)\s*-?\s*Channel\s*([A-Z])')
        if ($m.Success) { return "C$($m.Groups[1].Value)$($m.Groups[2].Value.ToUpper())" }
        # "ChannelA", "CHANNEL A", "P0 CHANNEL A", "Node0 Channel A", "Chan A"
        $m = [regex]::Match($s, '(?i)Cha(?:nnel|n)?\s*-?\s*([A-H])(?![A-Za-z])')
        if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
        # "DIMM_A1", "DIMM A2", "DIMMA1", "SODIMM_A", "XMM A1", "DDR4_A1"
        $m = [regex]::Match($s, '(?i)(?:SO-?DIMM|DDR\d|X?MM|DIMM)[\s_-]*([A-H])\s*\d?(?![A-Za-z])')
        if ($m.Success) { return $m.Groups[1].Value.ToUpper() }
    }
    return $null
}
$ramCanaux = @($ramSticks | ForEach-Object { Get-CanalRam $_ } | Where-Object { $_ })
$ramNbCanaux = @($ramCanaux | Select-Object -Unique).Count
# Si on n'a pas pu lire le canal de CHAQUE barrette, on ne conclut pas fermement.
$ramCanauxLisibles = ($ramCanaux.Count -eq $ramSlotsUsed -and $ramSlotsUsed -gt 0)
# Repli quand la carte n'etiquette pas les canaux (frequent sur PC de marque : "DIMM1".."DIMM4") :
# 2 barrettes d'un kit apparie + slots de parite differente => dual-channel tres probable.
$ramDualProbable = $false; $ramSingleProbable = $false
if (-not $ramCanauxLisibles -and $ramSlotsUsed -eq 2) {
    $ramPNs  = @($ramSticks | ForEach-Object { "$($_.PartNumber)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $ramCaps = @($ramSticks | ForEach-Object { [long]$_.Capacity } | Select-Object -Unique)
    $ramSlotN = @($ramSticks | ForEach-Object { if ("$($_.DeviceLocator)" -match '(\d+)\s*$') { [int]$Matches[1] } })
    if ($ramPNs.Count -le 1 -and $ramCaps.Count -eq 1 -and $ramSlotN.Count -eq 2) {
        if (($ramSlotN[0] % 2) -ne ($ramSlotN[1] % 2)) { $ramDualProbable = $true }
        else { $ramSingleProbable = $true }
    }
}

# VRAM fiable : Win32_VideoController.AdapterRAM est limite a 4 Go (champ 32 bits).
# On lit la vraie VRAM dans le registre (HardwareInformation.qwMemorySize, 64 bits).
function Get-RealVramGB {
    param([string]$GpuName)
    try {
        $base = "HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
        Get-ChildItem $base -EA SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -EA SilentlyContinue
            if ($p.'DriverDesc' -eq $GpuName -and $p.'HardwareInformation.qwMemorySize') {
                return [math]::Round($p.'HardwareInformation.qwMemorySize'/1GB,0)
            }
        } | Where-Object { $_ } | Select-Object -First 1
    } catch { return $null }
}

$gpu = Get-CimInstance Win32_VideoController |
    Select-Object Name, DriverVersion,
        @{N='DriverDate';E={ $d=ConvertTo-SafeDate $_.DriverDate; if($d){$d.ToString('yyyy-MM-dd')}else{'?'} }},
        @{N='VRAM_GB';E={ $v=Get-RealVramGB $_.Name; if($v){$v}elseif($_.AdapterRAM){[math]::Round($_.AdapterRAM/1GB,1)}else{'?'} }}

# GPU principal = le vrai GPU dedie (NVIDIA/AMD/Intel), pas un ecran virtuel (Parsec, etc.)
$gpuReel = $gpu | Where-Object { $_.Name -match "NVIDIA|GeForce|RTX|GTX|AMD|Radeon|RX |Intel" -and $_.Name -notmatch "Parsec|Virtual|Remote|Meta|Mirror" } | Select-Object -First 1
if (-not $gpuReel) { $gpuReel = $gpu | Select-Object -First 1 }

# Vendor GPU pour le lien pilote (base sur le GPU reel)
$gpuVendor="Inconnu"; $gpuLink=""
if     ($gpuReel.Name -match "NVIDIA|GeForce|RTX|GTX"){ $gpuVendor="NVIDIA"; $gpuLink="https://www.nvidia.com/Download/index.aspx" }
elseif ($gpuReel.Name -match "AMD|Radeon|RX ")        { $gpuVendor="AMD";    $gpuLink="https://www.amd.com/fr/support" }
elseif ($gpuReel.Name -match "Intel")                 { $gpuVendor="Intel";  $gpuLink="https://www.intel.fr/content/www/fr/fr/download-center/home.html" }
Write-Log "CPU: $($cpu.Name) | CM: $($bb.Manufacturer) $($bb.Product) | RAM: $ramTotalGB Go | GPU: $($gpuReel.Name)" "OK"

# --- Resizable BAR (Smart Access Memory) : detection REELLE en lecture seule ---
#   NVIDIA  : nvidia-smi -> BAR1 total vs VRAM (definitif).
#   AMD/Intel : plages memoire 32 bits. ReBAR actif => le grand BAR passe > 4 Go
#               et disparait des plages 32 bits (il ne reste que des stubs < 64 Mo).
$rebarActif = $null   # $true / $false / $null (indetermine)
$rebarEtat  = "indetermine"
try {
    $gpuPnp = Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue |
              Where-Object { $_.DeviceID -like 'PCI\VEN_*' } | Select-Object -First 1
    if ($gpuPnp) {
        $rebarCapable = $gpuPnp.Name -match 'RTX\s?\d{4}|GTX\s?16\d{2}|RX\s?5[5-9]\d0|RX\s?[6-9]\d{3}|Arc'
        if ((Get-Command nvidia-smi -EA SilentlyContinue) -and $gpuPnp.Name -match 'NVIDIA|GeForce') {
            try {
                $ctx = (& nvidia-smi -q 2>$null) | Select-String 'BAR1 Memory Usage' -Context 0, 1
                $bar1 = if ($ctx -and $ctx.Context.PostContext[0] -match '(\d+)\s*MiB') { [int]$Matches[1] } else { 0 }
                $vram = [int]("$((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1))".Trim())
                if ($bar1 -gt 0 -and $vram -gt 0) {
                    if ($bar1 -ge $vram * 0.5) { $rebarActif = $true;  $rebarEtat = "ACTIF (BAR1 $bar1 Mo / VRAM $vram Mo)" }
                    else                       { $rebarActif = $false; $rebarEtat = "INACTIF (BAR1 $bar1 Mo pour $vram Mo de VRAM)" }
                }
            } catch {}
        }
        if ($null -eq $rebarActif) {
            $vramB = 0
            try {
                $vramB = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -EA SilentlyContinue |
                          Where-Object { $_.'HardwareInformation.qwMemorySize' } |
                          Sort-Object 'HardwareInformation.qwMemorySize' -Descending | Select-Object -First 1).'HardwareInformation.qwMemorySize'
            } catch {}
            $barMB = 0
            try {
                $barMB = (Get-CimAssociatedInstance -InputObject $gpuPnp -ResultClassName Win32_DeviceMemoryAddress -EA Stop |
                          ForEach-Object { [math]::Round(($_.EndingAddress - $_.StartingAddress + 1)/1MB) } |
                          Measure-Object -Maximum).Maximum
            } catch {}
            if ($barMB -ge 2048) {
                $rebarActif = $true; $rebarEtat = "ACTIF (BAR $barMB Mo)"
            } elseif ($rebarCapable -and $vramB -gt 2GB -and $barMB -ge 200 -and $barMB -le 400) {
                $rebarActif = $false; $rebarEtat = "INACTIF (BAR $barMB Mo pour $([math]::Round($vramB/1GB)) Go de VRAM)"
            } elseif ($rebarCapable -and $vramB -gt 2GB -and $barMB -gt 0 -and $barMB -lt 128) {
                $rebarActif = $true; $rebarEtat = "ACTIF (grand BAR passe au-dessus de 4 Go)"
            } elseif (-not $rebarCapable) {
                $rebarEtat = "GPU non concerne (anterieur RTX 20 / RX 5000)"
            } else {
                $rebarEtat = "indetermine (BAR $barMB Mo)"
            }
        }
    }
} catch {}
if ($gpuVendor -eq "NVIDIA" -or $gpuVendor -eq "AMD" -or $gpuVendor -eq "Intel") {
    Write-Log "Resizable BAR : $rebarEtat" $(if ($rebarActif -eq $false) { "WARN" } elseif ($rebarActif) { "OK" } else { "INFO" })
}

# ============================================================
#  2. DISQUES + SANTE SMART
# ============================================================
Write-Log "Analyse des disques..."
$disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
    [PSCustomObject]@{
        Nom=$_.FriendlyName; Type=$_.MediaType; TailleGB=[math]::Round($_.Size/1GB,0)
        Sante=$_.HealthStatus; Usure=$_.Wear
    }
}
$volumes = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } | ForEach-Object {
    [PSCustomObject]@{
        Lettre=$_.DriveLetter; FS=$_.FileSystemType
        TotalGB=[math]::Round($_.Size/1GB,0)
        LibreGB=[math]::Round($_.SizeRemaining/1GB,0)
        PctLibre= if($_.Size){[math]::Round($_.SizeRemaining/$_.Size*100,0)}else{0}
    }
}
# CrystalDiskInfo : export texte (mode standard, ecrit DiskInfo.txt a cote de l'exe)
$smartText = ""
if ($toolStatus.CDI -eq "OK") {
    try {
        $cdiExe = Get-ChildItem "$env:ProgramFiles\CrystalDiskInfo","$env:ProgramFiles (x86)\CrystalDiskInfo" -Filter "DiskInfo*.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
        if ($cdiExe) {
            & $cdiExe.FullName /CopyExit 2>$null
            Start-Sleep 3
            $cdiTxt = Join-Path $cdiExe.DirectoryName "DiskInfo.txt"
            if (Test-Path $cdiTxt) { $smartText = Get-Content $cdiTxt -Raw }
        }
    } catch { Write-Log "CrystalDiskInfo : $_" "WARN" }
}

# ============================================================
#  EQUILIBRE DE CONFIGURATION (observations, pas de % invente)
# ============================================================
# On NE calcule PAS de "pourcentage de bottleneck" (ca ne veut rien dire a froid).
# On applique des regles de bon sens et on signale des PISTES a verifier en charge.
Write-Log "Evaluation de l'equilibre de configuration..."
$balance = @()   # chaque entree : @{ Niveau='info|attention'; Constat='...' }

# --- Detection generation CPU (Intel Core iX-XXXX / AMD Ryzen X XXXX) ---
$cpuName = $cpu.Name
$cpuGen = $null; $cpuBrand = $null
if ($cpuName -match "Intel.*i[3579]-(\d{4,5})") {
    $cpuBrand = "Intel"
    $num = [int]$Matches[1]
    # i9-9900 -> gen 9 ; i7-10700 -> gen 10 ; i5-12400 -> gen 12
    $cpuGen = if ($num -ge 10000) { [math]::Floor($num/1000) } else { [math]::Floor($num/1000) }
} elseif ($cpuName -match "Ryzen\s+[3579]\s+(\d{4})") {
    $cpuBrand = "AMD"
    $num = [int]$Matches[1]
    # Ryzen 2600 -> serie 2000 ; 5600X -> 5000 ; 3700 -> 3000
    $cpuGen = [math]::Floor($num/1000)
}

# --- Detection gamme GPU approximative ---
$gpuName = $gpuReel.Name
$gpuTier = "inconnu"   # entree / milieu / haut / tres-haut
if ($gpuName -match "RTX\s*40(8|9)0|RTX\s*4090|RX\s*7900") { $gpuTier = "tres-haut" }
elseif ($gpuName -match "RTX\s*40(6|7)0|RTX\s*30(8|9)0|RX\s*7(7|8)00|RX\s*6(8|9)00") { $gpuTier = "haut" }
elseif ($gpuName -match "RTX\s*30(6|7)0|RTX\s*20(7|8)0|GTX\s*1080|RX\s*6(6|7)00|RX\s*5700") { $gpuTier = "milieu" }
elseif ($gpuName -match "GTX\s*16|GTX\s*10[567]0|RTX\s*3050|RX\s*6[45]00|RX\s*5[45]00") { $gpuTier = "entree-milieu" }
elseif ($gpuName -match "Intel.*(UHD|HD)\s*Graphics|Radeon.*Vega|Graphics$") { $gpuTier = "integre" }

# --- Regle 1 : RAM ---
if ($ramTotalGB -lt 16) {
    $balance += @{ Niveau="attention"; Constat="RAM de $ramTotalGB Go : sous 16 Go, c'est un goulot frequent sur les jeux modernes. Passer a 16 Go (voire 32) est souvent le meilleur rapport gain/prix." }
} elseif ($ramTotalGB -ge 16) {
    $balance += @{ Niveau="info"; Constat="RAM de $ramTotalGB Go : suffisant pour la majorite des jeux." }
}

# --- Regle 2 : dual-channel (canal REEL, pas le simple nombre de barrettes) ---
if ($ramSlotsUsed -eq 1) {
    $balance += @{ Niveau="attention"; Constat="Une seule barrette detectee : pas de dual-channel. Passer a 2 barrettes ameliore nettement les perfs, surtout sur GPU integre et jeux CPU-dependants." }
} elseif (-not $ramCanauxLisibles -and $ramDualProbable) {
    $balance += @{ Niveau="info"; Constat="$ramSlotsUsed barrettes identiques (kit apparie) dans des slots de parite differente : dual-channel tres probable, mais cette carte n'etiquette pas les canaux. Confirmer avec CPU-Z onglet Memory (doit afficher 'Dual')." }
} elseif (-not $ramCanauxLisibles -and $ramSingleProbable) {
    $balance += @{ Niveau="attention"; Constat="$ramSlotsUsed barrettes identiques mais dans des slots de MEME parite : souvent le meme canal = single channel. Cette carte n'etiquette pas les canaux ; verifier CPU-Z (onglet Memory doit afficher 'Dual'). Si single : deplacer une barrette d'un cran (souvent slots 2 et 4)." }
} elseif (-not $ramCanauxLisibles) {
    $balance += @{ Niveau="info"; Constat="$ramSlotsUsed barrettes detectees. Le canal de chaque barrette n'a pas pu etre lu : verifier dans le BIOS ou avec CPU-Z que le mode dual-channel est bien actif." }
} elseif ($ramNbCanaux -eq 1) {
    $balance += @{ Niveau="attention"; Constat="$ramSlotsUsed barrettes mais TOUTES sur le meme canal ($($ramCanaux[0])) : la machine tourne en single channel, la bande passante memoire est divisee par deux. C'est l'erreur de montage la plus courante. Deplacer une barrette dans un slot de l'autre canal (souvent les slots 2 et 4, ou A2 et B2) : gain typique de 10 a 20 % de FPS, gratuit." }
} else {
    $balance += @{ Niveau="info"; Constat="$ramSlotsUsed barrettes reparties sur $ramNbCanaux canaux : mode multi-canal actif, c'est bien." }
}

# --- Regle 2bis : XMP / vitesse RAM ---
# Si la RAM tourne a une vitesse "de base" typique (2133/2400 DDR4, 4800 DDR5),
# XMP/EXPO n'est probablement pas active dans le BIOS -> perte de perfs en jeu.
$vitesseBase = @(2133, 2400, 4800, 5600)   # freq JEDEC par defaut courantes
$freqActuelle = if ($ramConfigured) { $ramConfigured } else { $ramSpeed }
if ($freqActuelle) {
    if ($vitesseBase -contains [int]$freqActuelle) {
        $balance += @{ Niveau="attention"; Constat="RAM a $freqActuelle MHz = frequence par defaut (JEDEC). Si les barrettes sont prevues plus rapides (3200/3600 MHz ou plus), XMP/EXPO n'est pas active dans le BIOS -> perte de perfs en jeu. A activer dans l'UEFI (profil XMP pour Intel, EXPO pour AMD). Verifier la vitesse annoncee des barrettes." }
    } else {
        $balance += @{ Niveau="info"; Constat="RAM a $freqActuelle MHz : au-dessus du JEDEC de base, XMP/EXPO probablement actif. (A confirmer avec la vitesse annoncee des barrettes.)" }
    }
}

# --- Regle 3 : disque systeme HDD vs SSD ---
$sysDisk = $disks | Where-Object { $_.Type -eq "HDD" }
$hasSSD = $disks | Where-Object { $_.Type -eq "SSD" -or $_.Type -eq "SSD (NVMe)" -or $_.Type -match "SSD" }
if ($disks -and -not $hasSSD) {
    $balance += @{ Niveau="attention"; Constat="Aucun SSD detecte : le disque est un goulot majeur (temps de chargement, reactivite Windows). Un SSD est l'upgrade le plus rentable sur une machine ancienne." }
} elseif ($hasSSD) {
    $balance += @{ Niveau="info"; Constat="SSD present : bon pour les chargements et la reactivite." }
}

# --- Regle 4 : equilibre CPU / GPU ---
if ($gpuTier -eq "integre") {
    $balance += @{ Niveau="attention"; Constat="GPU integre (pas de carte graphique dediee) : c'est le facteur limitant principal en jeu. Une carte graphique dediee changerait tout." }
} elseif ($cpuBrand -and $cpuGen) {
    $cpuAncien = ($cpuBrand -eq "Intel" -and $cpuGen -le 8) -or ($cpuBrand -eq "AMD" -and $cpuGen -le 2)
    $cpuMoyen  = ($cpuBrand -eq "Intel" -and ($cpuGen -eq 9 -or $cpuGen -eq 10)) -or ($cpuBrand -eq "AMD" -and ($cpuGen -eq 3 -or $cpuGen -eq 5))
    if ($cpuAncien -and ($gpuTier -eq "haut" -or $gpuTier -eq "tres-haut")) {
        $balance += @{ Niveau="attention"; Constat="CPU $cpuBrand generation $cpuGen (ancien) associe a un GPU $gpuTier de gamme : risque de bridage CPU, surtout en 1080p/1440p ou haut rafraichissement. A verifier en charge (utilisation CPU vs GPU pendant un jeu)." }
    } elseif ($cpuMoyen -and $gpuTier -eq "tres-haut") {
        $balance += @{ Niveau="attention"; Constat="CPU $cpuBrand generation $cpuGen avec un GPU tres haut de gamme : le CPU peut brider en 1080p. Moins genant en 4K ou le GPU redevient le facteur limitant." }
    } else {
        $balance += @{ Niveau="info"; Constat="CPU ($cpuBrand gen $cpuGen) et GPU ($gpuTier) globalement coherents. Pas de desequilibre evident sur la config." }
    }
} else {
    $balance += @{ Niveau="info"; Constat="Impossible d'evaluer precisement l'equilibre CPU/GPU (modele non reconnu). A juger en charge avec un overlay de monitoring." }
}

# --- Regle 5 : Resizable BAR ---
if ($rebarActif -eq $false) {
    $balance += @{ Niveau="attention"; Constat="Resizable BAR INACTIF sur la carte graphique. A activer dans le BIOS ('Above 4G Decoding' = Enabled + 'Re-Size BAR Support' = Enabled) : gain typique 5 a 15 % selon les jeux, gratuit. Verifier ensuite dans NVIDIA App / AMD Software." }
} elseif ($rebarActif -eq $true) {
    $balance += @{ Niveau="info"; Constat="Resizable BAR actif : rien a faire de ce cote." }
}

Write-Log "Equilibre : $($balance.Count) observation(s)." "OK"

# ============================================================
#  3. TEMPERATURES (LibreHardwareMonitor via WMI)
# ============================================================
Write-Log "Lecture des temperatures..."
$temps = @()
# Tentative 1 : capteur thermique ACPI natif
try {
    $thermal = Get-CimInstance -Namespace "root/wmi" -ClassName MSAcpi_ThermalZoneTemperature -EA SilentlyContinue
    foreach ($t in $thermal) {
        $c = [math]::Round(($t.CurrentTemperature/10)-273.15,1)
        $temps += [PSCustomObject]@{ Capteur="Zone thermique ACPI"; TempC=$c }
    }
} catch {}
# Note : LibreHardwareMonitor donne des temps GPU/CPU par coeur bien plus precises
# en le lancant avec son option de rapport. On signale sa presence dans le rapport.
if ($temps.Count -eq 0) { Write-Log "Capteurs ACPI non exposes (frequent). LHM disponible: $($toolStatus.LHM)" "WARN" }

# ============================================================
#  4. PILOTES (tries par anciennete)
# ============================================================
Write-Log "Inventaire des pilotes..."
# Categories de pilotes qui comptent vraiment (jeu, connectivite, materiel principal)
function Get-DriverCategory {
    param([string]$Name, [string]$Vendor)
    $t = "$Name $Vendor"
    if ($t -match "NVIDIA|GeForce|RTX|GTX|Radeon|AMD.*Graphics|Intel.*Graphics|Arc") { return "GPU" }
    if ($t -match "Ethernet|Realtek.*GbE|Gaming.*Controller|Wi-?Fi|Wireless|802\.11|Killer|Network Adapter") { return "Reseau" }
    if ($t -match "High Definition Audio|Realtek.*Audio|Audio.*Controller|USB Audio|Sound") { return "Audio" }
    if ($t -match "AHCI|NVMe|SATA|Storage Controller|RAID|Disk drive") { return "Stockage" }
    if ($t -match "Chipset|SMBus|LPC Controller|PCI Express Root|Management Engine|Serial IO|Z\d90|B\d50|X\d70") { return "Chipset" }
    if ($t -match "Bluetooth") { return "Bluetooth" }
    return "Systeme"
}
$ordreCategorie = @{ "GPU"=1; "Chipset"=2; "Reseau"=3; "Stockage"=4; "Audio"=5; "Bluetooth"=6; "Systeme"=7 }

$drivers = Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue |
    Where-Object { $_.DeviceName -and $_.DriverVersion } |
    ForEach-Object {
        $d = ConvertTo-SafeDate $_.DriverDate
        $cat = Get-DriverCategory $_.DeviceName $_.Manufacturer
        [PSCustomObject]@{
            Peripherique=$_.DeviceName; Fabricant=$_.Manufacturer
            Version=$_.DriverVersion; DateObj=$d
            Date= if($d){$d.ToString('yyyy-MM-dd')}else{'?'}
            AgeAns= if($d){[math]::Round(((Get-Date)-$d).Days/365,1)}else{99}
            Categorie=$cat
            Tri=$ordreCategorie[$cat]
        }
    }
# Pilotes "cles" (materiel important) vs pilotes systeme Windows
$driversKey = $drivers | Where-Object { $_.Categorie -ne "Systeme" } | Sort-Object Tri, Peripherique
$driversSys = $drivers | Where-Object { $_.Categorie -eq "Systeme" }
Write-Log "$($drivers.Count) pilotes ($($driversKey.Count) cles, $($driversSys.Count) systeme)." "OK"

# ============================================================
#  5. SANTE OS (sfc + DISM)
# ============================================================
$sfcResult = "Non execute"; $dismResult = "Non execute"
if ($Fast) {
    $sfcResult = "Saute (mode -Fast)"; $dismResult = "Saute (mode -Fast)"
    Write-Log "sfc + DISM sautes (mode -Fast). Pour un controle integrite complet : relancer sans -Fast." "WARN"
}
elseif ($Interactive -or $ReportOnly) {
    Write-Log "Verification integrite OS (sfc)... (peut durer plusieurs minutes)"
    try {
        $sfcRaw = (sfc /scannow) 2>&1 | Out-String
        $sfc = $sfcRaw -replace "`0",""   # sortie UTF-16 : on retire les octets nuls
        $sfcCode = $LASTEXITCODE

        # La sortie console de sfc est parfois vide en PS 5.1 (il ecrit en bas niveau).
        # Fallback fiable : lire la fin du log CBS que sfc ecrit toujours.
        if ([string]::IsNullOrWhiteSpace($sfc) -or $sfc.Length -lt 20) {
            $cbs = "$env:SystemRoot\Logs\CBS\CBS.log"
            if (Test-Path $cbs) {
                $tail = Get-Content $cbs -Tail 400 -EA SilentlyContinue | Where-Object { $_ -match "SR |\[SR\]" }
                $sfc = ($tail | Select-Object -Last 40) -join "`n"
            }
        }

        # Marqueurs [SR] du log CBS : toujours en anglais, quelle que soit la langue de Windows.
        $cbsCorrupt = $false; $cbsUnfixable = $false
        $cbsLog = "$env:SystemRoot\Logs\CBS\CBS.log"
        if (Test-Path $cbsLog) {
            $srTail = Get-Content $cbsLog -Tail 600 -EA SilentlyContinue | Where-Object { $_ -match '\[SR\]' }
            if ($srTail -match 'Cannot repair member file|Cannot repair|could not repair') { $cbsUnfixable = $true }
            if ($srTail -match 'Repairing \d+ component|Repaired file|Repairing corrupted file') { $cbsCorrupt = $true }
        }
        # Texte console sfc : FR / EN / IT / DE / ES (accents remplaces par . dans les motifs)
        if     ($sfc -match "did not find any integrity|n'a trouv.*aucune violation|aucune violation d|no.*integrity violations|non ha rilevato alcuna violazione|keine Integrit.tsverletzungen|no encontr. ninguna infracci.n") { $sfcResult="OK - aucune corruption" }
        elseif ($sfc -match "repair pending|reparation.*en attente|requires a reboot|redemarrage.*requis|redemarrer|riparazione in sospeso|riavvi|Neustart erforderlich|requiere reiniciar") { $sfcResult="Reparation en attente - REDEMARRER puis relancer" }
        elseif ($sfc -match "successfully repaired|a r.par|r.paration.*termin|Repairing|ha riparato|file danneggiati.*riparat|reparado correctamente|erfolgreich repariert") { $sfcResult="Corruptions reparees" }
        elseif ($cbsUnfixable -or ($sfc -match "found corrupt.*could not|impossible.*r.parer|n'a pas pu r.parer|unable to fix|non . stato in grado di ripar|impossibile ripar|no pudo repar|konnte.*nicht reparier")) { $sfcResult="Corruptions NON reparees - voir DISM" }
        elseif ($sfc -match "could not perform|unable to start|impossible d'ex.cuter|impossibile eseguire|konnte.*nicht ausgef")               { $sfcResult="Erreur d'execution" }
        elseif ($cbsCorrupt)                                                                                          { $sfcResult="Corruptions reparees" }
        elseif ($sfcCode -eq 0)                                                                                       { $sfcResult="OK (code retour 0)" }
        else { $sfcResult="Termine (voir log CBS)" }
        Write-Log "sfc : $sfcResult" "OK"
    } catch { $sfcResult="Erreur : $_"; Write-Log "sfc erreur" "ERROR" }

    Write-Log "Verification image Windows (DISM)..."
    Write-Host "  >> DISM analyse et repare l'image Windows. C'est l'etape la plus longue" -ForegroundColor Cyan
    Write-Host "     (5 a 30 min ; plus si l'image doit etre reparee depuis Windows Update)." -ForegroundColor Cyan
    Write-Host "     L'affichage peut sembler fige : c'est NORMAL, ca travaille." -ForegroundColor Cyan
    try {
        $dismRaw  = (DISM /Online /Cleanup-Image /RestoreHealth) 2>&1 | Out-String
        $dism     = $dismRaw -replace "`0",""
        $dismCode = $LASTEXITCODE
        # Le code retour de DISM est fiable quelle que soit la langue ; le texte sert juste
        # a distinguer "deja saine" de "reparee".
        if     ($dism -match "0x800f081f|source files could not be found|fichiers sources.*introuvables|impossibile trovare i file di origine|Quelldateien.*nicht gefunden|no se encontraron los archivos de origen") {
            $dismResult = "Sources introuvables (0x800f081f) - relancer connecte a Internet" }
        elseif ($dism -match "corruption was repaired|a repare.*corruption|riparato.*danneggiament|corrupci.n.*reparad|Besch.digung.*behoben|restored the|restaur") {
            $dismResult = "Image reparee (corruption corrigee)" }
        elseif ($dism -match "no component store corruption|aucune corruption du magasin|nessun danneggiamento.*archivi|sin da.os.*almac|keine.*Besch.digung des Komponentenspeichers") {
            $dismResult = "OK - image saine (aucune corruption)" }
        elseif ($dismCode -eq 0)    { $dismResult = "OK (code retour 0)" }
        elseif ($dismCode -eq 3010) { $dismResult = "OK - REDEMARRAGE requis pour finaliser" }
        else                        { $dismResult = "Termine avec code $dismCode - voir $env:SystemRoot\Logs\DISM\dism.log" }
        Write-Log "DISM : $dismResult (code $dismCode)" "OK"
    } catch { $dismResult="Erreur : $_"; Write-Log "DISM erreur" "ERROR" }
}

# ============================================================
#  6. DEMARRAGE (liste + desactivation interactive)
# ============================================================
Write-Log "Analyse du demarrage..."
$startupItems = @()
$runKeys = @(
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run"
)
foreach ($k in $runKeys) {
    if (Test-Path $k) { (Get-Item $k).Property | ForEach-Object {
        $startupItems += [PSCustomObject]@{ Name=$_; Command=(Get-ItemProperty $k).$_; Source=$k; Type="Run"; Status="Actif" }
    }}
}
foreach ($f in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup","$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")) {
    if (Test-Path $f) { Get-ChildItem $f -File -EA SilentlyContinue | ForEach-Object {
        $startupItems += [PSCustomObject]@{ Name=$_.Name; Command=$_.FullName; Source=$f; Type="Folder"; Status="Actif" }
    }}
}

# --- Source supplementaire 1 : taches planifiees declenchees au logon ---
try {
    Get-ScheduledTask -EA SilentlyContinue | Where-Object {
        $_.State -ne "Disabled" -and ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match "LogonTrigger" })
    } | ForEach-Object {
        # On ignore les taches Microsoft systeme (dossier \Microsoft\Windows\) : trop risque d'y toucher
        if ($_.TaskPath -notmatch "^\\Microsoft\\Windows\\") {
            $cmd = ($_.Actions | ForEach-Object { $_.Execute }) -join " "
            $startupItems += [PSCustomObject]@{ Name=$_.TaskName; Command="$($_.TaskPath)$($_.TaskName) [$cmd]"; Source=$_.TaskPath; Type="Task"; Status="Actif" }
        }
    }
} catch { Write-Log "Taches planifiees : $_" "WARN" }

# --- Source supplementaire 2 : apps UWP/Store au demarrage ---
# Elles sont gerees via la cle StartupApproved (valeur binaire : 1er octet pair=actif, impair=desactive)
$uwpKeys = @(
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\StartupFolder",
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run",
    "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run"
)
foreach ($k in $uwpKeys) {
    if (Test-Path $k) {
        $props = Get-Item $k
        $props.Property | ForEach-Object {
            $val = (Get-ItemProperty $k).$_
            # 1er octet : 2/6 = active, 3/... (impair) = deja desactive
            $etat = if ($val -and ($val[0] % 2 -eq 0)) { "Actif" } else { "Desactive" }
            $startupItems += [PSCustomObject]@{ Name=$_; Command="(App Store/UWP)"; Source=$k; Type="UWP"; Status=$etat }
        }
    }
}

Write-Log "$($startupItems.Count) elements de demarrage (Run, dossier, taches, UWP)." "OK"

# --- Classification de chaque element : vert (safe a couper) / rouge (garder) / orange (demander) ---
# Conservateur : dans le doute -> orange (on demande). Rien de risque n'est jamais en vert.
function Get-StartupClass {
    param($Name, $Command)
    $n = "$Name $Command"
    # ROUGE : composants systeme, securite, audio, anticheats -> ne jamais couper
    if ($n -match "SecurityHealth|Defender|RtkAud|Realtek|NVDisplay|nvcontainer|igfx|Vanguard|EasyAntiCheat|BattlEye|Waves|SynTP|Sonic") {
        return "rouge"
    }
    # VERT : navigateurs precharges, updaters redondants, bloatware helper connu -> couper safe partout
    if ($n -match "chrome.*--no-startup-window|msedge.*--no-startup-window|GoogleChromeAutoLaunch|MicrosoftEdgeAutoLaunch") { return "vert" }
    if ($n -match "jusched|SunJavaUpdate|AdobeAAMUpdater|Adobe Updater|AdobeGCInvoker|iTunesHelper|QuickTime|SquirrelMachineInstalls.*checkInstall|Wondershare Helper|CCleaner.*Monitoring|Spotify.*autostart") { return "vert" }
    # VERT : apps Store non essentielles au demarrage
    if ($n -match "^People$|Mobile connect|Phone Link|Your Phone|Cortana|Xbox App|GameBar|Feedback|Get Help|Solitaire|MicrosoftStickyNotes") { return "vert" }
    # ORANGE : tout le reste (cloud, lanceurs de jeux, peripheriques, apps pro, Teams, Spotify, inconnus) -> demander
    return "orange"
}

foreach ($item in $startupItems) {
    $item | Add-Member -NotePropertyName Classe -NotePropertyValue (Get-StartupClass $item.Name $item.Command) -Force
    # Cle de regroupement : nom normalise (sans GUID/suffixe) pour reunir les entrees d'une meme app
    # (ex: OneDrive en Run + Task + UWP = une seule app). On enleve les identifiants variables.
    $cle = $item.Name -replace '_[0-9A-Fa-f]{16,}.*$','' -replace '-S-1-5-.*$','' -replace '\{.*\}','' -replace '\d{3,}.*$',''
    $cle = $cle.Trim().ToLower()
    if ([string]::IsNullOrWhiteSpace($cle)) { $cle = $item.Name.ToLower() }
    $item | Add-Member -NotePropertyName CleGroupe -NotePropertyValue $cle -Force
}

# Desactive un element de demarrage selon sa source (Run/Folder/Task/UWP)
function Disable-StartupItem {
    param($Item)
    switch ($Item.Type) {
        "Run"    { Remove-ItemProperty -Path $Item.Source -Name $Item.Name -Force -EA Stop }
        "Folder" { Remove-Item -Path $Item.Command -Force -EA Stop }   # supprime le raccourci du dossier Startup
        "Task"   { Disable-ScheduledTask -TaskPath $Item.Source -TaskName $Item.Name -EA Stop | Out-Null }
        "UWP"    {
            # Marque l'app comme desactivee dans StartupApproved (1er octet impair = desactive)
            $bytes = (Get-ItemProperty $Item.Source).($Item.Name)
            if ($bytes) { $bytes[0] = 3 } else { $bytes = [byte[]](3,0,0,0,0,0,0,0,0,0,0,0) }
            Set-ItemProperty -Path $Item.Source -Name $Item.Name -Value $bytes -Type Binary -Force -EA Stop
        }
        default  { Remove-ItemProperty -Path $Item.Source -Name $Item.Name -Force -EA Stop }
    }
}

if ($Interactive -and $startupItems.Count -gt 0) {
    # Tous les elements actionnables (toutes sources), hors deja desactives
    $runItems = $startupItems | Where-Object { $_.Status -eq "Actif" }
    $verts   = $runItems | Where-Object { $_.Classe -eq "vert" }
    $rouges  = $runItems | Where-Object { $_.Classe -eq "rouge" }
    $oranges = $runItems | Where-Object { $_.Classe -eq "orange" }

    # ROUGE : signale ce qui est garde d'office (pas de question), dedoublonne par app
    if ($rouges) {
        Write-Host "`n=== Demarrage : gardes d'office (systeme / securite / anticheat) ===" -ForegroundColor DarkGray
        $rouges | Group-Object CleGroupe | ForEach-Object { Write-Host "  [garde] $($_.Group[0].Name)" -ForegroundColor DarkGray }
    }

    # VERT : une seule question pour tout le lot (apps uniques)
    if ($verts) {
        $vertsGroupes = $verts | Group-Object CleGroupe
        Write-Host "`n=== Demarrage : lot 'sur a desactiver' ===" -ForegroundColor Green
        Write-Host "Navigateurs precharges, updaters redondants, helpers inutiles. Safe a couper :" -ForegroundColor Gray
        $vertsGroupes | ForEach-Object { Write-Host "  - $($_.Group[0].Name)" -ForegroundColor Green }
        if (Confirm-Action "Desactiver tout ce lot d'un coup ?") {
            foreach ($grp in $vertsGroupes) {
                foreach ($item in $grp.Group) {
                    try { Disable-StartupItem $item; $item.Status="Desactive"; Write-Log "Desactive (lot vert): $($item.Name) [$($item.Type)]" "OK" }
                    catch { Write-Log "Echec: $($item.Name)" "ERROR" }
                }
            }
        }
    }

    # ORANGE : au cas par cas, UNE question par app (toutes ses sources traitees ensemble)
    if ($oranges) {
        Write-Host "`n=== Demarrage : a decider (depend de l'usage) ===" -ForegroundColor Yellow
        Write-Host "O = desactiver, N = garder`n" -ForegroundColor Gray
        foreach ($grp in ($oranges | Group-Object CleGroupe)) {
            $ref = $grp.Group[0]
            $sources = ($grp.Group | ForEach-Object { $_.Type } | Sort-Object -Unique) -join ", "
            Write-Host "[$($ref.Name)] -> $($ref.Command)" -ForegroundColor White
            if ($grp.Count -gt 1) { Write-Host "   (presente dans : $sources - la reponse s'applique a toutes)" -ForegroundColor DarkGray }
            if (Confirm-Action "   Desactiver ?") {
                foreach ($item in $grp.Group) {
                    try { Disable-StartupItem $item; $item.Status="Desactive"; Write-Log "Desactive: $($item.Name) [$($item.Type)]" "OK" }
                    catch { Write-Log "Echec: $($item.Name)" "ERROR" }
                }
            }
        }
    }
}

# ============================================================
#  7. RESIDUS (detection + suppression sur validation)
# ============================================================
Write-Log "Recherche de residus..."
$residues = @()
$installed = @()
$installed += (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*" -EA SilentlyContinue).DisplayName
$installed += (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -EA SilentlyContinue).DisplayName
$installed = $installed | Where-Object { $_ }

# Garde-fou 1 : detecter les jeux installes via les launchers (Epic/Steam),
# qui n'apparaissent PAS dans la liste Uninstall classique.
$gamesInstalled = $false
$launcherPaths = @(
    "$env:ProgramData\Epic\EpicGamesLauncher",
    "${env:ProgramFiles}\Epic Games",
    "${env:ProgramFiles(x86)}\Epic Games",
    "${env:ProgramFiles(x86)}\Steam\steamapps",
    "${env:ProgramFiles}\Steam\steamapps",
    "${env:ProgramFiles(x86)}\Riot Games",
    "C:\Riot Games"
)
foreach ($lp in $launcherPaths) { if (Test-Path $lp) { $gamesInstalled = $true; break } }

$knownLeftovers = @("Epic Games","Fortnite","EasyAntiCheat","BattlEye","Riot Games","Rockstar Games","Ubisoft","Origin","Battle.net")
$seuilJours = 30   # un dossier modifie il y a moins de 30 j = probablement actif, pas un residu

foreach ($root in @("$env:LOCALAPPDATA","$env:APPDATA","$env:ProgramData","${env:ProgramFiles}","${env:ProgramFiles(x86)}")) {
    if (-not (Test-Path $root)) { continue }
    Get-ChildItem $root -Directory -EA SilentlyContinue | ForEach-Object {
        $dir=$_
        foreach ($kw in $knownLeftovers) {
            if ($dir.Name -like "*$kw*" -and -not ($installed | Where-Object { $_ -like "*$kw*" })) {
                # Garde-fou 2 : si un launcher de jeux est installe, ces dossiers sont
                # tres probablement actifs (anticheats, configs) -> ne pas proposer.
                if ($gamesInstalled -and $kw -match "Epic|Fortnite|EasyAntiCheat|BattlEye|Riot") { return }
                # Garde-fou 3 : dossier modifie recemment = actif, pas un residu.
                $ageJours = ((Get-Date) - $dir.LastWriteTime).Days
                if ($ageJours -lt $seuilJours) { return }
                $size=(Get-ChildItem $dir.FullName -Recurse -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum
                $residues += [PSCustomObject]@{ Name=$dir.Name; Path=$dir.FullName; SizeMB=if($size){[math]::Round($size/1MB,1)}else{0}; Related=$kw; DernierAcces=$dir.LastWriteTime.ToString('yyyy-MM-dd'); Deleted="Non" }
            }
        }
    }
}
$residues = $residues | Sort-Object SizeMB -Descending
if ($Interactive -and $residues.Count -gt 0) {
    Write-Host "`n=== Residus (dossiers orphelins, non touches depuis >$seuilJours j) ===" -ForegroundColor Yellow
    Write-Host "Verifie saves/configs avant suppression.`n" -ForegroundColor Gray
    foreach ($r in $residues) {
        Write-Host "[$($r.Name)] $($r.SizeMB) Mo - dernier acces $($r.DernierAcces) -> $($r.Path)" -ForegroundColor White
        if (Confirm-Action "   Supprimer ?") {
            try { Remove-Item $r.Path -Recurse -Force -EA Stop; $r.Deleted="Oui"; Write-Log "Supprime: $($r.Path)" "OK" }
            catch { Write-Log "Echec suppression: $($r.Path)" "ERROR" }
        }
    }
} elseif ($Interactive) {
    Write-Host "`nAucun residu orphelin detecte (les dossiers de jeux actifs sont ignores)." -ForegroundColor Green
}

# ============================================================
#  8. NETTOYAGE SUR (categories jetables uniquement)
# ============================================================
# On ne touche QU'A des fichiers connus comme jetables : temp, cache Update,
# corbeille, vignettes, rapports d'erreur, Windows.old. Aucune suppression
# de "doublons" (dangereux). Espace mesure avant/apres et reporte.
Write-Log "Nettoyage sur des fichiers jetables..."
$cleanReport = @()

function Get-FolderSizeMB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return 0 }
    $s = (Get-ChildItem $Path -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
    if ($s) { [math]::Round($s/1MB,1) } else { 0 }
}

# Cibles jetables (chemin + libelle)
$cleanTargets = @(
    @{ Label="Fichiers temp utilisateur"; Path="$env:TEMP" },
    @{ Label="Fichiers temp Windows";     Path="$env:SystemRoot\Temp" },
    @{ Label="Cache Windows Update";       Path="$env:SystemRoot\SoftwareDistribution\Download" },
    @{ Label="Rapports d'erreur (WER)";    Path="$env:ProgramData\Microsoft\Windows\WER" },
    @{ Label="Cache vignettes";            Path="$env:LOCALAPPDATA\Microsoft\Windows\Explorer" }
)

if ($Interactive) {
    Write-Host "`n=== Nettoyage sur ===" -ForegroundColor Cyan
    Write-Host "Uniquement des fichiers jetables (temp, cache Update, corbeille...). Rien de risque.`n" -ForegroundColor Gray
    if (Confirm-Action "Lancer le nettoyage sur des categories jetables ?") {
        foreach ($t in $cleanTargets) {
            $before = Get-FolderSizeMB $t.Path
            if ($before -gt 0) {
                # Cache vignettes : ne supprimer que les fichiers thumbcache*, pas tout Explorer
                if ($t.Label -eq "Cache vignettes") {
                    Get-ChildItem $t.Path -Filter "thumbcache_*.db" -Force -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
                } else {
                    Get-ChildItem $t.Path -Recurse -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue
                }
                $after = Get-FolderSizeMB $t.Path
                $freed = [math]::Round($before - $after,1)
                if ($freed -lt 0) { $freed = 0 }   # des fichiers temp se recreent pendant la mesure -> jamais de negatif
                $cleanReport += [PSCustomObject]@{ Categorie=$t.Label; LibereMB=$freed }
                Write-Log "$($t.Label) : $freed Mo liberes" "OK"
            }
        }
        # Corbeille
        try { Clear-RecycleBin -Force -EA SilentlyContinue; $cleanReport += [PSCustomObject]@{ Categorie="Corbeille"; LibereMB="videe" }; Write-Log "Corbeille videe" "OK" } catch {}

        # Caches shaders GPU : les vieux caches causent des saccades apres MAJ pilote.
        # On les vide, ils se reconstruisent proprement au prochain lancement des jeux. Sans risque.
        $shaderCaches = @(
            "$env:LOCALAPPDATA\D3DSCache",
            "$env:LOCALAPPDATA\NVIDIA\DXCache",
            "$env:LOCALAPPDATA\NVIDIA\GLCache",
            "$env:LOCALAPPDATA\AMD\DxCache",
            "$env:LOCALAPPDATA\AMD\GLCache"
        )
        $shaderMB = 0
        foreach ($cache in $shaderCaches) {
            if (Test-Path $cache) {
                $avant = Get-FolderSizeMB $cache
                Remove-Item -Path "$cache\*" -Recurse -Force -EA SilentlyContinue
                $shaderMB += $avant
            }
        }
        if ($shaderMB -gt 0) { $cleanReport += [PSCustomObject]@{ Categorie="Caches shaders GPU (anti-saccades)"; LibereMB=[math]::Round($shaderMB,1) }; Write-Log "Caches shaders vides : $([math]::Round($shaderMB,1)) Mo" "OK" }

        # Nettoyage de disque Windows (cleanmgr) sur un profil predefini, silencieux
        # sageset 64 = jeu de cases pre-coche cote script ; on lance sagerun
        try {
            # Pre-selection des categories via registre VolumeCaches (StateFlags0064)
            $vc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches"
            Get-ChildItem $vc -EA SilentlyContinue | ForEach-Object {
                Set-ItemProperty -Path $_.PSPath -Name "StateFlags0064" -Value 2 -Type DWord -Force -EA SilentlyContinue
            }
            Write-Log "Lancement de cleanmgr (Nettoyage de disque Windows)..."
            Start-Process -FilePath "cleanmgr.exe" -ArgumentList "/sagerun:64" -Wait -EA SilentlyContinue
            $cleanReport += [PSCustomObject]@{ Categorie="Nettoyage de disque Windows (cleanmgr)"; LibereMB="execute" }
            Write-Log "cleanmgr termine." "OK"
        } catch { Write-Log "cleanmgr : $_" "WARN" }
    }
} else {
    # Mode rapport seul : on mesure sans supprimer (indicatif)
    foreach ($t in $cleanTargets) {
        $sz = Get-FolderSizeMB $t.Path
        if ($sz -gt 0) { $cleanReport += [PSCustomObject]@{ Categorie=$t.Label; LibereMB="$sz (a nettoyer)" } }
    }
}

# ============================================================
#  8bis. ESPACE DISQUE : ou est passee la place (lecture seule + 3 actions sures)
# ============================================================
Write-Log "Analyse de l'espace disque (gros dossiers, apps, recuperable)..."
Write-Host "  >> Scan des gros dossiers en cours. Sur un disque tres rempli, ca peut prendre" -ForegroundColor Cyan
Write-Host "     plusieurs minutes. Patiente, l'affichage reprend ensuite." -ForegroundColor Cyan
$sysDrive = $env:SystemDrive   # ex: C:
$bigFolders = @()
$bigApps = @()
$recoverable = @()   # actions sures : @{ Item; TailleMB; Action(scriptblock ou $null) }

# --- Top 15 des plus gros dossiers de premier niveau sur C: ---
try {
    $roots = @("$sysDrive\", "$env:USERPROFILE", "$env:ProgramFiles", "${env:ProgramFiles(x86)}", "$env:LOCALAPPDATA")
    $seen = @{}
    $racines = @("$sysDrive\Program Files","$sysDrive\Program Files (x86)","$sysDrive\Users","$sysDrive\Windows","$sysDrive\ProgramData")
    $iR = 0; $totalR = $racines.Count
    foreach ($r in $racines) {
        $iR++
        if (-not (Test-Path $r)) { continue }
        Write-Progress -Activity "Analyse de l'espace disque" -Status "Scan de $r" -PercentComplete (($iR / $totalR) * 100)
        Get-ChildItem $r -Directory -EA SilentlyContinue | ForEach-Object {
            $sz = (Get-ChildItem $_.FullName -Recurse -File -Force -EA SilentlyContinue | Measure-Object Length -Sum).Sum
            if ($sz -gt 500MB) {
                $bigFolders += [PSCustomObject]@{ Chemin=$_.FullName; TailleGB=[math]::Round($sz/1GB,1) }
            }
        }
    }
    Write-Progress -Activity "Analyse de l'espace disque" -Completed
    $bigFolders = $bigFolders | Sort-Object TailleGB -Descending | Select-Object -First 15
    Write-Log "$($bigFolders.Count) gros dossiers reperes." "OK"
} catch { Write-Log "Analyse gros dossiers : $_" "WARN" }

# --- Grosses applications installees (avec taille estimee) ---
try {
    $uninstallKeys = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    foreach ($uk in $uninstallKeys) {
        Get-ItemProperty $uk -EA SilentlyContinue | Where-Object { $_.DisplayName -and $_.EstimatedSize } | ForEach-Object {
            $bigApps += [PSCustomObject]@{ Nom=$_.DisplayName; TailleMB=[math]::Round($_.EstimatedSize/1024,0) }
        }
    }
    $bigApps = $bigApps | Sort-Object TailleMB -Descending | Select-Object -First 12
    Write-Log "$($bigApps.Count) grosses apps listees." "OK"
} catch { Write-Log "Analyse apps : $_" "WARN" }

# --- Espace recuperable par actions sures ---
# 1) Windows.old
$winOld = "$sysDrive\Windows.old"
if (Test-Path $winOld) {
    $szMB = Get-FolderSizeMB $winOld
    $recoverable += [PSCustomObject]@{ Item="Windows.old (ancienne installation)"; TailleMB=$szMB; Type="winold" }
}
# 2) Hibernation (hiberfil.sys)
$hiber = "$sysDrive\hiberfil.sys"
if (Test-Path $hiber) {
    $szMB = [math]::Round((Get-Item $hiber -Force -EA SilentlyContinue).Length/1MB,0)
    $recoverable += [PSCustomObject]@{ Item="Fichier d'hibernation (hiberfil.sys)"; TailleMB=$szMB; Type="hiber" }
}
# 3) Anciens points de restauration (on ne garde que le dernier)
try {
    $rp = Get-ComputerRestorePoint -EA SilentlyContinue
    if ($rp -and $rp.Count -gt 1) {
        $recoverable += [PSCustomObject]@{ Item="Anciens points de restauration ($($rp.Count) au total, garde le plus recent)"; TailleMB="variable"; Type="restore" }
    }
} catch {}

# ============================================================
#  MOTEUR DE REGLES : espace disque recuperable, par categorie
#  Chaque regle = un chemin/une mesure + une classe de surete :
#    "sur"     : cache qui se regenere, aucun risque -> nettoyage groupe
#    "prudent" : recuperable mais on perd quelque chose (rollback, MAJ desinstallables)
#    "manuel"  : fichiers du client ou casse la reparation d'apps -> on signale seulement
#  Lecture seule ici ; l'application se fait plus bas, avec confirmation.
# ============================================================
Write-Log "Moteur de regles : espace disque recuperable..."
function Get-PathMB { param([string[]]$P)
    $t = 0
    foreach ($x in $P) { if (Test-Path $x) { try { $t += (Get-ChildItem $x -Recurse -Force -File -EA SilentlyContinue | Measure-Object Length -Sum).Sum } catch {} } }
    [int][math]::Round($t / 1MB, 0)
}
$ru = "$env:SystemRoot"; $lad = "$env:LOCALAPPDATA"; $ad = "$env:APPDATA"; $pd = "$env:ProgramData"

# --- surs (cache qui se regenere) ---
$reglesSures = @(
    @{ Item="Cache Windows Update (SoftwareDistribution)"; Paths=@("$ru\SoftwareDistribution\Download"); Type="wu_cache" }
    @{ Item="Cache Delivery Optimization"; Paths=@("$ru\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache","$ru\SoftwareDistribution\DeliveryOptimization"); Type="do_cache" }
    @{ Item="Fichiers temporaires (utilisateur + Windows)"; Paths=@("$env:TEMP","$ru\Temp"); Type="temp" }
    @{ Item="Corbeille"; Paths=@("$sysDrive\`$Recycle.Bin"); Type="recycle" }
    @{ Item="Cache de shaders (NVIDIA / DirectX / Steam)"; Paths=@("$lad\NVIDIA\DXCache","$lad\NVIDIA\GLCache","$lad\D3DSCache","$lad\AMD\DxCache","${env:ProgramFiles(x86)}\Steam\steamapps\shadercache","$sysDrive\SteamLibrary\steamapps\shadercache","F:\SteamLibrary\steamapps\shadercache") ; Type="shaders" }
    @{ Item="Rapports d'erreur et vidages memoire (crash dumps)"; Paths=@("$ru\Minidump","$lad\CrashDumps","$pd\Microsoft\Windows\WER","$lad\Microsoft\Windows\WER"); Type="dumps" }
    @{ Item="Vidage memoire complet (MEMORY.DMP)"; Paths=@("$ru\MEMORY.DMP"); Type="memdmp" }
    @{ Item="Caches navigateurs (Chrome / Edge / Firefox)"; Paths=@("$lad\Google\Chrome\User Data\Default\Cache","$lad\Microsoft\Edge\User Data\Default\Cache","$lad\Mozilla\Firefox\Profiles"); Type="browsers" }
    @{ Item="Caches Teams / Discord"; Paths=@("$ad\discord\Cache","$ad\discord\Code Cache","$ad\discord\GPUCache","$lad\Microsoft\Teams\Cache","$lad\Packages\MSTeams_8wekyb3d8bbwe\LocalCache"); Type="chat_cache" }
    @{ Item="Restes de mise a jour de fonctionnalite (\$WINDOWS.~BT, \$Windows.~WS)"; Paths=@("$sysDrive\`$WINDOWS.~BT","$sysDrive\`$Windows.~WS","$sysDrive\`$GetCurrent"); Type="featstaging" }
)
foreach ($r in $reglesSures) {
    $mb = Get-PathMB $r.Paths
    if ($mb -ge 150) { $recoverable += [PSCustomObject]@{ Item=$r.Item; TailleMB=$mb; Type=$r.Type; Classe="sur" } }
}

# --- prudents ---
# Magasin de composants WinSxS surdimensionne
try {
    $winsxsMB = Get-PathMB @("$ru\WinSxS")
    if ($winsxsMB -ge 12000) {
        $recoverable += [PSCustomObject]@{ Item="Magasin de composants WinSxS volumineux ($([math]::Round($winsxsMB/1024,1)) Go) - purge des versions superseded"; TailleMB="1000 a 6000"; Type="winsxs"; Classe="prudent" }
    }
} catch {}
# Anciens pilotes accumules dans le magasin (pertinent apres beaucoup de MAJ pilotes)
try {
    $oemCount = @((& pnputil.exe /enum-drivers 2>$null) -match '(?i)oem\d+\.inf').Count
    if ($oemCount -ge 40) {
        $recoverable += [PSCustomObject]@{ Item="$oemCount paquets de pilotes dans le magasin (anciennes versions incluses)"; TailleMB="200 a 2000"; Type="drvstore"; Classe="prudent" }
    }
} catch {}

# --- manuels (on signale, on ne touche pas) ---
$dlMB = Get-PathMB @("$env:USERPROFILE\Downloads")
$dlVieux = @(Get-ChildItem "$env:USERPROFILE\Downloads" -File -EA SilentlyContinue | Where-Object { $_.Extension -match '\.(exe|msi|zip|iso|dmg)$' -and $_.LastWriteTime -lt (Get-Date).AddDays(-90) })
if ($dlMB -ge 3000 -or $dlVieux.Count -ge 5) {
    $recoverable += [PSCustomObject]@{ Item="Dossier Telechargements : $([math]::Round($dlMB/1024,1)) Go ($($dlVieux.Count) installeurs de +90 jours)"; TailleMB=$dlMB; Type="downloads"; Classe="manuel" }
}
$pkgCacheMB = Get-PathMB @("$pd\Package Cache","$lad\Package Cache")
if ($pkgCacheMB -ge 1500) {
    $recoverable += [PSCustomObject]@{ Item="Package Cache ($([math]::Round($pkgCacheMB/1024,1)) Go) - sert a reparer/desinstaller certaines apps, a ne vider qu'en dernier recours"; TailleMB=$pkgCacheMB; Type="pkgcache"; Classe="manuel" }
}
$edb = "$pd\Microsoft\Search\Data\Applications\Windows\Windows.edb"
if (Test-Path $edb) {
    $edbMB = [int][math]::Round((Get-Item $edb -Force -EA SilentlyContinue).Length/1MB,0)
    if ($edbMB -ge 2000) { $recoverable += [PSCustomObject]@{ Item="Index de recherche Windows (Windows.edb) : $([math]::Round($edbMB/1024,1)) Go - se reconstruit si on le reinitialise"; TailleMB=$edbMB; Type="searchidx"; Classe="prudent" } }
}

$recupSurTotalMB = ($recoverable | Where-Object { $_.Classe -eq 'sur' -and $_.TailleMB -is [int] } | Measure-Object -Property TailleMB -Sum).Sum
if (-not $recupSurTotalMB) { $recupSurTotalMB = 0 }
Write-Log "Recuperable sur (caches) : ~$([math]::Round($recupSurTotalMB/1024,1)) Go sur $($recoverable.Count) poste(s)." "OK"

# --- Proposition des actions (avec confirmation) ---
if ($Interactive -and $recoverable.Count -gt 0) {
    Write-Host "`n=== Recuperer de l'espace disque ===" -ForegroundColor Cyan
    foreach ($rc in ($recoverable | Sort-Object @{e={switch($_.Classe){'sur'{0}'prudent'{1}'manuel'{2}default{3}}}}, @{e={if($_.TailleMB -is [int]){-$_.TailleMB}else{0}}})) {
        $tMB = if ($rc.TailleMB -is [string]) { $rc.TailleMB + " Mo" } else { "$($rc.TailleMB) Mo" }
        $tag = switch ($rc.Classe) { 'sur' {'[SUR]    '} 'prudent' {'[PRUDENT]'} 'manuel' {'[MANUEL] '} default {'         '} }
        $col = switch ($rc.Classe) { 'sur' {'Green'} 'prudent' {'Yellow'} 'manuel' {'DarkGray'} default {'Gray'} }
        Write-Host ("  {0} {1,-8}  {2}" -f $tag, $tMB, $rc.Item) -ForegroundColor $col
    }

    # 1) tout le "sur" en un coup
    $lotSur = @($recoverable | Where-Object { $_.Classe -eq 'sur' })
    if ($lotSur.Count -gt 0) {
        $gSur = ($lotSur | Where-Object { $_.TailleMB -is [int] } | Measure-Object TailleMB -Sum).Sum
        Write-Host ""
        if (Confirm-Action "  Nettoyer d'un coup tout ce qui est [SUR] (~$([math]::Round($gSur/1024,1)) Go, caches qui se regenerent) ?") {
            foreach ($rc in $lotSur) {
                try {
                    switch ($rc.Type) {
                        "recycle"     { Clear-RecycleBin -Force -EA SilentlyContinue }
                        "wu_cache"    { Stop-Service wuauserv -Force -EA SilentlyContinue; Get-ChildItem "$env:SystemRoot\SoftwareDistribution\Download" -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue; Start-Service wuauserv -EA SilentlyContinue }
                        "memdmp"      { Remove-Item "$env:SystemRoot\MEMORY.DMP" -Force -EA SilentlyContinue }
                        default {
                            $paths = ($reglesSures | Where-Object { $_.Type -eq $rc.Type }).Paths
                            foreach ($p in $paths) { if (Test-Path $p) { Get-ChildItem $p -Force -EA SilentlyContinue | Remove-Item -Recurse -Force -EA SilentlyContinue } }
                        }
                    }
                    $rc | Add-Member NoteProperty Fait "Oui" -Force
                    Write-Log "Nettoye : $($rc.Item)" "OK"
                } catch { Write-Log "Nettoyage $($rc.Item) : $_" "WARN" }
            }
        }
    }

    # 2) les "prudent" et "manuel" un par un
    foreach ($rc in ($recoverable | Where-Object { $_.Classe -ne 'sur' })) {
        $tMB = if ($rc.TailleMB -is [string]) { $rc.TailleMB + " Mo" } else { "$($rc.TailleMB) Mo" }
        Write-Host "`n[$($rc.Classe.ToUpper())] $($rc.Item) - $tMB" -ForegroundColor $(if($rc.Classe -eq 'prudent'){'Yellow'}else{'DarkGray'})
        switch ($rc.Type) {
            "winsxs" {
                Write-Host "   Purge les versions superseded du magasin. Apres : les MAJ Windows deja installees ne sont plus desinstallables. Long (5-20 min)." -ForegroundColor DarkGray
                if (Confirm-Action "   Lancer Dism /StartComponentCleanup /ResetBase ?") {
                    try { & Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase 2>&1 | Out-Null; Write-Log "WinSxS : purge des composants lancee." "OK"; $rc | Add-Member NoteProperty Fait "Oui" -Force } catch { Write-Log "WinSxS : $_" "WARN" }
                }
            }
            "drvstore" {
                Write-Host "   Retire les paquets de pilotes obsoletes (non lies a un peripherique). Reversible seulement si on a garde les .inf." -ForegroundColor DarkGray
                if (Confirm-Action "   Purger les anciens paquets de pilotes du magasin ?") {
                    try {
                        $nb = 0
                        foreach ($l in ((& pnputil.exe /enum-drivers 2>$null) -split '(?=Nom publi|Published Name)')) {
                            if ($l -match '(?i)(oem\d+\.inf)' -and $l -notmatch '(?i)nvlddmkm|rt640x64|realtek|igdlh64') {
                                # ne retire que ceux non actuellement lies : pnputil refuse tout seul les autres
                                $oem = $Matches[1]
                                if ((& pnputil.exe /delete-driver $oem 2>&1) -match 'supprim|deleted') { $nb++ }
                            }
                        }
                        Write-Log "$nb paquet(s) de pilotes obsoletes retires." "OK"; $rc | Add-Member NoteProperty Fait "Oui" -Force
                    } catch { Write-Log "Magasin pilotes : $_" "WARN" }
                }
            }
            "searchidx" {
                if (Confirm-Action "   Reinitialiser l'index de recherche (se reconstruit en arriere-plan) ?") {
                    try { Stop-Service WSearch -Force -EA SilentlyContinue; Remove-Item "$env:ProgramData\Microsoft\Search\Data\Applications\Windows\Windows.edb" -Force -EA SilentlyContinue; Start-Service WSearch -EA SilentlyContinue; Write-Log "Index de recherche reinitialise." "OK"; $rc | Add-Member NoteProperty Fait "Oui" -Force } catch { Write-Log "Index : $_" "WARN" }
                }
            }
            "downloads" {
                Write-Host "   Ce sont des fichiers a TOI. Le script ne supprime rien ici. Ouvre le dossier et fais le tri." -ForegroundColor DarkGray
                if (Confirm-Action "   Ouvrir le dossier Telechargements ?") { Start-Process explorer.exe "$env:USERPROFILE\Downloads" }
            }
            "pkgcache" {
                Write-Host "   A NE PAS vider sauf disque vraiment critique : certaines apps ne pourront plus se reparer/desinstaller." -ForegroundColor DarkGray
            }
            "winold" {
                if (Confirm-Action "   Supprimer Windows.old (via Nettoyage de disque) ?") {
                    try {
                        # Passe par cleanmgr qui gere Windows.old proprement
                        $vc = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installation(s)"
                        if (Test-Path $vc) { Set-ItemProperty $vc "StateFlags0065" 2 -Type DWord -Force -EA SilentlyContinue }
                        Start-Process "cleanmgr.exe" -ArgumentList "/sagerun:65" -Wait -EA SilentlyContinue
                        Write-Log "Windows.old : nettoyage lance." "OK"
                        $rc | Add-Member NoteProperty Fait "Oui" -Force
                    } catch { Write-Log "Windows.old : $_" "WARN" }
                }
            }
            "hiber" {
                Write-Host "   (Desactive la veille prolongee. La mise en veille normale n'est PAS affectee.)" -ForegroundColor DarkGray
                if (Confirm-Action "   Desactiver l'hibernation et supprimer hiberfil.sys ?") {
                    try { powercfg /hibernate off; Write-Log "Hibernation desactivee, hiberfil.sys supprime." "OK"; $rc | Add-Member NoteProperty Fait "Oui" -Force }
                    catch { Write-Log "Hibernation : $_" "WARN" }
                }
            }
            "restore" {
                if (Confirm-Action "   Supprimer les anciens points de restauration (garde le plus recent) ?") {
                    try { vssadmin delete shadows /for=$sysDrive /oldest /quiet 2>$null; Write-Log "Anciens points de restauration supprimes." "OK"; $rc | Add-Member NoteProperty Fait "Oui" -Force }
                    catch { Write-Log "Points de restauration : $_" "WARN" }
                }
            }
        }
    }
}

# ============================================================
#  8ter. DOUBLONS REELS (par hash) dans Telechargements & Documents
# ============================================================
# Detection par CONTENU (hash MD5), pas par nom : deux fichiers de meme hash
# sont identiques octet pour octet. On garde TOUJOURS une copie, on ne propose
# que les copies en trop, avec validation manuelle. Jamais de suppression auto.
Write-Log "Recherche de doublons reels (par contenu)..."
Write-Host "  >> Calcul des empreintes (hash) des fichiers. Peut prendre 1-2 min si le dossier" -ForegroundColor Cyan
Write-Host "     Telechargements est volumineux. Patiente." -ForegroundColor Cyan
$dupGroups = @()
$dupTotalMB = 0
$scanDup = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents")
$minSize = 1MB   # on ignore les petits fichiers (gain negligeable, scan plus rapide)

# DOSSIERS TECHNIQUES A EXCLURE : y supprimer un "doublon" casse le projet/l'appli.
# node_modules (npm duplique volontairement), .next/build/dist (sorties de build),
# .git (historique), venv/__pycache__ (Python), et les extractions de drivers (versions par OS).
$exclureDossiers = @(
    "\node_modules\", "\.next\", "\.git\", "\build\", "\dist\", "\vendor\",
    "\venv\", "\.venv\", "\__pycache__\", "\.gradle\", "\target\", "\bin\", "\obj\",
    "\packages\", "\bower_components\", "\.nuget\"
)
function Est-DossierTechnique {
    param([string]$Path)
    foreach ($ex in $exclureDossiers) { if ($Path -like "*$ex*") { return $true } }
    return $false
}

try {
    $files = foreach ($d in $scanDup) {
        if (Test-Path $d) {
            Get-ChildItem $d -Recurse -File -Force -EA SilentlyContinue |
                Where-Object { $_.Length -ge $minSize -and -not (Est-DossierTechnique $_.FullName) }
        }
    }
    Write-Log "$(@($files).Count) fichiers candidats (dossiers techniques exclus)." "OK"
    # Pre-filtre par taille : seuls les fichiers de meme taille peuvent etre identiques.
    # On ne hash que ces candidats -> beaucoup plus rapide sur gros dossiers.
    $bySize = $files | Group-Object Length | Where-Object { $_.Count -gt 1 }
    $totalGrp = @($bySize).Count; $iGrp = 0
    foreach ($grp in $bySize) {
        $iGrp++
        if ($totalGrp -gt 0) { Write-Progress -Activity "Recherche de doublons" -Status "Analyse groupe $iGrp / $totalGrp" -PercentComplete (($iGrp / $totalGrp) * 100) }
        $hashes = @{}
        foreach ($f in $grp.Group) {
            try {
                $h = (Get-FileHash -Path $f.FullName -Algorithm MD5 -EA Stop).Hash
                if (-not $hashes.ContainsKey($h)) { $hashes[$h] = @() }
                $hashes[$h] += $f
            } catch {}
        }
        foreach ($h in $hashes.Keys) {
            if ($hashes[$h].Count -gt 1) {
                $items = $hashes[$h] | Sort-Object LastWriteTime   # le plus ancien = l'original a garder
                $tailleUn = $items[0].Length
                $copiesEnTrop = $items.Count - 1
                $dupTotalMB += [math]::Round(($tailleUn * $copiesEnTrop)/1MB,1)
                $dupGroups += [PSCustomObject]@{
                    Nom=$items[0].Name
                    TailleMB=[math]::Round($tailleUn/1MB,1)
                    NbCopies=$items.Count
                    AGarder=$items[0].FullName
                    ATrop=@($items[1..($items.Count-1)])
                    Supprimes=0
                }
            }
        }
    }
    $dupGroups = $dupGroups | Sort-Object { $_.TailleMB * ($_.NbCopies-1) } -Descending
    Write-Progress -Activity "Recherche de doublons" -Completed
    Write-Log "$($dupGroups.Count) groupe(s) de doublons, ~$dupTotalMB Mo recuperables." "OK"
} catch { Write-Log "Recherche doublons : $_" "WARN" }

if ($Interactive -and $dupGroups.Count -gt 0) {
    Write-Host "`n=== Doublons reels (contenu identique) ===" -ForegroundColor Cyan
    Write-Host "Une copie est TOUJOURS gardee. On ne supprime que les copies en trop.`n" -ForegroundColor Gray
    foreach ($g in $dupGroups) {
        Write-Host "[$($g.Nom)] $($g.TailleMB) Mo x $($g.NbCopies) copies" -ForegroundColor White
        Write-Host "   Garde : $($g.AGarder)" -ForegroundColor DarkGray
        $g.ATrop | ForEach-Object { Write-Host "   En trop : $($_.FullName)" -ForegroundColor DarkGray }
        if (Confirm-Action "   Supprimer les $($g.NbCopies-1) copie(s) en trop (garde l'original) ?") {
            foreach ($f in $g.ATrop) {
                try { Remove-Item $f.FullName -Force -EA Stop; $g.Supprimes++; Write-Log "Doublon supprime: $($f.FullName)" "OK" }
                catch { Write-Log "Echec doublon: $($f.FullName)" "ERROR" }
            }
        }
    }
}

# ============================================================
#  9. WINDOWS UPDATE en attente
# ============================================================
Write-Log "Recherche des MAJ Windows en attente..."
$updates = @()
try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and IsHidden=0")
    foreach ($u in $result.Updates) { $updates += $u.Title }
    Write-Log "$($updates.Count) MAJ Windows en attente." "OK"
} catch { Write-Log "MAJ Windows : recherche impossible ($_)" "WARN" }

# ============================================================
#  9. EVENEMENTS CRITIQUES (crashs recents - 7 jours)
# ============================================================
Write-Log "Analyse des evenements critiques (7 jours)..."
$events = @()
try {
    # On recupere plus large puis on REGROUPE par (Id + source) pour ne pas
    # afficher 25 fois la meme erreur DCOM. On garde le plus recent de chaque type + le compte.
    $raw = Get-WinEvent -FilterHashtable @{ LogName='System'; Level=1,2; StartTime=(Get-Date).AddDays(-7) } -MaxEvents 200 -EA SilentlyContinue |
        Select-Object TimeCreated, Id, ProviderName,
            @{N='Msg';E={ ($_.Message -split "`n")[0] }}
    $events = $raw | Group-Object Id, ProviderName | ForEach-Object {
        $dernier = $_.Group | Sort-Object TimeCreated -Descending | Select-Object -First 1
        [PSCustomObject]@{
            TimeCreated=$dernier.TimeCreated; Id=$dernier.Id; ProviderName=$dernier.ProviderName
            Msg=$dernier.Msg; Count=$_.Count
        }
    } | Sort-Object Count -Descending
    Write-Log "$(@($raw).Count) evenements, regroupes en $(@($events).Count) types." "OK"
} catch { Write-Log "Evenements : $_" "WARN" }

# ============================================================
#  10. RESEAU
# ============================================================
Write-Log "Test reseau..."
$net = $null
try {
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        # PowerShell 7+ : -TargetName et propriete Latency
        $ping = Test-Connection -TargetName "8.8.8.8" -Count 8 -EA SilentlyContinue
        $lat  = ($ping | Measure-Object -Property Latency -Average).Average
    } else {
        # Windows PowerShell 5.1 : -ComputerName et propriete ResponseTime
        $ping = Test-Connection -ComputerName "8.8.8.8" -Count 8 -EA SilentlyContinue
        $lat  = ($ping | Measure-Object -Property ResponseTime -Average).Average
    }
    if ($ping) {
        $recu = @($ping).Count
        $avg  = [math]::Round($lat,0)
        $loss = [math]::Round((8 - $recu)/8*100,0)
        $net  = [PSCustomObject]@{ LatenceMs=$avg; PerteePct=$loss }
        Write-Log "Reseau : ${avg}ms, perte ${loss}%" "OK"
    }
} catch { Write-Log "Test reseau : $_" "WARN" }

# ============================================================
#  11. SECURITE (lecture seule)
# ============================================================
Write-Log "Analyse securite..."
$secu = @()   # @{ Item; Etat; Niveau(ok/warn/bad) }

# Windows Defender / antivirus
try {
    $av = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -EA SilentlyContinue
    if ($av) {
        foreach ($a in $av) {
            # productState : le 2e octet hex indique actif (10/11) ; on reste simple
            $actif = ($a.productState -band 0x1000) -ne 0
            $secu += @{ Item="Antivirus : $($a.displayName)"; Etat=if($actif){"Actif"}else{"Inactif ou obsolete"}; Niveau=if($actif){"ok"}else{"bad"} }
        }
    } else {
        # Fallback : etat de Defender directement
        $def = Get-MpComputerStatus -EA SilentlyContinue
        if ($def) {
            $secu += @{ Item="Windows Defender - protection temps reel"; Etat=if($def.RealTimeProtectionEnabled){"Active"}else{"DESACTIVEE"}; Niveau=if($def.RealTimeProtectionEnabled){"ok"}else{"bad"} }
            $secu += @{ Item="Defender - signatures antivirus"; Etat="Version $($def.AntivirusSignatureVersion)"; Niveau=if($def.AntivirusSignatureAge -le 3){"ok"}elseif($def.AntivirusSignatureAge -le 7){"warn"}else{"bad"} }
        }
    }
} catch { Write-Log "Antivirus : $_" "WARN" }

# Pare-feu (les 3 profils)
try {
    $fw = Get-NetFirewallProfile -EA SilentlyContinue
    foreach ($p in $fw) {
        $secu += @{ Item="Pare-feu - profil $($p.Name)"; Etat=if($p.Enabled){"Actif"}else{"DESACTIVE"}; Niveau=if($p.Enabled){"ok"}else{"bad"} }
    }
} catch { Write-Log "Pare-feu : $_" "WARN" }

# BitLocker (chiffrement du disque systeme)
try {
    $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -EA SilentlyContinue
    if ($bl) {
        $secu += @{ Item="BitLocker ($env:SystemDrive)"; Etat="$($bl.ProtectionStatus) / $($bl.VolumeStatus)"; Niveau=if($bl.ProtectionStatus -eq "On"){"ok"}else{"mut"} }
    }
} catch {}

# Secure Boot
try {
    $sb = Confirm-SecureBootUEFI -EA SilentlyContinue
    $secu += @{ Item="Secure Boot"; Etat=if($sb){"Active"}else{"Desactive"}; Niveau=if($sb){"ok"}else{"warn"} }
} catch {}

# MAJ Windows critiques en attente (deja collecte plus haut dans $updates)
if ($updates) {
    $secu += @{ Item="Mises a jour Windows en attente"; Etat="$($updates.Count) en attente"; Niveau=if($updates.Count -eq 0){"ok"}elseif($updates.Count -le 5){"warn"}else{"bad"} }
}
Write-Log "$($secu.Count) points de securite verifies." "OK"

# ============================================================
#  12. RESEAU APPROFONDI (latence multi-cibles, DNS, debit estime)
# ============================================================
Write-Log "Reseau approfondi..."
$netDetail = @()
$ciblesPing = @(
    @{ Nom="Google DNS (8.8.8.8)"; Cible="8.8.8.8" },
    @{ Nom="Cloudflare (1.1.1.1)"; Cible="1.1.1.1" },
    @{ Nom="Passerelle locale"; Cible=(Get-NetRoute -DestinationPrefix "0.0.0.0/0" -EA SilentlyContinue | Select-Object -First 1).NextHop }
)
foreach ($c in $ciblesPing) {
    if (-not $c.Cible) { continue }
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) { $p = Test-Connection -TargetName $c.Cible -Count 4 -EA SilentlyContinue; $l=($p|Measure-Object Latency -Average).Average }
        else { $p = Test-Connection -ComputerName $c.Cible -Count 4 -EA SilentlyContinue; $l=($p|Measure-Object ResponseTime -Average).Average }
        if ($p) {
            $ms=[math]::Round($l,0); $perte=[math]::Round((4-@($p).Count)/4*100,0)
            $netDetail += @{ Cible=$c.Nom; Latence="$ms ms"; Perte="$perte%"; Niveau=if($ms -le 30 -and $perte -eq 0){"ok"}elseif($ms -le 80){"warn"}else{"bad"} }
        } else {
            $netDetail += @{ Cible=$c.Nom; Latence="injoignable"; Perte="100%"; Niveau="bad" }
        }
    } catch {}
}
# Resolution DNS (test de rapidite)
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Resolve-DnsName "www.google.com" -EA SilentlyContinue | Out-Null
    $sw.Stop()
    $dnsMs = $sw.ElapsedMilliseconds
    $netDetail += @{ Cible="Resolution DNS (google.com)"; Latence="$dnsMs ms"; Perte="-"; Niveau=if($dnsMs -le 100){"ok"}elseif($dnsMs -le 300){"warn"}else{"bad"} }
} catch {}
# Type de connexion (Wi-Fi vs Ethernet) et debit du lien
try {
    $adapter = Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
    if ($adapter) {
        $linkGbps = [math]::Round($adapter.LinkSpeed / 1, 0)
        $netDetail += @{ Cible="Connexion active"; Latence="$($adapter.Name) ($($adapter.LinkSpeed))"; Perte="-"; Niveau="ok" }
    }
} catch {}
Write-Log "$($netDetail.Count) tests reseau approfondis." "OK"

# ============================================================
#  13. PERFS (mini-benchmark disque + infos CPU)
# ============================================================
Write-Log "Mini-benchmark disque..."
$perf = @()
# Test d'ecriture/lecture sequentielle simple sur le disque systeme
try {
    $testFile = "$env:TEMP\avdiag_bench.tmp"
    $data = New-Object byte[] (50MB); (New-Object Random).NextBytes($data)
    # ECRITURE : on force le flush disque (FileStream avec WriteThrough) pour une vraie mesure
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $fs = [System.IO.File]::Create($testFile, 1MB, [System.IO.FileOptions]::WriteThrough)
    $fs.Write($data, 0, $data.Length); $fs.Flush($true); $fs.Close()
    $sw.Stop(); $writeMs = [math]::Max($sw.ElapsedMilliseconds,1)
    $writeMBs = [math]::Round(50 / ($writeMs/1000), 0)
    # LECTURE : on lit dans une variable (PAS de | Out-Null qui enumere octet par octet = ultra lent)
    $sw.Restart()
    $read = [System.IO.File]::ReadAllBytes($testFile)
    $sw.Stop(); $readMs = [math]::Max($sw.ElapsedMilliseconds,1)
    $readMBs = [math]::Round(50 / ($readMs/1000), 0)
    $read = $null
    Remove-Item $testFile -Force -EA SilentlyContinue
    $perf += @{ Item="Ecriture disque systeme"; Valeur="$writeMBs Mo/s"; Niveau=if($writeMBs -ge 300){"ok"}elseif($writeMBs -ge 100){"warn"}else{"bad"} }
    $perf += @{ Item="Lecture disque systeme"; Valeur="$readMBs Mo/s"; Niveau=if($readMBs -ge 400){"ok"}elseif($readMBs -ge 150){"warn"}else{"bad"} }
    Write-Log "Bench disque : ecriture $writeMBs Mo/s, lecture $readMBs Mo/s" "OK"
} catch { Write-Log "Bench disque : $_" "WARN" }
# Infos CPU utiles
try {
    $perf += @{ Item="CPU"; Valeur="$($cpu.NumberOfCores) coeurs / $($cpu.NumberOfLogicalProcessors) threads @ $([math]::Round($cpu.MaxClockSpeed/1000,1)) GHz"; Niveau="ok" }
    $load = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $perf += @{ Item="Charge CPU actuelle"; Valeur="$load %"; Niveau=if($load -lt 40){"ok"}elseif($load -lt 80){"warn"}else{"bad"} }
} catch {}

# --- Top consommateurs RAM et CPU (diagnostic pur) ---
Write-Log "Top consommateurs RAM/CPU..."
$topRam = @(); $topCpu = @()
try {
    $topRam = Get-Process -EA SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 8 |
        ForEach-Object { [PSCustomObject]@{ Nom=$_.ProcessName; MB=[math]::Round($_.WorkingSet64/1MB,0) } }
    # CPU : deux mesures espacees pour un % fiable
    $s1 = Get-Process -EA SilentlyContinue | Select-Object Id, ProcessName, @{N='T';E={$_.TotalProcessorTime.TotalMilliseconds}}
    Start-Sleep -Milliseconds 500
    $s2 = Get-Process -EA SilentlyContinue | Select-Object Id, ProcessName, @{N='T';E={$_.TotalProcessorTime.TotalMilliseconds}}
    $nproc = [Environment]::ProcessorCount
    $topCpu = foreach ($p in $s2) {
        $prev = $s1 | Where-Object { $_.Id -eq $p.Id } | Select-Object -First 1
        if ($prev) {
            $pct = [math]::Round((($p.T - $prev.T) / 500 / $nproc) * 100, 0)
            if ($pct -gt 0) { [PSCustomObject]@{ Nom=$p.ProcessName; Pct=$pct } }
        }
    }
    $topCpu = $topCpu | Sort-Object Pct -Descending | Select-Object -First 8
    Write-Log "Top consommateurs releves." "OK"
} catch { Write-Log "Top consommateurs : $_" "WARN" }

# --- Conseils specifiques a la marque du GPU (in-game) ---
$gpuTips = @()
switch ($gpuVendor) {
    "NVIDIA" {
        $gpuTips = @(
            "Panneau NVIDIA > Gerer les parametres 3D > Mode faible latence : Ultra (reduit l'input lag).",
            "Activer Resizable BAR si CPU/CM/GPU compatibles (gain de perfs sur jeux recents).",
            "DLSS dans les jeux compatibles : gros gain de FPS avec perte de qualite minime.",
            "Mode de gestion de l'alimentation : Performances maximales privilegiees."
        )
    }
    "AMD" {
        $gpuTips = @(
            "AMD Software > Gaming : activer Radeon Anti-Lag (reduit l'input lag).",
            "Activer Smart Access Memory (equivalent Resizable BAR) si config compatible.",
            "FSR dans les jeux compatibles : gain de FPS notable.",
            "Radeon Chill a desactiver en competitif (bride les FPS pour economiser)."
        )
    }
    "Intel" {
        $gpuTips = @(
            "Intel Arc Control : activer les optimisations par jeu.",
            "XeSS dans les jeux compatibles : upscaling qui booste les FPS.",
            "Verifier que le Resizable BAR est actif (important sur Arc)."
        )
    }
}

# ============================================================
#  14. TWEAKS GAMING (tous reversibles, backup + confirmation)
# ============================================================
# Chaque tweak sauvegarde la valeur d'origine dans un .reg avant modif.
# Un point de restauration est cree en amont. Gain reel mais MODESTE
# (surtout fluidite / 1% low), jamais un doublement de FPS.
$script:tweaksApplied = @()
$tweakBackupDir = "$AppDir\Backups"
New-Item -ItemType Directory -Path $tweakBackupDir -Force | Out-Null
$tweakBackup = "$tweakBackupDir\Tweaks-Backup-$Stamp.reg"
# Manifeste : le .reg seul NE SUFFIT PAS a annuler. "reg import" fusionne, il ne
# supprime jamais une valeur creee de toutes pieces par un tweak (ex: TcpAckFrequency,
# HwSchMode, MSISupported... qui n'existent pas sur un Windows par defaut).
# On note donc, AVANT chaque modif, si la cle et la valeur existaient deja.
# L'Undo s'en sert pour supprimer ce qui n'existait pas, au lieu de le laisser a vie.
$tweakManifest = "$tweakBackupDir\Tweaks-Manifest-$Stamp.json"
$script:tweakManifestEntries = @()

# Etat NON-registre (carte reseau, taches planifiees...) : le .reg et le manifeste
# ne savent pas le reconstituer. On note l'etat d'origine ici, l'Undo le relit.
$tweakNonReg = "$tweakBackupDir\NonReg-$Stamp.json"
$script:tweakNonRegState = [ordered]@{ netAdapters = @(); scheduledDefragWasDisabled = $false }
function Save-NonRegState {
    try { ConvertTo-Json -InputObject $script:tweakNonRegState -Depth 6 | Set-Content -Path $tweakNonReg -Encoding UTF8 } catch {}
}

function Register-TweakValue {
    param([string]$Path, [string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return }
    # Deja enregistre ? on conserve le tout premier etat releve (= l'etat d'origine)
    foreach ($e in $script:tweakManifestEntries) {
        if ($e.Path -eq $Path -and $e.Name -eq $Name) { return }
    }
    $cleExiste = Test-Path $Path
    $valExiste = $false
    if ($cleExiste) {
        $prop = Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue
        $valExiste = ($null -ne $prop -and $null -ne $prop.PSObject.Properties[$Name])
    }
    $script:tweakManifestEntries += [pscustomobject]@{
        Path = $Path; Name = $Name; CleExistait = $cleExiste; ValeurExistait = $valExiste
    }
    # Ecriture immediate : si le script est interrompu en plein tweak, l'Undo reste complet
    # -InputObject et pas le pipe : en PS 5.1, "$tableau | ConvertTo-Json" deballe
    # le tableau et ",$tableau | ConvertTo-Json" produit {"value":[...],"Count":N}.
    try { ConvertTo-Json -InputObject @($script:tweakManifestEntries) -Depth 3 | Set-Content -Path $tweakManifest -Encoding UTF8 } catch {}
}

function Backup-RegValue {
    param([string]$Path, [string]$Name)
    Register-TweakValue $Path $Name
    # Exporte la cle dans le .reg de backup (append) avant modif
    $regPath = $Path -replace "HKLM:","HKEY_LOCAL_MACHINE" -replace "HKCU:","HKEY_CURRENT_USER"
    try { reg export ($regPath) "$tweakBackupDir\tmp.reg" /y 2>$null | Out-Null; Get-Content "$tweakBackupDir\tmp.reg" -EA SilentlyContinue | Add-Content $tweakBackup; Remove-Item "$tweakBackupDir\tmp.reg" -EA SilentlyContinue } catch {}
}
function Apply-Tweak {
    param([string]$Label, [string]$Path, [string]$Name, $Value, [string]$Type="DWord")
    Backup-RegValue $Path $Name
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
    $script:tweaksApplied += $Label
    Write-Log "Tweak applique: $Label" "OK"
}

if ($Interactive -and $tweaksGamingAutorises) {
    Write-Host "`n=== Tweaks gaming (niveau $($niveau.ToUpper()), reversibles, backup cree) ===" -ForegroundColor Cyan
    Write-Host "Gain reel mais modeste (fluidite, 1% low). Backup registre + point de restauration.`n" -ForegroundColor Gray

    if (Confirm-Action "Appliquer les tweaks gaming (avec sauvegarde) ?") {
        # Point de restauration en filet de securite (on FORCE l'activation de la protection systeme,
        # souvent desactivee sur les PC montes maison, sinon le point echoue silencieusement).
        $rpAvant = @(Get-ComputerRestorePoint -EA SilentlyContinue).Count
        try {
            Enable-ComputerRestore -Drive "$env:SystemDrive\" -EA SilentlyContinue
            Set-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore" "SystemRestorePointCreationFrequency" 0 -Type DWord -Force -EA SilentlyContinue
            Checkpoint-Computer -Description "AlloValentin-AvantTweaks" -RestorePointType "MODIFY_SETTINGS" -EA SilentlyContinue
            $rpApres = @(Get-ComputerRestorePoint -EA SilentlyContinue).Count
            if ($rpApres -gt $rpAvant) {
                Write-Log "Point de restauration cree (filet de securite actif)." "OK"
            } else {
                Write-Log "Point de restauration NON confirme. Le backup .reg reste le filet principal." "WARN"
                Write-Host "  ATTENTION : le point de restauration n'a pas pu etre cree." -ForegroundColor Yellow
                Write-Host "  Le backup registre (.reg) est ton filet. Tu peux continuer, ou repondre N pour annuler." -ForegroundColor Yellow
                if (-not (Confirm-Action "  Continuer sans point de restauration (le .reg suffit dans 99% des cas) ?")) {
                    Write-Log "Tweaks annules par l'utilisateur (pas de point de restauration)." "WARN"
                    return
                }
            }
        } catch { Write-Log "Point de restauration : $_" "WARN" }

        "Windows Registry Editor Version 5.00`n; Backup AlloValentin $Stamp" | Out-File $tweakBackup -Encoding ASCII

        # 1) Plan d'alimentation Ultimate Performance
        try {
            $ult = "e9a42b02-d5df-448d-aa00-03f14749eb61"
            powercfg -duplicatescheme $ult 2>$null | Out-Null
            powercfg -setactive $ult 2>$null
            if ($LASTEXITCODE -eq 0) { $script:tweaksApplied += "Plan Ultimate Performance"; Write-Log "Plan Ultimate Performance actif." "OK" }
            else { powercfg -setactive SCHEME_MIN; $script:tweaksApplied += "Plan Haute performance"; Write-Log "Plan Haute performance actif." "OK" }
        } catch { Write-Log "Plan alim : $_" "WARN" }

        # 2) Game DVR / Game Bar off (anti-stutter)
        Apply-Tweak "Game DVR off" "HKCU:\System\GameConfigStore" "GameDVR_Enabled" 0
        Apply-Tweak "Game DVR policy off" "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" "AllowGameDVR" 0

        # 4) Effets visuels reduits (perfs)
        Apply-Tweak "Effets visuels reduits" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects" "VisualFXSetting" 2

        # 6) HAGS (Hardware-accelerated GPU scheduling)
        Apply-Tweak "HAGS active" "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2

        # 7) Windows Update : distribution pair-a-pair limitee au reseau local.
        #    Moins d'upload en tache de fond pendant le jeu (plus de seeding vers Internet),
        #    la MAJ continue de se telecharger normalement. Reversible via manifeste.
        Apply-Tweak "MAJ Windows : partage en LAN uniquement" `
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization" "DODownloadMode" 1

        # 8) Demarrage rapide (Fast Startup) off : les pilotes et le noyau repartent
        #    proprement a chaque arret. Reversible via manifeste (valeur registre).
        Apply-Tweak "Demarrage rapide (Fast Startup) off" `
            "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power" "HiberbootEnabled" 0

        # 9) Optimisation planifiee des lecteurs : la reactiver si un ancien logiciel
        #    l'avait coupee (un HDD se fragmente, un SSD perd le TRIM regulier).
        try {
            $tOpt = Get-ScheduledTask -TaskName 'ScheduledDefrag' -EA SilentlyContinue
            if ($tOpt -and $tOpt.State -eq 'Disabled') {
                Enable-ScheduledTask -TaskName 'ScheduledDefrag' -EA SilentlyContinue | Out-Null
                $script:tweakNonRegState.scheduledDefragWasDisabled = $true
                Save-NonRegState
                $script:tweaksApplied += "Optimisation planifiee des lecteurs reactivee"
                Write-Log "Tache ScheduledDefrag reactivee." "OK"
            }
        } catch { Write-Log "ScheduledDefrag : $_" "WARN" }

        # 10) Carte(s) reseau : couper les proprietes d'economie d'energie (EEE / Green
        #     Ethernet / Power Saving Mode). Vraie cause de micro-lag et de pics de ping
        #     en jeu en ligne. Applique en -NoRestart (aucune coupure reseau : l'effet
        #     se fait au prochain redemarrage). Valeurs d'origine notees dans NonReg-*.json.
        #     On ne touche PAS 'autoriser a eteindre ce peripherique' (semantique du flag
        #     PnPCapabilities trop variable selon les pilotes, gain marginal en jeu).
        try {
            foreach ($ad in (Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -notmatch 'Wireless|802.11' })) {
                $rec = [ordered]@{ Name = $ad.Name; AdvProps = @() }
                $eco = Get-NetAdapterAdvancedProperty -Name $ad.Name -EA SilentlyContinue | Where-Object {
                    $_.DisplayName -match '(?i)energ|nergie|efficient|efficien|green ethernet|econom|.conomie d|risparmio|ahorro|power sav|ultra low power|\bEEE\b|idle power|veille|niedrig.*energ' -and
                    $_.DisplayValue -notmatch '(?i)d.sactiv|disabl|deaktiv|desactiv|\boff\b|\bnon\b|maximum performance|no power|nessun' -and
                    $_.RegistryKeyword
                }
                foreach ($p in $eco) {
                    $rec.AdvProps += [ordered]@{ Keyword = $p.RegistryKeyword; OldValue = "$($p.RegistryValue)" }
                    try { Set-NetAdapterAdvancedProperty -Name $ad.Name -RegistryKeyword $p.RegistryKeyword -RegistryValue 0 -NoRestart -EA Stop } catch {}
                }
                if ($rec.AdvProps.Count -gt 0) {
                    $script:tweakNonRegState.netAdapters += $rec
                    Save-NonRegState
                    $script:tweaksApplied += "Economie d'energie coupee sur $($ad.InterfaceDescription)"
                    Write-Log "Economie d'energie reseau coupee : $($ad.InterfaceDescription) ($($rec.AdvProps.Count) propriete(s), effet au reboot)." "OK"
                }
            }
        } catch { Write-Log "Economie d'energie reseau : $_" "WARN" }

        # --- Tweaks AGRESSIFS : niveau Extreme uniquement ---
        if ($tweaksExtremeAutorises) {
            Write-Host "  (Niveau Extreme : tweaks agressifs core parking + reseau)" -ForegroundColor Red
            # 3) Core parking off (favorise les 1% low)
            try {
                powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR CPMINCORES 100 2>$null
                powercfg -setactive SCHEME_CURRENT 2>$null
                $script:tweaksApplied += "Core parking desactive (Extreme)"; Write-Log "Core parking off." "OK"
            } catch { Write-Log "Core parking : $_" "WARN" }

            # 5) Reseau : Nagle off + throttling off (latence)
            Apply-Tweak "Network throttling off (Extreme)" "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" "NetworkThrottlingIndex" 0xffffffff
            foreach ($if in (Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -EA SilentlyContinue)) {
                Apply-Tweak "Nagle off ($($if.PSChildName)) (Extreme)" $if.PSPath "TcpAckFrequency" 1
                Apply-Tweak "TCPNoDelay ($($if.PSChildName)) (Extreme)" $if.PSPath "TCPNoDelay" 1
            }

            # SysMain (SuperFetch) : contre-productif sur SSD, peut causer des micro-stutters.
            # On ne le desactive QUE si un SSD est present (sur HDD il reste utile).
            if ($hasSSD) {
                try {
                    Stop-Service -Name "SysMain" -Force -EA SilentlyContinue
                    Set-Service -Name "SysMain" -StartupType Disabled -EA SilentlyContinue
                    $script:tweaksApplied += "SysMain desactive (SSD detecte) (Extreme)"
                    Write-Log "SysMain desactive (SSD present)." "OK"
                } catch { Write-Log "SysMain : $_" "WARN" }
            } else {
                Write-Log "SysMain conserve (pas de SSD, il reste utile sur HDD)." "INFO"
            }

            # DiagTrack (telemetrie "Experiences des utilisateurs connectes") : desactivable sans risque fonctionnel.
            try {
                Stop-Service -Name "DiagTrack" -Force -EA SilentlyContinue
                Set-Service -Name "DiagTrack" -StartupType Disabled -EA SilentlyContinue
                $script:tweaksApplied += "Telemetrie DiagTrack desactivee (Extreme)"
                Write-Log "DiagTrack desactive." "OK"
            } catch { Write-Log "DiagTrack : $_" "WARN" }

            # Taches planifiees de telemetrie lourdes (CEIP, Compatibility Appraiser) : sans risque, reversibles.
            $tachesTelemetrie = @(
                "\Microsoft\Windows\Customer Experience Improvement Program\Consolidator",
                "\Microsoft\Windows\Customer Experience Improvement Program\UsbCeip",
                "\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser"
            )
            $tachesCoupe = 0
            foreach ($task in $tachesTelemetrie) {
                try {
                    Disable-ScheduledTask -TaskPath (Split-Path $task) -TaskName (Split-Path $task -Leaf) -EA Stop | Out-Null
                    $tachesCoupe++
                } catch {}
            }
            if ($tachesCoupe -gt 0) { $script:tweaksApplied += "$tachesCoupe tache(s) de telemetrie desactivee(s) (Extreme)"; Write-Log "$tachesCoupe taches telemetrie desactivees." "OK" }

            # Cache shaders NVIDIA agrandi : reduit le stuttering de compilation (DX12/Vulkan).
            # Sans risque et reversible. On adapte la taille a l'espace SSD dispo (pas 10 Go sur un disque plein).
            if ($gpuVendor -eq "NVIDIA") {
                try {
                    $libreSysGB = ($volumes | Where-Object { $_.Lettre -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1).LibreGB
                    # Taille prudente : 4 Go si peu d'espace, 8 Go si confortable
                    $cacheGB = if ($libreSysGB -ge 40) { 8 } elseif ($libreSysGB -ge 15) { 4 } else { 0 }
                    if ($cacheGB -gt 0) {
                        $nvPath = "HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak"
                        Backup-RegValue $nvPath "OglShaderCacheSize"
                        if (-not (Test-Path $nvPath)) { New-Item -Path $nvPath -Force | Out-Null }
                        Set-ItemProperty -Path $nvPath -Name "OglShaderCacheSize" -Value ([int64]($cacheGB * 1GB)) -Type QWord -Force
                        $script:tweaksApplied += "Cache shaders NVIDIA a $cacheGB Go (anti-stutter) (Extreme)"
                        Write-Log "Cache shaders NVIDIA regle a $cacheGB Go." "OK"
                    } else {
                        Write-Log "Cache shaders NVIDIA non agrandi : disque systeme trop plein ($libreSysGB Go)." "WARN"
                    }
                } catch { Write-Log "Cache shaders NVIDIA : $_" "WARN" }
            }

            # MMCSS : Windows reserve 20% du CPU aux taches de fond des qu'un media tourne.
            # On reduit cette reserve et on pousse la priorite des jeux. Reversible.
            $sysProfile = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            $gamesTask  = "$sysProfile\Tasks\Games"
            Apply-Tweak "MMCSS SystemResponsiveness=0 (Extreme)" $sysProfile "SystemResponsiveness" 0
            try {
                # Backup AVANT la creation de la cle : sinon on exporte une cle vide
                # et l'Undo n'a plus rien a restaurer.
                Backup-RegValue $gamesTask "GPU Priority"
                foreach ($vn in @("Priority","Scheduling Category","SFIO Priority")) { Register-TweakValue $gamesTask $vn }
                if (-not (Test-Path $gamesTask)) { New-Item -Path $gamesTask -Force | Out-Null }
                Set-ItemProperty $gamesTask "GPU Priority" 8 -Type DWord -Force
                Set-ItemProperty $gamesTask "Priority" 6 -Type DWord -Force
                Set-ItemProperty $gamesTask "Scheduling Category" "High" -Type String -Force
                Set-ItemProperty $gamesTask "SFIO Priority" "High" -Type String -Force
                $script:tweaksApplied += "Priorite jeux MMCSS poussee (Extreme)"
                Write-Log "MMCSS priorite jeux poussee." "OK"
            } catch { Write-Log "MMCSS jeux : $_" "WARN" }

            # DisablePagingExecutive : verrouille noyau+pilotes en RAM (pas de swap) si RAM >= 16 Go.
            if ($ramTotalGB -ge 16) {
                Apply-Tweak "Kernel verrouille en RAM (Extreme)" "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management" "DisablePagingExecutive" 1
            }

            # Optimisations jeux fenetres (borderless) : latence proche du plein ecran exclusif.
            Apply-Tweak "Optim jeux fenetres (Extreme)" "HKCU:\System\GameConfigStore" "GameDVR_DSEBehavior" 2

            # Suspension selective USB off : evite les drops sur souris haute frequence (1000/4000/8000 Hz).
            try {
                powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba4d5a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 2>$null
                powercfg /setactive SCHEME_CURRENT 2>$null
                $script:tweaksApplied += "Suspension selective USB desactivee (Extreme)"
                Write-Log "Suspension selective USB desactivee." "OK"
            } catch { Write-Log "USB selective suspend : $_" "WARN" }

            # Win32PrioritySeparation : donne des tranches CPU plus longues a l'appli au premier plan (le jeu).
            # Reversible (simple cle registre), sans risque de boot.
            Apply-Tweak "Focus CPU premier plan (Extreme)" "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" "Win32PrioritySeparation" 38

            # MSI Mode sur la carte RESEAU uniquement (safe et benefique).
            # PAS sur USB/NVMe en masse : trop risque (peripheriques qui peuvent ne plus repondre).
            try {
                $netPnp = Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.Name -match "Ethernet|GbE|Network|Wi-?Fi|Wireless" -and $_.PNPDeviceID -like "PCI*" }
                foreach ($n in $netPnp) {
                    $msiN = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($n.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
                    if (Test-Path (Split-Path $msiN)) {
                        Backup-RegValue $msiN "MSISupported"
                        if (-not (Test-Path $msiN)) { New-Item -Path $msiN -Force | Out-Null }
                        Set-ItemProperty -Path $msiN -Name "MSISupported" -Value 1 -Type DWord -Force
                        $script:tweaksApplied += "MSI Mode carte reseau (Extreme)"
                        Write-Log "MSI Mode active sur carte reseau : $($n.Name)" "OK"
                    }
                }
            } catch { Write-Log "MSI reseau : $_" "WARN" }

            # C-States / EPP : empeche le CPU de s'endormir en jeu (reactivite instantanee).
            # Via powercfg officiel, reversible, sans risque de boot.
            try {
                # EPP a 0 (performance absolue)
                powercfg -attributes SUB_PROCESSOR 36687f9e-e3a5-4dbf-b1dc-15eb381c686c -ATTRIB_HIDE 2>$null
                powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 36687f9e-e3a5-4dbf-b1dc-15eb381c686c 0 2>$null
                # Processor Idle Disable (coeurs toujours prets)
                powercfg -attributes SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad -ATTRIB_HIDE 2>$null
                powercfg -setacvalueindex SCHEME_CURRENT SUB_PROCESSOR 5d76a2ca-e8c0-402f-a133-2158492d58ad 1 2>$null
                powercfg -setactive SCHEME_CURRENT 2>$null
                $script:tweaksApplied += "CPU C-States bloques + EPP perf max (Extreme)"
                Write-Log "Latence de reveil CPU annulee (C-States, EPP)." "OK"
            } catch { Write-Log "C-States/EPP : $_" "WARN" }

            # Reactivite de l'interface : delai des menus a 0 (fluidite ressentie de l'OS). Sans risque.
            Apply-Tweak "Delai menus a 0 (Extreme)" "HKCU:\Control Panel\Desktop" "MenuShowDelay" 0 "String"
            Apply-Tweak "Bureau en processus separe (Extreme)" "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer" "DesktopProcess" 1

            # FSO (Fullscreen Optimizations) off : rendu exclusif GPU, moins de stutter/input lag en plein ecran.
            $gc = "HKCU:\System\GameConfigStore"
            if (-not (Test-Path $gc)) { New-Item -Path $gc -Force | Out-Null }
            Apply-Tweak "FSO off - FSEBehaviorMode (Extreme)" $gc "GameDVR_FSEBehaviorMode" 2
            Apply-Tweak "FSO off - HonorUserFSE (Extreme)" $gc "GameDVR_HonorUserFSEBehaviorMode" 1

            # Raw Input souris : desactive "Ameliorer la precision du pointeur" (acceleration).
            # Garantit le 1:1, essentiel en FPS. Reversible.
            Apply-Tweak "Souris acceleration off - MouseSpeed (Extreme)" "HKCU:\Control Panel\Mouse" "MouseSpeed" 0 "String"
            Apply-Tweak "Souris acceleration off - Threshold1 (Extreme)" "HKCU:\Control Panel\Mouse" "MouseThreshold1" 0 "String"
            Apply-Tweak "Souris acceleration off - Threshold2 (Extreme)" "HKCU:\Control Panel\Mouse" "MouseThreshold2" 0 "String"

            # LSO (Large Send Offload) off : reduit le jitter reseau en jeu (paquets non regroupes).
            # Reversible via Enable-NetAdapterLso. On NE touche PAS au checksum offload (peut charger un CPU faible).
            try {
                Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
                    Disable-NetAdapterLso -Name $_.Name -IPv4 -EA SilentlyContinue
                }
                $script:tweaksApplied += "LSO reseau desactive - anti-jitter (Extreme)"
                Write-Log "LSO desactive sur les cartes reseau actives." "OK"
            } catch { Write-Log "LSO : $_" "WARN" }

            # RSS (Receive Side Scaling) : distribue les interruptions reseau sur plusieurs coeurs
            # au lieu du seul Core 0. Souvent deja actif par defaut, mais on le force. Reversible.
            try {
                Enable-NetAdapterRss -Name "*" -EA SilentlyContinue
                $script:tweaksApplied += "RSS reseau active - Core 0 desengorge (Extreme)"
                Write-Log "RSS active (charge reseau repartie sur plusieurs coeurs)." "OK"
            } catch { Write-Log "RSS : $_" "WARN" }
        }

        # --- Tweak COMPETITION uniquement : reduit une protection de securite Windows ---
        # (VBS / Memory Integrity). PAS un tweak de confort comme les autres : ca coupe une
        # defense contre les rootkits/malwares sophistiques pour un gain FPS mesurable sur
        # certains PC. Reversible via Undo + reboot, mais ce n'est PAS anodin. On exige donc
        # une confirmation ECRITE distincte (pas juste o/N) et on trace tout dans le log,
        # avec la machine et l'heure : c'est la preuve que Valentin a choisi cette action en
        # connaissance de cause pour ce client precis (voir DECHARGE-CLIENT.md).
        if ($tweaksCompetitionAutorises) {
            Write-Host "`n===============================================" -ForegroundColor Magenta
            Write-Host "  NIVEAU COMPETITION - Reduction de securite Windows" -ForegroundColor Magenta
            Write-Host "===============================================" -ForegroundColor Magenta
            Write-Host "  Ce tweak desactive VBS / Memory Integrity (Isolation du noyau)." -ForegroundColor Yellow
            Write-Host "  Gain FPS reel sur certains PC, MAIS reduit la protection contre" -ForegroundColor Yellow
            Write-Host "  les rootkits et malwares sophistiques. Ce n'est PAS un simple" -ForegroundColor Yellow
            Write-Host "  confort : c'est un compromis securite contre performance." -ForegroundColor Yellow
            Write-Host "  A n'appliquer QUE si le client a ete informe et est volontaire" -ForegroundColor Yellow
            Write-Host "  (usage competitif/esport). Necessite un redemarrage pour agir." -ForegroundColor Yellow
            Write-Host "  Reversible : Undo (menu 1 > 4) restaure la cle, puis redemarrer.`n" -ForegroundColor Gray

            $confirmation = Read-Host "  Pour confirmer, tape exactement : JE CONFIRME"
            if ($confirmation -ceq "JE CONFIRME") {
                Apply-Tweak "VBS/Memory Integrity desactive (Competition)" `
                    "HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" `
                    "Enabled" 0
                Write-Log "COMPETITION : VBS/Memory Integrity desactive sur $env:COMPUTERNAME. Confirmation ecrite recue de l'operateur. Redemarrage requis pour effet." "WARN"
                Write-Host "`n  Applique. REDEMARRE la machine pour que ca prenne effet." -ForegroundColor Green
                Write-Host "  Pour revenir en arriere : menu 1 > 4 (Undo), puis redemarrer." -ForegroundColor Gray
            } else {
                Write-Log "COMPETITION : tweak VBS/Memory Integrity NON applique (confirmation ecrite absente ou incorrecte)." "WARN"
                Write-Host "`n  Confirmation non reconnue : le tweak COMPETITION n'a PAS ete applique." -ForegroundColor Yellow
            }
        }

        Write-Log "$($script:tweaksApplied.Count) tweaks appliques. Backup: $tweakBackup" "OK"
        Write-Host "`nBackup registre : $tweakBackup" -ForegroundColor Green
        Write-Host "Pour tout annuler : double-clic sur ce .reg + point de restauration disponible." -ForegroundColor Gray
        Write-Host "NB : SysMain/DiagTrack sont des SERVICES - pour les reactiver : Set-Service SysMain -StartupType Automatic." -ForegroundColor Gray
    }
}

# --- MSI Mode pour le GPU (reduit la latence des interruptions) ---
# Modification registre REVERSIBLE, uniquement sur confirmation.
$msiState = "Non verifie"
try {
    # Trouve la cle PCI du GPU pour lire/ecrire MSISupported
    $gpuPnp = Get-CimInstance Win32_PnPEntity -EA SilentlyContinue | Where-Object { $_.Name -eq $gpuReel.Name } | Select-Object -First 1
    if ($gpuPnp -and $gpuPnp.PNPDeviceID) {
        $msiPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($gpuPnp.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
        $cur = (Get-ItemProperty $msiPath -Name MSISupported -EA SilentlyContinue).MSISupported
        $msiState = if ($cur -eq 1) { "Deja actif" } elseif ($cur -eq 0) { "Inactif" } else { "Non defini (defaut Windows)" }

        if ($Interactive -and $tweaksGamingAutorises -and $msiState -ne "Deja actif") {
            Write-Host "`n=== MSI Mode GPU ($($gpuReel.Name)) ===" -ForegroundColor Cyan
            Write-Host "Reduit la latence des interruptions GPU. Reversible. Necessite un redemarrage." -ForegroundColor Gray
            if (Confirm-Action "Activer le MSI Mode pour le GPU ?") {
                Backup-RegValue $msiPath "MSISupported"
                if (-not (Test-Path $msiPath)) { New-Item -Path $msiPath -Force | Out-Null }
                Set-ItemProperty -Path $msiPath -Name MSISupported -Value 1 -Type DWord -Force
                $msiState = "Active (redemarrage requis)"
                Write-Log "MSI Mode active pour $($gpuReel.Name)." "OK"
            }
        }
    }
} catch { Write-Log "MSI Mode : $_" "WARN" }

# --- MPO (Multi-Plane Overlay) : LEVIER CONDITIONNEL (cf passation section 9) ---
# A ne desactiver QUE si le client constate un scintillement noir ou des micro-freezes
# en jeu FENETRE. C'est le correctif officiel Microsoft/NVIDIA pour ce symptome precis,
# pas une optimisation de confort. Reversible via manifeste, redemarrage requis.
if ($Interactive -and $tweaksGamingAutorises) {
    try {
        $mpoPath = "HKLM:\SOFTWARE\Microsoft\Windows\Dwm"
        $mpoCur  = (Get-ItemProperty $mpoPath -Name OverlayTestMode -EA SilentlyContinue).OverlayTestMode
        if ($mpoCur -ne 5) {
            Write-Host "`n=== MPO (Multi-Plane Overlay) ===" -ForegroundColor Cyan
            Write-Host "A ne toucher QUE si le client constate un scintillement noir ou des" -ForegroundColor Gray
            Write-Host "micro-freezes en jeu FENETRE / borderless. Sinon laisser tel quel." -ForegroundColor Gray
            if (Confirm-Action "Le client constate-t-il ce scintillement / stutter en jeu fenetre ?") {
                Backup-RegValue $mpoPath "OverlayTestMode"
                if (-not (Test-Path $mpoPath)) { New-Item -Path $mpoPath -Force | Out-Null }
                Set-ItemProperty -Path $mpoPath -Name OverlayTestMode -Value 5 -Type DWord -Force
                $script:tweaksApplied += "MPO desactive (scintillement fenetre constate)"
                Write-Log "MPO desactive (OverlayTestMode=5). Redemarrage requis." "OK"
            } else {
                Write-Log "MPO laisse actif (aucun symptome signale)." "INFO"
            }
        }
    } catch { Write-Log "MPO : $_" "WARN" }
}

# ============================================================
#  RAPPORT HTML BRANDE
# ============================================================
# ============================================================
#  MOTEUR DE RAISONNEMENT : croise les donnees et conclut
# ============================================================
# Chaque diagnostic produit une conclusion PRIORISEE (P1/P2/P3) en langage clair,
# en reliant les faits entre eux plutot qu'en les listant separement.
Write-Log "Analyse croisee (moteur de raisonnement)..."
$diagnostics = @()   # @{ Prio(1/2/3); Titre; Constat; Action }

# Raccourcis de lecture des donnees collectees
$volSysR = $volumes | Where-Object { $_.Lettre -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
if (-not $volSysR) { $volSysR = $volumes | Where-Object { $_.Lettre -eq "C" } | Select-Object -First 1 }
$aCrash = $events | Where-Object { $_.Id -eq 41 -or $_.Id -eq 6008 }
$aVolsnap = $events | Where-Object { $_.Id -eq 36 -or $_.ProviderName -match "Volsnap" }
$ramBase = $freqActuelle -and ($vitesseBase -contains [int]$freqActuelle)
$sfcKo = $sfcResult -match "NON reparees|Erreur"
$defenderOff = $secu | Where-Object { $_.Item -match "Defender|Antivirus" -and $_.Niveau -eq "bad" }
$fwOff = $secu | Where-Object { $_.Item -match "Pare-feu" -and $_.Niveau -eq "bad" }
$diskLent = $perf | Where-Object { $_.Item -match "Lecture disque" -and $_.Niveau -eq "bad" }

# --- P1 : Disque systeme sature (et ses consequences en chaine) ---
if ($volSysR -and $volSysR.PctLibre -lt 15) {
    $consequences = @()
    if ($aVolsnap) { $consequences += "les points de restauration ne peuvent plus etre crees (cliches annules detectes)" }
    if ($aCrash)   { $consequences += "un plantage recent a eu lieu (un disque sature peut y contribuer)" }
    $lien = if ($consequences) { " Consequences constatees : " + ($consequences -join " ; ") + "." } else { "" }
    # ou est passee la place : le plus gros poste "manuel" + le total des caches surs
    $ouChercher = @()
    $topManuel = $recoverable | Where-Object { $_.Classe -eq 'manuel' } | Sort-Object TailleMB -Descending | Select-Object -First 1
    if ($topManuel) { $ouChercher += "$($topManuel.Item)" }
    if ($recupSurTotalMB -ge 1000) { $ouChercher += "~$([math]::Round($recupSurTotalMB/1024,1)) Go de caches nettoyables en un clic (voir section espace disque)" }
    if (($recoverable | Where-Object { $_.Type -eq 'winsxs' })) { $ouChercher += "magasin de composants WinSxS surdimensionne" }
    $ouTxt = if ($ouChercher) { " A regarder en premier : " + ($ouChercher -join " ; ") + "." } else { "" }
    $prio = if ($volSysR.PctLibre -lt 10) { 1 } else { 2 }
    $diagnostics += @{
        Prio=$prio; Titre=$(if ($prio -eq 1) { "Disque systeme sature" } else { "Disque systeme un peu juste" })
        Constat="Le disque $($volSysR.Lettre): n'a que $($volSysR.LibreGB) Go libres ($($volSysR.PctLibre)%).$(if($prio -eq 1){' C''est la cause racine la plus probable des lenteurs et de l''instabilite.'})$lien$ouTxt"
        Action="Nettoyer les caches [SUR] (section espace disque), faire le tri dans le dossier Telechargements, puis deplacer les jeux vers un autre disque si besoin. Viser 15-20% libres."
    }
}

# --- P1 : Antivirus ou pare-feu desactive (securite critique) ---
if ($defenderOff -or $fwOff) {
    $quoi = @(); if($defenderOff){$quoi+="l'antivirus"}; if($fwOff){$quoi+="le pare-feu"}
    $diagnostics += @{
        Prio=1; Titre="Protection desactivee"
        Constat="Point critique : $($quoi -join ' et ') $(if($quoi.Count -gt 1){'sont'}else{'est'}) inactif. La machine est exposee."
        Action="Reactiver la protection immediatement (Securite Windows), sauf si un antivirus tiers reconnu prend le relais."
    }
}

# --- P2 : XMP non active (perte de perfs identifiee) ---
if ($ramBase) {
    $diagnostics += @{
        Prio=2; Titre="RAM bridee (XMP/EXPO inactif)"
        Constat="La RAM tourne a $freqActuelle MHz, la frequence par defaut. Si les barrettes sont prevues plus rapides, du potentiel est perdu, surtout sur les 1% low en jeu."
        Action="Activer le profil XMP (Intel) ou EXPO (AMD) dans le BIOS/UEFI. Verifier d'abord la vitesse annoncee des barrettes. Gain gratuit."
    }
}

# --- P2 : Corruption systeme non reparee ---
if ($sfcKo) {
    $diagnostics += @{
        Prio=2; Titre="Fichiers systeme corrompus"
        Constat="SFC a detecte des corruptions qu'il n'a pas toutes reparees. Peut causer bugs, plantages et comportements erratiques."
        Action="Relancer DISM /RestoreHealth puis SFC, dans cet ordre. Si ca persiste, envisager une reparation d'installation Windows."
    }
}

# --- P2 : Disque lent (HDD systeme ou SSD fatigue) ---
if ($diskLent) {
    $diagnostics += @{
        Prio=2; Titre="Disque systeme lent"
        Constat="Le benchmark montre un debit faible sur le disque systeme. Chargements longs et systeme peu reactif."
        Action="Si c'est un HDD : migrer Windows sur SSD (upgrade le plus rentable). Si c'est un SSD : verifier son taux de remplissage et sa sante SMART."
    }
}

# --- P3 : Beaucoup d'elements au demarrage encore actifs ---
$startupActifs = ($startupItems | Where-Object { $_.Status -eq "Actif" -and $_.Classe -ne "rouge" }).Count
if ($startupActifs -ge 8) {
    $diagnostics += @{
        Prio=3; Titre="Demarrage charge"
        Constat="$startupActifs programmes non essentiels se lancent encore au demarrage. Boot plus lent et RAM consommee en fond."
        Action="Desactiver les lanceurs et applis non essentiels (section demarrage) : ils s'ouvriront a la demande."
    }
}

# --- P3 : Erreurs DCOM/GameBar recurrentes (bruit, souvent benin) ---
$dcomCount = ($events | Where-Object { $_.Id -eq 10010 -and $_.Msg -match "GameBar|Presence" }).Count
if ($dcomCount -ge 5) {
    $diagnostics += @{
        Prio=3; Titre="Erreurs Game Bar recurrentes (mineur)"
        Constat="$dcomCount erreurs DCOM liees a la Game Bar dans les logs. Generalement benin, mais pollue les journaux."
        Action="Si la Game Bar n'est pas utilisee, la desactiver (Parametres > Jeux) elimine ces erreurs."
    }
}

# Tri par priorite
$diagnostics = $diagnostics | Sort-Object { $_.Prio }
$nbP1 = @($diagnostics | Where-Object { $_.Prio -eq 1 }).Count
$nbP2 = @($diagnostics | Where-Object { $_.Prio -eq 2 }).Count
$nbP3 = @($diagnostics | Where-Object { $_.Prio -eq 3 }).Count
Write-Log "Analyse : $nbP1 critique(s), $nbP2 important(s), $nbP3 mineur(s)." "OK"

# ============================================================
#  RAPPORT HTML BRANDE
# ============================================================
Write-Log "Generation du rapport..."
$reportFile = "$ReportDir\Diagnostic-$Stamp.html"
$now = Get-Date -Format 'dddd dd MMMM yyyy - HH:mm'
$machine = $env:COMPUTERNAME

# --- Alertes prioritaires (bandeau en haut du rapport) ---
$alertes = @()
# Disque systeme presque plein
$volSys = $volumes | Where-Object { $_.Lettre -eq $env:SystemDrive.TrimEnd(':') } | Select-Object -First 1
if (-not $volSys) { $volSys = $volumes | Where-Object { $_.Lettre -eq "C" } | Select-Object -First 1 }
if ($volSys -and $volSys.PctLibre -lt 10) {
    $alertes += "Disque systeme ($($volSys.Lettre):) presque plein : $($volSys.LibreGB) Go libres ($($volSys.PctLibre)%). C'est une cause majeure de lenteurs et plantages. Liberer de l'espace en priorite."
}
# Crash / arret inattendu recent (Kernel-Power 41)
$crash = $events | Where-Object { $_.Id -eq 41 -or $_.Id -eq 6008 } | Select-Object -First 1
if ($crash) {
    $alertes += "Arret inattendu / plantage detecte le $($crash.TimeCreated.ToString('dd-MM')) (l'ordinateur s'est eteint ou fige sans arret propre). A surveiller si ca se repete."
}
# Disque dur mecanique comme systeme (rare mais lourd)
if ($volSys -and ($disks | Where-Object { $_.Type -eq "HDD" }) -and -not ($disks | Where-Object { $_.Type -match "SSD" })) {
    $alertes += "Aucun SSD : disque systeme mecanique, gros goulot. Migrer Windows sur SSD est l'upgrade le plus rentable."
}

function Row { param([string[]]$cells,[string]$cls="") $tds=($cells | ForEach-Object {"<td>$_</td>"}) -join ""; "<tr class='$cls'>$tds</tr>" }

$gpuRows = Row @("$(HtmlEnc $gpuReel.Name)","$($gpuReel.VRAM_GB) Go","$($gpuReel.DriverVersion)","$($gpuReel.DriverDate)")
$diskRows = ($disks | ForEach-Object {
    $sc = if($_.Sante -ne "Healthy" -and $_.Sante){"bad"}else{"ok"}
    "<tr><td>$(HtmlEnc $_.Nom)</td><td>$($_.Type)</td><td>$($_.TailleGB) Go</td><td class='$sc'>$($_.Sante)</td><td>$(if($_.Usure){"$($_.Usure)%"}else{'-'})</td></tr>"
}) -join "`n"
$volRows = ($volumes | ForEach-Object {
    $sc = if($_.PctLibre -lt 10){"bad"}elseif($_.PctLibre -lt 20){"warn"}else{"ok"}
    "<tr><td>$($_.Lettre):</td><td>$($_.FS)</td><td>$($_.TotalGB) Go</td><td>$($_.LibreGB) Go</td><td class='$sc'>$($_.PctLibre)%</td></tr>"
}) -join "`n"
$driverRows = ($driversKey | ForEach-Object {
    $isGpu = $_.Categorie -eq "GPU"
    # AgeAns=99 = date inconnue -> gris neutre (mut), surtout PAS rouge (trompeur)
    if ($_.AgeAns -ge 99) { $ageCls="mut"; $ageTxt="date inconnue" }
    elseif ($_.AgeAns -ge 4) { $ageCls="bad"; $ageTxt="$($_.AgeAns) an(s)" }
    elseif ($_.AgeAns -ge 2) { $ageCls="warn"; $ageTxt="$($_.AgeAns) an(s)" }
    else { $ageCls="ok"; $ageTxt="$($_.AgeAns) an(s)" }
    $cls = if($isGpu){"gpu"}else{""}
    "<tr class='$cls'><td>$($_.Categorie)</td><td>$(HtmlEnc $_.Peripherique)</td><td>$(HtmlEnc $_.Fabricant)</td><td>$($_.Version)</td><td class='$ageCls'>$ageTxt</td></tr>"
}) -join "`n"
if (-not $driverRows) { $driverRows = "<tr><td colspan='5'>Aucun pilote cle detecte</td></tr>" }
# Resume des pilotes systeme (comptes, pas listes)
$sysCount = @($driversSys).Count
$startupRows = if($startupItems){($startupItems | Sort-Object Type, Name | ForEach-Object { $b=if($_.Status -eq "Desactive"){"<span class='warn'>Desactive</span>"}else{"<span class='ok'>Actif</span>"}; "<tr><td>$($_.Type)</td><td>$(HtmlEnc $_.Name)</td><td class='mono'>$(HtmlEnc $_.Command)</td><td>$b</td></tr>" }) -join "`n"}else{"<tr><td colspan='4'>Aucun</td></tr>"}
$residueRows = if($residues){($residues | ForEach-Object { $b=if($_.Deleted -eq "Oui"){"<span class='warn'>Supprime</span>"}else{"<span class='ok'>Conserve</span>"}; "<tr><td>$(HtmlEnc $_.Name)</td><td>$($_.SizeMB) Mo</td><td>$(HtmlEnc $_.Related)</td><td class='mono'>$(HtmlEnc $_.Path)</td><td>$b</td></tr>" }) -join "`n"}else{"<tr><td colspan='5'>Aucun residu detecte</td></tr>"}
$updateRows = if($updates.Count){($updates | ForEach-Object { "<tr><td>$(HtmlEnc $_)</td></tr>" }) -join "`n"}else{"<tr><td>Systeme a jour</td></tr>"}
$cleanRows = if($cleanReport){($cleanReport | ForEach-Object { "<tr><td>$(HtmlEnc $_.Categorie)</td><td>$($_.LibereMB)</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Nettoyage non execute</td></tr>"}
$bigFolderRows = if($bigFolders){($bigFolders | ForEach-Object { "<tr><td class='mono'>$(HtmlEnc $_.Chemin)</td><td>$($_.TailleGB) Go</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Analyse non disponible</td></tr>"}
$bigAppRows = if($bigApps){($bigApps | ForEach-Object { $g=[math]::Round($_.TailleMB/1024,1); "<tr><td>$(HtmlEnc $_.Nom)</td><td>$(if($g -ge 1){"$g Go"}else{"$($_.TailleMB) Mo"})</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Analyse non disponible</td></tr>"}
$recovRows = if($recoverable){($recoverable | ForEach-Object { $t=if($_.TailleMB -is [string]){$_.TailleMB}else{"$($_.TailleMB) Mo"}; $f=if($_.Fait -eq "Oui"){"<span class='warn'>Traite</span>"}else{"<span class='ok'>Disponible</span>"}; "<tr><td>$(HtmlEnc $_.Item)</td><td>$t</td><td>$f</td></tr>" }) -join "`n"}else{"<tr><td colspan='3'>Rien de recuperable detecte</td></tr>"}
$dupRows = if($dupGroups){($dupGroups | ForEach-Object { $etat=if($_.Supprimes -gt 0){"<span class='warn'>$($_.Supprimes) supprime(s)</span>"}else{"<span class='ok'>Conserve</span>"}; $gain=[math]::Round($_.TailleMB*($_.NbCopies-1),1); "<tr><td>$(HtmlEnc $_.Nom)</td><td>$($_.TailleMB) Mo</td><td>$($_.NbCopies)</td><td>$gain Mo</td><td>$etat</td></tr>" }) -join "`n"}else{"<tr><td colspan='5'>Aucun doublon detecte</td></tr>"}
$balanceRows = if($balance){($balance | ForEach-Object {
    $ic = if($_.Niveau -eq "attention"){"<span class='warn'>&#9888; A verifier</span>"}else{"<span class='ok'>&#10003; OK</span>"}
    "<tr><td>$ic</td><td>$(HtmlEnc $_.Constat)</td></tr>"
}) -join "`n"}else{"<tr><td colspan='2'>Aucune observation</td></tr>"}
$eventRows = if($events){($events | ForEach-Object { $occ=if($_.Count -gt 1){"<span class='warn'>x$($_.Count)</span>"}else{"1"}; "<tr><td>$($_.TimeCreated.ToString('MM-dd HH:mm'))</td><td>$occ</td><td>$($_.Id)</td><td>$(HtmlEnc $_.ProviderName)</td><td>$(HtmlEnc $_.Msg)</td></tr>" }) -join "`n"}else{"<tr><td colspan='5'>Aucun evenement critique sur 7 jours</td></tr>"}
$tempRows = if($temps){($temps | ForEach-Object { $tc=if($_.TempC -ge 85){"bad"}elseif($_.TempC -ge 75){"warn"}else{"ok"}; "<tr><td>$(HtmlEnc $_.Capteur)</td><td class='$tc'>$($_.TempC) &deg;C</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Capteurs ACPI non exposes. LibreHardwareMonitor ($($toolStatus.LHM)) donne le detail CPU/GPU en le lancant manuellement.</td></tr>"}

$sfcCls  = if($sfcResult -match "OK"){"ok"}elseif($sfcResult -match "NON reparees|Erreur"){"bad"}elseif($sfcResult -match "repar|attente|REDEMARRER"){"warn"}else{"mut"}
$dismCls = if($dismResult -match "OK"){"ok"}elseif($dismResult -match "repar"){"warn"}else{"bad"}
$netHtml = if($net){ $nc=if($net.LatenceMs -ge 80 -or $net.PerteePct -gt 0){"warn"}else{"ok"}; "<span class='$nc'>$($net.LatenceMs) ms, perte $($net.PerteePct)%</span>" }else{"Test indisponible"}
$secuRows = if($secu){($secu | ForEach-Object { "<tr><td>$(HtmlEnc $_.Item)</td><td class='$($_.Niveau)'>$(HtmlEnc $_.Etat)</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Analyse non disponible</td></tr>"}
$netDetailRows = if($netDetail){($netDetail | ForEach-Object { "<tr><td>$(HtmlEnc $_.Cible)</td><td class='$($_.Niveau)'>$(HtmlEnc $_.Latence)</td><td>$(HtmlEnc $_.Perte)</td></tr>" }) -join "`n"}else{"<tr><td colspan='3'>Analyse non disponible</td></tr>"}
$perfRows = if($perf){($perf | ForEach-Object { "<tr><td>$(HtmlEnc $_.Item)</td><td class='$($_.Niveau)'>$(HtmlEnc $_.Valeur)</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Analyse non disponible</td></tr>"}
$topRamRows = if($topRam){($topRam | ForEach-Object { "<tr><td>$(HtmlEnc $_.Nom)</td><td>$($_.MB) Mo</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>-</td></tr>"}
$topCpuRows = if($topCpu){($topCpu | ForEach-Object { "<tr><td>$(HtmlEnc $_.Nom)</td><td>$($_.Pct) %</td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>-</td></tr>"}
$gpuTipRows = if($gpuTips){($gpuTips | ForEach-Object { "<li>$(HtmlEnc $_)</li>" }) -join "`n"}else{""}
$tweakRows = if($script:tweaksApplied){($script:tweaksApplied | ForEach-Object { "<tr><td>$(HtmlEnc $_)</td><td><span class='ok'>Applique</span></td></tr>" }) -join "`n"}else{"<tr><td colspan='2'>Aucun tweak applique (non lance ou refuse)</td></tr>"}
# Moteur de raisonnement : cartes de diagnostic priorisees
$diagCards = if($diagnostics){($diagnostics | ForEach-Object {
    $pcls = switch($_.Prio){ 1{"diagp1"} 2{"diagp2"} default{"diagp3"} }
    $plabel = switch($_.Prio){ 1{"CRITIQUE"} 2{"IMPORTANT"} default{"MINEUR"} }
    "<div class='diagcard $pcls'><div class='diaghead'><span class='diagbadge'>$plabel</span> $(HtmlEnc $_.Titre)</div><div class='diagconstat'>$(HtmlEnc $_.Constat)</div><div class='diagaction'><b>Action :</b> $(HtmlEnc $_.Action)</div></div>"
}) -join "`n"}else{"<div class='diagcard diagok'>Aucun probleme majeur detecte. La machine est globalement saine.</div>"}
$diagResume = "$nbP1 critique(s) &middot; $nbP2 important(s) &middot; $nbP3 mineur(s)"

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Diagnostic $machine</title>
<style>
  :root{--bg:#23272e;--bg2:#1b1e24;--card:#2b2f37;--line:#3a3f4a;--txt:#f2f3f5;--mut:#9aa1ac;--red:#e23b3b;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171;}
  *{box-sizing:border-box;} body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg2);color:var(--txt);line-height:1.5;}
  .header{background:linear-gradient(160deg,#2b2f37,#1b1e24);padding:36px 32px;border-bottom:1px solid var(--line);}
  .logo{font-size:34px;font-weight:800;letter-spacing:-.5px;} .logo .u{color:var(--red);}
  .logo .sub{display:block;font-size:12px;font-weight:600;letter-spacing:.22em;color:var(--mut);margin-top:6px;}
  .meta{color:var(--mut);font-size:13px;margin-top:14px;}
  .wrap{padding:24px 32px;max-width:1150px;}
  h2{font-size:13px;margin:30px 0 10px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em;}
  h2::before{content:"";display:inline-block;width:3px;height:13px;background:var(--red);margin-right:8px;vertical-align:-1px;}
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;}
  .kv{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;}
  .kv .k{color:var(--mut);font-size:12px;} .kv .v{font-size:16px;font-weight:700;margin-top:2px;}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;overflow-x:auto;}
  table{width:100%;border-collapse:collapse;font-size:13px;} th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top;}
  th{color:var(--mut);font-weight:600;} tr.gpu td{color:var(--ok);font-weight:600;}
  .mono{font-family:Consolas,monospace;font-size:11px;color:var(--mut);word-break:break-all;}
  .ok{color:var(--ok);font-weight:600;} .warn{color:var(--warn);font-weight:600;} .bad{color:var(--bad);font-weight:600;} .mut{color:var(--mut);}
  .note{background:rgba(226,59,59,.08);border:1px solid rgba(226,59,59,.3);border-radius:8px;padding:12px 14px;font-size:13px;color:#f3b0b0;margin-top:12px;}
  .btn{display:inline-block;background:var(--red);color:#fff;padding:8px 16px;border-radius:7px;text-decoration:none;font-weight:600;font-size:13px;margin-top:10px;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
  .alertbox{background:rgba(248,113,113,.08);border:1px solid rgba(248,113,113,.35);border-radius:10px;padding:14px 16px;}
  .alertline{color:#f8b4b4;font-size:14px;font-weight:600;padding:5px 0;}
  .diagcard{border-radius:10px;padding:14px 16px;margin-bottom:10px;border:1px solid var(--line);background:var(--card);}
  .diaghead{font-size:15px;font-weight:700;margin-bottom:6px;}
  .diagbadge{display:inline-block;font-size:11px;font-weight:800;padding:2px 8px;border-radius:5px;margin-right:8px;vertical-align:1px;}
  .diagp1{border-left:4px solid var(--bad);} .diagp1 .diagbadge{background:var(--bad);color:#3a0d0d;}
  .diagp2{border-left:4px solid var(--warn);} .diagp2 .diagbadge{background:var(--warn);color:#3a2c05;}
  .diagp3{border-left:4px solid var(--mut);} .diagp3 .diagbadge{background:var(--mut);color:#1b1e24;}
  .diagok{border-left:4px solid var(--ok);color:var(--ok);font-weight:600;}
  .diagconstat{font-size:13px;color:var(--txt);margin-bottom:6px;}
  .diagaction{font-size:13px;color:var(--mut);}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Diagnostic complet &middot; Niveau : <b>$($niveau.ToUpper())</b></div>
</div>
<div class="wrap">

  $(if($alertes){"<h2>Points d'attention prioritaires</h2><div class='alertbox'>" + (($alertes | ForEach-Object { "<div class='alertline'>&#9888; $(HtmlEnc $_)</div>" }) -join "`n") + "</div>"})

  <h2>Analyse &amp; recommandations &nbsp;<span style="color:var(--mut);font-weight:400;text-transform:none;letter-spacing:0">($diagResume)</span></h2>
  $diagCards

  <h2>Synthese materiel</h2>
  <div class="grid">
    <div class="kv"><div class="k">Processeur</div><div class="v">$(HtmlEnc $cpu.Name)</div></div>
    <div class="kv"><div class="k">Carte mere</div><div class="v">$(HtmlEnc "$($bb.Manufacturer) $($bb.Product)")</div></div>
    <div class="kv"><div class="k">Memoire</div><div class="v">$ramTotalGB Go @ $(if($ramConfigured){$ramConfigured}else{$ramSpeed}) MHz ($ramSlotsUsed/$ramSlotsTotal slots)</div></div>
    <div class="kv"><div class="k">BIOS</div><div class="v">$(HtmlEnc $bios.SMBIOSBIOSVersion)</div></div>
    <div class="kv"><div class="k">Windows</div><div class="v">$(HtmlEnc $os.Caption) ($($os.Version))</div></div>
    <div class="kv"><div class="k">Reseau</div><div class="v">$netHtml</div></div>
  </div>

  <h2>Equilibre de configuration (pistes)</h2>
  <div class="card">
    <table><tr><th>Etat</th><th>Observation</th></tr>$balanceRows</table>
    <div class="note">Ce sont des pistes basees sur les composants, pas une mesure. Le vrai goulot d'etranglement se verifie <b>en charge</b> : lance un jeu avec l'overlay de LibreHardwareMonitor et compare l'utilisation CPU et GPU. Si le CPU est a 100% et le GPU en dessous, le CPU bride ; si c'est l'inverse, le GPU est le facteur limitant (normal et souhaitable).</div>
  </div>

  <h2>Carte graphique (priorite jeu)</h2>
  <div class="card">
    <table><tr><th>GPU</th><th>VRAM</th><th>Pilote</th><th>Date</th></tr>$gpuRows</table>
    <div class="note">winget met a jour l'application $gpuVendor, pas le pilote GPU lui-meme. Installe le pilote gaming a jour depuis l'appli constructeur ou le lien ci-dessous.</div>
    <a class="btn" href="$gpuLink" target="_blank">Dernier pilote $gpuVendor</a>
    $(if($gpuTips){"<div style='margin-top:14px'><b style='color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.05em'>Conseils $gpuVendor pour le jeu</b><ul style='margin:8px 0 0;padding-left:18px;font-size:13px;color:var(--txt)'>$gpuTipRows</ul></div>"})
    <div class="note">MSI Mode GPU : <b>$msiState</b>. Reduit la latence des interruptions (reversible, redemarrage requis).</div>
  </div>

  <h2>Temperatures</h2>
  <div class="card"><table><tr><th>Capteur</th><th>Temperature</th></tr>$tempRows</table></div>

  <h2>Disques &amp; sante SMART</h2>
  <div class="card">
    <table><tr><th>Disque</th><th>Type</th><th>Taille</th><th>Sante</th><th>Usure</th></tr>$diskRows</table>
    <div style="height:10px"></div>
    <table><tr><th>Volume</th><th>FS</th><th>Total</th><th>Libre</th><th>% libre</th></tr>$volRows</table>
    $(if($smartText){"<div class='note'>Rapport CrystalDiskInfo detaille disponible dans les logs.</div>"})
  </div>

  <h2>Sante du systeme</h2>
  <div class="grid">
    <div class="kv"><div class="k">SFC (fichiers systeme)</div><div class="v $sfcCls">$sfcResult</div></div>
    <div class="kv"><div class="k">DISM (image Windows)</div><div class="v $dismCls">$dismResult</div></div>
  </div>

  <h2>Securite</h2>
  <div class="card"><table><tr><th>Element</th><th>Etat</th></tr>$secuRows</table></div>

  <h2>Reseau approfondi</h2>
  <div class="card"><table><tr><th>Cible</th><th>Latence</th><th>Perte</th></tr>$netDetailRows</table></div>

  <h2>Performances</h2>
  <div class="card">
    <table><tr><th>Mesure</th><th>Valeur</th></tr>$perfRows</table>
    <div class="note">Mini-benchmark disque (50 Mo sequentiel) : indicatif, pas un test complet. SSD SATA sain : ~500 Mo/s. NVMe : 1500+ Mo/s. HDD : 80-150 Mo/s.</div>
  </div>

  <h2>Top consommateurs (RAM &amp; CPU)</h2>
  <div class="grid">
    <div class="card"><table><tr><th>Processus (RAM)</th><th>Memoire</th></tr>$topRamRows</table></div>
    <div class="card"><table><tr><th>Processus (CPU)</th><th>Charge</th></tr>$topCpuRows</table></div>
  </div>

  <h2>Tweaks gaming appliques</h2>
  <div class="card">
    <table><tr><th>Tweak</th><th>Etat</th></tr>$tweakRows</table>
    <div class="note">Tous reversibles. Backup registre dans C:\ProgramData\AlloValentin\Backups + point de restauration cree. Gain reel mais modeste (fluidite, 1% low) : l'essentiel des FPS vient du materiel, des reglages in-game (DLSS/FSR), du pilote GPU et de XMP.</div>
  </div>

  <h2>Pilotes materiels importants ($(@($driversKey).Count))</h2>
  <div class="card">
    <table><tr><th>Type</th><th>Peripherique</th><th>Fabricant</th><th>Version</th><th>Age</th></tr>$driverRows</table>
    <div class="note">Seuls les pilotes qui comptent pour les perfs et la connectivite sont detailles (GPU, chipset, reseau, audio, stockage, Bluetooth). $sysCount pilotes systeme Windows standards ne sont pas listes (ils se mettent a jour via Windows Update). "Date inconnue" = Windows n'expose pas la date pour ce pilote, ce n'est pas un signe d'anciennete.</div>
  </div>

  <h2>Programmes au demarrage</h2>
  <div class="card"><table><tr><th>Source</th><th>Nom</th><th>Commande</th><th>Etat</th></tr>$startupRows</table>
  <div class="note">Sources : Run (registre), Folder (dossier demarrage), Task (tache planifiee au logon), UWP (application Store). Le script couvre desormais toutes ces sources, comme le Gestionnaire des taches.</div></div>

  <h2>Residus d'applications</h2>
  <div class="card"><table><tr><th>Dossier</th><th>Taille</th><th>Lie a</th><th>Chemin</th><th>Etat</th></tr>$residueRows</table></div>

  <h2>Nettoyage (fichiers jetables)</h2>
  <div class="card"><table><tr><th>Categorie</th><th>Libere (Mo)</th></tr>$cleanRows</table></div>

  <h2>Recuperer de l'espace (actions sures)</h2>
  <div class="card">
    <table><tr><th>Element</th><th>Taille</th><th>Etat</th></tr>$recovRows</table>
    <div class="note">Ces actions ne touchent pas tes fichiers persos. Windows.old = ancienne version de Windows (recuperable apres une mise a jour). Hibernation = desactive seulement la veille prolongee, pas la mise en veille normale.</div>
  </div>

  <h2>Ou est passee la place : plus gros dossiers</h2>
  <div class="card"><table><tr><th>Dossier</th><th>Taille</th></tr>$bigFolderRows</table></div>

  <h2>Grosses applications installees</h2>
  <div class="card">
    <table><tr><th>Application</th><th>Taille</th></tr>$bigAppRows</table>
    <div class="note">Les jeux (Steam, Epic) peuvent souvent etre <b>deplaces</b> sur un autre disque sans reinstaller, via le launcher. C'est le meilleur moyen de liberer C: sans rien perdre.</div>
  </div>

  <h2>Doublons reels (Telechargements &amp; Documents)</h2>
  <div class="card">
    <table><tr><th>Fichier</th><th>Taille unite</th><th>Copies</th><th>Recuperable</th><th>Etat</th></tr>$dupRows</table>
    <div class="note">Doublons detectes par contenu identique (hash), pas par nom : ce sont vraiment les memes fichiers. Une copie est toujours conservee. Total recuperable estime : $dupTotalMB Mo.</div>
  </div>

  <h2>Mises a jour Windows en attente</h2>
  <div class="card"><table><tr><th>Mise a jour</th></tr>$updateRows</table></div>

  <h2>Evenements critiques (7 derniers jours)</h2>
  <div class="card"><table><tr><th>Dernier</th><th>Occ.</th><th>ID</th><th>Source</th><th>Message</th></tr>$eventRows</table>
  <div class="note">Evenements regroupes par type (le compteur "xN" indique les repetitions). Les erreurs DCOM/Game Bar sont generalement benignes. Un ID 41 (Kernel-Power) ou 6008 signale un vrai plantage.</div></div>

</div>
<div class="foot">Genere par Allo Valentin &middot; Maintenance &amp; Support Informatique &middot; Log : $LogFile</div>
</body></html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8
Write-Log "Rapport genere : $reportFile" "OK"

# ============================================================
#  LANCEMENT DES OUTILS TIERS (mode interactif)
# ============================================================
function Find-Exe {
    param([string[]]$Roots, [string]$Filter)
    foreach ($r in $Roots) {
        if (Test-Path $r) {
            $e = Get-ChildItem $r -Filter $Filter -Recurse -EA SilentlyContinue | Select-Object -First 1
            if ($e) { return $e.FullName }
        }
    }
    return $null
}

if ($Interactive) {
    Start-Process $reportFile   # ouvre le rapport HTML

    # LibreHardwareMonitor : lecture temps reel des temperatures CPU/GPU
    if ($toolStatus.LHM -eq "OK") {
        $lhm = Find-Exe -Roots @("$env:ProgramFiles\LibreHardwareMonitor","${env:ProgramFiles(x86)}\LibreHardwareMonitor","$env:LOCALAPPDATA\Programs") -Filter "LibreHardwareMonitor.exe"
        if ($lhm -and (Confirm-Action "`nLancer LibreHardwareMonitor pour voir les temperatures en direct ?")) {
            Start-Process $lhm
            Write-Log "LibreHardwareMonitor lance." "OK"
        }
    }

    # CrystalDiskInfo : detail SMART (lance automatiquement)
    if ($toolStatus.CDI -eq "OK") {
        $cdi = Find-Exe -Roots @("$env:ProgramFiles\CrystalDiskInfo","${env:ProgramFiles(x86)}\CrystalDiskInfo") -Filter "DiskInfo*.exe"
        if ($cdi) {
            Start-Process $cdi
            Write-Log "CrystalDiskInfo lance." "OK"
        }
    }
}

# ============================================================
#  RELAI VERS L'OUTIL CARTE MERE / BIOS / XMP
#  Si le diagnostic a releve un point BIOS/memoire (XMP au JEDEC,
#  single channel, canal a verifier), on propose d'enchainer.
# ============================================================
if ($Interactive) {
    $freinsCM = @($balance | Where-Object {
        ($_.Niveau -eq 'attention' -and $_.Constat -match "JEDEC|XMP|EXPO|single channel|meme canal|Resizable BAR|Above 4G") -or
        ($_.Constat -match "verifier dans le BIOS ou avec CPU-Z")
    })
    if ($freinsCM.Count -gt 0) {
        Write-Host ""
        Write-Log "Points carte mere / BIOS releves :" "WARN"
        $freinsCM | ForEach-Object {
            Write-Host "   - $($_.Constat)" -ForegroundColor Yellow
            Write-Log "  CM/BIOS : $($_.Constat)" "WARN"
        }
        $scriptCM = Join-Path (Split-Path -Parent $PSCommandPath) "AlloValentin-CarteMere.ps1"
        if (-not (Test-Path $scriptCM)) {
            Write-Log "AlloValentin-CarteMere.ps1 introuvable a cote du script - relai ignore." "WARN"
        }
        elseif (Confirm-Action "`nLancer maintenant l'outil Carte mere / BIOS / XMP ?") {
            Write-Log "Lancement de AlloValentin-CarteMere.ps1" "OK"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptCM
        }
    }
}

# ============================================================
#  RELAI VERS LES MISES A JOUR  (Windows + pilotes)
#  Si des pilotes cles sont vieux (>= 2 ans) ou des MAJ Windows en attente,
#  on propose d'enchainer sur "Tout mettre a jour" (CarteMere -Mode MAJ).
# ============================================================
if ($Interactive) {
    $pilVieux = @($driversKey | Where-Object { $_.AgeAns -ge 2 -and $_.AgeAns -lt 99 })
    $wuEnAttente = 0
    try { $wuEnAttente = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0").Updates.Count } catch {}
    if ($pilVieux.Count -gt 0 -or $wuEnAttente -gt 0) {
        Write-Host ""
        if ($pilVieux.Count -gt 0) {
            Write-Log "$($pilVieux.Count) pilote(s) cle(s) de 2 ans ou plus :" "WARN"
            $pilVieux | ForEach-Object { Write-Host "   - $($_.Categorie) : $($_.Peripherique) ($($_.AgeAns) ans)" -ForegroundColor Yellow; Write-Log "  pilote vieux : $($_.Categorie) $($_.Peripherique) $($_.AgeAns)a" "WARN" }
        }
        if ($wuEnAttente -gt 0) { Write-Log "$wuEnAttente mise(s) a jour Windows en attente." "WARN" }
        $scriptMAJ = Join-Path (Split-Path -Parent $PSCommandPath) "AlloValentin-CarteMere.ps1"
        if ((Test-Path $scriptMAJ) -and (Confirm-Action "`nLancer maintenant 'Tout mettre a jour' (Windows + pilotes + chipset) ?")) {
            Write-Log "Lancement de CarteMere -Mode MAJ" "OK"
            & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $scriptMAJ -Mode MAJ
        } else {
            Write-Log "MAJ non lancees. Menu -> 5 quand tu veux." "INFO"
        }
    }
}

Write-Log "=== Fin diagnostic ==="
