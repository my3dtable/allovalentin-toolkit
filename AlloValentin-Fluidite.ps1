<#
.SYNOPSIS
    Allo Valentin - Analyse de fluidite / FPS (lecture seule)
.DESCRIPTION
    Cherche les CAUSES REELLES de perte de FPS et de micro-freezes, qui sont
    presque toujours des erreurs de configuration, pas des valeurs de registre.

    CE SCRIPT N'ECRIT RIEN. Aucune cle modifiee, aucun service touche, aucun
    fichier supprime. Il ne peut donc rien casser. Il constate et il explique.

    Passage rapide (moins de 15 secondes), concu pour etre lance en debut
    d'intervention chez un client, avant meme le diagnostic complet.

.NOTES
    A executer en Administrateur (auto-elevation incluse). PowerShell 5.1.
#>

param(
    [switch]$SansRapport   # console seulement, pas de HTML
)

# --- Auto-elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement en mode Administrateur..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($SansRapport) { $argList += " -SansRapport" }
    try { Start-Process powershell.exe -ArgumentList $argList -Verb RunAs }
    catch { Write-Host "Elevation refusee. Le script a besoin des droits admin." -ForegroundColor Red }
    exit
}

$AppDir    = "$env:ProgramData\AlloValentin"
$ReportDir = "$AppDir\Reports"
$LogDir    = "$AppDir\Logs"
New-Item -ItemType Directory -Path $ReportDir, $LogDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$LogDir\Fluidite-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
}
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }

Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - Analyse de fluidite / FPS" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
Write-Host "  Lecture seule : ce script ne modifie rien." -ForegroundColor DarkGray
Write-Host ""

$constats = New-Object System.Collections.ArrayList
function Add-Constat {
    param(
        [int]$Priorite,          # 1 = gros gain, 2 = gain net, 3 = marginal / info
        [string]$Titre,
        [string]$Constat,
        [string]$Action,
        [string]$Gain = "moyen"  # eleve | moyen | faible | aucun
    )
    $null = $constats.Add([pscustomobject]@{
        Priorite = $Priorite; Titre = $Titre; Constat = $Constat; Action = $Action; Gain = $Gain
    })
}

# ============================================================
#  CONTEXTE MACHINE (sert de garde-fou aux tests suivants)
# ============================================================
Write-Host "  Analyse en cours..." -ForegroundColor Cyan

$estPortable = $false
try {
    $chassis = (Get-CimInstance Win32_SystemEnclosure -EA SilentlyContinue).ChassisTypes
    # 8-14, 18, 21, 30-32 : portables, tablettes, convertibles
    foreach ($c in $chassis) { if ($c -in @(8,9,10,11,12,13,14,18,21,30,31,32)) { $estPortable = $true } }
} catch {}
Write-Log "Type de machine : $(if($estPortable){'portable'}else{'poste fixe'})"

# Cartes graphiques : on separe dediees et integrees
$cartes = @(Get-CimInstance Win32_VideoController -EA SilentlyContinue |
            Where-Object { $_.Name -notmatch "Parsec|Virtual Display|Remote Display|DisplayLink|Meta |Citrix" })
function Test-CarteIntegree {
    param($c)
    return ($c.Name -match "UHD Graphics|HD Graphics|Iris|Vega \d+ Graphics|Radeon\(TM\) Graphics|AMD Radeon Graphics|Arc.*1[0-9]0[TV]")
}
$dediees   = @($cartes | Where-Object { -not (Test-CarteIntegree $_) -and $_.Name -match "NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc A\d" })
$actives   = @($cartes | Where-Object { $_.CurrentHorizontalResolution -gt 0 })

# ============================================================
#  1. TAUX DE RAFRAICHISSEMENT DE L'ECRAN
# ============================================================
# Le gain de fluidite le plus important et le plus souvent rate.
$maxSupporte = 0
try {
    $modes = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -EA Stop
    foreach ($m in $modes) {
        foreach ($d in $m.MonitorSourceModes) {
            $den = [math]::Max($d.VerticalRefreshRateDenominator, 1)
            $hz  = [math]::Round($d.VerticalRefreshRateNumerator / $den, 0)
            if ($hz -gt $maxSupporte) { $maxSupporte = $hz }
        }
    }
} catch { Write-Log "Modes ecran illisibles : $($_.Exception.Message)" "WARN" }

$hzActuel = 0
foreach ($a in $actives) {
    if ($a.CurrentRefreshRate -gt $hzActuel) { $hzActuel = $a.CurrentRefreshRate }
    if ($a.MaxRefreshRate -gt $maxSupporte)  { $maxSupporte = $a.MaxRefreshRate }
}

if ($hzActuel -gt 0 -and $maxSupporte -gt 0) {
    if ($maxSupporte - $hzActuel -ge 10) {
        Add-Constat 1 "Ecran bride a $hzActuel Hz alors qu'il supporte $maxSupporte Hz" `
            "L'ecran affiche $hzActuel images par seconde alors qu'il peut en afficher $maxSupporte. Meme si le jeu calcule 200 FPS, seuls $hzActuel sont visibles. C'est de tres loin la plus grosse perte de fluidite possible, et elle est invisible dans les jeux." `
            "Parametres Windows > Systeme > Affichage > Parametres avances > choisir $maxSupporte Hz. Verifier aussi le cable : un HDMI ancien peut brider le taux, le DisplayPort ne pose pas ce probleme." `
            "eleve"
    } else {
        Add-Constat 3 "Taux de rafraichissement correct ($hzActuel Hz)" `
            "L'ecran tourne bien a sa frequence maximale de $maxSupporte Hz." "Rien a faire." "aucun"
    }
} else {
    Add-Constat 3 "Taux de rafraichissement non mesurable" `
        "Windows n'a pas remonte la frequence de l'ecran." "A verifier a la main dans les parametres d'affichage." "aucun"
}

# ============================================================
#  2. ECRAN BRANCHE SUR LA CARTE MERE AU LIEU DU GPU
# ============================================================
# Uniquement sur poste fixe : sur portable, l'affichage hybride est normal.
if (-not $estPortable -and $dediees.Count -gt 0) {
    $afficheurIntegre = @($actives | Where-Object { Test-CarteIntegree $_ })
    $afficheurDedie   = @($actives | Where-Object { -not (Test-CarteIntegree $_) })
    if ($afficheurIntegre.Count -gt 0 -and $afficheurDedie.Count -eq 0) {
        Add-Constat 1 "Ecran branche sur la carte mere, pas sur la carte graphique" `
            "L'affichage passe par le circuit graphique du processeur ($($afficheurIntegre[0].Name)) alors que la machine possede une carte dediee ($($dediees[0].Name)), qui ne sert donc a rien. Les FPS peuvent etre divises par 3 ou 4." `
            "Debrancher le cable ecran de la carte mere et le rebrancher sur les sorties de la carte graphique, en bas du boitier. Redemarrer." `
            "eleve"
    }
}

