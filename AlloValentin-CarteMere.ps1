<#
.SYNOPSIS
    Allo Valentin - Carte mere / BIOS / XMP / appli constructeur (flux auto)
.DESCRIPTION
    Un seul outil qui s'adapte a la machine et enchaine :

      PHASE 1  Detection
               marque systeme + carte mere -> PC monte ou PC de marque

      PHASE 2  Memoire / XMP  (lecture seule)
               vitesse reelle vs annoncee, dual-channel, Resizable BAR

      PHASE 3  BIOS
               PC monte  : si XMP inactif -> propose de REDEMARRER DANS l'UEFI
                           (affiche le chemin du menu pour la carte detectee)
               PC marque : XMP verrouille constructeur -> rien a activer

      PHASE 4  Appli de reglage  (optionnelle, sur demande)
               PC monte  : Gigabyte Control Center / Armoury Crate / MSI Center /
                           ASRock Motherboard Utility  (courbe ventilo, RGB)
               PC marque : OMEN Gaming Hub / Alienware CC / Lenovo Vantage /
                           PredatorSense / MyASUS  (mode thermique)
               -> installe, PAUSE reglages, desinstalle SEULEMENT si on a installe,
                  nettoie les residus.

    Modes : -Mode Auto (defaut, tout l'enchainement)
            -Mode Bios      (phases 1-3 + pilotes/BIOS, sans la phase 4)
            -Mode App       (phase 4 seulement)
            -Mode Uninstall (retire l'appli installee par ce script)
            -Mode MAJ       (mises a jour uniquement : Windows Update + tous les
                             pilotes via le catalogue Microsoft + chipset. Aucun
                             flash BIOS. C'est l'entree "5" du menu.)

    PRE-DEPOT (une fois) pour les applis hors winget/Store :
      C:\ProgramData\AlloValentin\Tools\VendorApps\<Cle>\  + l'installeur .exe
      ASUS PC monte : y ajouter "Armoury Crate Uninstall Tool.exe"
.NOTES
    PowerShell 5.1. Auto-elevation. Sans accents (convention projet).
    Passation : section 0 (reversibilite), 7 (pas de forcage BIOS), 8 (pieges PS 5.1).
#>

param(
    [ValidateSet('Auto','Bios','App','Uninstall','MAJ')]
    [string]$Mode = 'Auto'
)

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement..." -ForegroundColor Yellow
    try { Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode" -Verb RunAs }
    catch { Write-Host "Elevation refusee." -ForegroundColor Red }
    exit
}

$AppDir    = "$env:ProgramData\AlloValentin"
$LogDir    = "$AppDir\Logs"
$ReportDir = "$AppDir\Reports"
$ToolDir   = "$AppDir\Tools\VendorApps"
$StateFile = "$AppDir\CarteMere-Etat.json"
New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
$LogFile = "$LogDir\CarteMere-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"

function Log {
    param([string]$m, [string]$lvl = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$lvl] $m"
    $c = switch ($lvl) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} "TITRE"{"Cyan"} default{"Gray"} }
    Write-Host $line -ForegroundColor $c
    Add-Content -Path $LogFile -Value $line
}
function Confirm-ON { param([string]$q) return ((Read-Host "$q (O/N)") -match '^[OoYy]') }
function Pause-Entree { param([string]$m = "Appuie sur Entree pour fermer...") Write-Host "`n  $m" -ForegroundColor DarkGray; try { Read-Host | Out-Null } catch {} }

# ============================================================
#  Catalogue
# ============================================================
$Catalogue = @(
    [pscustomobject]@{ Cle='Gigabyte'; Type='Monte'; MatchBoard='gigabyte'; MatchSys=$null
        AppName='Gigabyte Control Center'; Store=$null
        DetectLike=@('*Gigabyte Control Center*','*GIGABYTE Control Center*','*Gigabyte App Center*')
        InstallerGlob=@('*Control*Center*.exe','*GCC*.exe','*gigabytecontrolcenter*.exe','Setup*.exe','*Setup.exe'); InstallArgs=@('/S'); UninstallToolGlob=@()
        DownloadPage='https://www.gigabyte.com/Support/Utility'
        Services=@('GigabyteAppUpdate','GCCService','GProbe','GLCKIO'); Tasks=@('*Gigabyte*','*GCC*')
        Folders=@("$env:ProgramFiles\GIGABYTE\Control Center","${env:ProgramFiles(x86)}\GIGABYTE\Control Center","$env:ProgramData\Gigabyte")
        Bios=@{
            Enter = "SUPPR au demarrage (F2 sur certains modeles). F2 = bascule Easy Mode / Advanced Mode."
            XMP   = "Tweaker > 'Extreme Memory Profile (X.M.P.)' > Profile1.  (Easy Mode : bouton X.M.P. en haut a droite.)"
            ReBAR = "Settings > IO Ports > 'Above 4G Decoding' = Enabled, puis 'Re-Size BAR Support' = Enabled."
            Turbo = "Tweaker > Advanced CPU Settings : 'Intel Turbo Boost' = Enabled ; 'Turbo Power Limits' = Enabled/Auto ; ne pas reduire 'Package Power Limit'."
            CSM   = "Boot > 'CSM Support' = Disabled (requis pour ReBAR + Secure Boot).  Secure Boot : Boot > Secure Boot."
            Fans  = "Smart Fan 6 (touche F6) : une courbe par connecteur (CPU_FAN, SYS_FAN...)."
            Save  = "F10 > 'Save & Exit Setup' > Yes."
        } }

    [pscustomobject]@{ Cle='ASUS'; Type='Monte'; MatchBoard='asus|asustek'; MatchSys=$null
        AppName='Armoury Crate'; Store=$null
        DetectLike=@('*Armoury Crate*','*ARMOURY CRATE*')
        InstallerGlob=@('*Armoury*Crate*Install*.exe','*ArmouryCrate*Install*.exe'); InstallArgs=@()
        UninstallToolGlob=@('Armoury Crate Uninstall Tool.exe','Armoury_Crate_Uninstall_Tool.exe','*Uninstall*Tool*.exe')
        DownloadPage='https://www.asus.com/supportonly/armoury%20crate/helpdesk_download/'
        Services=@('ArmouryCrateService','ArmouryCrateControlInterface','AsusCertService','AsusAppService','LightingService','ASUSLinkNear','ASUSLinkRemote','ASUSOptimization','ASUSSoftwareManager','ASUSSystemAnalysis','ASUSSystemDiagnosis','asComSvc','asHmComSvc')
        Tasks=@('*Armoury*'); Folders=@("$env:ProgramFiles\ASUS\ARMOURY CRATE Service","$env:ProgramFiles\ASUS\ARMOURY CRATE Lite Service","$env:ProgramData\ASUS\ARMOURY CRATE Service")
        Bios=@{
            Enter = "SUPPR ou F2 au demarrage. F7 = bascule EZ Mode / Advanced Mode."
            XMP   = "Advanced Mode > Ai Tweaker > 'Ai Overclock Tuner' > XMP I / XMP II (Intel) ou D.O.C.P. / EXPO (AMD).  EZ Mode : bandeau 'XMP' en haut."
            ReBAR = "Advanced Mode > Advanced > 'PCI Subsystem Settings' > 'Above 4G Decoding' = Enabled + 'Re-Size BAR Support' = Enabled."
            Turbo = "Ai Tweaker : 'Turbo Boost' / 'Core Performance Boost' = Auto/Enabled ; ne pas reduire 'Long/Short Duration Package Power Limit' ; 'MCE' selon carte."
            CSM   = "Boot > 'CSM (Compatibility Support Module)' > 'Launch CSM' = Disabled.  Secure Boot : Boot > Secure Boot."
            Fans  = "Monitor > 'Q-Fan Configuration' (ou touche F6 : QFan Control)."
            Save  = "F10 > OK."
        } }

    [pscustomobject]@{ Cle='MSI'; Type='Monte'; MatchBoard='micro-star|msi'; MatchSys=$null
        AppName='MSI Center'; Store='MSI.MSICenter'
        DetectLike=@('*MSI Center*')
        InstallerGlob=@('*MSI*Center*.exe'); InstallArgs=@('/quiet','/norestart'); UninstallToolGlob=@()
        DownloadPage='https://www.msi.com/Landing/MSI-Center'
        Services=@('MSI_Center_Service','MSI Foundation Service','MSI_Foundation_Service'); Tasks=@('*MSI*Center*')
        Folders=@("$env:ProgramFiles\MSI\MSI Center","$env:ProgramData\MSI\MSI Center")
        Bios=@{
            Enter = "SUPPR au demarrage. F7 = bascule EZ Mode / Advanced Mode."
            XMP   = "Bouton 'XMP' / 'EXPO' en haut de l'ecran (EZ Mode) ; ou Advanced > OC > 'Extreme Memory Profile (XMP)' = Enabled / Profile 1."
            ReBAR = "Advanced > Settings > Advanced > 'PCI Subsystem Settings' > 'Above 4G memory / Crypto Currency mining' = Enabled + 'Re-Size BAR Support' = Enabled."
            Turbo = "OC > 'CPU Features' : 'Intel Turbo Boost' = Enabled ; ne pas brider 'Long Duration Power Limit' ; 'Enhanced Turbo' selon carte."
            CSM   = "Settings > Advanced > 'Windows OS Configuration' > 'BIOS UEFI/CSM Mode' = UEFI.  Secure Boot : meme menu > Secure Boot."
            Fans  = "'Hardware Monitor' (touche F ou l'icone ventilateur) : courbe par ventilateur."
            Save  = "F10 > Yes."
        } }

    [pscustomobject]@{ Cle='ASRock'; Type='Monte'; MatchBoard='asrock'; MatchSys=$null
        AppName='ASRock Motherboard Utility'; Store=$null
        DetectLike=@('*ASRock Motherboard Utility*','*A-Tuning*','*ASRock*Utility*','*ASRRGBLED*')
        InstallerGlob=@('*ASRock*Utility*.exe','*A-Tuning*.exe','*MotherboardUtility*.exe'); InstallArgs=@('/S'); UninstallToolGlob=@()
        DownloadPage='https://www.asrock.com/mb/index.asp'
        Services=@('Jekyll','AsrAppCharger','ASRockOCTuner','FanControlService'); Tasks=@('*ASRock*')
        Folders=@("$env:ProgramFiles\ASRock Utility","${env:ProgramFiles(x86)}\ASRock Utility","$env:ProgramData\ASRock")
        Bios=@{
            Enter = "F2 ou SUPPR au demarrage. F6 = Advanced Mode."
            XMP   = "OC Tweaker > 'DRAM Configuration' > 'Load XMP Setting' = 'XMP 2.0 Profile 1' (ou 'Load EXPO Setting' sur AMD)."
            ReBAR = "Advanced > 'PCI Configuration' > 'Above 4G Decoding' = Enabled + 'Re-Size BAR Support' = Enabled."
            Turbo = "OC Tweaker > 'CPU Configuration' : 'Intel Turbo Boost' = Enabled ; ne pas reduire 'Long Duration Power Limit' ; 'Base Frequency Boost' selon carte."
            CSM   = "Boot > 'CSM' > 'Launch CSM' = Disabled.  Secure Boot : Security > Secure Boot."
            Fans  = "'H/W Monitor' > 'FAN-Tastic Tuning'."
            Save  = "F10 > Yes."
        } }

    [pscustomobject]@{ Cle='HP'; Type='Marque'; MatchBoard=$null; MatchSys='hewlett|^hp$|hp inc'
        AppName='OMEN Gaming Hub'; Store='9NQDW009T0T5'
        DetectLike=@('*OMEN*','*HP Command Center*')
        InstallerGlob=@('*OMEN*.exe'); InstallArgs=@(); UninstallToolGlob=@()
        DownloadPage='https://apps.microsoft.com/detail/9NQDW009T0T5'
        Services=@('OMEN*'); Tasks=@('*OMEN*'); Folders=@()
        Note='Omen/Victus : OMEN Gaming Hub (Performance Control / fan). HP Pavilion / bureautique : souvent AUCUN controle ventilo.'
        Bios=@{ Enter="F10 au demarrage = BIOS. Esc = menu de demarrage. BIOS HP tres limite : pas de XMP ; Secure Boot / TPM sous 'Security' ou 'Advanced'." } }

    [pscustomobject]@{ Cle='Dell'; Type='Marque'; MatchBoard=$null; MatchSys='dell|alienware'
        AppName='Alienware Command Center / Dell'; Store=$null
        DetectLike=@('*Alienware Command Center*','*Dell Power Manager*','*My Dell*')
        InstallerGlob=@('*AWCC*.exe','*Alienware*Command*.exe','*DellPowerManager*.exe'); InstallArgs=@(); UninstallToolGlob=@()
        DownloadPage='https://www.dell.com/support/home  (ou Microsoft Store : Alienware Command Center / My Dell)'
        Services=@('AWCCService','SupportAssistAgent','DellClientManagementService'); Tasks=@('*Alienware*'); Folders=@()
        Note='Alienware : Alienware Command Center (modes thermiques). Autres Dell : "My Dell" ou Dell Power Manager (Optimise / Frais / Silencieux / Ultra perf).'
        Bios=@{ Enter="F2 au demarrage = BIOS. F12 = menu de demarrage. Pas de XMP ; Secure Boot sous 'Boot Configuration' ; modes thermiques via l'appli." } }

    [pscustomobject]@{ Cle='Lenovo'; Type='Marque'; MatchBoard=$null; MatchSys='lenovo'
        AppName='Lenovo Vantage'; Store='9WZDNCRFJ4MV'
        DetectLike=@('*Lenovo Vantage*','*Legion Toolkit*','*Lenovo Legion*')
        InstallerGlob=@('*LenovoVantage*.exe','*LegionToolkit*.exe'); InstallArgs=@(); UninstallToolGlob=@()
        DownloadPage='https://apps.microsoft.com/detail/9WZDNCRFJ4MV'
        Services=@('LenovoVantageService','ImControllerService'); Tasks=@('*Lenovo*Vantage*','*Legion*'); Folders=@()
        Note='Legion : modes thermiques Quiet / Balanced / Performance (Vantage ou Legion Toolkit). IdeaPad bureautique : peu ou pas de controle ventilo.'
        Bios=@{ Enter="F1 (ThinkCentre/ThinkPad) ou F2 (Legion/IdeaPad) au demarrage ; ou bouton Novo / F12. Pas de XMP ; Secure Boot sous 'Security' ; modes thermiques via l'appli ou Fn+Q." } }

    [pscustomobject]@{ Cle='Acer'; Type='Marque'; MatchBoard=$null; MatchSys='acer'
        AppName='PredatorSense / NitroSense'; Store='9MWXQ15JQ4XR'
        DetectLike=@('*PredatorSense*','*NitroSense*','*Acer*Sense*')
        InstallerGlob=@('*PredatorSense*.exe','*NitroSense*.exe'); InstallArgs=@(); UninstallToolGlob=@()
        DownloadPage='https://www.acer.com/  (Support > Drivers and Manuals) ou Microsoft Store'
        Services=@('*PredatorSense*','*NitroSense*'); Tasks=@('*Predator*','*Nitro*'); Folders=@()
        Note='Predator/Nitro : PredatorSense/NitroSense (modes + parfois courbe). Aspire bureautique : rien.'
        Bios=@{ Enter="F2 au demarrage = BIOS. F12 = menu de demarrage (a activer d'abord sous 'Main' > F12 Boot Menu). Pas de XMP ; Secure Boot sous 'Boot'." } }

    [pscustomobject]@{ Cle='ASUS-Marque'; Type='Marque'; MatchBoard=$null; MatchSys='asus|asustek'
        AppName='MyASUS / Armoury Crate'; Store='9N7R5S6B0ZZH'
        DetectLike=@('*MyASUS*','*Armoury Crate*')
        InstallerGlob=@('*MyASUS*.exe'); InstallArgs=@(); UninstallToolGlob=@('*Uninstall*Tool*.exe')
        DownloadPage='https://apps.microsoft.com/detail/9N7R5S6B0ZZH'
        Services=@('ASUSOptimization','ASUSSystemAnalysis','ASUSLinkNear'); Tasks=@('*ASUS*','*Armoury*'); Folders=@()
        Note='ROG/TUF prebuilt : Armoury Crate. Autres : MyASUS (Full Speed / Standard / Silencieux).'
        Bios=@{ Enter="F2 ou SUPPR au demarrage. Sur prebuilt ROG, XMP parfois present (Ai Tweaker > Ai Overclock Tuner) mais souvent verrouille selon le modele." } }

    [pscustomobject]@{ Cle='MSI-Marque'; Type='Marque'; MatchBoard=$null; MatchSys='micro-star|msi'
        AppName='MSI Center'; Store='MSI.MSICenter'
        DetectLike=@('*MSI Center*')
        InstallerGlob=@('*MSI*Center*.exe'); InstallArgs=@('/quiet','/norestart'); UninstallToolGlob=@()
        DownloadPage='https://www.msi.com/Landing/MSI-Center'
        Services=@('MSI_Center_Service','MSI Foundation Service'); Tasks=@('*MSI*Center*'); Folders=@()
        Note='MSI Aegis/Trident/Codex : MSI Center (User Scenario).'
        Bios=@{ Enter="SUPPR au demarrage. Sur prebuilt MSI, XMP parfois present (OC > Extreme Memory Profile) mais souvent verrouille selon le modele." } }
)
$MarquesOEM = 'hewlett|hp inc|dell|alienware|lenovo|acer|medion|gateway|packard|fujitsu|samsung|lg electronics|huawei|honor|microsoft corporation|dynabook|toshiba|clevo|tongfang'

