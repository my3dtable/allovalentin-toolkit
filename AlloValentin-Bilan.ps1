<#
.SYNOPSIS
    Allo Valentin - Bilan sante & depannage (lecture seule)
.DESCRIPTION
    Le couteau suisse du depannage courant. Repond en un passage aux questions qui
    reviennent le plus chez un particulier ou une TPE, et que les autres outils du
    toolkit (orientes jeux / FPS) ne traitent pas :

      - la batterie du portable est-elle usee ?
      - le PC a-t-il des ecrans bleus, et quel pilote plante ?
      - l'imprimante est-elle bloquee (spouleur, file d'attente) ?
      - le disque est-il en train de lacher (SMART) ?
      - la machine est-elle detournee par un adware (hosts, proxy, DNS) ?
      - Windows est-il active ?
      - qu'est-ce qui est reellement sauvegarde si le disque lache demain ?

    CE SCRIPT N'ECRIT RIEN. Aucune cle modifiee, aucun service touche, aucun fichier
    supprime. Il constate, il explique, il classe par urgence. Zero risque.

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
$LogFile = "$LogDir\Bilan-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $line
}
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }

Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - Bilan sante & depannage" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
Write-Host "  Lecture seule : ce script ne modifie rien." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Analyse en cours..." -ForegroundColor Cyan

# Urgence : 1 = a traiter, 2 = a surveiller, 3 = pour information (tout va bien)
$constats = New-Object System.Collections.ArrayList
function Add-Constat {
    param([int]$Urgence, [string]$Domaine, [string]$Titre, [string]$Constat, [string]$Action = "")
    $null = $constats.Add([pscustomobject]@{
        Urgence = $Urgence; Domaine = $Domaine; Titre = $Titre; Constat = $Constat; Action = $Action
    })
}

$estPortable = $false
try {
    foreach ($c in (Get-CimInstance Win32_SystemEnclosure -EA SilentlyContinue).ChassisTypes) {
        if ($c -in @(8,9,10,11,12,13,14,18,21,30,31,32)) { $estPortable = $true }
    }
} catch {}

# ============================================================
#  1. BATTERIE (portables)
# ============================================================
Write-Host "  - batterie..." -ForegroundColor DarkGray
if ($estPortable) {
    try {
        $bat = Get-CimInstance Win32_Battery -EA SilentlyContinue | Select-Object -First 1
        # Capacites reelles via root\wmi (en mWh). Design = capacite d'usine,
        # FullCharged = ce que la batterie encaisse aujourd'hui. Usure = 1 - full/design.
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -EA SilentlyContinue | Select-Object -First 1).DesignedCapacity
        $full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -EA SilentlyContinue | Select-Object -First 1).FullChargedCapacity
        if ($design -and $full -and $design -gt 0) {
            $usure = [math]::Round((1 - ($full / $design)) * 100, 0)
            $sante = 100 - $usure
            $txt = "Capacite d'usine $([math]::Round($design/1000,1)) Wh, capacite actuelle $([math]::Round($full/1000,1)) Wh. Sante $sante %."
            if ($usure -ge 40) {
                Add-Constat 1 "Batterie" "Batterie tres usee (sante $sante %)" `
                    "$txt Une batterie a moins de 60 % de sante ne tient plus une vraie session sans le chargeur et peut s'eteindre sans prevenir." `
                    "Proposer un remplacement de batterie (prestation Remplacement de piece). En attendant, brancher pour tout usage serieux."
            } elseif ($usure -ge 20) {
                Add-Constat 2 "Batterie" "Batterie qui fatigue (sante $sante %)" `
                    "$txt L'autonomie a nettement baisse par rapport au neuf." `
                    "A surveiller. Un remplacement sera a envisager si la sante continue de descendre."
            } else {
                Add-Constat 3 "Batterie" "Batterie en bon etat (sante $sante %)" $txt
            }
            Write-Log "Batterie : design=$design full=$full usure=$usure%"
        } else {
            Add-Constat 3 "Batterie" "Usure de batterie non lisible" `
                "Le portable n'expose pas ses capacites d'origine (frequent sur certains modeles)." `
                "Verifier a la main avec : powercfg /batteryreport"
        }
    } catch { Write-Log "Batterie : $_" "WARN" }
} else {
    Add-Constat 3 "Batterie" "Poste fixe" "Pas de batterie a controler."
}