# ============================================================
#  3. OU SONT LES JEUX, ET SUR QUEL TYPE DE DISQUE
# ============================================================
# Mappe lettre de lecteur -> disque physique -> type de support (SSD / HDD).
# On passe par les associateurs WMI Win32_LogicalDisk -> Win32_DiskPartition ->
# Win32_DiskDrive : contrairement a Get-Partition, ils remontent aussi les disques
# DYNAMIQUES ("Logical Disk Manager"). Sans ca, une bibliotheque de jeux posee sur
# un HDD dynamique passait inapercue (detection "jeux sur disque mecanique" ratee).
# L'ancienne methode (Get-Partition) reste en filet de secours.
$typeParLettre = @{}
try {
    $mediaParIndex = @{}
    foreach ($pd in (Get-PhysicalDisk -EA SilentlyContinue)) {
        $mediaParIndex["$($pd.DeviceId)"] = "$($pd.MediaType)"
    }
    foreach ($ld in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue)) {
        foreach ($p in (Get-CimInstance -Query "ASSOCIATORS OF {Win32_LogicalDisk.DeviceID='$($ld.DeviceID)'} WHERE ResultClass=Win32_DiskPartition" -EA SilentlyContinue)) {
            foreach ($dd in (Get-CimInstance -Query "ASSOCIATORS OF {Win32_DiskPartition.DeviceID='$($p.DeviceID)'} WHERE ResultClass=Win32_DiskDrive" -EA SilentlyContinue)) {
                $mt = $mediaParIndex["$($dd.Index)"]
                if ($mt) { $typeParLettre["$($ld.DeviceID)"] = $mt }
            }
        }
    }
    foreach ($disque in (Get-PhysicalDisk -EA SilentlyContinue)) {
        foreach ($part in (Get-Partition -DiskNumber $disque.DeviceId -EA SilentlyContinue)) {
            if ($part.DriveLetter -and -not $typeParLettre["$($part.DriveLetter):"]) {
                $typeParLettre["$($part.DriveLetter):"] = "$($disque.MediaType)"
            }
        }
    }
} catch { Write-Log "Mappage disques : $_" "WARN" }

# Bibliotheques de jeux : Steam (chemin reel + toutes les bibliotheques du .vdf),
# Epic, GOG, Ubisoft, plus les dossiers Games/Jeux/XboxGames a la racine des disques.
$bibliotheques = New-Object System.Collections.ArrayList
function Add-Biblio {
    param($p)
    if ([string]::IsNullOrWhiteSpace($p)) { return }
    $p = "$p".Trim()
    try { if ((Test-Path $p) -and ($bibliotheques -notcontains $p)) { $null = $bibliotheques.Add($p) } } catch {}
}
$steamBases = @(
    (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -Name SteamPath -EA SilentlyContinue).SteamPath,
    (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -Name InstallPath -EA SilentlyContinue).InstallPath,
    "${env:ProgramFiles(x86)}\Steam", "${env:ProgramFiles}\Steam"
)
foreach ($sb in ($steamBases | Where-Object { $_ } | Select-Object -Unique)) {
    $vdf = Join-Path $sb 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in (Select-String -Path $vdf -Pattern '"path"\s+"([^"]+)"' -AllMatches).Matches) {
            Add-Biblio ($m.Groups[1].Value -replace '\\\\', '\')
        }
    }
}
$epicDat = "$env:ProgramData\Epic\UnrealEngineLauncher\LauncherInstalled.dat"
if (Test-Path $epicDat) {
    try { (Get-Content $epicDat -Raw | ConvertFrom-Json).InstallationList | ForEach-Object { Add-Biblio $_.InstallLocation } } catch {}
}
Add-Biblio "${env:ProgramFiles}\Epic Games"
Add-Biblio "${env:ProgramFiles(x86)}\Epic Games"
foreach ($gk in (Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games' -EA SilentlyContinue)) {
    Add-Biblio (Get-ItemProperty $gk.PSPath -Name path -EA SilentlyContinue).path
}
foreach ($uk in (Get-ChildItem 'HKLM:\SOFTWARE\WOW6432Node\Ubisoft\Launcher\Installs' -EA SilentlyContinue)) {
    Add-Biblio (Get-ItemProperty $uk.PSPath -Name InstallDir -EA SilentlyContinue).InstallDir
}
foreach ($d in (Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -EA SilentlyContinue)) {
    foreach ($sub in @('XboxGames', 'Games', 'Jeux', 'SteamLibrary')) {
        Add-Biblio (Join-Path "$($d.DeviceID)\" $sub)
    }
}
foreach ($ea in @("${env:ProgramFiles}\EA Games", "${env:ProgramFiles(x86)}\Origin Games", "${env:ProgramFiles(x86)}\EA Games")) {
    Add-Biblio $ea
}

$surHDD = New-Object System.Collections.ArrayList
foreach ($b in ($bibliotheques | Select-Object -Unique)) {
    $lettre = ($b -split ':')[0] + ":"
    $type = $typeParLettre[$lettre]
    if ($type -eq "HDD") { $null = $surHDD.Add("$b (disque $lettre)") }
}
if ($surHDD.Count -gt 0) {
    Add-Constat 1 "Jeux installes sur un disque dur mecanique" `
        "Ces bibliotheques sont sur un disque a plateaux : $($surHDD -join ' ; '). Un HDD lit environ 100 Mo/s contre 500 a 3000 pour un SSD. Cela ne change pas les FPS bruts mais provoque les micro-freezes quand le jeu charge des textures, plus des temps de chargement tres longs." `
        "Deplacer les jeux vers le SSD. Steam le fait sans reinstaller : clic droit sur le jeu > Proprietes > Fichiers locaux > Deplacer le dossier d'installation." `
        "eleve"
}

# ============================================================
#  4. ESPACE LIBRE SUR LES DISQUES QUI PORTENT LES JEUX
# ============================================================
# Un SSD presque plein perd en performance d'ecriture et le cache de shaders
# n'a plus de place : c'est une cause directe de stutter.
$lettresAControler = New-Object System.Collections.ArrayList
$null = $lettresAControler.Add($env:SystemDrive)
foreach ($b in ($bibliotheques | Select-Object -Unique)) {
    $l = ($b -split ':')[0] + ":"
    if ($lettresAControler -notcontains $l) { $null = $lettresAControler.Add($l) }
}
foreach ($l in $lettresAControler) {
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$l'" -EA SilentlyContinue
    if (-not $vol -or $vol.Size -eq 0) { continue }
    $pct   = [math]::Round(($vol.FreeSpace / $vol.Size) * 100, 1)
    $libGo = [math]::Round($vol.FreeSpace / 1GB, 1)
    $porteJeux = @($bibliotheques | Where-Object { $_ -like "$l*" }).Count -gt 0
    $mention = $(if ($porteJeux) { " Ce disque porte des jeux." } else { "" })
    if ($pct -lt 10) {
        Add-Constat 1 "Disque $l sature ($pct % libres, $libGo Go)" `
            "Sous 10 % d'espace libre, un SSD perd nettement en vitesse d'ecriture et Windows n'a plus de place pour le fichier d'echange ni pour le cache de shaders.$mention C'est une cause frequente de micro-freezes en jeu." `
            "Liberer de la place : desinstaller ce qui ne sert plus, vider les caches de shaders, deplacer une bibliotheque de jeux. Viser au moins 15 % libres." `
            "eleve"
    } elseif ($pct -lt 15) {
        Add-Constat 2 "Disque $l peu d'espace libre ($pct % libres, $libGo Go)" `
            "L'espace libre passe sous le seuil confortable de 15 %.$mention Les performances d'ecriture commencent a se degrader." `
            "Faire un peu de menage pour repasser au-dessus de 15 %." `
            "moyen"
    }
}

# ============================================================
#  5. PLAN D'ALIMENTATION ET BRIDAGE PORTABLE
# ============================================================
$schemas = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
$actif = (Get-ItemProperty $schemas -Name ActivePowerScheme -EA SilentlyContinue).ActivePowerScheme
$noms = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Utilisation normale (Equilibre)'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'Performances elevees'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Economies d energie'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Performances ultimes'
}
if ($actif -eq 'a1841308-3541-4fab-bc81-f71556f20b4a') {
    Add-Constat 1 "Mode Economies d energie actif" `
        "Le processeur est volontairement bride pour consommer moins. En jeu, la perte est massive." `
        "Basculer sur Utilisation normale ou Performances elevees." "eleve"
} elseif ($actif -eq '381b4222-f694-41f0-9685-ff5bb260df2e') {
    Add-Constat 3 "Plan d'alimentation : Utilisation normale" `
        "Plan equilibre. Correct au quotidien ; le mode Performances elevees peut aider un peu sur les 1% low." `
        "Optionnel : passer en Performances elevees pendant les sessions de jeu." "faible"
}

if ($estPortable) {
    try {
        $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
        # BatteryStatus 1 = sur batterie, 2 = sur secteur
        if ($bat -and $bat.BatteryStatus -eq 1) {
            Add-Constat 1 "Portable en fonctionnement sur batterie" `
                "Sur batterie, le processeur et la carte graphique sont fortement brides par le constructeur. Les FPS peuvent etre divises par deux ou plus, quel que soit le reglage Windows." `
                "Brancher le chargeur pour jouer. C'est le premier reflexe avant tout autre reglage." "eleve"
        }
    } catch {}
}

# ============================================================
#  6. PILOTE GRAPHIQUE
# ============================================================
# Get-WmiObject rend une chaine DMTF, Get-CimInstance rend deja un [datetime].
# Les deux doivent etre acceptes, sinon la date du pilote est systematiquement perdue.
function ConvertTo-SafeDate {
    param($Valeur)
    if ($null -eq $Valeur) { return $null }
    if ($Valeur -is [datetime]) { return $Valeur }
    if ([string]::IsNullOrWhiteSpace([string]$Valeur)) { return $null }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Valeur) } catch { return $null }
}
$carteRef = $(if ($dediees.Count -gt 0) { $dediees[0] } elseif ($actives.Count -gt 0) { $actives[0] } else { $null })
if ($carteRef) {
    $dt = ConvertTo-SafeDate $carteRef.DriverDate
    if ($dt) {
        $jours = [int]((Get-Date) - $dt).TotalDays
        if ($jours -gt 365) {
            Add-Constat 1 "Pilote graphique tres ancien ($([math]::Round($jours/30)) mois)" `
                "Le pilote de $($carteRef.Name) date du $($dt.ToString('dd/MM/yyyy')). Les jeux recents sont optimises pilote par pilote : un pilote d'un an peut couter 10 a 20 % de FPS sur les titres sortis depuis." `
                "Installer le dernier pilote depuis le site du fabricant. Sur changement de marque de carte, passer par une desinstallation propre." "eleve"
        } elseif ($jours -gt 180) {
            Add-Constat 2 "Pilote graphique ancien ($([math]::Round($jours/30)) mois)" `
                "Pilote de $($carteRef.Name) du $($dt.ToString('dd/MM/yyyy'))." `
                "Une mise a jour est conseillee, surtout pour les jeux sortis recemment." "moyen"
        } else {
            Add-Constat 3 "Pilote graphique a jour" `
                "$($carteRef.Name), pilote du $($dt.ToString('dd/MM/yyyy'))." "Rien a faire." "aucun"
        }
    }
}