# ============================================================
#  Fonctions
# ============================================================
function Get-InstalledEntries {
    param([string[]]$Like)
    $roots = @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*')
    $res = @()
    foreach ($r in $roots) {
        foreach ($e in (Get-ItemProperty $r -EA SilentlyContinue)) {
            if (-not $e.DisplayName) { continue }
            foreach ($pat in $Like) { if ($e.DisplayName -like $pat) { $res += $e; break } }
        }
    }
    $res
}
function Get-AppxMatches {
    param($V)
    try {
        Get-AppxPackage -AllUsers -EA SilentlyContinue | Where-Object {
            switch ($V.Cle) {
                'MSI'         { $_.Name -match 'MSICenter' }
                'MSI-Marque'  { $_.Name -match 'MSICenter' }
                'ASUS'        { $_.Name -match 'ArmouryCrate' }
                'ASUS-Marque' { $_.Name -match 'MyASUS|ArmouryCrate|B9ECED6F' }
                'Gigabyte'    { $_.Name -match 'GigabyteControlCenter' }
                'HP'          { $_.Name -match 'OmenCommandCenter|E046963F|AD2F1837' }
                'Lenovo'      { $_.Name -match 'LenovoVantage|E046963F|LenovoCorporation' }
                'Acer'        { $_.Name -match 'PredatorSense|NitroSense|AcerIncorporated' }
                'Dell'        { $_.Name -match 'AlienwareCommandCenter|DellInc' }
                default       { $false }
            }
        }
    } catch { @() }
}
function Test-VendorInstalled { param($V) (@(Get-InstalledEntries -Like $V.DetectLike).Count + @(Get-AppxMatches $V).Count) -gt 0 }
function Invoke-Wait {
    param([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 300)
    if (-not (Test-Path $File)) { Log "Introuvable : $File" "ERROR"; return $false }
    Log ("Execution : {0} {1}" -f (Split-Path $File -Leaf), ($Arguments -join ' '))
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -ErrorAction Stop
        if (-not $p.WaitForExit($TimeoutSec * 1000)) { Log "Delai depasse ($TimeoutSec s), on ne force pas." "WARN"; return $false }
        $good = ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010)
        Log ("Termine, code {0}" -f $p.ExitCode) $(if ($good) { "OK" } else { "WARN" })
        return $good
    } catch { Log "Erreur execution : $_" "ERROR"; return $false }
}
function Invoke-Winget {
    param([string]$Action, [string]$Id)
    if (-not (Get-Command winget -EA SilentlyContinue)) { return }
    $src = if ($Id -match '^[0-9A-Z]{12}$') { 'msstore' } else { 'winget' }
    $a = @($Action, '--id', $Id, '--source', $src, '--accept-source-agreements', '--silent')
    if ($Action -eq 'install') { $a += '--accept-package-agreements' }
    Log "winget $Action $Id (source $src)..."
    try { & winget @a 2>&1 | ForEach-Object { Log "  $_" } } catch { Log "  winget : $_" "WARN" }
}
function Find-Staged {
    param([string[]]$Globs, [string]$VendorKey)
    $dir = Join-Path $ToolDir $VendorKey
    if (-not (Test-Path $dir)) { return $null }
    foreach ($g in $Globs) {
        $hit = Get-ChildItem $dir -Filter $g -File -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

# Installe les pilotes que le technicien a telecharges depuis le site du constructeur
# (source la plus fiable) et deposes dans un dossier. .zip -> extraction -> pnputil.
# Les .exe (installeurs auto-extractibles) sont laisses au tech.
function Install-StagedDrivers {
    param([string]$Dir)
    if (-not (Test-Path $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $zips = @(Get-ChildItem $Dir -Filter *.zip -File -EA SilentlyContinue)
    $exes = @(Get-ChildItem $Dir -Filter *.exe -File -EA SilentlyContinue)
    if ($zips.Count -eq 0 -and $exes.Count -eq 0) { Log "Aucun .zip / .exe dans $Dir." "WARN"; return }

    $work = Join-Path $Dir "_extract"
    Remove-Item $work -Recurse -Force -EA SilentlyContinue
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    foreach ($z in $zips) {
        try { Expand-Archive -Path $z.FullName -DestinationPath (Join-Path $work $z.BaseName) -Force -EA Stop; Log "Extrait : $($z.Name)" "OK" }
        catch { Log "Extraction $($z.Name) : $_" "WARN" }
    }
    if ($exes.Count -gt 0) { Log "$($exes.Count) .exe present(s) : ce sont des installeurs, lance-les a la main (double-clic)." "INFO" }

    $infs = @(Get-ChildItem $work -Recurse -Filter *.inf -File -EA SilentlyContinue |
              Where-Object { $_.Name -notmatch '^(autorun|setup)\.inf$' })
    if ($infs.Count -eq 0) { Log "Aucun .inf trouve dans les .zip (ce sont peut-etre des installeurs .exe a lancer a la main)." "WARN"; return }

    Log "$($infs.Count) fichier(s) .inf. Installation via pnputil (ne lie un pilote que si un peripherique correspond)..." "TITRE"
    $avant = @((& pnputil.exe /enum-drivers 2>$null) -match 'oem\d+\.inf' | ForEach-Object { ($_ -split ':')[-1].Trim() })
    foreach ($inf in ($infs | Sort-Object FullName -Unique)) {
        Log "  + $($inf.Directory.Name)\$($inf.Name)"
        (& pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1) |
            Where-Object { $_ -match 'ajout|added|publi|driver package|echec|failed|deja|already|redemarr|reboot' } |
            ForEach-Object { Log "      $_" }
    }
    $apres = @((& pnputil.exe /enum-drivers 2>$null) -match 'oem\d+\.inf' | ForEach-Object { ($_ -split ':')[-1].Trim() })
    $nouveaux = @($apres | Where-Object { $_ -notin $avant })
    Log "Installation terminee." "OK"
    if ($nouveaux.Count -gt 0) {
        Log "Pilotes ajoutes au magasin : $($nouveaux -join ', ')" "INFO"
        Log "Pour revenir en arriere : Gestionnaire de peripheriques > peripherique > Pilote > 'Restaurer le pilote precedent'," "INFO"
        Log "  ou en admin : pnputil /delete-driver <oemXX.inf> /uninstall" "INFO"
    }
    Log "Un redemarrage peut etre necessaire pour que le nouveau pilote soit actif." "WARN"
}

# Cherche un pilote plus recent dans le Microsoft Update Catalog (accessible aux
# scripts, contrairement aux sites constructeur), le telecharge, l'extrait et
# l'installe via pnputil.
#   - comparaison par DATE (les schemas de version mentent d'un fabricant a l'autre)
#   - $DateActuelle = date du pilote installe ; on n'installe QUE si le catalogue
#     propose plus recent (marge 30 j) -> jamais de downgrade
#   - $VendorActuel : si fourni, on ignore les paquets d'un autre fabricant
#     (evite le pilote SMBus "ELAN" sur une carte Intel, etc.)
function Update-DriverFromCatalog {
    param([string]$Hwid, [string]$Label, [datetime]$DateActuelle, [string]$VendorActuel)
    $m = [regex]::Match("$Hwid", '(?i)VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
    if (-not $m.Success) { Log "$Label : identifiant PCI illisible, on saute." "INFO"; return $false }
    $q = "VEN_$($m.Groups[1].Value.ToUpper())%26DEV_$($m.Groups[2].Value.ToUpper())"
    try { $sr = Invoke-WebRequest "https://www.catalog.update.microsoft.com/Search.aspx?q=$q" -UseBasicParsing -TimeoutSec 30 -EA Stop }
    catch { Log "$Label : Microsoft Update Catalog injoignable." "WARN"; return $false }
    $rows = [regex]::Matches($sr.Content, '(?s)<tr[^>]*id="([0-9a-f\-]{36})_R\d+"[^>]*>(.*?)</tr>')
    if ($rows.Count -eq 0) { Log "$Label : rien dans le catalogue pour ce peripherique." "INFO"; return $false }
    $cands = foreach ($row in $rows) {
        $cell  = $row.Groups[2].Value
        $titre = ([regex]::Match($cell, '(?s)<a[^>]*>\s*(.*?)\s*</a>')).Groups[1].Value -replace '\s+', ' '
        $tds   = [regex]::Matches($cell, '(?s)<td[^>]*>\s*(.*?)\s*</td>') | ForEach-Object { ($_.Groups[1].Value -replace '<[^>]+>', '' -replace '&nbsp;', ' ' -replace '\s+', ' ').Trim() }
        # le catalogue sert des dates US M/d/yyyy : on parse en culture invariante
        # (sinon sur Windows FR, "8/18/2025" echoue -> aucune date trouvee)
        $dd = $null
        foreach ($t in $tds) {
            foreach ($fmt in @('M/d/yyyy', 'MM/dd/yyyy', 'yyyy-MM-dd')) {
                try {
                    $x = [datetime]::ParseExact($t, $fmt, [System.Globalization.CultureInfo]::InvariantCulture)
                    if ($x.Year -ge 2000 -and $x -le (Get-Date)) { $dd = $x; break }
                } catch {}
            }
            if ($dd) { break }
        }
        [pscustomobject]@{ Id = $row.Groups[1].Value; Titre = $titre; Date = $dd }
    }
    # filtre fabricant : le titre doit contenir le nom du fabricant actuel
    if ($VendorActuel) {
        $vk = ($VendorActuel -split '[ ,]')[0]
        if ($vk.Length -ge 3) { $cands = @($cands | Where-Object { $_.Titre -match [regex]::Escape($vk) -or $_.Titre -match 'Microsoft' }) }
    }
    $best = $cands | Where-Object { $_.Date } | Sort-Object Date | Select-Object -Last 1
    if (-not $best) { Log "$Label : aucun paquet date/compatible dans le catalogue." "INFO"; return $false }
    if ($DateActuelle -and $best.Date -le $DateActuelle.AddDays(30)) {
        Log "$Label : deja a jour (installe $($DateActuelle.ToString('yyyy-MM')) >= catalogue $($best.Date.ToString('yyyy-MM')))." "OK"
        return $false
    }
    Log "$Label : le catalogue propose $($best.Titre) ($($best.Date.ToString('yyyy-MM')))." "INFO"
    $body = "updateIDs=" + [uri]::EscapeDataString("[{`"size`":0,`"languages`":`"`",`"uidInfo`":`"$($best.Id)`",`"updateID`":`"$($best.Id)`"}]")
    try { $dd2 = Invoke-WebRequest "https://www.catalog.update.microsoft.com/DownloadDialog.aspx" -Method POST -Body $body -ContentType 'application/x-www-form-urlencoded' -UseBasicParsing -TimeoutSec 30 -EA Stop }
    catch { Log "  lien de telechargement indisponible." "WARN"; return $false }
    $url = ([regex]::Match($dd2.Content, "(https?://[^'`"]+\.(?:cab|msu|exe))")).Value
    if (-not $url) { Log "  pas de fichier retourne par le catalogue." "WARN"; return $false }
    $wk = Join-Path "$AppDir\Drivers" ("_cat_" + ($Label -replace '\W', '') + "_" + (Get-Random -Maximum 99999))
    New-Item -ItemType Directory -Path $wk -Force | Out-Null
    try {
        $pkg = Join-Path $wk ([IO.Path]::GetFileName($url.Split('?')[0]))
        try { Invoke-WebRequest $url -OutFile $pkg -UseBasicParsing -TimeoutSec 300 -EA Stop } catch { Log "  telechargement echoue." "WARN"; return $false }
        if ($pkg -match '\.cab$') { & expand.exe -F:* "$pkg" "$wk" | Out-Null }
        elseif ($pkg -match '\.exe$') { Log "  paquet .exe (installeur) : depose dans $wk, a lancer a la main." "INFO"; return $false }
        $infs = @(Get-ChildItem $wk -Recurse -Filter *.inf -File -EA SilentlyContinue | Where-Object { $_.Name -notmatch '^(autorun|setup)\.inf$' } | Sort-Object FullName -Unique)
        if ($infs.Count -eq 0) { Log "  aucun .inf dans le paquet." "WARN"; return $false }
        $ok = $false
        foreach ($inf in $infs) {
            $o = (& pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1)
            if ($o -match 'installe sur|installed on the device|correctement ajout|successfully added') { $ok = $true }
            $o | Where-Object { $_ -match 'echec|failed|redemarr|reboot' } | ForEach-Object { Log "     $_" }
        }
        if ($ok) { Log "$Label : pilote du $($best.Date.ToString('yyyy-MM')) installe (actif au redemarrage)." "OK"; return $true }
        Log "$Label : le paquet n'a pas pu s'installer (dependances/extension). A voir avec l'assistant du fondeur." "WARN"; return $false
    } finally {
        Remove-Item $wk -Recurse -Force -EA SilentlyContinue   # menage : le pilote est dans le store, pas besoin du .cab
    }
}

# Peripherique d'une categorie : renvoie hwid + date du pilote installe +
# fabricant, pour que Update-DriverFromCatalog puisse comparer et filtrer.
# Accepte PCI\VEN_ ET HDAUDIO\FUNC_ (les codecs audio ne sont pas sur le bus PCI).
function Get-DriverInfoCategorie {
    param([string[]]$Classes, [string]$Inclut, [string]$Exclut)
    foreach ($dev in (Get-PnpDevice -EA SilentlyContinue | Where-Object {
        $_.Class -in $Classes -and $_.Status -eq 'OK' -and
        ($_.InstanceId -like 'PCI\VEN_*' -or $_.InstanceId -like 'HDAUDIO\FUNC_*') -and
        ($(-not $Inclut) -or $_.FriendlyName -match $Inclut) -and
        ($(-not $Exclut) -or $_.FriendlyName -notmatch $Exclut)
    })) {
        $h = (Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -EA SilentlyContinue).Data
        if (-not $h) { continue }
        $dt = $null
        try { $dt = [datetime](Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverDate' -EA SilentlyContinue).Data } catch {}
        $pv = "$((Get-PnpDeviceProperty -InstanceId $dev.InstanceId -KeyName 'DEVPKEY_Device_DriverProvider' -EA SilentlyContinue).Data)"
        return [pscustomobject]@{ Hwid = @($h)[0]; Nom = $dev.FriendlyName; Date = $dt; Provider = $pv }
    }
    return $null
}

function Parse-UninstallString {
    param([string]$u)
    if ($u -match '^\s*"([^"]+)"\s*(.*)$') { return @{ Exe = $Matches[1]; Args = @($Matches[2].Split(' ') | Where-Object { $_ }) } }
    if ($u -match '^\s*(\S+\.exe)\s*(.*)$') { return @{ Exe = $Matches[1]; Args = @($Matches[2].Split(' ') | Where-Object { $_ }) } }
    return @{ Exe = $u; Args = @() }
}
function Save-State { param($obj) $obj | ConvertTo-Json -Depth 5 | Set-Content -Path $StateFile -Encoding UTF8 }
function Load-State { if (Test-Path $StateFile) { try { Get-Content $StateFile -Raw | ConvertFrom-Json } catch { $null } } else { $null } }

function Get-RatedSpeed {
    param($dimm)
    if ($dimm.PartNumber -match '(?<!\d)([2-9]\d{3})(?!\d)') { $n = [int]$Matches[1]; if ($n -ge 2000 -and $n -le 8400) { return $n } }
    return [int]$dimm.Speed
}

# Etat du Resizable BAR d'un GPU.
#   NVIDIA : via nvidia-smi (BAR1 total vs VRAM) - definitif.
#   AMD / Intel / pas de nvidia-smi : via les plages memoire 32 bits.
#     Quand ReBAR est actif, le grand BAR passe au-dessus de 4 Go et disparait
#     des plages 32 bits : il ne reste que de petits stubs (< ~64 Mo).
# Retourne @{ Actif = $true/$false/$null ; Detail = "texte" }
function Get-ReBARState {
    param($gpu)
    # 1. NVIDIA
    if ((Get-Command nvidia-smi -EA SilentlyContinue) -and $gpu.Name -match 'NVIDIA|GeForce') {
        try {
            $q = & nvidia-smi -q 2>$null
            $ctx = $q | Select-String 'BAR1 Memory Usage' -Context 0, 1
            $bar1 = if ($ctx -and $ctx.Context.PostContext[0] -match '(\d+)\s*MiB') { [int]$Matches[1] } else { 0 }
            $vram = [int]("$((& nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1))".Trim())
            if ($bar1 -gt 0 -and $vram -gt 0) {
                if ($bar1 -ge $vram * 0.5) { return @{ Actif = $true;  Detail = "BAR1 $bar1 Mo / VRAM $vram Mo (ReBAR)" } }
                else                       { return @{ Actif = $false; Detail = "BAR1 $bar1 Mo pour $vram Mo de VRAM" } }
            }
        } catch {}
    }
    # 2. fallback plages memoire 32 bits
    $vramB = 0
    try {
        $vramB = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\0*' -EA SilentlyContinue |
                  Where-Object { $_.'HardwareInformation.qwMemorySize' } |
                  Sort-Object 'HardwareInformation.qwMemorySize' -Descending | Select-Object -First 1).'HardwareInformation.qwMemorySize'
    } catch {}
    $barMB = 0
    try {
        $barMB = (Get-CimAssociatedInstance -InputObject $gpu -ResultClassName Win32_DeviceMemoryAddress -EA Stop |
                  ForEach-Object { [math]::Round(($_.EndingAddress - $_.StartingAddress + 1)/1MB) } |
                  Measure-Object -Maximum).Maximum
    } catch {}
    $vGB = [math]::Round($vramB/1GB, 1)
    $capable = $gpu.Name -match 'RTX\s?\d{4}|GTX\s?16\d{2}|RX\s?5[5-9]\d0|RX\s?[6-9]\d{3}|Arc'
    if ($barMB -ge 2048) { return @{ Actif = $true; Detail = "BAR $barMB Mo (couvre la VRAM)" } }
    if ($vramB -gt 2GB -and $capable) {
        if ($barMB -ge 200 -and $barMB -le 400) { return @{ Actif = $false; Detail = "BAR $barMB Mo pour $vGB Go de VRAM (fenetre 256 Mo)" } }
        if ($barMB -gt 0 -and $barMB -lt 128)   { return @{ Actif = $true;  Detail = "grand BAR passe au-dessus de 4 Go (stub 32 bits $barMB Mo)" } }
    }
    return @{ Actif = $null; Detail = "BAR $barMB Mo, VRAM $vGB Go (indetermine)" }
}

function Remove-VendorApp {
    param($V)
    Log "=== DESINSTALLATION : $($V.AppName) ===" "TITRE"
    $tool = Find-Staged -Globs $V.UninstallToolGlob -VendorKey $V.Cle
    if ($tool) {
        Log "Outil de desinstallation officiel : $(Split-Path $tool -Leaf)" "OK"
        Invoke-Wait -File $tool -Arguments @() -TimeoutSec 900 | Out-Null
    } else {
        if ($V.Store) { Invoke-Winget -Action 'uninstall' -Id $V.Store }
        $entries = @(Get-InstalledEntries -Like $V.DetectLike) | Sort-Object { if ($_.DisplayName -like "*SDK*" -or $_.DisplayName -like "*Service*") { 0 } else { 1 } }
        foreach ($e in $entries) {
            $u = $e.UninstallString
            if (-not $u) { continue }
            Log "Desinstallation : $($e.DisplayName)"
            if ($u -match 'msiexec' -and $u -match '\{[0-9A-Fa-f\-]{36}\}') {
                Invoke-Wait -File "$env:SystemRoot\System32\msiexec.exe" -Arguments @('/x', $Matches[0], '/qn', '/norestart') -TimeoutSec 600 | Out-Null
            } else {
                $pu = Parse-UninstallString $u
                $ua = @($pu.Args)
                if (-not ($ua -match '/S|/silent|/quiet|/qn|--silent')) { $ua += '/S' }
                Invoke-Wait -File $pu.Exe -Arguments $ua -TimeoutSec 600 | Out-Null
            }
        }
        foreach ($a in @(Get-AppxMatches $V)) {
            Log "Suppression paquet Store : $($a.Name)"
            try { Remove-AppxPackage -Package $a.PackageFullName -AllUsers -EA Stop } catch { Log "  $_" "WARN" }
        }
    }
    foreach ($svcPat in $V.Services) {
        Get-Service -Name $svcPat -EA SilentlyContinue | ForEach-Object {
            Log "Service residuel : $($_.Name)"
            try { Stop-Service $_.Name -Force -EA SilentlyContinue } catch {}
            & "$env:SystemRoot\System32\sc.exe" delete $_.Name | Out-Null
        }
    }
    foreach ($tPat in $V.Tasks) {
        Get-ScheduledTask -EA SilentlyContinue | Where-Object { $_.TaskName -like $tPat } | ForEach-Object {
            Log "Tache residuelle : $($_.TaskPath)$($_.TaskName)"
            try { Unregister-ScheduledTask -TaskName $_.TaskName -TaskPath $_.TaskPath -Confirm:$false -EA Stop } catch { Log "  $_" "WARN" }
        }
    }
    foreach ($f in $V.Folders) {
        if ($f -and (Test-Path $f)) {
            Log "Dossier residuel : $f"
            try { Remove-Item $f -Recurse -Force -EA Stop } catch { Log "  laisse en place ($_)" "WARN" }
        }
    }
    Log "Desinstallation terminee. REDEMARRAGE recommande (surtout ASUS/HP)." "OK"
    $st = Load-State
    if ($st) { $st | Add-Member UninstalledAt ((Get-Date).ToString('s')) -Force; Save-State $st }
}

function Invoke-VendorApp {
    param($V, [bool]$Deja)
    $installedByUs = $false
    if ($Deja) {
        Log "Appli deja presente : on saute l'installation." "INFO"
    } else {
        Log "=== INSTALLATION : $($V.AppName) ===" "TITRE"
        try { Enable-ComputerRestore -Drive "$env:SystemDrive\" -EA SilentlyContinue; Checkpoint-Computer -Description "AlloValentin - avant appli $($V.Cle)" -RestorePointType MODIFY_SETTINGS -EA Stop; Log "Point de restauration cree." "OK" }
        catch { Log "Point de restauration non cree : $_" "WARN" }

        $ok = $false
        if ($V.Store) { Invoke-Winget -Action 'install' -Id $V.Store; Start-Sleep 3; $ok = Test-VendorInstalled $V }
        if (-not $ok) {
            $staged = Find-Staged -Globs $V.InstallerGlob -VendorKey $V.Cle
            if ($staged) {
                Log "Installeur pre-depose : $(Split-Path $staged -Leaf)"
                if ($V.InstallArgs.Count -gt 0) {
                    Invoke-Wait -File $staged -Arguments $V.InstallArgs -TimeoutSec 900 | Out-Null
                    Start-Sleep 3; $ok = Test-VendorInstalled $V
                }
                # Silencieux echoue (ou pas de mode silencieux) -> on ouvre la fenetre.
                if (-not $ok) {
                    Log "Installation silencieuse non confirmee : la fenetre de l'installeur va s'ouvrir. Termine-la, puis reviens ici." "WARN"
                    Start-Process -FilePath $staged | Out-Null
                    Read-Host "  Entree quand l'installation est terminee" | Out-Null
                    Start-Sleep 3; $ok = Test-VendorInstalled $V
                }
            } else {
                Log "Aucun installeur dans : $(Join-Path $ToolDir $V.Cle)" "ERROR"
                Log "Telecharge-le une fois depuis : $($V.DownloadPage)" "INFO"
                if ($V.UninstallToolGlob.Count) { Log "ASUS PC monte : ajoute aussi 'Armoury Crate Uninstall Tool.exe'." "INFO" }
                return
            }
        }
        if ($ok) {
            Log "$($V.AppName) installee." "OK"
            $installedByUs = $true
            Save-State ([pscustomobject]@{ Vendor=$V.Cle; AppName=$V.AppName; Type=$V.Type; InstalledByUs=$true; InstalledAt=(Get-Date).ToString('s'); UninstalledAt=$null; Machine=$env:COMPUTERNAME })

            # Beaucoup d'applis constructeur n'enregistrent leurs services / taches
            # qu'au 1er lancement. On ouvre donc l'appli tout de suite.
            $lnk = @(
                Get-ChildItem "$env:ProgramData\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter '*.lnk' -EA SilentlyContinue
                Get-ChildItem "$env:AppData\Microsoft\Windows\Start Menu\Programs" -Recurse -Filter '*.lnk' -EA SilentlyContinue
            ) | Where-Object { $_.BaseName -like "*$($V.AppName)*" -or $_.Directory.Name -match $V.Cle -or $_.BaseName -match $V.Cle } | Select-Object -First 1
            $exe = $null
            if (-not $lnk) {
                $exe = Get-ChildItem $V.Folders -Recurse -Filter '*.exe' -EA SilentlyContinue |
                       Where-Object { $_.BaseName -notmatch 'unins|setup|update|helper|crash|report|service|daemon' -and ($_.BaseName -match $V.Cle -or $_.BaseName -match ($V.AppName -replace '\W')) } |
                       Sort-Object Length -Descending | Select-Object -First 1
            }
            $cible = if ($lnk) { $lnk.FullName } elseif ($exe) { $exe.FullName } else { $null }
            if ($cible) {
                Log "Ouverture de $($V.AppName) (enregistre ses services au 1er lancement)..." "INFO"
                try { Start-Process -FilePath $cible; Start-Sleep 12 } catch { Log "  ouverture manuelle a faire : $_" "WARN" }
                $svcApres = @(Get-Service -EA SilentlyContinue | Where-Object { $V.Services -contains $_.Name })
                if ($svcApres.Count -gt 0) { Log "$($svcApres.Count) service(s) $($V.Cle) enregistre(s)." "OK" }
                else { Log "Services pas encore vus - laisse l'appli finir de s'ouvrir, ou un reboot les posera." "INFO" }
            } else {
                Log "Raccourci de $($V.AppName) introuvable : ouvre-la a la main depuis le menu Demarrer." "WARN"
            }
        } else { Log "Installation non confirmee. Arret de la phase appli." "ERROR"; return }
    }

    Write-Host ""
    Log "=== REGLAGES ===" "TITRE"
    if ($V.Type -eq 'Monte') {
        Write-Host "  Dans $($V.AppName) : courbe(s) de ventilation, profil perf, RGB." -ForegroundColor Gray
        Write-Host "  (XMP reste dans le BIOS, pas ici.)" -ForegroundColor DarkGray
    } else {
        Write-Host "  Dans $($V.AppName) : mode thermique (Silencieux / Equilibre / Performance), profil batterie." -ForegroundColor Gray
    }
    Read-Host "`n  Entree quand tes reglages sont faits et enregistres" | Out-Null

    Write-Host ""
    if (-not $installedByUs) { Log "Appli deja presente avant notre passage : on la LAISSE." "OK"; return }
    if ($V.Type -eq 'Monte') {
        Log "Verifie que la courbe ventilo tient SANS l'appli. Sinon refais-la dans le BIOS avant de desinstaller." "WARN"
    } else {
        Log "Sur PC de marque : le mode thermique peut ne PAS tenir sans le service constructeur." "WARN"
        Log "Si le client veut garder Performance/Silencieux en permanence -> GARDER l'appli." "WARN"
    }
    if (Confirm-ON "  Desinstaller $($V.AppName) maintenant ?") {
        Remove-VendorApp $V
        if (Confirm-ON "  Redemarrer maintenant pour finaliser ?") { shutdown.exe /r /t 5 }
    } else {
        Log "Desinstallation reportee. Plus tard : AlloValentin-CarteMere.ps1 -Mode Uninstall" "INFO"
    }
}

# ============================================================
#  PHASE 1 - Detection
# ============================================================
Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - CARTE MERE / BIOS / XMP" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host ""

$cs = Get-CimInstance Win32_ComputerSystem -EA SilentlyContinue
$bb = Get-CimInstance Win32_BaseBoard -EA SilentlyContinue
$bios = Get-CimInstance Win32_BIOS -EA SilentlyContinue
$sysMan = "$($cs.Manufacturer)"; $sysModel = "$($cs.Model)"
$boardMan = "$($bb.Manufacturer)"; $boardPrd = "$($bb.Product)"
Log ("Systeme : {0} / {1}" -f $sysMan, $sysModel) "TITRE"
Log ("Carte mere : {0} / {1}" -f $boardMan, $boardPrd) "TITRE"
$rd = $null; try { $rd = [Management.ManagementDateTimeConverter]::ToDateTime($bios.ReleaseDate) } catch { $rd = $bios.ReleaseDate }
Log ("BIOS : {0} v{1} ({2})" -f $bios.Manufacturer, $bios.SMBIOSBIOSVersion, $(if ($rd -is [datetime]) { $rd.ToString('yyyy-MM-dd') } else { $rd }))

$isUefi = $false
try { if (Test-Path 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State') { $isUefi = $true }
      else { $isUefi = ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name PEFirmwareType -EA Stop).PEFirmwareType -eq 2) } } catch {}
Log ("Firmware : " + $(if ($isUefi) { "UEFI" } else { "BIOS legacy / indetermine" }))

$placeholders = @('System Product Name','To be filled by O.E.M.','To Be Filled By O.E.M.','Default string','Not Applicable','','OEM')
$looksOEM = ($sysMan -match $MarquesOEM) -or (($sysModel -notin $placeholders) -and ($sysModel -ne $boardPrd) -and ($sysMan -notmatch 'gigabyte|asrock'))

$V = $null
if ($looksOEM) { $V = $Catalogue | Where-Object { $_.Type -eq 'Marque' -and $_.MatchSys -and $sysMan -match $_.MatchSys } | Select-Object -First 1 }
if (-not $V)   { $V = $Catalogue | Where-Object { $_.Type -eq 'Monte'  -and $_.MatchBoard -and $boardMan -match $_.MatchBoard } | Select-Object -First 1; if ($V) { $looksOEM = $false } }
if (-not $V) {
    Log "Machine non cataloguee (systeme '$sysMan', carte '$boardMan')." "WARN"
    if ($looksOEM) { Log "PC de marque : XMP verrouille constructeur. Chercher l'appli du support constructeur pour les modes ventilo." "INFO" }
    Pause-Entree; exit
}
$estMonte = ($V.Type -eq 'Monte')
Log ("Categorie : {0}  ->  {1}" -f $(if ($estMonte) { 'PC monte' } else { 'PC de marque' }), $V.AppName) "OK"

# rappel diag
$dernierDiag = Get-ChildItem $ReportDir -Filter 'Diagnostic-*.html' -EA SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $dernierDiag -or $dernierDiag.LastWriteTime -lt (Get-Date).AddDays(-7)) {
    Log "Pas de diagnostic recent : l'option 1 donne le contexte complet (disque, pilotes, equilibre) avant de toucher au BIOS." "WARN"
} else {
    Log "Dernier diagnostic : $($dernierDiag.LastWriteTime.ToString('yyyy-MM-dd HH:mm'))"
}

# ============================================================
#  MODE MAJ  -  tout mettre a jour (Windows + pilotes + chipset)
#  Aucun flash BIOS. Aucun tweak. Juste les mises a jour.
# ============================================================
if ($Mode -eq 'MAJ') {
    Write-Host ""
    Log "=== TOUT METTRE A JOUR : Windows Update + pilotes + chipset ===" "TITRE"
    Log "Ni le pilote GPU (via son appli) ni le BIOS (Q-Flash) ne sont touches ici." "INFO"

    # --- Windows Update ---
    $rebootWU = $false
    Write-Host ""
    Log "--- Windows Update ---" "TITRE"
    try {
        $wuS = New-Object -ComObject Microsoft.Update.Session
        Log "Recherche (1 a 5 min)..."
        $wuR = $wuS.CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0")
        if ($wuR.Updates.Count -eq 0) { Log "Windows est deja a jour." "OK" }
        else {
            $wuC = New-Object -ComObject Microsoft.Update.UpdateColl
            foreach ($u in $wuR.Updates) { Log "  - $($u.Title)"; try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}; $wuC.Add($u) | Out-Null }
            Log "Telechargement + installation..."
            $wd = $wuS.CreateUpdateDownloader(); $wd.Updates = $wuC; $wd.Download() | Out-Null
            $wi = $wuS.CreateUpdateInstaller(); $wi.Updates = $wuC; $wres = $wi.Install()
            for ($i = 0; $i -lt $wuC.Count; $i++) {
                $rc = $wres.GetUpdateResult($i).ResultCode
                Log ("  [{0}] {1}" -f $(if ($rc -eq 2) { 'OK' } elseif ($rc -eq 3) { 'OK partiel' } else { "code $rc" }), $wuC.Item($i).Title)
            }
            $rebootWU = [bool]$wres.RebootRequired
            if ($rebootWU) { Log "Un redemarrage sera necessaire." "WARN" }
        }
    } catch { Log "Windows Update : $($_.Exception.Message)" "WARN" }

    # --- Pilotes via le catalogue Microsoft : Reseau / Stockage / Audio ---
    # PAS le chipset : le catalogue renvoie n'importe quel paquet revendiquant
    # l'ID (on a deja vu un pilote SMBus "ELAN" de 2019 s'installer sur une
    # carte Intel). Le chipset passe par l'assistant du fondeur, curatif.
    Write-Host ""
    Log "--- Pilotes (Microsoft Update Catalog) ---" "TITRE"
    $cpuVendor = "$((Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1).Manufacturer)"
    $estIntel  = $cpuVendor -match 'Intel'
    $estAmdCpu = $cpuVendor -match 'AMD|Advanced Micro'
    $majD = 0
    $catCfg = @(
        @{ C = 'Reseau';   Classes = @('Net');                Inclut = 'Ethernet|GbE|Wi-?Fi|Wireless|Gigabit|2\.5G|Killer'; Exclut = $null; SkipMS = $false }
        @{ C = 'Stockage'; Classes = @('HDC', 'SCSIAdapter'); Inclut = $null; Exclut = $null;                              SkipMS = $true }
        @{ C = 'Audio';    Classes = @('MEDIA');              Inclut = 'Audio|Realtek|SmartSound'; Exclut = 'NVIDIA|HDMI|DisplayPort|AMD High'; SkipMS = $false }
    )
    foreach ($cfg in $catCfg) {
        $info = Get-DriverInfoCategorie -Classes $cfg.Classes -Inclut $cfg.Inclut -Exclut $cfg.Exclut
        if (-not $info) { continue }
        if ($cfg.SkipMS -and $info.Provider -match 'Microsoft') { Log "$($cfg.C) : pilote Windows standard, on ne force pas un pilote tiers." "OK"; continue }
        if (Update-DriverFromCatalog -Hwid $info.Hwid -Label $cfg.C -DateActuelle $info.Date -VendorActuel $info.Provider) { $majD++ }
    }

    # --- Chipset : l'assistant du fondeur (curatif, teste par Intel/AMD) ---
    Write-Host ""
    if ($estIntel -and (Get-Command winget -EA SilentlyContinue)) {
        Log "Chipset : Intel Driver & Support Assistant (curatif). Installation..." "TITRE"
        Invoke-Winget -Action 'install' -Id 'Intel.IntelDriverAndSupportAssistant'
        $dsa = Get-ChildItem "$env:ProgramFiles\Intel\Driver and Support Assistant","${env:ProgramFiles(x86)}\Intel\Driver and Support Assistant" -Recurse -Filter 'DSA*.exe' -EA SilentlyContinue | Select-Object -First 1
        if ($dsa) { Start-Process $dsa.FullName; Log "DSA lance : sur la page qui s'ouvre, clique 'Telecharger et installer' pour le chipset." "OK" }
    } elseif ($estAmdCpu) {
        Log "Chipset AMD : telecharger sur amd.com/support > Chipsets (pas de MAJ auto fiable)." "INFO"
    }

    Write-Host ""
    Log "$majD pilote(s) Reseau/Stockage/Audio mis a jour via le catalogue." $(if ($majD) { "OK" } else { "INFO" })
    if ($rebootWU -or $majD -gt 0) { Log ">>> REDEMARRE la machine pour finaliser. <<<" "WARN" }
    else { Log "Rien de nouveau cote catalogue." "OK" }
    Pause-Entree "Journal : $LogFile"
    exit
}

# ============================================================
#  MODE Uninstall
# ============================================================
if ($Mode -eq 'Uninstall') {
    $st = Load-State
    if (-not $st -or $st.Vendor -ne $V.Cle -or -not $st.InstalledByUs -or $st.UninstalledAt) { Log "Rien d'installe par ce script a retirer pour $($V.Cle)." "WARN"; Pause-Entree; exit }

    # On NE se fie PAS au seul fichier d'etat : on montre ce qui est REELLEMENT installe
    # (nom + version + date), et si une date d'installation est anterieure a notre
    # passage, c'est probablement une appli que le client avait deja -> on bloque.
    $entries = @(Get-InstalledEntries -Like $V.DetectLike)
    $appx    = @(Get-AppxMatches $V)
    if ($entries.Count -eq 0 -and $appx.Count -eq 0) {
        Log "$($V.AppName) n'est plus installee : rien a retirer." "OK"
        try { $st | Add-Member UninstalledAt ((Get-Date).ToString('s')) -Force; Save-State $st } catch {}
        Pause-Entree; exit
    }

    Write-Host ""
    Log "A retirer (fichier d'etat : installe par nous le $($st.InstalledAt)) :" "TITRE"
    $stampNous = $null; try { $stampNous = [datetime]$st.InstalledAt } catch {}
    $suspect = $false
    foreach ($e in $entries) {
        $di = $null
        if ("$($e.InstallDate)" -match '^\d{8}$') { try { $di = [datetime]::ParseExact("$($e.InstallDate)", 'yyyyMMdd', $null) } catch {} }
        $ligne = "  - {0}  v{1}{2}" -f $e.DisplayName, $e.DisplayVersion, $(if ($di) { "  (installe le " + $di.ToString('yyyy-MM-dd') + ")" } else { "  (date inconnue)" })
        Log $ligne
        if ($di -and $stampNous -and $di -lt $stampNous.Date.AddDays(-2)) { $suspect = $true }
    }
    foreach ($a in $appx) { Log ("  - (paquet Store) {0} {1}" -f $a.Name, $a.Version) }

    if ($suspect) {
        Write-Host ""
        Log "ATTENTION : une des applis ci-dessus a ete installee AVANT notre passage." "WARN"
        Log "Le fichier d'etat est probablement perime : ce n'est sans doute PAS une appli" "WARN"
        Log "que ce script a installee. La retirer supprimerait un logiciel du client." "WARN"
        if ((Read-Host "  Taper exactement  RETIRER  pour desinstaller quand meme") -cne 'RETIRER') {
            Log "Desinstallation annulee (garde-fou date)." "OK"; Pause-Entree; exit
        }
    }
    elseif (-not (Confirm-ON "  Confirmer la desinstallation de ce qui est liste ci-dessus ?")) {
        Log "Desinstallation annulee." "INFO"; Pause-Entree; exit
    }

    Remove-VendorApp $V
    if (Confirm-ON "  Redemarrer maintenant ?") { shutdown.exe /r /t 5 }
    Pause-Entree "Journal : $LogFile"; exit
}

# ============================================================
#  PHASE 2 - FIRMWARE + MEMOIRE / XMP + RESIZABLE BAR   (Auto + Bios)
#  Analyse en LECTURE SEULE. Aucune ecriture BIOS forcee (cf passation 7).
#  Sortie : un scorecard "A FAIRE DANS LE BIOS" ($todoBios).
# ============================================================
$xmpActif = $null
$todoBios = @()
if ($Mode -in @('Auto','Bios')) {

    # ---------- FIRMWARE ----------
    Write-Host ""
    Log "=== FIRMWARE ===" "TITRE"
    Log ("Mode : " + $(if ($isUefi) { "UEFI" } else { "BIOS legacy" }) + $(if (-not $isUefi) { "  (bloque Secure Boot ET Resizable BAR)" } else { "" })) $(if ($isUefi) { "OK" } else { "WARN" })

    $sbOn = $null
    try { $sbOn = [bool]((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -EA Stop).UEFISecureBootEnabled) } catch {}
    if ($null -ne $sbOn) { Log ("Secure Boot : " + $(if ($sbOn) { "actif" } else { "inactif" })) $(if ($sbOn) { "OK" } else { "INFO" }) }

    $bootStyle = $null
    try { $bootStyle = (Get-Disk -EA Stop | Where-Object IsBoot | Select-Object -First 1).PartitionStyle } catch {}
    if ($bootStyle) {
        Log ("Disque systeme : $bootStyle") $(if ($bootStyle -eq 'GPT') { "OK" } else { "WARN" })
        if ($bootStyle -eq 'MBR') {
            Log "Disque en MBR : le PC boote en Legacy/CSM. Conversion GPT (mbr2gpt) puis passage UEFI = pre-requis pour ReBAR + Secure Boot." "WARN"
            $todoBios += [pscustomobject]@{ T="Passer en UEFI (apres 'mbr2gpt') - debloque ReBAR et Secure Boot"; P=$(if ($V.Bios) { $V.Bios.CSM }) }
        }
    }

    if ($rd -is [datetime]) {
        $ageAns = [math]::Floor(((Get-Date) - $rd).Days / 365.25)
        $verTxt = "BIOS v$($bios.SMBIOSBIOSVersion) du $($rd.ToString('yyyy-MM-dd'))"
        # $estAMD est defini plus bas ; ici on relit vite le fabricant CPU
        $amd = "$((Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1).Manufacturer)" -match 'AMD'
        if ($ageAns -ge 3 -and $amd) {
            Log ("$verTxt - $ageAns ans. Sur AMD, une MAJ AGESA apporte souvent des gains RAM / stabilite EXPO : verifier sur le site du constructeur.") "WARN"
            $todoBios += [pscustomobject]@{ T="Verifier une mise a jour du BIOS (AGESA) - actuel : $($bios.SMBIOSBIOSVersion)"; P="Site du constructeur > Support > BIOS. Flasher avec l'outil integre : Q-Flash (Gigabyte) / EZ Flash (ASUS) / M-Flash (MSI) / Instant Flash (ASRock). NE PAS couper l'alimentation pendant." }
        } elseif ($ageAns -ge 4) {
            Log ("$verTxt - $ageAns ans. Verifier s'il existe une version plus recente (moins critique sur Intel).")
        } else {
            Log ("$verTxt - $ageAns an(s).")
        }
    }

    # ---------- MEMOIRE ----------
    Write-Host ""
    Log "=== MEMOIRE / XMP ===" "TITRE"
    $dimms = @(Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue)
    $pma   = Get-CimInstance Win32_PhysicalMemoryArray -EA SilentlyContinue | Select-Object -First 1
    $ddr   = switch ("$($dimms[0].SMBIOSMemoryType)") { '24'{'DDR3'} '26'{'DDR4'} '34'{'DDR5'} default{'DDR?'} }
    $jedecBase = switch ($ddr) { 'DDR3'{1600} 'DDR4'{3200} 'DDR5'{5600} default{3200} }  # plafond JEDEC : au-dela = profil XMP/EXPO
    $slotsTot  = [int]$pma.MemoryDevices
    $slotsLibr = if ($slotsTot) { $slotsTot - $dimms.Count } else { $null }
    $ramTotGB  = [math]::Round((@($dimms | ForEach-Object { $_.Capacity }) | Measure-Object -Sum).Sum / 1GB)

    if ($dimms.Count -eq 0) { Log "Aucune barrette lue." "WARN" }
    else {
        Log ("$ddr - $($dimms.Count) barrette(s), $ramTotGB Go total" + $(if ($null -ne $slotsLibr) { ", $slotsLibr slot(s) libre(s) / $slotsTot" } else { "" }))
        foreach ($d in $dimms) {
            $rank = switch ("$($d.Attributes)") { '1'{'1Rx'} '2'{'2Rx'} default{''} }
            Log ("  {0,-16} {1,-20} {2,3} Go  {3}  annonce {4} / reel {5} MHz  {6} mV" -f `
                $d.DeviceLocator, "$($d.PartNumber)".Trim(), [math]::Round($d.Capacity/1GB), $rank.PadRight(3),
                (Get-RatedSpeed $d), $d.ConfiguredClockSpeed, $d.ConfiguredVoltage)
        }
    }

    $cfgMin = (@($dimms | ForEach-Object { [int]$_.ConfiguredClockSpeed } | Where-Object { $_ -gt 0 }) | Measure-Object -Minimum).Minimum
    $ratMax = (@($dimms | ForEach-Object { Get-RatedSpeed $_ }) | Measure-Object -Maximum).Maximum
    $ratConnue = ($ratMax -gt $jedecBase) -or ($dimms.Count -and ("$($dimms[0].PartNumber)".Trim() -match '(?<!\d)[2-9]\d{3}(?!\d)'))
    Write-Host ""

    if (-not $estMonte) {
        Log "PC de marque : profil memoire (XMP/EXPO) VERROUILLE par le constructeur - rien a activer." "WARN"
        if ($cfgMin) { Log "La RAM tourne a $cfgMin MHz, c'est la valeur imposee." "INFO" }
        $xmpActif = $true
    }
    elseif ($cfgMin -and $ratMax) {
        if ($cfgMin -ge ($ratMax - 100)) {
            if ($ratMax -le $jedecBase -and -not $ratConnue) {
                Log "RAM a $cfgMin MHz = plafond JEDEC $ddr. Barrettes standard, pas de profil XMP/EXPO au-dela : rien a activer." "OK"
            } else {
                Log "XMP / EXPO : ACTIF - la RAM atteint sa vitesse annoncee ($cfgMin MHz)." "OK"
            }
            $xmpActif = $true
        }
        elseif ($ratConnue) {
            Log "XMP / EXPO : INACTIF - RAM a $cfgMin MHz alors que le kit vise $ratMax MHz. Perte typique 5 a 15 % en jeu CPU-dependant." "WARN"
            $xmpActif = $false
            $todoBios += [pscustomobject]@{ T="Activer le profil XMP / EXPO ($ratMax MHz)"; P=$(if ($V.Bios) { $V.Bios.XMP }) }
        }
        else {
            # vitesse annoncee non lisible dans la reference : echelle JEDEC
            $seuilBas = if ($ddr -eq 'DDR5') { 4800 } else { 2666 }
            if ($cfgMin -le $seuilBas) {
                Log "XMP / EXPO : probablement INACTIF - RAM a $cfgMin MHz (niveau JEDEC $ddr). Confirmer la vitesse annoncee des barrettes / CPU-Z." "WARN"
                $xmpActif = $false
                $todoBios += [pscustomobject]@{ T="Verifier / activer XMP-EXPO (RAM a $cfgMin MHz, kit peut-etre plus rapide)"; P=$(if ($V.Bios) { $V.Bios.XMP }) }
            } else {
                Log "XMP / EXPO : au-dessus du JEDEC de base ($cfgMin MHz) - profil probablement actif. Confirmer avec la fiche du kit." "INFO"
                $xmpActif = $true
            }
        }
        if ($estMonte -and $xmpActif) { Log "Timings (CAS) non lisibles ici : en cas de doute, CPU-Z onglet Memory." "INFO" }
    }

    # ---------- DUAL-CHANNEL ----------
    $canaux = @($dimms | ForEach-Object {
        $src = "$($_.DeviceLocator) $($_.BankLabel)"
        if     ($src -match '(?i)Controller\s*\d+\s*-?\s*Channel\s*([A-H])') { $Matches[1].ToUpper() }
        elseif ($src -match '(?i)Cha(?:nnel|n)?\s*-?\s*([A-H])(?![A-Za-z])') { $Matches[1].ToUpper() }
        elseif ($src -match '(?i)(?:SO-?DIMM|DDR\d|X?MM|DIMM)[\s_-]*([A-H])\s*\d?(?![A-Za-z])') { $Matches[1].ToUpper() }
        else { $null }
    }) | Where-Object { $_ } | Sort-Object -Unique
    $pnsRam  = @($dimms | ForEach-Object { "$($_.PartNumber)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
    $capsRam = @($dimms | ForEach-Object { [long]$_.Capacity } | Select-Object -Unique)
    $slotNum = @($dimms | ForEach-Object { if ("$($_.DeviceLocator)" -match '(\d+)\s*$') { [int]$Matches[1] } })
    if ($dimms.Count -ge 2 -and $canaux.Count -ge 2) {
        Log ("Dual-channel : ACTIF (canaux $($canaux -join '+'))." ) "OK"
        if ($slotsTot -ge 4 -and $dimms.Count -eq 2 -and (@($dimms | Where-Object { $_.DeviceLocator -match '1$' }).Count -eq 2)) {
            Log "2 barrettes dans les slots n.1 d'une carte 4 slots : verifier qu'elles sont dans les slots recommandes (souvent 2 et 4 / A2+B2) pour la stabilite XMP." "INFO"
        }
    }
    elseif ($dimms.Count -ge 2 -and $canaux.Count -eq 1) {
        Log ("Dual-channel : les $($dimms.Count) barrettes sont sur le meme canal ($($canaux[0])) = SINGLE CHANNEL. Bande passante /2.") "WARN"
        Log "Deplacer une barrette dans un slot de l'autre canal (souvent slots 2 et 4). Gain 10 a 20 % de FPS, gratuit." "WARN"
        $todoBios += [pscustomobject]@{ T="Repositionner une barrette pour le dual-channel"; P="PC eteint, capot ouvert : placer les 2 barrettes dans des slots de canaux DIFFERENTS (souvent slots 2 et 4, notes A2 / B2). Voir le manuel de la carte mere." }
    }
    elseif ($dimms.Count -eq 2 -and $pnsRam.Count -le 1 -and $capsRam.Count -eq 1 -and $slotNum.Count -eq 2 -and ($slotNum[0] % 2) -eq ($slotNum[1] % 2)) {
        Log ("Dual-channel : les 2 barrettes identiques sont dans des slots de MEME parite ($($dimms[0].DeviceLocator) / $($dimms[1].DeviceLocator)) - souvent le meme canal = SINGLE CHANNEL. Cette carte n'etiquette pas les canaux.") "WARN"
        Log "Confirmer avec CPU-Z (onglet Memory, ligne 'Channel'). Si 'Single' : deplacer une barrette d'un cran." "WARN"
        $todoBios += [pscustomobject]@{ T="Verifier le dual-channel (CPU-Z) et repositionner une barrette si besoin"; P="PC eteint : placer les 2 barrettes dans des slots de canaux DIFFERENTS (souvent slots 2 et 4). Voir le manuel de la carte mere." }
    }
    elseif ($dimms.Count -eq 2 -and $pnsRam.Count -le 1 -and $capsRam.Count -eq 1 -and $slotNum.Count -eq 2) {
        Log "Dual-channel : probable (2 barrettes identiques, slots de parite differente) mais canal non etiquete par cette carte. Confirmer CPU-Z (onglet Memory doit afficher 'Dual')." "INFO"
    }
    elseif ($dimms.Count -ge 2) { Log "Dual-channel : canal non lisible, verifier au BIOS / CPU-Z (doit afficher 'Dual')." "WARN" }
    else { Log "Une seule barrette : pas de dual-channel. Ajouter une 2e barrette identique = gros gain." "WARN" }

    # ---------- RESIZABLE BAR ----------
    Write-Host ""
    Log "=== RESIZABLE BAR ===" "TITRE"
    $gpu = Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Display'" -EA SilentlyContinue |
           Where-Object { $_.DeviceID -like 'PCI\VEN_*' -and $_.Name -match 'NVIDIA|GeForce|Radeon|\bRX\b|Arc|Intel Arc' } | Select-Object -First 1
    if (-not $gpu) {
        Log "Pas de carte graphique dediee detectee : Resizable BAR sans objet." "INFO"
    } else {
        $rb = Get-ReBARState $gpu
        Log ("GPU : $($gpu.Name)  -  $($rb.Detail)")
        if (-not $isUefi -or $bootStyle -eq 'MBR') {
            Log "Resizable BAR impossible tant que le PC boote en Legacy/CSM (voir Firmware ci-dessus)." "WARN"
        }
        elseif ($rb.Actif -eq $true) {
            Log "Resizable BAR : ACTIF." "OK"
        }
        elseif ($rb.Actif -eq $false) {
            Log "Resizable BAR : INACTIF. Gain typique 5 a 15 % selon les jeux." "WARN"
            $todoBios += [pscustomobject]@{ T="Above 4G Decoding = Enabled  +  Re-Size BAR Support = Enabled"; P=$(if ($V.Bios) { $V.Bios.ReBAR }) }
        }
        elseif (-not ($gpu.Name -match 'RTX\s?\d{4}|GTX\s?16\d{2}|RX\s?5[5-9]\d0|RX\s?[6-9]\d{3}|Arc')) {
            Log "Resizable BAR : GPU trop ancien (anterieur RTX 20 / RX 5000) - non concerne." "INFO"
        }
        else {
            Log "Resizable BAR : indetermine. Confirmer dans NVIDIA App / AMD Software / GPU-Z." "INFO"
        }
    }

    # ---------- CPU / TURBO BOOST ----------
    Write-Host ""
    Log "=== CPU / TURBO BOOST ===" "TITRE"
    $cpu = Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1
    $baseMHz = [int]$cpu.MaxClockSpeed
    $nLog = [int]$cpu.NumberOfLogicalProcessors
    Log ("$("$($cpu.Name)".Trim())  -  $($cpu.NumberOfCores)C/${nLog}T, base $baseMHz MHz")

    $planNom = ((powercfg /getactivescheme) -join ' ')
    if ($planNom -match '\(([^)]+)\)\s*$') { $planNom = $Matches[1] }
    $planHP = ($planNom -match 'perf|perform') -and ($planNom -notmatch 'conomie|saver')
    Log ("Plan d'alimentation : $planNom")

    # --- charge breve tous coeurs (processus powershell caches) + lecture compteurs par coeur ---
    $charge = @()
    try {
        $charge = 1..$nLog | ForEach-Object {
            Start-Process powershell -WindowStyle Hidden -PassThru -ArgumentList `
                '-NoProfile','-Command','$x=0.0; $e=(Get-Date).AddSeconds(7); while((Get-Date) -lt $e){ $x=[math]::Sqrt($x+1) }'
        }
    } catch {}
    Log "Mesure du boost en cours (~6 s)..."
    Start-Sleep -Seconds 4
    $cores = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -EA SilentlyContinue | Where-Object { $_.Name -match '^\d+,\d+$' }
    if (-not $cores) { $cores = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -EA SilentlyContinue }
    $mhzMax = ($cores | ForEach-Object { [int]($_.ProcessorFrequency * $_.PercentProcessorPerformance / 100) } | Measure-Object -Maximum).Maximum
    $charge | ForEach-Object { try { $_.Kill() } catch {} }

    $cpuBoostOK = $true
    if (-not $mhzMax) {
        Log "Mesure du boost indisponible (compteurs de perf). Verifier sous charge avec HWiNFO / LibreHardwareMonitor." "WARN"
    }
    elseif ($mhzMax -le [int]($baseMHz * 1.05)) {
        $cpuBoostOK = $false
        Log ("Le CPU ne booste PAS sous charge : ~$mhzMax MHz = frequence de base.") "WARN"
        Log "Causes : Turbo desactive au BIOS, limites de puissance trop basses, throttling thermique, ou plan d'alim." "WARN"
        if ($estMonte) {
            $todoBios += [pscustomobject]@{ T="CPU : Turbo Boost / Core Performance Boost = Enabled, limites de puissance (PL1/PL2, MCE) non bridees"; P=$(if ($V.Bios) { $V.Bios.Turbo }) }
        } else {
            Log "PC de marque : limites souvent verrouillees. Le mode 'Performance' de l'appli constructeur peut aider." "INFO"
        }
    }
    else {
        $pct = [math]::Round(($mhzMax / $baseMHz - 1) * 100)
        Log ("Turbo ACTIF : jusqu'a ~$mhzMax MHz sous charge (+$pct % vs base $baseMHz).") "OK"
    }

    if (-not $cpuBoostOK -and -not $planHP) {
        $todoWin += "Passer sur le plan d'alimentation Haute performance"
    }
    Log "Aller au-dela (OC multiplicateur / voltage / undervolt / suppression des limites) : dans le BIOS, par le technicien." "INFO"
    Log "Jamais applique par ce script : risque d'instabilite et de casse (cf passation section 7)." "INFO"

    # ---------- SCORECARD ----------
    Write-Host ""
    if ($todoWin.Count -gt 0) {
        Log "Correctif Windows disponible :" "WARN"
        $todoWin | ForEach-Object { Write-Host "     - $_" -ForegroundColor Yellow }
        if (Confirm-ON "  Basculer sur le plan Haute performance maintenant (reversible) ?") {
            try {
                $hp = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
                cmd /c "powercfg -duplicatescheme $hp" 2>$null | Out-Null
                powercfg /setactive $hp 2>$null | Out-Null
                if (((powercfg /getactivescheme) -join ' ') -notmatch $hp) { powercfg /setactive SCHEME_MIN 2>$null | Out-Null }
                Log "Plan Haute performance actif (reversible : /config > alimentation, ou Undo du Diagnostic)." "OK"
            } catch { Log "Echec bascule de plan : $_" "WARN" }
        }
    }
    if ($estMonte) {
        if ($todoBios.Count -gt 0) {
            Log "=== A FAIRE DANS LE BIOS : $($todoBios.Count) point(s) ===" "WARN"
            $todoBios | ForEach-Object {
                Write-Host "     [ ] $($_.T)" -ForegroundColor Yellow
                if ($_.P) { Write-Host "         ou : $($_.P)" -ForegroundColor DarkGray }
            }
        } else {
            Log "=== BIOS : rien de bloquant d'apres l'analyse. ===" "OK"
        }
    }
}

# ============================================================
#  PHASE 3b - PILOTES & MISE A JOUR BIOS   (Auto + Bios, TOUS les PC)
#  Lecture seule + une seule action optionnelle (installer l'assistant
#  pilotes officiel). Aucun flash BIOS, aucune install de pilote forcee.
# ============================================================
if ($Mode -in @('Auto','Bios')) {
    Write-Host ""
    Log "=== PILOTES : etat et mise a jour ===" "TITRE"

    $cpuVendor = "$((Get-CimInstance Win32_Processor -EA SilentlyContinue | Select-Object -First 1).Manufacturer)"
    $estIntel  = $cpuVendor -match 'Intel'
    $estAmdCpu = $cpuVendor -match 'AMD|Advanced Micro'

    # On classe par DeviceClass (fiable) et on ELIMINE les pilotes generiques Windows
    # et les peripheriques virtuels (dates bidon type 1968 / 2006). Pour chaque
    # categorie on garde le pilote reel le PLUS RECENT = celui qui est actif.
    function Cat-Pilote {
        param($D)
        $cl = "$($D.DeviceClass)".ToUpper()
        $n  = "$($D.DeviceName)"
        $prov = "$($D.DriverProviderName)"
        if ($prov -match '^Microsoft$' -and $n -notmatch 'NVIDIA|AMD|Intel|Realtek') { return $null }
        if ($n -match 'Virtual|Enumerator|Miniport|WAN |Kernel|Loopback|Wintun|WireGuard|TAP-|Hyper-V|WFP|QoS|Bluetooth|Composite|Root Hub|Generic (PnP|software)|Remote|RAS Async|Debug|Composant|Component|Extension Package') { return $null }
        switch ($cl) {
            'DISPLAY'      { if ($n -match 'NVIDIA|Radeon|Arc|Iris|UHD Graphics|HD Graphics') { return 'GPU' } }
            'NET'          { if ($n -match 'Ethernet|GbE|Wi-?Fi|Wireless|802\.11|Killer|Family Controller|Gigabit|2\.5G') { return 'Reseau' } }
            { $_ -in 'HDC','SCSIADAPTER' } { return 'Stockage' }
            'MEDIA'        { if ($n -match 'Audio|Realtek|Sound') { return 'Audio' } }
            'SYSTEM'       { if ($prov -notmatch 'Microsoft' -and $n -match 'Chipset|SMBus|LPC|Management Engine|Serial IO|PCH|Platform|PCI Express Root Port') { return 'Chipset' } }
        }
        return $null
    }
    $pil = @{}
    foreach ($d in (Get-CimInstance Win32_PnPSignedDriver -EA SilentlyContinue | Where-Object { $_.DeviceName -and $_.DriverVersion })) {
        $c = Cat-Pilote $d
        if (-not $c) { continue }
        $dt = $null
        try { $dt = [Management.ManagementDateTimeConverter]::ToDateTime($d.DriverDate) }
        catch { if ($d.DriverDate -is [datetime]) { $dt = $d.DriverDate } }
        if ($dt -and ($dt.Year -lt 2000 -or $dt -gt (Get-Date))) { $dt = $null }   # date invalide
        # on garde le plus RECENT (le pilote reellement actif)
        if (-not $pil.ContainsKey($c) -or ($dt -and (-not $pil[$c].Date -or $dt -gt $pil[$c].Date))) {
            $pil[$c] = @{ Nom = "$($d.DeviceName)"; Ver = "$($d.DriverVersion)"; Date = $dt }
        }
    }
    $anciens = @()
    foreach ($c in @('GPU','Chipset','Reseau','Stockage','Audio')) {
        if (-not $pil.ContainsKey($c)) { continue }
        $p = $pil[$c]
        $nom = if ($p.Nom.Length -gt 40) { $p.Nom.Substring(0,40) } else { $p.Nom }
        if ($p.Date) {
            $ans = [math]::Round(((Get-Date) - $p.Date).Days / 365, 1)
            $ageTxt = "$($p.Date.ToString('yyyy-MM'))  ($ans an$(if ($ans -ge 2) { 's' } else { '' }))"
            $vieux = ((Get-Date) - $p.Date).Days -gt 730
        } else { $ageTxt = "date inconnue"; $vieux = $false }
        Log ("  {0,-9}: {1,-40} v{2}   {3}" -f $c, $nom, $p.Ver, $ageTxt) $(if ($vieux) { "WARN" } else { "INFO" })
        if ($vieux -and $c -ne 'GPU') { $anciens += $c }
    }

    # Assistant pilotes officiel adapte a la plateforme
    $assist = if ($looksOEM) {
        switch -Regex ($sysMan) {
            'hewlett|hp inc|^hp$' { @{ Nom = 'HP Support Assistant';   Winget = $null;                 Url = 'support.hp.com (chercher "HP Support Assistant")'; Fait = 'pilotes ET BIOS HP' } }
            'dell|alienware'      { @{ Nom = 'Dell Command | Update';   Winget = 'Dell.CommandUpdate';   Url = 'dell.com/support (Service Tag)';                  Fait = 'pilotes ET BIOS Dell, MAJ en un clic' } }
            'lenovo'             { @{ Nom = 'Lenovo Vantage';           Winget = '9WZDNCRFJ4MV';        Url = 'support.lenovo.com';                             Fait = 'pilotes ET BIOS Lenovo' } }
            'acer'              { @{ Nom = 'Acer Care Center';          Winget = $null;                 Url = 'acer.com/support (SNID)';                        Fait = 'pilotes ET BIOS Acer' } }
            default            { @{ Nom = "l'assistant du constructeur"; Winget = $null;               Url = 'site support du constructeur';                   Fait = 'pilotes et BIOS' } }
        }
    } elseif ($estIntel) {
        @{ Nom = 'Intel Driver & Support Assistant'; Winget = 'Intel.IntelDriverAndSupportAssistant'; Url = 'intel.com/content/www/us/en/support/detect.html'; Fait = 'chipset, LAN, Wi-Fi, Thunderbolt Intel (PAS le GPU dedie NVIDIA/AMD)' }
    } elseif ($estAmdCpu) {
        @{ Nom = 'AMD Chipset Drivers'; Winget = $null; Url = 'amd.com/support > Chipsets > selectionner la carte'; Fait = 'chipset AMD (a telecharger sur le site AMD, pas de winget fiable)' }
    } else {
        @{ Nom = 'les pilotes du site de la carte mere'; Winget = $null; Url = "$($V.DownloadPage)"; Fait = 'chipset, LAN, audio' }
    }

    Write-Host ""
    if ($anciens.Count -gt 0) { Log ("$($anciens.Count) pilote(s) cle(s) de plus de 2 ans : $($anciens -join ', ').") "WARN" }
    else { Log "Pilotes cles recents (moins de 2 ans)." "OK" }
    Log "Le pilote GPU dedie (NVIDIA / AMD Radeon) se met a jour a part, via son appli." "INFO"

    # --- 1) Reseau / Stockage / Audio via le catalogue Microsoft ---
    # (comparaison par DATE + filtre fabricant : jamais de downgrade, jamais un
    #  paquet d'un autre fabricant). PAS le chipset - trop d'ambiguite sur les ID.
    $autoCat = @($anciens | Where-Object { $_ -in @('Reseau','Stockage','Audio') })
    if ($autoCat.Count -gt 0 -and (Confirm-ON "  Mettre a jour Reseau/Stockage/Audio via le catalogue Microsoft ?")) {
        if ($autoCat -contains 'Reseau') { Log "Note : la carte reseau se reinitialise brievement (coupure de quelques secondes)." "WARN" }
        $cfgAll = @(
            @{ C='Reseau';   Classes=@('Net');               Inclut='Ethernet|GbE|Wi-?Fi|Wireless|Gigabit|2\.5G|Killer'; Exclut=$null; SkipMS=$false }
            @{ C='Stockage'; Classes=@('HDC','SCSIAdapter'); Inclut=$null; Exclut=$null;                                 SkipMS=$true }
            @{ C='Audio';    Classes=@('MEDIA');             Inclut='Audio|Realtek|SmartSound'; Exclut='NVIDIA|HDMI|DisplayPort|AMD High'; SkipMS=$false }
        )
        $maj = 0
        # reseau en dernier (sa reinstall coupe le lien)
        foreach ($cfg in ($cfgAll | Where-Object { $_.C -in $autoCat } | Sort-Object { $_.C -eq 'Reseau' })) {
            $info = Get-DriverInfoCategorie -Classes $cfg.Classes -Inclut $cfg.Inclut -Exclut $cfg.Exclut
            if (-not $info) { continue }
            if ($cfg.SkipMS -and $info.Provider -match 'Microsoft') { Log "$($cfg.C) : pilote Windows standard, on ne force pas un pilote tiers." "OK"; continue }
            if (Update-DriverFromCatalog -Hwid $info.Hwid -Label $cfg.C -DateActuelle $info.Date -VendorActuel $info.Provider) { $maj++ }
        }
        Log "$maj pilote(s) mis a jour via le catalogue. Redemarre pour finaliser." $(if ($maj) { "OK" } else { "INFO" })
    }

    # --- 2) Chipset (+ Wi-Fi/Thunderbolt/GNA) : assistant officiel du fondeur ---
    # On NE bricole PAS le chipset via le catalogue : il renvoie n'importe quel
    # paquet revendiquant l'ID (deja vu : pilote SMBus "ELAN" de 2019 sur du Intel).
    Log ("Chipset : $($assist.Nom) -> $($assist.Fait).") "INFO"
    Log ("  $($assist.Url)") "INFO"
    if ($assist.Winget -and (Get-Command winget -EA SilentlyContinue) -and (Confirm-ON "  Installer $($assist.Nom) maintenant (outil officiel, faible risque) ?")) {
        Invoke-Winget -Action 'install' -Id $assist.Winget
        Log "Installe. Ouvre-le, lance une recherche de mises a jour, applique. A desinstaller ensuite si le client n'en veut pas." "OK"
    }

    # --- Installer des pilotes telecharges depuis le SITE DU CONSTRUCTEUR ---
    # Source la plus fiable : les pilotes exacts pour la carte exacte. Le
    # telechargement est manuel (Cloudflare bloque les scripts), l'installation
    # est automatique (extraction + pnputil, logguee, reversible).
    $mbSlug = ($boardPrd -replace '\s+', '-')
    $navUrl = if ($looksOEM) {
        switch -Regex ($sysMan) {
            'hewlett|hp inc|^hp$' { 'https://support.hp.com/us-en/drivers' }
            'dell|alienware'      { 'https://www.dell.com/support/home' }
            'lenovo'             { 'https://support.lenovo.com' }
            'acer'              { 'https://www.acer.com/us-en/support' }
            default            { 'https://www.google.com/search?q=' + [uri]::EscapeDataString("$sysMan $sysModel drivers support") }
        }
    } else {
        switch ($V.Cle) {
            'Gigabyte' { "https://www.gigabyte.com/Motherboard/$mbSlug/support" }
            'MSI'      { "https://www.msi.com/Motherboard/$mbSlug/support" }
            'ASUS'     { 'https://www.asus.com/support/' }
            'ASRock'   { 'https://www.asrock.com/mb/' }
            default    { "https://$($V.DownloadPage)" -replace '^https://https://', 'https://' }
        }
    }
    $drvDir = "$AppDir\Drivers"
    if (Confirm-ON "  Telecharger des pilotes depuis le site du constructeur et les installer ?") {
        New-Item -ItemType Directory -Path $drvDir -Force | Out-Null
        try { Start-Process $navUrl } catch { Log "Ouvre a la main : $navUrl" "WARN" }
        try { Start-Process explorer.exe $drvDir } catch {}
        Write-Host ""
        Write-Host "  1. Sur la page ouverte : telecharge les pilotes voulus (priorite : $(if ($anciens.Count) { $anciens -join ', ' } else { 'LAN, Chipset, Audio' }))." -ForegroundColor Gray
        Write-Host "     Pour Gigabyte : onglet 'Support' > 'Driver'. Prends la version Windows 10/11 64-bit." -ForegroundColor DarkGray
        Write-Host "  2. Mets les fichiers .zip dans le dossier qui vient de s'ouvrir :" -ForegroundColor Gray
        Write-Host "     $drvDir" -ForegroundColor White
        Read-Host "  3. Entree quand les .zip (ou .exe) sont dans le dossier"
        Install-StagedDrivers -Dir $drvDir
    }

    # BIOS : version, age, page support, outil de flash
    Write-Host ""
    Log "=== BIOS : mise a jour ===" "TITRE"
    $biosAge = $null
    if ($rd -is [datetime]) { $biosAge = [math]::Round(((Get-Date) - $rd).Days / 365, 1) }
    Log ("Version : $($bios.SMBIOSBIOSVersion)" + $(if ($rd -is [datetime]) { "  du $($rd.ToString('yyyy-MM-dd'))  ($biosAge an$(if ($biosAge -ge 2) { 's' } else { '' }))" } else { "" }))
    if ($biosAge -ne $null -and (($estAmdCpu -and $biosAge -ge 3) -or ($biosAge -ge 5))) {
        Log ("BIOS ancien : chercher une version plus recente" + $(if ($estAmdCpu) { " -- sur AMD, une MAJ AGESA ameliore souvent la stabilite RAM / EXPO et le support CPU" } else { " (moins critique sur Intel, mais corrige parfois microcode / securite / compat NVMe)" }) + ".") "WARN"
    } else { Log "BIOS pas particulierement ancien." "OK" }

    $supUrl = if ($looksOEM) {
        switch -Regex ($sysMan) {
            'hewlett|hp inc|^hp$' { 'support.hp.com  (saisir le numero de serie)' }
            'dell|alienware'      { 'dell.com/support  (Service Tag)' }
            'lenovo'             { 'support.lenovo.com  (numero de serie)' }
            'acer'              { 'acer.com/support  (SNID)' }
            default            { 'site support du constructeur' }
        }
    } else {
        switch ($V.Cle) {
            'Gigabyte' { "gigabyte.com/Motherboard/$mbSlug/support   (ajouter -rev-XX si la page 404, ex : -rev-10)" }
            'MSI'      { "msi.com/Motherboard/$mbSlug/support" }
            'ASUS'     { "asus.com/support   (chercher '$boardPrd')" }
            'ASRock'   { "asrock.com/mb   (chercher '$boardPrd')" }
            default    { "$($V.DownloadPage)" }
        }
    }
    Log ("Page BIOS : $supUrl") "INFO"

    $flash = if ($looksOEM) {
        "l'outil de MAJ du constructeur (voir ci-dessus). Ne PAS lancer un .exe de BIOS brut sous Windows si un flash integre existe."
    } else {
        switch ($V.Cle) {
            'Gigabyte' { 'Q-Flash : touche END au demarrage, ou dans le BIOS (Save & Exit)' }
            'ASUS'     { 'EZ Flash 3 : dans le BIOS, onglet Tool' }
            'MSI'      { 'M-Flash : dans le BIOS' }
            'ASRock'   { 'Instant Flash : dans le BIOS, onglet Tool' }
            default    { "l'outil de flash integre au BIOS de la carte" }
        }
    }
    Log ("Outil de flash : $flash") "INFO"
    Log "REGLE ABSOLUE : ne JAMAIS couper l'alimentation pendant un flash BIOS. Onduleur recommande. Mettre le bon fichier pour la BONNE revision de carte. Ce script ne flashe jamais : une coupure = carte morte." "WARN"
}

# ============================================================
#  PHASE 3 - ACCES BIOS   (Auto + Bios, PC monte seulement)
# ============================================================
if ($Mode -in @('Auto','Bios') -and $estMonte) {
    Write-Host ""
    Log "=== BIOS $($V.Cle) : par ou passer ===" "TITRE"
    Log ("Entrer : " + $V.Bios.Enter) "INFO"
    foreach ($k in @('XMP','ReBAR','Turbo','CSM','Fans','Save')) {
        if ($V.Bios.$k) {
            $marque = if (($todoBios | Where-Object { $_.P -eq $V.Bios.$k })) { ">>" } else { "  " }
            Log ("$marque {0,-6}: {1}" -f $k, $V.Bios.$k) $(if ($marque -eq '>>') { "WARN" } else { "INFO" })
        }
    }
    Write-Host "  ( >> = point releve par l'analyse, a corriger )" -ForegroundColor DarkGray

    if (-not $isUefi) {
        Log "PC en BIOS legacy : 'redemarrer dans l'UEFI' indisponible. Utiliser $($V.Bios.Enter)" "WARN"
    }
    else {
        Write-Host ""
        if ($todoBios.Count -gt 0) {
            Write-Host "  $($todoBios.Count) reglage(s) BIOS a faire (liste + reperes >> ci-dessus)." -ForegroundColor Yellow
        }
        if (Confirm-ON "  Fermer les applis et REDEMARRER DIRECTEMENT DANS L'UEFI ?") {
            $delai = 15
            Log "Redemarrage dans l'UEFI dans $delai s. Annulation possible : ouvrir un invite admin et taper  shutdown /a" "WARN"
            shutdown.exe /r /fw /t $delai /c "Allo Valentin : redemarrage dans le BIOS/UEFI"
            Pause-Entree "Redemarrage programme ($delai s). 'shutdown /a' pour annuler."
            exit
        } else {
            Log "Reboot UEFI non demande. Plus tard (admin) : shutdown /r /fw /t 0" "INFO"
        }
    }
}

if ($Mode -eq 'Bios') { Pause-Entree "Journal : $LogFile"; exit }

# ============================================================
#  PHASE 4 - Appli de reglage   (Auto + App)
# ============================================================
Write-Host ""
Log "=== APPLI DE REGLAGE ===" "TITRE"
if ($V.Note) { Log $V.Note "INFO" }
$deja = Test-VendorInstalled $V
if ($deja) {
    Log ("{0} est DEJA installee - on n'y touchera pas." -f $V.AppName) "WARN"
    @(Get-InstalledEntries -Like $V.DetectLike) | ForEach-Object { Log ("  - {0} {1}" -f $_.DisplayName, $_.DisplayVersion) }
}

$question = if ($estMonte) {
    "  Installer $($V.AppName) pour regler la courbe ventilo / RGB sous Windows ?"
} else {
    "  Installer / ouvrir $($V.AppName) pour regler le mode thermique ?"
}
if ($deja -or (Confirm-ON $question)) {
    Invoke-VendorApp -V $V -Deja $deja
} else {
    Log "Phase appli ignoree." "INFO"
    if ($estMonte) { Log "Rappel : sur PC monte, la courbe ventilo se fait tres bien directement au BIOS (Smart Fan / Q-Fan / FAN-Tastic)." "INFO" }
}

Pause-Entree "Journal : $LogFile"