# ============================================================
#  2. ECRANS BLEUS (BugCheck + minidumps, sur 30 jours)
# ============================================================
Write-Host "  - ecrans bleus..." -ForegroundColor DarkGray
try {
    $depuis = (Get-Date).AddDays(-30)
    $bsod = @()
    try {
        $bsod = @(Get-WinEvent -FilterHashtable @{ LogName='System'; Id=1001; ProviderName='Microsoft-Windows-WER-SystemErrorReporting'; StartTime=$depuis } -EA Stop)
    } catch {
        # Aucun evenement trouve : Get-WinEvent leve plutot que de renvoyer vide.
        $bsod = @()
    }
    $minidumps = @(Get-ChildItem "$env:SystemRoot\Minidump\*.dmp" -EA SilentlyContinue | Where-Object { $_.LastWriteTime -ge $depuis })
    $nb = [math]::Max($bsod.Count, $minidumps.Count)

    if ($nb -gt 0) {
        # Le pilote fautif est souvent nomme dans le texte de l'evenement BugCheck.
        $dernier = if ($bsod.Count) { ($bsod | Sort-Object TimeCreated -Descending)[0] } else { $null }
        $quand = if ($dernier) { $dernier.TimeCreated.ToString('dd/MM/yyyy HH:mm') }
                 elseif ($minidumps.Count) { ($minidumps | Sort-Object LastWriteTime -Descending)[0].LastWriteTime.ToString('dd/MM/yyyy HH:mm') }
                 else { "?" }
        $pilote = ""
        if ($dernier -and $dernier.Message -match '([A-Za-z0-9_]+\.sys)') { $pilote = $Matches[1] }
        $codeM = if ($dernier -and $dernier.Message -match '(0x[0-9A-Fa-f]{8})') { $Matches[1] } else { "" }
        $detail = "Dernier plante le $quand."
        if ($codeM)  { $detail += " Code $codeM." }
        if ($pilote) { $detail += " Pilote mis en cause : $pilote." }
        $urg = if ($nb -ge 3) { 1 } else { 2 }
        Add-Constat $urg "Ecrans bleus" "$nb ecran(s) bleu(s) sur les 30 derniers jours" `
            "$detail $(if($nb -ge 3){'Des plantages repetes signalent souvent un pilote defectueux, une barrette de RAM fatiguee, ou une surchauffe.'}else{'Un plantage isole peut etre sans suite ; a surveiller.'})" `
            "$(if($pilote){"Mettre a jour ou remplacer le pilote $pilote (menu Carte mere / Tout mettre a jour). "})$(if($nb -ge 3){'Sinon, lancer un test memoire (mdsched.exe) et verifier les temperatures.'}else{'Reverifier si ca se reproduit.'})"
        Write-Log "BSOD : $nb sur 30j, dernier $quand, pilote='$pilote', code='$codeM'"
    } else {
        Add-Constat 3 "Ecrans bleus" "Aucun ecran bleu recent" "Pas de plantage systeme enregistre sur les 30 derniers jours."
    }
} catch { Write-Log "BSOD : $_" "WARN"; Add-Constat 3 "Ecrans bleus" "Historique des plantages illisible" "Le journal systeme n'a pas pu etre lu." }