# ============================================================
#  7. CHARGE DE FOND
# ============================================================
$nbDem = 0
foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
                 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
                 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run')) {
    if (Test-Path $k) {
        $p = Get-ItemProperty $k -EA SilentlyContinue
        if ($p) { $nbDem += @($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count }
    }
}
foreach ($f in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                 "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")) {
    if (Test-Path $f) { $nbDem += @(Get-ChildItem $f -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count }
}
if ($nbDem -ge 12) {
    Add-Constat 2 "$nbDem programmes se lancent au demarrage" `
        "Chacun consomme de la memoire et du processeur en permanence. L'effet se voit surtout sur les 1% low, ces chutes breves qui donnent la sensation de saccade meme avec une moyenne de FPS elevee." `
        "Passer la liste en revue dans le Gestionnaire des taches, onglet Demarrage, et desactiver ce qui n'est pas indispensable. Reversible a tout moment." "moyen"
}

# Les gros consommateurs actuels, a titre indicatif
$gros = @(Get-Process -EA SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 |
          ForEach-Object { "$($_.ProcessName) ($([math]::Round($_.WorkingSet64/1MB)) Mo)" })
if ($gros.Count) {
    Add-Constat 3 "Plus gros consommateurs de memoire en ce moment" `
        ($gros -join " ; ") "A titre indicatif : fermer les plus lourds avant de jouer." "faible"
}

# ============================================================
#  8. RAM : CANAL REEL (single channel deguise en dual)
# ============================================================
# Compter les barrettes ne suffit pas : deux barrettes dans A1 et A2 sont sur
# le meme canal. C'est l'erreur de montage la plus frequente apres un ajout.
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
$barrettes = @(Get-CimInstance Win32_PhysicalMemory -EA SilentlyContinue)
if ($barrettes.Count -ge 2) {
    $canaux = @($barrettes | ForEach-Object { Get-CanalRam $_ } | Where-Object { $_ })
    if ($canaux.Count -eq $barrettes.Count) {
        $nbCanaux = @($canaux | Select-Object -Unique).Count
        if ($nbCanaux -eq 1) {
            Add-Constat 1 "$($barrettes.Count) barrettes de RAM, toutes sur le meme canal" `
                "La machine a $($barrettes.Count) barrettes mais elles occupent toutes le canal $($canaux[0]). Elle tourne donc en single channel : la bande passante memoire est divisee par deux alors que le materiel est deja la." `
                "Deplacer une barrette vers un slot de l'autre canal, en general les slots 2 et 4 en partant du processeur (marques A2 et B2 sur la carte mere). Gain typique de 10 a 20 % de FPS, sans rien acheter." `
                "eleve"
        }
    } else {
        # Carte qui n'etiquette pas les canaux (PC de marque : "DIMM1".."DIMM4").
        # Repli : 2 barrettes d'un kit apparie, slots de parite -> indice fiable.
        $pns  = @($barrettes | ForEach-Object { "$($_.PartNumber)".Trim() } | Where-Object { $_ } | Select-Object -Unique)
        $caps = @($barrettes | ForEach-Object { [long]$_.Capacity } | Select-Object -Unique)
        $slotN = @($barrettes | ForEach-Object { if ("$($_.DeviceLocator)" -match '(\d+)\s*$') { [int]$Matches[1] } })
        if ($barrettes.Count -eq 2 -and $pns.Count -le 1 -and $caps.Count -eq 1 -and $slotN.Count -eq 2 -and ($slotN[0] % 2) -eq ($slotN[1] % 2)) {
            Add-Constat 1 "2 barrettes probablement sur le meme canal (single channel)" `
                "Les 2 barrettes identiques sont dans des slots de meme parite ($($barrettes[0].DeviceLocator) / $($barrettes[1].DeviceLocator)) : sur la plupart des cartes c'est le meme canal, donc single channel et bande passante /2. Cette carte n'etiquette pas les canaux, donc c'est un indice, pas une certitude." `
                "Verifier avec CPU-Z, onglet Memory : si la ligne 'Channel' affiche 'Single', deplacer une barrette d'un cran (souvent vers les slots 2 et 4). Gain typique 10 a 20 % de FPS." `
                "eleve"
        } elseif ($barrettes.Count -eq 2 -and $pns.Count -le 1 -and $caps.Count -eq 1 -and $slotN.Count -eq 2) {
            Add-Constat 3 "Canaux memoire non etiquetes (dual-channel probable)" `
                "$($barrettes.Count) barrettes identiques dans des slots de parite differente : dual-channel tres probable, mais cette carte ne remonte pas le canal." `
                "Pour confirmer : CPU-Z, onglet Memory, ligne 'Channel' (doit afficher 'Dual')." "faible"
        } else {
            Add-Constat 3 "Canaux memoire non lisibles" `
                "$($barrettes.Count) barrettes detectees, mais le BIOS ne remonte pas leur canal." `
                "A verifier avec CPU-Z, onglet Memory, ligne Channel." "faible"
        }
    }
}

# ============================================================
#  9. DEUX ANTIVIRUS EN TEMPS REEL
# ============================================================
# Chaque lecture de fichier est scannee deux fois : saccades garanties.
# Le conseil (retirer le doublon) ameliore aussi la securite, il ne l'affaiblit pas.
try {
    $avs = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -EA Stop)
    $actifs = @($avs | Where-Object {
        $hex = [Convert]::ToString($_.productState, 16).PadLeft(6, '0')
        $hex.Substring(2, 2) -match '^(10|11)$'
    })
    if ($actifs.Count -ge 2) {
        $noms = ($actifs | ForEach-Object { $_.displayName }) -join " + "
        Add-Constat 1 "Deux antivirus tournent en temps reel" `
            "$noms sont actifs simultanement. Chaque fichier lu par un jeu est analyse par les deux moteurs, qui se surveillent parfois l'un l'autre. C'est une cause classique de saccades et de temps de chargement doubles." `
            "Garder un seul antivirus temps reel. Desinstaller le doublon via Panneau de configuration > Programmes. Attention : desinstaller, pas seulement desactiver. La protection reste entiere avec un seul moteur." `
            "eleve"
    }
} catch { Write-Log "Antivirus : $($_.Exception.Message)" "WARN" }