# ============================================================
#  3. IMPRIMANTES (spouleur + file d'attente)
# ============================================================
Write-Host "  - imprimantes..." -ForegroundColor DarkGray
try {
    $spool = Get-Service Spooler -EA SilentlyContinue
    if ($spool -and $spool.Status -ne 'Running') {
        Add-Constat 1 "Imprimante" "Le service d'impression est arrete" `
            "Le spouleur d'impression (Spooler) ne tourne pas : aucune imprimante ne peut fonctionner." `
            "Le redemarrer : services.msc > Spouleur d'impression > Demarrer (ou net start spooler)."
    }
    $impr = @(Get-Printer -EA SilentlyContinue | Where-Object { -not $_.Shared -or $_.Type -eq 'Local' })
    $horsLigne = @($impr | Where-Object { $_.PrinterStatus -eq 'Offline' -or $_.WorkOffline })
    if ($horsLigne.Count) {
        Add-Constat 2 "Imprimante" "$($horsLigne.Count) imprimante(s) hors ligne" `
            "En hors ligne : $(( $horsLigne | ForEach-Object { $_.Name }) -join ', '). Windows garde ce statut meme apres rallumage de l'imprimante." `
            "Verifier le cable / le Wi-Fi de l'imprimante, puis decocher 'Utiliser l'imprimante hors connexion' dans la file d'attente."
    }
    $bloques = 0; $detBloq = @()
    foreach ($p in $impr) {
        $jobs = @(Get-PrintJob -PrinterName $p.Name -EA SilentlyContinue)
        $vieux = @($jobs | Where-Object { $_.SubmittedTime -and $_.SubmittedTime -lt (Get-Date).AddMinutes(-10) })
        if ($jobs.Count -ge 1 -and ($vieux.Count -ge 1 -or ($jobs | Where-Object { $_.JobStatus -match 'Error|Blocked|Paused' }).Count)) {
            $bloques += $jobs.Count; $detBloq += "$($p.Name) ($($jobs.Count))"
        }
    }
    if ($bloques) {
        Add-Constat 1 "Imprimante" "File d'attente bloquee ($bloques document(s))" `
            "Des documents restent coinces dans la file : $($detBloq -join ', '). Tant qu'ils y sont, rien de nouveau ne s'imprime." `
            "Vider la file : clic droit sur l'imprimante > Afficher les travaux > Annuler tous. Si ca resiste, arreter le spouleur, vider C:\Windows\System32\spool\PRINTERS, relancer le spouleur."
    }
    if (-not $horsLigne.Count -and -not $bloques -and $spool.Status -eq 'Running') {
        $n = $impr.Count
        Add-Constat 3 "Imprimante" "Impression operationnelle" "$(if($n){"$n imprimante(s) installee(s), "})spouleur actif, aucune file bloquee."
    }
} catch { Write-Log "Imprimantes : $_" "WARN" }

# ============================================================
#  4. SANTE DES DISQUES (SMART)
# ============================================================
Write-Host "  - sante des disques..." -ForegroundColor DarkGray
try {
    $disques = Get-PhysicalDisk -EA SilentlyContinue
    foreach ($d in $disques) {
        $rel = $d | Get-StorageReliabilityCounter -EA SilentlyContinue
        $secteurs = if ($rel) { $rel.ReadErrorsUncorrected } else { $null }
        $realloc  = 0
        # Wear (SSD) : usure en %, dispo sur certains modeles.
        $wear = if ($rel -and $rel.Wear -ne $null) { $rel.Wear } else { $null }
        $etat = $d.HealthStatus  # Healthy / Warning / Unhealthy
        $nom = "$($d.FriendlyName) ($([math]::Round($d.Size/1GB,0)) Go, $($d.MediaType))"
        if ($etat -eq 'Unhealthy' -or ($secteurs -ne $null -and $secteurs -gt 0)) {
            Add-Constat 1 "Disque" "Disque en fin de vie : $($d.FriendlyName)" `
                "$nom. Windows signale l'etat '$etat'$(if($secteurs){", avec $secteurs erreur(s) de lecture non corrigee(s)"}). Un disque dans cet etat peut lacher a tout moment." `
                "Sauvegarder les donnees IMMEDIATEMENT, puis remplacer le disque. Ne pas attendre."
        } elseif ($etat -eq 'Warning' -or ($wear -ne $null -and $wear -ge 80)) {
            Add-Constat 2 "Disque" "Disque a surveiller : $($d.FriendlyName)" `
                "$nom. Etat '$etat'$(if($wear -ne $null){", usure SSD $wear %"}). Encore fonctionnel, mais en declin." `
                "Prevoir un remplacement et verifier que les sauvegardes tournent."
        } else {
            Add-Constat 3 "Disque" "Disque sain : $($d.FriendlyName)" "$nom. Etat '$etat'$(if($wear -ne $null){", usure SSD $wear %"})."
        }
    }
} catch { Write-Log "SMART : $_" "WARN" }