# ============================================================
#  10. FICHIER D'ECHANGE
# ============================================================
try {
    $usages = @(Get-CimInstance Win32_PageFileUsage -EA SilentlyContinue)
    if ($usages.Count -eq 0) {
        Add-Constat 1 "Fichier d'echange desactive" `
            "Windows n'a aucun fichier d'echange. C'est un reglage que l'on croit malin quand on a beaucoup de RAM, mais plusieurs jeux recents reservent de la memoire virtuelle au lancement et plantent ou saccadent sans lui, meme avec 32 Go libres." `
            "Parametres systeme avances > Performances > Avance > Memoire virtuelle : recocher la gestion automatique." `
            "eleve"
    } else {
        foreach ($u in $usages) {
            $lettre = ($u.Name -split ':')[0] + ":"
            if ($typeParLettre[$lettre] -eq "HDD") {
                Add-Constat 1 "Fichier d'echange sur un disque dur mecanique" `
                    "Le fichier d'echange est sur $lettre, un disque a plateaux. Chaque fois que Windows y touche pendant un jeu, la machine se fige brievement." `
                    "Deplacer le fichier d'echange sur le SSD : Parametres systeme avances > Performances > Avance > Memoire virtuelle." `
                    "eleve"
            }
            # Fichier tres surdimensionne par rapport a l'usage reel, sur un disque tendu
            $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$lettre'" -EA SilentlyContinue
            if ($vol -and $vol.Size -gt 0) {
                $pctLibre = ($vol.FreeSpace / $vol.Size) * 100
                if ($u.AllocatedBaseSize -gt 8192 -and $u.PeakUsage -lt ($u.AllocatedBaseSize / 8) -and $pctLibre -lt 20) {
                    $recup = [math]::Round(($u.AllocatedBaseSize - 8192) / 1024, 1)
                    Add-Constat 2 "Fichier d'echange surdimensionne sur un disque tendu" `
                        "Le fichier d'echange occupe $([math]::Round($u.AllocatedBaseSize/1024,1)) Go sur $lettre alors que le pic d'utilisation mesure est de $([math]::Round($u.PeakUsage/1024,2)) Go, alors que le disque n'a que $([math]::Round($pctLibre,1)) % de libre." `
                        "Le fixer manuellement autour de 8 Go libererait environ $recup Go. A faire seulement si l'espace disque est un probleme : garder la gestion automatique reste le choix le plus sur." `
                        "moyen"
                }
            }
        }
    }
} catch { Write-Log "Fichier d'echange : $($_.Exception.Message)" "WARN" }

# ============================================================
#  11. TRIM SUR SSD
# ============================================================
$aUnSSD = $false
try { $aUnSSD = @(Get-PhysicalDisk -EA SilentlyContinue | Where-Object { $_.MediaType -eq "SSD" }).Count -gt 0 } catch {}
if ($aUnSSD) {
    try {
        $sortie = (fsutil behavior query DisableDeleteNotify 2>$null) -join " "
        $m = [regex]::Match($sortie, '(?i)NTFS\s+DisableDeleteNotify\s*=\s*(\d)')
        if (-not $m.Success) { $m = [regex]::Match($sortie, '(?i)DisableDeleteNotify\s*=\s*(\d)') }
        if ($m.Success -and $m.Groups[1].Value -eq '1') {
            Add-Constat 1 "TRIM desactive sur un SSD" `
                "Le TRIM est coupe. Sans lui, le SSD ne sait plus quels blocs sont libres : ses performances d'ecriture s'effondrent progressivement et son usure s'accelere. C'est souvent le residu d'un ancien logiciel d'optimisation." `
                "Reactiver avec la commande : fsutil behavior set DisableDeleteNotify 0" `
                "eleve"
        }
    } catch { Write-Log "TRIM : $($_.Exception.Message)" "WARN" }
}