# ============================================================
#  5. DETOURNEMENT ADWARE (hosts, proxy, DNS)
# ============================================================
Write-Host "  - detournement reseau..." -ForegroundColor DarkGray
try {
    # a) fichier hosts : des entrees non standard redirigent des sites (banque, MAJ...)
    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $lignesHosts = @()
    if (Test-Path $hostsFile) {
        $lignesHosts = @(Get-Content $hostsFile -EA SilentlyContinue | Where-Object {
            $l = $_.Trim()
            $l -and -not $l.StartsWith('#') -and $l -notmatch '^\s*(127\.0\.0\.1|::1)\s+localhost\s*$'
        })
    }
    if ($lignesHosts.Count) {
        Add-Constat 1 "Detournement" "Le fichier hosts contient $($lignesHosts.Count) redirection(s)" `
            "Des sites sont redetournes au niveau du fichier hosts : $((($lignesHosts | Select-Object -First 3) -join ' | ')). C'est une technique classique d'adware pour rediriger vers de la pub ou bloquer des mises a jour / antivirus." `
            "Verifier chaque ligne. Si elles n'ont pas ete ajoutees volontairement, les retirer (ouvrir le fichier en admin) et lancer un Nettoyage & virus."
    }
    # b) proxy systeme active (souvent pose par un adware)
    $proxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyOn = (Get-ItemProperty $proxyKey -Name ProxyEnable -EA SilentlyContinue).ProxyEnable
    $proxySrv = (Get-ItemProperty $proxyKey -Name ProxyServer -EA SilentlyContinue).ProxyServer
    if ($proxyOn -eq 1 -and $proxySrv) {
        Add-Constat 2 "Detournement" "Un proxy est actif ($proxySrv)" `
            "Tout le trafic web passe par ce proxy. Legitime en entreprise, mais souvent pose par un adware chez un particulier." `
            "Confirmer avec le client. S'il n'a rien configure : Parametres > Reseau > Proxy > desactiver, puis Nettoyage & virus."
    }
    # c) DNS fixe non fourni par la box (peut etre legitime : Cloudflare/Google)
    $connus = '1\.1\.1\.1|1\.0\.0\.1|8\.8\.8\.8|8\.8\.4\.4|9\.9\.9\.9'
    $dnsSuspects = @()
    foreach ($a in (Get-DnsClientServerAddress -AddressFamily IPv4 -EA SilentlyContinue | Where-Object { $_.ServerAddresses })) {
        $ad = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -EA SilentlyContinue
        if ($ad -and $ad.Status -eq 'Up') {
            foreach ($srv in $a.ServerAddresses) {
                if ($srv -notmatch $connus -and $srv -notmatch '^(192\.168\.|10\.|172\.(1[6-9]|2\d|3[01])\.|127\.|169\.254\.|fe80)') {
                    $dnsSuspects += "$srv ($($ad.Name))"
                }
            }
        }
    }
    if ($dnsSuspects.Count) {
        Add-Constat 2 "Detournement" "DNS inhabituel force" `
            "Serveur(s) DNS defini(s) a la main : $($dnsSuspects -join ', '). Un DNS pirate peut rediriger vers de faux sites. (Un DNS public connu comme Cloudflare ou Google n'apparait pas ici.)" `
            "Verifier avec le client. Sinon, remettre le DNS en automatique (fourni par la box)."
    }
    if (-not $lignesHosts.Count -and $proxyOn -ne 1 -and -not $dnsSuspects.Count) {
        Add-Constat 3 "Detournement" "Aucun detournement reseau detecte" "Fichier hosts propre, pas de proxy impose, DNS normal."
    }
} catch { Write-Log "Detournement : $_" "WARN" }

# ============================================================
#  6. ACTIVATION WINDOWS
# ============================================================
Write-Host "  - activation Windows..." -ForegroundColor DarkGray
try {
    $lic = Get-CimInstance SoftwareLicensingProduct -EA SilentlyContinue |
           Where-Object { $_.PartialProductKey -and $_.ApplicationID -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } |
           Select-Object -First 1
    # LicenseStatus : 1 = active
    if ($lic) {
        if ($lic.LicenseStatus -eq 1) {
            Add-Constat 3 "Activation" "Windows est active" "Licence valide ($($lic.Name))."
        } else {
            $etats = @{0='Non active';2='Delai de grace';3='Delai etendu';4='Delai non genuine';5='Notification';6='Grace etendu'}
            $e = if ($etats.ContainsKey([int]$lic.LicenseStatus)) { $etats[[int]$lic.LicenseStatus] } else { "etat $($lic.LicenseStatus)" }
            Add-Constat 2 "Activation" "Windows n'est pas active ($e)" `
                "Windows fonctionne mais n'est pas active : filigrane, personnalisation bloquee, rappels. Certains adware se cachent derriere un 'activateur' installe pour contourner ca." `
                "Verifier la licence du client. Ne jamais installer d'activateur pirate (KMS crack) : c'est une porte d'entree a virus."
        }
    }
} catch { Write-Log "Activation : $_" "WARN" }

# ============================================================
#  7. QU'EST-CE QUI EST SAUVEGARDE ?
# ============================================================
Write-Host "  - sauvegardes..." -ForegroundColor DarkGray
try {
    $protege = @(); $nonProtege = @()
    # OneDrive : dossier present et processus en cours
    $odDir = $env:OneDrive
    $odProc = Get-Process OneDrive -EA SilentlyContinue
    if ($odDir -and (Test-Path $odDir)) {
        if ($odProc) { $protege += "OneDrive (synchronisation active)" } else { $nonProtege += "OneDrive installe mais pas en cours d'execution" }
    }
    # Historique des fichiers
    $fh = Get-Service fhsvc -EA SilentlyContinue
    $fhOn = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\FileHistory' -Name 'Enabled' -EA SilentlyContinue).Enabled
    # Cle plus fiable : la config utilisateur
    $fhCfg = Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\FileHistory\Configuration\Config1.xml"
    if ($fhCfg) { $protege += "Historique des fichiers configure" }
    # Points de restauration systeme
    $rp = @(Get-ComputerRestorePoint -EA SilentlyContinue)
    if ($rp.Count) {
        $dernier = ($rp | Sort-Object { $_.ConvertToDateTime($_.CreationTime) } -Descending)[0]
        $dRp = try { $dernier.ConvertToDateTime($dernier.CreationTime).ToString('dd/MM/yyyy') } catch { "?" }
        $protege += "Points de restauration systeme (dernier : $dRp)"
    }

    if ($protege.Count -eq 0) {
        Add-Constat 1 "Sauvegarde" "Aucune sauvegarde detectee" `
            "Ni OneDrive actif, ni Historique des fichiers, ni point de restauration. Si le disque lache demain, TOUT est perdu : photos, documents, tout." `
            "Proposer la prestation Sauvegarde de vos donnees (disque externe + cloud). C'est l'argument le plus fort a poser en fin d'intervention."
    } else {
        $urg = if ($nonProtege.Count) { 2 } else { 3 }
        Add-Constat $urg "Sauvegarde" "Sauvegarde $(if($nonProtege.Count){'partielle'}else{'en place'})" `
            ("Protege : " + ($protege -join ' ; ') + "." + $(if($nonProtege.Count){" A verifier : " + ($nonProtege -join ' ; ') + "."})) `
            $(if($nonProtege.Count){"Verifier que OneDrive tourne bien, ou completer par une sauvegarde locale."}else{""})
    }
    Write-Log "Sauvegarde : protege=$($protege.Count) aVerifier=$($nonProtege.Count)"
} catch { Write-Log "Sauvegarde : $_" "WARN" }