# ============================================================
#  12. JEU FORCE SUR LE CIRCUIT GRAPHIQUE DU PROCESSEUR
# ============================================================
# Uniquement si la machine a bien une carte dediee ET une integree.
$aIntegre = @($cartes | Where-Object { Test-CarteIntegree $_ }).Count -gt 0
if ($dediees.Count -gt 0 -and $aIntegre) {
    $kPref = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    if (Test-Path $kPref) {
        $p = Get-ItemProperty $kPref -EA SilentlyContinue
        $forcesIgpu = @()
        foreach ($pr in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
            # GpuPreference=1 : economie d'energie = circuit graphique du processeur
            if ([string]$pr.Value -match 'GpuPreference=1') { $forcesIgpu += (Split-Path $pr.Name -Leaf) }
        }
        if ($forcesIgpu.Count -gt 0) {
            Add-Constat 1 "$($forcesIgpu.Count) application(s) forcee(s) sur le circuit graphique du processeur" `
                "Ces programmes sont regles pour utiliser le circuit graphique integre au lieu de la carte dediee : $($forcesIgpu -join ', '). Si un jeu est dans la liste, ses FPS sont divises par trois ou plus." `
                "Parametres > Systeme > Affichage > Graphiques : passer chaque jeu concerne sur Hautes performances." `
                "eleve"
        }
    }
}

# ============================================================
#  13. LIEN PCIe DE LA CARTE GRAPHIQUE (largeur reduite)
# ============================================================
# La LARGEUR (x16 / x8 / x4) ne depend pas de l'etat d'energie : une largeur
# reduite est un vrai probleme (carte mal enfoncee, mauvais slot, lignes partagees
# avec un SSD NVMe). La GENERATION (Gen3/Gen4) chute au repos pour economiser :
# on ne s'en sert donc PAS comme signal.
if ($dediees.Count -gt 0) {
    $curW = $null; $maxW = $null
    if ($dediees[0].Name -match "NVIDIA|GeForce|RTX|GTX") {
        $smi = "$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe"
        if (-not (Test-Path $smi)) { $smi = "nvidia-smi" }
        try {
            $o = (& $smi --query-gpu=pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits 2>$null) -join " "
            if ($o -match '(\d+)\D+(\d+)') { $curW = [int]$Matches[1]; $maxW = [int]$Matches[2] }
        } catch {}
    }
    if (-not $curW) {
        try {
            $gpuPnp = Get-PnpDevice -Class Display -Status OK -EA SilentlyContinue |
                      Where-Object { $_.FriendlyName -match "NVIDIA|GeForce|RTX|GTX|Radeon RX|Arc A" } | Select-Object -First 1
            if ($gpuPnp) {
                $cw = (Get-PnpDeviceProperty -InstanceId $gpuPnp.InstanceId -KeyName 'DEVPKEY_PciDevice_CurrentLinkWidth' -EA SilentlyContinue).Data
                $mw = (Get-PnpDeviceProperty -InstanceId $gpuPnp.InstanceId -KeyName 'DEVPKEY_PciDevice_MaxLinkWidth' -EA SilentlyContinue).Data
                if ($cw) { $curW = [int]$cw }
                if ($mw) { $maxW = [int]$mw }
            }
        } catch { Write-Log "Lien PCIe GPU : $($_.Exception.Message)" "WARN" }
    }
    if ($curW -and $maxW -and $curW -lt $maxW) {
        Add-Constat 1 "Carte graphique en PCIe x$curW au lieu de x$maxW" `
            "La carte $($dediees[0].Name) ne communique que sur $curW lignes PCIe sur les $maxW possibles. Causes frequentes : carte mal enfoncee, branchee dans un slot secondaire (souvent cable en x4), ou lignes partagees avec un SSD M.2. Perte de 5 a 15 % de FPS, davantage en 1440p et 4K." `
            "Verifier que la carte est dans le premier slot PCIe x16 (le plus proche du processeur) et bien clipsee. Consulter le manuel de la carte mere pour le partage de lignes entre ce slot et les ports M.2." `
            "eleve"
    }
}

# ============================================================
#  14. RAM EN DESSOUS DE SA VITESSE NOTEE (XMP / EXPO non active)
# ============================================================
if ($barrettes.Count -ge 1) {
    try {
        $ddr = switch ([int]$barrettes[0].SMBIOSMemoryType) { 26 { "DDR4" } 34 { "DDR5" } 24 { "DDR3" } default { "DDR" } }
        $reelle = ($barrettes | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } |
                   Where-Object { $_ } | Measure-Object -Minimum).Minimum
        $noteeParPN = 0
        foreach ($b in $barrettes) {
            $m = [regex]::Match("$($b.PartNumber)".Trim(), '(?<![0-9])([2-8][0-9]{3})(?![0-9])')
            if ($m.Success) {
                $v = [int]$m.Groups[1].Value
                if ($v -ge 2133 -and $v -le 8400 -and $v -gt $noteeParPN) { $noteeParPN = $v }
            }
        }
        if ($reelle -and $noteeParPN -and ($noteeParPN - $reelle) -ge 200) {
            $profil = if ($ddr -eq "DDR5") { "EXPO / XMP" } else { "XMP" }
            Add-Constat 1 "RAM a $reelle MHz alors qu'elle est notee $noteeParPN MHz" `
                "Les barrettes ($($barrettes[0].PartNumber)) sont concues pour $noteeParPN MHz mais tournent a $reelle MHz : le profil $profil n'est pas active dans le BIOS. La bande passante memoire pese lourd sur les 1% low et les jeux gourmands en processeur ; c'est du gain deja paye qui dort." `
                "Activer le profil $profil dans le BIOS (menu deroulant 'X.M.P.', 'EXPO' ou 'DOCP'). L'outil Carte mere / BIOS du menu principal detaille le chemin exact selon la marque de la carte." `
                "eleve"
        }
    } catch { Write-Log "Vitesse RAM : $($_.Exception.Message)" "WARN" }
}

# ============================================================
#  15. MINUTERIES DE BOOT FORCEES (residu de "tweak" nuisible)
# ============================================================
try {
    $bcd = (& bcdedit /enum '{current}' 2>$null) -join "`n"
    $mauvais = @()
    if ($bcd -match '(?im)^\s*useplatformclock\s+Yes')  { $mauvais += "useplatformclock (force le timer HPET, ajoute de la latence sur les systemes recents)" }
    if ($bcd -match '(?im)^\s*disabledynamictick\s+Yes') { $mauvais += "disabledynamictick (empeche le processeur de descendre en veille : gain nul, chauffe en plus)" }
    if ($bcd -match '(?im)^\s*useplatformtick\s+Yes')    { $mauvais += "useplatformtick" }
    if ($bcd -match '(?im)^\s*tscsyncpolicy\s+\S')       { $mauvais += "tscsyncpolicy (synchro d'horloge non standard)" }
    if ($mauvais.Count -gt 0) {
        Add-Constat 2 "Minuteries systeme modifiees par un ancien tweak" `
            "Le demarrage de Windows contient des reglages ajoutes a la main, presentes comme des optimisations sur les forums mais qui, sur Windows 10/11 recent, ne font rien gagner et peuvent ajouter de la latence ou empecher la mise en veille du processeur : $($mauvais -join ' ; ')." `
            "Les retirer remet Windows dans sa configuration d'origine : bcdedit /deletevalue useplatformclock (et de meme pour chaque autre entree citee). Redemarrer ensuite." `
            "moyen"
    }
} catch { Write-Log "bcdedit : $($_.Exception.Message)" "WARN" }

# ============================================================
#  16. PLANIFICATION GPU MATERIELLE (HAGS) ET MODE JEU
# ============================================================
try {
    $hw = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name HwSchMode -EA SilentlyContinue).HwSchMode
    $piloteRecent = $false
    if ($carteRef) {
        $dtx = ConvertTo-SafeDate $carteRef.DriverDate
        if ($dtx -and ((Get-Date) - $dtx).TotalDays -lt 730) { $piloteRecent = $true }
    }
    if ($dediees.Count -gt 0 -and $piloteRecent -and $hw -ne $null -and $hw -ne 2) {
        Add-Constat 3 "Planification GPU materielle (HAGS) desactivee" `
            "La planification du processeur graphique a acceleration materielle est coupee. Sur une carte recente avec un pilote a jour, l'activer reduit un peu la latence d'affichage et conditionne certaines options (NVIDIA Reflex, fenetre optimisee, Auto HDR)." `
            "Parametres > Systeme > Affichage > Graphismes > Modifier les parametres graphiques par defaut : activer la planification GPU a acceleration materielle. Redemarrer. A repasser sur off si une instabilite apparait." `
            "faible"
    }
} catch {}
try {
    $gm = Get-ItemProperty 'HKCU:\Software\Microsoft\GameBar' -EA SilentlyContinue
    if ($gm -and (($null -ne $gm.AutoGameModeEnabled -and $gm.AutoGameModeEnabled -eq 0) -or
                  ($null -ne $gm.AllowAutoGameMode -and $gm.AllowAutoGameMode -eq 0))) {
        Add-Constat 3 "Mode Jeu de Windows desactive" `
            "Le Mode Jeu est coupe. Il retarde Windows Update et certaines taches de fond pendant une partie et stabilise un peu les 1% low. Effet modere, aucun inconvenient connu." `
            "Parametres > Jeux > Mode Jeu : activer." `
            "faible"
    }
} catch {}

# ============================================================
#  17. CONNECTIQUE DE L'ECRAN (HDMI / DVI sur ecran haute frequence)
# ============================================================
# Test PAR ECRAN : on compare le type de prise a la frequence max de CET ecran
# precis, pas au max global (sinon un ecran secondaire 60 Hz en HDMI fait un
# faux positif quand le principal 360 Hz est deja en DisplayPort).
if (-not $estPortable) {
    try {
        $conn  = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -EA Stop)
        $modes = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -EA SilentlyContinue)
        foreach ($cn in $conn) {
            # VideoOutputTechnology : 0 VGA, 4 DVI, 5 HDMI, 10 DisplayPort externe, 11 DP embarque
            $vot = [int]$cn.VideoOutputTechnology
            if ($vot -notin @(0, 4, 5)) { continue }
            $hzMon = 0
            foreach ($md in ($modes | Where-Object { $_.InstanceName -eq $cn.InstanceName })) {
                foreach ($d in $md.MonitorSourceModes) {
                    $den = [math]::Max($d.VerticalRefreshRateDenominator, 1)
                    $hz  = [math]::Round($d.VerticalRefreshRateNumerator / $den, 0)
                    if ($hz -gt $hzMon) { $hzMon = $hz }
                }
            }
            if ($hzMon -lt 100) { continue }
            $type  = switch ($vot) { 0 { "VGA" } 4 { "DVI" } 5 { "HDMI" } }
            $grave = ($vot -in @(0, 4))
            Add-Constat $(if ($grave) { 1 } else { 2 }) "Ecran $hzMon Hz branche en $type" `
                "Un ecran capable de $hzMon Hz est connecte en $type. Le VGA et le DVI plafonnent a 60 Hz en haute resolution ; en HDMI, il faut une prise et un cable HDMI 2.1 recents pour tenir $hzMon Hz, sinon la frequence ou la resolution sont bridees. Le DisplayPort tient $hzMon Hz sans condition." `
                "Si la carte graphique et l'ecran ont chacun une prise DisplayPort libre, y brancher l'ecran avec un cable DisplayPort. En HDMI, verifier dans Parametres > Affichage > Parametres avances que $hzMon Hz est bien selectionne." `
                $(if ($grave) { "eleve" } else { "moyen" })
            break
        }
    } catch { Write-Log "Connectique ecran : $($_.Exception.Message)" "WARN" }
}

# ============================================================
#  18. OVERLAYS ET LOGICIELS DE FOND CONNUS EN COURS
# ============================================================
$overlays = @(
    @{ M = 'RTSS';           L = 'RivaTuner Statistics Server' }
    @{ M = 'MSIAfterburner'; L = 'MSI Afterburner' }
    @{ M = 'NVIDIA Share';   L = 'Superposition NVIDIA (GeForce Experience / NVIDIA App)' }
    @{ M = 'iCUE';           L = 'Corsair iCUE (RGB)' }
    @{ M = 'LGHUB';          L = 'Logitech G HUB' }
    @{ M = 'RzSynapse';      L = 'Razer Synapse' }
    @{ M = 'SteelSeriesGG';  L = 'SteelSeries GG' }
    @{ M = 'OpenRGB';        L = 'OpenRGB' }
    @{ M = 'SignalRgb';      L = 'SignalRGB' }
    @{ M = 'wallpaper32';    L = 'Wallpaper Engine (fond anime)' }
    @{ M = 'wallpaper64';    L = 'Wallpaper Engine (fond anime)' }
    @{ M = 'obs64';          L = 'OBS Studio (capture)' }
    @{ M = 'obs32';          L = 'OBS Studio (capture)' }
    @{ M = 'Discord';        L = 'Discord (overlay in-game)' }
    @{ M = 'Overwolf';       L = 'Overwolf (overlays CurseForge / autres)' }
)
$procNoms = @(Get-Process -EA SilentlyContinue | Select-Object -ExpandProperty ProcessName -Unique)
$ovTrouves = @($overlays | Where-Object { $procNoms -contains $_.M } | ForEach-Object { $_.L } | Select-Object -Unique)
if ($ovTrouves.Count -ge 3) {
    Add-Constat 2 "$($ovTrouves.Count) logiciels de fond / overlays actifs" `
        "En cours d'execution : $($ovTrouves -join ' ; '). Les overlays s'injectent dans le rendu des jeux (Direct3D) et sont une cause reconnue de micro-freezes et de baisse des 1% low, surtout quand plusieurs se cumulent. Les logiciels RGB et de fond anime consomment en continu." `
        "Fermer ceux qui ne servent pas avant de jouer, ou couper leur overlay dans leurs reglages. Wallpaper Engine a une option de pause automatique quand une application est en plein ecran." `
        "moyen"
}

# ============================================================
#  19. MULTI-PLANE OVERLAY (piste conditionnelle : scintillement / stutter)
# ============================================================
try {
    $otm = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' -Name OverlayTestMode -EA SilentlyContinue).OverlayTestMode
    if ($dediees.Count -gt 0 -and $otm -ne 5) {
        Add-Constat 3 "Multi-Plane Overlay actif (configuration normale)" `
            "Le MPO est actif, c'est le reglage standard de Windows. Sur certaines combinaisons carte NVIDIA + pilote + jeu en mode fenetre, il provoque un scintillement noir ou des micro-freezes. Ce n'est un probleme QUE si ce symptome est constate." `
            "Uniquement en cas de scintillement ou de stutter en jeu fenetre : le desactiver est un correctif reconnu de Microsoft et NVIDIA (valeur DWORD OverlayTestMode = 5 sous HKLM\SOFTWARE\Microsoft\Windows\Dwm, puis redemarrage). Ne rien faire sinon." `
            "faible"
    }
} catch {}

# ============================================================
#  20. DOSSIERS DE JEUX INDEXES PAR WINDOWS SEARCH
# ============================================================
# Si l'index de recherche parcourt une bibliotheque de jeux, chaque ecriture du jeu
# (cache de shaders, sauvegardes, mises a jour) relance une reindexation en fond :
# acces disque + CPU au pire moment. On interroge l'index reel via ADODB.
try {
    if (@($bibliotheques).Count -gt 0 -and (Get-Service WSearch -EA SilentlyContinue).Status -eq 'Running') {
        $indexes = New-Object System.Collections.ArrayList
        $cn = New-Object -ComObject ADODB.Connection
        $cn.Open("Provider=Search.CollatorDSO;Extended Properties='Application=Windows'")
        foreach ($b in ($bibliotheques | Select-Object -Unique)) {
            $safe = ($b -replace "'", "''")
            try {
                $rs = $cn.Execute("SELECT TOP 1 System.ItemUrl FROM SystemIndex WHERE SCOPE='file:$safe'")
                if (-not $rs.EOF) { $null = $indexes.Add($b) }
                $rs.Close()
            } catch {}
        }
        $cn.Close()
        if ($indexes.Count -gt 0) {
            Add-Constat 2 "Windows Search indexe $($indexes.Count) dossier(s) de jeux" `
                "L'index de recherche parcourt : $($indexes -join ' ; '). Chaque fois qu'un jeu ecrit des fichiers (shaders, sauvegardes, mises a jour), Windows relance une indexation en tache de fond - acces disque et CPU pendant que tu joues." `
                "Clic droit sur le dossier > Proprietes > bouton 'Avance' > decocher 'Autoriser l'indexation du contenu des fichiers de ce dossier' > appliquer au dossier, aux sous-dossiers et aux fichiers." `
                "moyen"
        }
    }
} catch { Write-Log "Index Search : $($_.Exception.Message)" "WARN" }

# ============================================================
#  21. DEMARRAGE RAPIDE (Fast Startup / hiberboot)
# ============================================================
# Le "demarrage rapide" ne recharge pas completement le noyau et les pilotes :
# c'est une cause classique de comportements bizarres qui ne partent qu'apres un
# VRAI redemarrage, et il masque le vrai temps de boot.
try {
    $hb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -EA SilentlyContinue).HiberbootEnabled
    if ($hb -eq 1) {
        Add-Constat 3 "Demarrage rapide (Fast Startup) actif" `
            "A l'arret, Windows ne ferme pas vraiment la session : il hiberne le noyau. Consequence : les pilotes et le noyau ne sont jamais rafraichis par un simple Arret, ce qui accumule des petits bugs (peripheriques, reseau, GPU) qui ne partent qu'avec 'Redemarrer'. Sur poste fixe le gain de temps est minime." `
            "Optionnel : Panneau de configuration > Options d'alimentation > 'Choisir l'action des boutons' > decocher 'Activer le demarrage rapide'. Sinon, prendre l'habitude de faire 'Redemarrer' et pas 'Arreter'." `
            "faible"
    }
} catch {}

# ============================================================
#  22. CARTE RESEAU : ECONOMIE D'ENERGIE / EEE (micro-lag)
# ============================================================
# "Autoriser l'ordinateur a eteindre ce peripherique" + Energy Efficient Ethernet :
# la carte s'endort pendant les micro-pauses, le reveil ajoute de la latence.
try {
    $adaptActifs = Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq 'Up' -and $_.MediaType -notmatch 'Wireless|802.11' }
    foreach ($ad in $adaptActifs) {
        $souci = @()
        $pm = Get-NetAdapterPowerManagement -Name $ad.Name -EA SilentlyContinue
        if ($pm -and "$($pm.AllowComputerToTurnOffDevice)" -match 'Enabled') { $souci += "'autoriser l'ordinateur a eteindre ce peripherique' est coche" }
        $eco = Get-NetAdapterAdvancedProperty -Name $ad.Name -EA SilentlyContinue | Where-Object {
            $_.DisplayName -match '(?i)energ|nergie|efficient|efficien|green ethernet|econom|.conomie d|risparmio|ahorro|power sav|ultra low power|\bEEE\b|idle power|veille|niedrig.*energ' -and
            $_.DisplayValue -notmatch '(?i)d.sactiv|disabl|deaktiv|desactiv|\boff\b|\bnon\b|maximum performance|no power|nessun'
        }
        foreach ($p in $eco) { $souci += "$($p.DisplayName) = $($p.DisplayValue)" }
        if ($souci.Count -gt 0) {
            Add-Constat 2 "Carte reseau '$($ad.InterfaceDescription)' : economie d'energie active" `
                "$($souci -join ' ; '). La carte passe en veille pendant les micro-pauses de trafic ; le reveil ajoute de la latence et provoque des pics de ping / micro-coupures en jeu en ligne. Aucun interet sur un poste fixe branche au secteur." `
                "Gestionnaire de peripheriques > la carte reseau > Proprietes. Onglet 'Gestion de l'alimentation' : decocher 'Autoriser l'ordinateur a eteindre ce peripherique'. Onglet 'Avance' : passer sur Desactive tout ce qui parle d'economie d'energie / Green / EEE / Power Saving." `
                "moyen"
        }
    }
} catch { Write-Log "Carte reseau energie : $($_.Exception.Message)" "WARN" }

# ============================================================
#  23. FICHIER D'HIBERNATION SUR UN DISQUE SYSTEME TENDU
# ============================================================
# hiberfil.sys = ~40 a 75 % de la RAM. Sur un C: presque plein, le supprimer
# (powercfg /h off) libere plusieurs Go tout de suite.
try {
    $sysDrive = $env:SystemDrive
    $hiber = Join-Path "$sysDrive\" 'hiberfil.sys'
    $volSys = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sysDrive'" -EA SilentlyContinue
    if ((Test-Path $hiber) -and $volSys -and $volSys.Size -gt 0) {
        $hGo = [math]::Round((Get-Item $hiber -Force -EA SilentlyContinue).Length / 1GB, 1)
        $pctLibre = [math]::Round(($volSys.FreeSpace / $volSys.Size) * 100, 1)
        if ($hGo -ge 3 -and $pctLibre -lt 15) {
            Add-Constat 2 "hiberfil.sys occupe $hGo Go sur un $sysDrive presque plein ($pctLibre % libres)" `
                "Le fichier d'hibernation reserve $hGo Go sur $sysDrive. Si tu n'utilises jamais la mise en veille prolongee (rare sur un PC de jeu fixe), le desactiver rend ces $hGo Go immediatement. Le demarrage rapide (voir plus haut) est alors aussi desactive - ce qui est plutot une bonne chose." `
                "Invite de commandes en administrateur : powercfg /h off  (pour revenir en arriere : powercfg /h on)." `
                "moyen"
        }
    }
} catch {}