# ============================================================
#  RESTITUTION CONSOLE
# ============================================================
$u1 = @($constats | Where-Object { $_.Urgence -eq 1 })
$u2 = @($constats | Where-Object { $_.Urgence -eq 2 })
$u3 = @($constats | Where-Object { $_.Urgence -eq 3 })

Write-Host ""
if ($u1.Count -eq 0 -and $u2.Count -eq 0) {
    Write-Host "  Rien d'urgent : la machine est saine sur tous les points controles." -ForegroundColor Green
} else {
    Write-Host "  $($u1.Count) point(s) a traiter, $($u2.Count) a surveiller" -ForegroundColor Cyan
}
Write-Host ""
foreach ($g in @(@{L=$u1;N="A TRAITER";C="Red"}, @{L=$u2;N="A SURVEILLER";C="Yellow"}, @{L=$u3;N="TOUT VA BIEN";C="DarkGray"})) {
    if ($g.L.Count -eq 0) { continue }
    Write-Host "  --- $($g.N) ---" -ForegroundColor $g.C
    foreach ($c in $g.L) {
        Write-Host "   > [$($c.Domaine)] $($c.Titre)" -ForegroundColor White
        Write-Host "     $($c.Constat)" -ForegroundColor Gray
        if ($c.Action) { Write-Host "     A FAIRE : $($c.Action)" -ForegroundColor Cyan }
        Write-Host ""
    }
}
Write-Log "$($u1.Count) a traiter, $($u2.Count) a surveiller, $($u3.Count) info."

if ($SansRapport) {
    Write-Host "  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# ============================================================
#  RAPPORT HTML (charte Allo Valentin)
# ============================================================
$machine = $env:COMPUTERNAME
$now     = Get-Date -Format 'dd/MM/yyyy HH:mm'

$cartesHtml = ""
foreach ($g in @(@{L=$u1;Cls="c1";N="A traiter"}, @{L=$u2;Cls="c2";N="A surveiller"}, @{L=$u3;Cls="c3";N="Tout va bien"})) {
    if ($g.L.Count -eq 0) { continue }
    $cartesHtml += "<h2>$(HtmlEnc $g.N)</h2>"
    foreach ($c in $g.L) {
        $cartesHtml += "<div class='cc $($g.Cls)'><div class='cbadge'>$(HtmlEnc $c.Domaine)</div>" +
                       "<div class='chead'>$(HtmlEnc $c.Titre)</div>" +
                       "<div class='cconst'>$(HtmlEnc $c.Constat)</div>"
        if ($c.Action) { $cartesHtml += "<div class='cact'><b>A faire :</b> $(HtmlEnc $c.Action)</div>" }
        $cartesHtml += "</div>"
    }
}

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Bilan sante $machine</title>
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
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Bilan sante et depannage</div>
</div>
<div class="wrap">
  <div class="intro">Ce bilan est en lecture seule : aucun reglage n'a ete modifie sur la machine.
  Il liste, par ordre d'urgence, ce qui merite une intervention.</div>
  $cartesHtml
</div>
<div class="foot">Allo Valentin &middot; Bilan genere le $now &middot; Aucune modification effectuee sur la machine</div>
</body></html>
"@

$rapport = "$ReportDir\Bilan-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host "  Rapport : $rapport" -ForegroundColor Green
Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (o/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