# ============================================================
#  24. TDR GPU DESACTIVE (residu de tweak dangereux)
# ============================================================
# TdrLevel=0 : Windows ne recupere plus un GPU qui se bloque -> ecran fige,
# reboot forcue au lieu d'un simple flash noir. Pose par de vieux "fix".
try {
    $gd = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -EA SilentlyContinue
    if ($gd -and $null -ne $gd.TdrLevel -and [int]$gd.TdrLevel -eq 0) {
        Add-Constat 1 "Recuperation GPU (TDR) desactivee" `
            "La detection/recuperation des blocages GPU est coupee (TdrLevel = 0). Si le pilote graphique se fige une fraction de seconde - ce qui arrive et se corrige normalement tout seul - la machine reste bloquee et il faut la redemarrer de force. C'est le residu d'un ancien 'tweak' qui circulait pour certains jeux." `
            "Supprimer la valeur TdrLevel (et TdrDelay si present) sous HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers, puis redemarrer. Windows reprend son comportement normal (flash noir + 'le pilote a recupere')." `
            "eleve"
    }
} catch {}

# ============================================================
#  25. OPTIMISATION DES LECTEURS PLANIFIEE COUPEE (HDD de jeux)
# ============================================================
# On ne lance PAS "defrag /A" (trop long pour un outil rapide). On verifie que la
# tache Windows d'optimisation tourne encore : desactivee, un HDD se fragmente et
# ralentit. Signale seulement si un disque mecanique porte des jeux.
try {
    $tacheOpt = Get-ScheduledTask -TaskName 'ScheduledDefrag' -EA SilentlyContinue
    $hddJeux  = @($bibliotheques | Select-Object -Unique | Where-Object { $typeParLettre[(($_ -split ':')[0] + ":")] -eq 'HDD' })
    if ($tacheOpt -and $tacheOpt.State -eq 'Disabled' -and $hddJeux.Count -gt 0) {
        Add-Constat 2 "Optimisation planifiee des lecteurs desactivee (des jeux sont sur un HDD)" `
            "La tache Windows qui defragmente les disques a plateaux et envoie le TRIM aux SSD est desactivee - souvent le fait d'un ancien logiciel d'optimisation. Un disque mecanique qui porte des jeux ($($hddJeux -join ' ; ')) va se fragmenter et ralentir les chargements." `
            "'Defragmenter et optimiser les lecteurs' (menu Demarrer) > Modifier les parametres > recocher 'Execution planifiee'. Puis selectionner le disque mecanique et cliquer Optimiser une fois. Ne JAMAIS optimiser un SSD manuellement." `
            "moyen"
    }
} catch { Write-Log "Optim lecteurs : $($_.Exception.Message)" "WARN" }

# ============================================================
#  RESTITUTION
# ============================================================
$p1 = @($constats | Where-Object { $_.Priorite -eq 1 })
$p2 = @($constats | Where-Object { $_.Priorite -eq 2 })
$p3 = @($constats | Where-Object { $_.Priorite -eq 3 })

Write-Host ""
if ($p1.Count -eq 0 -and $p2.Count -eq 0) {
    Write-Host "  Aucun frein majeur a la fluidite detecte." -ForegroundColor Green
} else {
    Write-Host "  $($p1.Count) frein(s) majeur(s), $($p2.Count) amelioration(s) nette(s)" -ForegroundColor Cyan
}
Write-Host ""
foreach ($groupe in @(@{L=$p1;N="FREINS MAJEURS";C="Red"}, @{L=$p2;N="GAINS NETS";C="Yellow"}, @{L=$p3;N="POUR INFORMATION";C="DarkGray"})) {
    if ($groupe.L.Count -eq 0) { continue }
    Write-Host "  --- $($groupe.N) ---" -ForegroundColor $groupe.C
    foreach ($c in $groupe.L) {
        Write-Host "   > $($c.Titre)" -ForegroundColor White
        Write-Host "     $($c.Constat)" -ForegroundColor Gray
        if ($c.Action -ne "Rien a faire.") { Write-Host "     A FAIRE : $($c.Action)" -ForegroundColor Cyan }
        Write-Host ""
    }
}
Write-Log "$($p1.Count) freins majeurs, $($p2.Count) gains nets, $($p3.Count) infos."

if ($SansRapport) {
    Write-Host "  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# --- Rapport HTML ---
$machine = $env:COMPUTERNAME
$now     = Get-Date -Format 'dd/MM/yyyy HH:mm'
$badges  = @{ "eleve"="Gain eleve"; "moyen"="Gain moyen"; "faible"="Gain faible"; "aucun"="Rien a faire" }

$cartesHtml = ""
foreach ($g in @(@{L=$p1;Cls="c1";N="Freins majeurs a la fluidite"}, @{L=$p2;Cls="c2";N="Ameliorations nettes"}, @{L=$p3;Cls="c3";N="Pour information"})) {
    if ($g.L.Count -eq 0) { continue }
    $cartesHtml += "<h2>$(HtmlEnc $g.N)</h2>"
    foreach ($c in $g.L) {
        $cartesHtml += "<div class='cc $($g.Cls)'><div class='cbadge'>$(HtmlEnc $badges[$c.Gain])</div>" +
                       "<div class='chead'>$(HtmlEnc $c.Titre)</div>" +
                       "<div class='cconst'>$(HtmlEnc $c.Constat)</div>"
        if ($c.Action -ne "Rien a faire.") { $cartesHtml += "<div class='cact'><b>A faire :</b> $(HtmlEnc $c.Action)</div>" }
        $cartesHtml += "</div>"
    }
}

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Fluidite $machine</title>
<style>
  :root{--bg:#23272e;--bg2:#1b1e24;--card:#2b2f37;--line:#3a3f4a;--txt:#f2f3f5;--mut:#9aa1ac;--red:#e23b3b;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171;}
  *{box-sizing:border-box;} body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg2);color:var(--txt);line-height:1.5;}
  .header{background:linear-gradient(160deg,#2b2f37,#1b1e24);padding:36px 32px;border-bottom:1px solid var(--line);}
  .logo{font-size:34px;font-weight:800;letter-spacing:-.5px;} .logo .u{color:var(--red);}
  .logo .sub{display:block;font-size:12px;font-weight:600;letter-spacing:.22em;color:var(--mut);margin-top:6px;}
  .meta{color:var(--mut);font-size:13px;margin-top:14px;}
  .wrap{padding:24px 32px;max-width:1000px;}
  h2{font-size:13px;margin:30px 0 10px;color:var(--mut);text-transform:uppercase;letter-spacing:.08em;}
  h2::before{content:"";display:inline-block;width:3px;height:13px;background:var(--red);margin-right:8px;vertical-align:-1px;}
  .cc{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin-bottom:10px;}
  .c1{border-left:4px solid var(--bad);} .c2{border-left:4px solid var(--warn);} .c3{border-left:4px solid var(--mut);}
  .cbadge{display:inline-block;font-size:10px;font-weight:800;letter-spacing:.06em;text-transform:uppercase;color:var(--mut);margin-bottom:4px;}
  .c1 .cbadge{color:var(--bad);} .c2 .cbadge{color:var(--warn);}
  .chead{font-size:16px;font-weight:700;margin-bottom:6px;}
  .cconst{font-size:13px;color:var(--txt);} .cact{font-size:13px;color:var(--mut);margin-top:8px;}
  .intro{background:rgba(226,59,59,.07);border:1px solid rgba(226,59,59,.28);border-radius:10px;padding:14px 16px;font-size:13px;color:#f3c9c9;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Analyse de fluidite et de FPS</div>
</div>
<div class="wrap">
  <div class="intro">Cette analyse est en lecture seule : aucun reglage n'a ete modifie sur la machine.
  Elle liste les causes reelles de perte de fluidite, classees par gain attendu.</div>
  $cartesHtml
</div>
<div class="foot">Allo Valentin &middot; Analyse generee le $now &middot; Aucune modification effectuee sur la machine</div>
</body></html>
"@

$rapport = "$ReportDir\Fluidite-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host "  Rapport : $rapport" -ForegroundColor Green
Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (o/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
