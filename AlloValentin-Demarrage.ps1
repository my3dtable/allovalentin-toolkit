<#
.SYNOPSIS
    Allo Valentin - Ce qui se lance tout seul (persistance / autoruns natif, lecture seule)
.DESCRIPTION
    L'equivalent natif d'Autoruns (Sysinternals), l'outil n1 des depanneurs pour
    reperer en deux minutes ce qui demarre avec Windows et, surtout, ce qui n'a rien
    a y faire (adware, malware, logiciel indesirable qui ralentit la machine).

    Il fait le tour de TOUS les points de demarrage et de persistance :
      - Cles Run / RunOnce (HKLM, HKCU, 32 bits)
      - Dossiers Demarrage (utilisateur + tous les utilisateurs)
      - Taches planifiees non-Microsoft
      - Services en demarrage auto, non-Microsoft
      - Winlogon (Shell, Userinit) : cible favorite des virus
      - Detournement IFEO (un programme lance a la place d'un autre)
      - AppInit_DLLs (injection dans tous les programmes)
      - Abonnements WMI (persistance avancee)
      - Nombre d'extensions de navigateur

    Pour chaque programme lance, il verifie la SIGNATURE numerique et l'emplacement,
    puis classe : rouge (suspect), jaune (a verifier), gris (signe / connu).

    CE SCRIPT N'ECRIT RIEN. Lecture seule, zero risque. Il constate et il explique ;
    la desinfection reste une decision manuelle (prestation Nettoyage & virus).

.NOTES
    A executer en Administrateur (auto-elevation incluse). PowerShell 5.1.
#>

param(
    [switch]$SansRapport
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
$LogFile = "$LogDir\Demarrage-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
}
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }

Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - Ce qui se lance tout seul" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
Write-Host "  Lecture seule : ce script ne modifie rien." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Analyse des points de demarrage..." -ForegroundColor Cyan

# ============================================================
#  Analyse d'un executable : signature + emplacement -> suspicion
# ============================================================
# Cache des signatures : Get-AuthenticodeSignature est lent, on evite de repasser
# deux fois sur le meme fichier.
$sigCache = @{}
function Get-CibleExe {
    # Extrait le chemin de l'exe d'une ligne de commande (gere les guillemets).
    param([string]$Commande)
    if ([string]::IsNullOrWhiteSpace($Commande)) { return $null }
    $c = $Commande.Trim()
    if ($c.StartsWith('"')) {
        $fin = $c.IndexOf('"', 1)
        if ($fin -gt 1) { return $c.Substring(1, $fin - 1) }
    }
    # Sans guillemets : on prend jusqu'au premier .exe
    $m = [regex]::Match($c, '^(.*?\.exe)\b', 'IgnoreCase')
    if ($m.Success) { return $m.Groups[1].Value }
    return ($c -split '\s+')[0]
}
function Test-Suspicion {
    # Retourne @{ Niveau=1|2|3; Pourquoi=""; Editeur=""; Chemin="" }
    param([string]$Commande)
    $exe = Get-CibleExe $Commande
    $res = [ordered]@{ Niveau = 3; Pourquoi = ""; Editeur = ""; Chemin = $exe }
    if (-not $exe) { $res.Niveau = 2; $res.Pourquoi = "cible illisible"; return $res }
    # Resolution des variables d'environnement
    $chemin = [Environment]::ExpandEnvironmentVariables($exe)
    $res.Chemin = $chemin
    if (-not (Test-Path $chemin -PathType Leaf -EA SilentlyContinue)) {
        $res.Niveau = 2; $res.Pourquoi = "fichier introuvable a cet emplacement"; return $res
    }
    # Applications du Microsoft Store (signees au niveau du paquet) : de confiance.
    if ($chemin -like '*\WindowsApps\*') { $res.Niveau = 3; $res.Editeur = "Microsoft Store"; $res.Pourquoi = "application du Microsoft Store"; return $res }
    # Signature (avec cache)
    if ($sigCache.ContainsKey($chemin)) { $sig = $sigCache[$chemin] }
    else { $sig = Get-AuthenticodeSignature $chemin -EA SilentlyContinue; $sigCache[$chemin] = $sig }
    $signe = $sig -and $sig.Status -eq 'Valid'
    if ($signe -and $sig.SignerCertificate) {
        $res.Editeur = ($sig.SignerCertificate.Subject -replace '^CN=([^,]+).*', '$1').Trim('"')
    }
    # Regle des pros (comme Autoruns, qui masque les entrees signees) : une signature
    # numerique VALIDE = editeur identifie = on fait confiance, quel que soit l'emplacement.
    # Spotify, Discord, Teams, OneDrive, Windows Defender se lancent normalement depuis
    # AppData / ProgramData : signes, donc pas suspects. C'est l'ABSENCE de signature,
    # surtout dans un dossier temporaire / utilisateur, qui trahit un indesirable.
    if ($signe) {
        $res.Niveau = 3
        $res.Pourquoi = "signe : $($res.Editeur)"
        return $res
    }
    $zonesLouches = @('\AppData\Local\Temp\', '\AppData\Roaming\', '\AppData\Local\', '\Downloads\',
                      '\Users\Public\', '\Temp\')
    $dansZoneLouche = $false
    foreach ($z in $zonesLouches) { if ($chemin -like "*$z*") { $dansZoneLouche = $true; break } }
    if ($dansZoneLouche) {
        $res.Niveau = 1
        $res.Pourquoi = "non signe et lance depuis un dossier temporaire / utilisateur ($([System.IO.Path]::GetDirectoryName($chemin)))"
    } else {
        $res.Niveau = 2
        $res.Pourquoi = "programme non signe numeriquement"
    }
    return $res
}

$items = New-Object System.Collections.ArrayList
function Add-Item {
    param([string]$Source, [string]$Nom, [string]$Commande, [hashtable]$Forcer = $null)
    $s = if ($Forcer) { $Forcer } else { Test-Suspicion $Commande }
    $null = $items.Add([pscustomobject]@{
        Source = $Source; Nom = $Nom; Commande = $Commande
        Niveau = $s.Niveau; Pourquoi = $s.Pourquoi; Editeur = $s.Editeur; Chemin = $s.Chemin
    })
}

# ============================================================
#  1. Cles Run / RunOnce
# ============================================================
$runKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\RunOnce',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
)
foreach ($k in $runKeys) {
    if (-not (Test-Path $k)) { continue }
    $p = Get-ItemProperty $k -EA SilentlyContinue
    foreach ($prop in ($p.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })) {
        $ruche = if ($k -like 'HKLM:*') { 'HKLM' } else { 'HKCU' }
        Add-Item "Run ($ruche)" $prop.Name ([string]$prop.Value)
    }
}

# ============================================================
#  2. Dossiers Demarrage
# ============================================================
foreach ($d in @("$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup",
                 "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Startup")) {
    if (-not (Test-Path $d)) { continue }
    Get-ChildItem $d -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object {
        $cible = $_.FullName
        # Un .lnk pointe vers un exe : on suit le raccourci
        if ($_.Extension -eq '.lnk') {
            try { $sh = New-Object -ComObject WScript.Shell; $cible = $sh.CreateShortcut($_.FullName).TargetPath } catch {}
        }
        Add-Item "Dossier Demarrage" $_.Name $cible
    }
}

# ============================================================
#  3. Taches planifiees non-Microsoft, declenchees au demarrage / a l'ouverture
# ============================================================
try {
    Get-ScheduledTask -EA SilentlyContinue | Where-Object {
        $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and
        ($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'Logon|Boot|Startup' })
    } | ForEach-Object {
        $t = $_
        $act = ($t.Actions | Where-Object { $_.Execute } | Select-Object -First 1)
        if ($act) {
            $cmd = $act.Execute; if ($act.Arguments) { $cmd += " $($act.Arguments)" }
            Add-Item "Tache planifiee" ($t.TaskPath + $t.TaskName) $cmd
        }
    }
} catch { Write-Log "Taches : $_" "WARN" }

# ============================================================
#  4. Services en demarrage automatique, non-Microsoft
# ============================================================
try {
    Get-CimInstance Win32_Service -EA SilentlyContinue | Where-Object {
        $_.StartMode -eq 'Auto' -and $_.PathName
    } | ForEach-Object {
        $svc = $_
        $s = Test-Suspicion $svc.PathName
        # On ne liste que ce qui n'est pas clairement Microsoft/Windows signe et bien range
        $estWindows = $svc.PathName -match '\\Windows\\' -and $s.Niveau -eq 3
        if (-not $estWindows) {
            Add-Item "Service auto" $svc.Name $svc.PathName $s
        }
    }
} catch { Write-Log "Services : $_" "WARN" }

# ============================================================
#  5. Winlogon : Shell et Userinit (favoris des virus)
# ============================================================
try {
    $wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $shell = (Get-ItemProperty $wl -Name Shell -EA SilentlyContinue).Shell
    $userinit = (Get-ItemProperty $wl -Name Userinit -EA SilentlyContinue).Userinit
    if ($shell -and $shell.Trim().ToLower() -ne 'explorer.exe') {
        Add-Item "Winlogon Shell" "Shell" $shell @{ Niveau=1; Pourquoi="Shell modifie (normal = explorer.exe) : signature tres frequente d'un virus"; Editeur=""; Chemin=$shell }
    }
    if ($userinit -and $userinit -notmatch '(?i)\\userinit\.exe,?\s*$') {
        Add-Item "Winlogon Userinit" "Userinit" $userinit @{ Niveau=1; Pourquoi="Userinit modifie (normal = ...\userinit.exe,) : a inspecter"; Editeur=""; Chemin=$userinit }
    }
} catch { Write-Log "Winlogon : $_" "WARN" }

# ============================================================
#  6. IFEO : un debogueur detourne un programme vers un autre
# ============================================================
try {
    $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
    if (Test-Path $ifeo) {
        Get-ChildItem $ifeo -EA SilentlyContinue | ForEach-Object {
            $dbg = (Get-ItemProperty $_.PSPath -Name Debugger -EA SilentlyContinue).Debugger
            if ($dbg) {
                Add-Item "Detournement IFEO" $_.PSChildName $dbg @{ Niveau=1; Pourquoi="'$($_.PSChildName)' est detourne vers : $dbg. Technique de blocage d'antivirus ou de detournement."; Editeur=""; Chemin=(Get-CibleExe $dbg) }
            }
        }
    }
} catch { Write-Log "IFEO : $_" "WARN" }

# ============================================================
#  7. AppInit_DLLs : DLL injectee dans tous les programmes
# ============================================================
try {
    foreach ($w in @('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows',
                     'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Windows')) {
        $ai = (Get-ItemProperty $w -Name AppInit_DLLs -EA SilentlyContinue).AppInit_DLLs
        if ($ai -and $ai.Trim()) {
            Add-Item "AppInit_DLLs" "DLL injectee" $ai @{ Niveau=1; Pourquoi="Une DLL est injectee dans tous les programmes : $ai. Presque toujours malveillant sur un PC recent."; Editeur=""; Chemin=$ai }
        }
    }
} catch { Write-Log "AppInit : $_" "WARN" }

# ============================================================
#  8. Abonnements WMI (persistance avancee, rare mais grave)
# ============================================================
try {
    $consumers = @(Get-CimInstance -Namespace root\subscription -ClassName __EventConsumer -EA SilentlyContinue |
                   Where-Object { $_.Name -notmatch '^(SCM Event|BVTConsumer|NTEventLog)' })
    foreach ($c in $consumers) {
        $cmd = if ($c.CommandLineTemplate) { $c.CommandLineTemplate } elseif ($c.ScriptText) { "(script WMI)" } else { $c.Name }
        Add-Item "Abonnement WMI" $c.Name $cmd @{ Niveau=1; Pourquoi="Persistance par abonnement WMI : rare, technique avancee de malware. A inspecter serieusement."; Editeur=""; Chemin="" }
    }
} catch { Write-Log "WMI : $_" "WARN" }

# ============================================================
#  9. Extensions de navigateur (compte indicatif)
# ============================================================
$extInfo = @()
foreach ($nav in @(@{N="Chrome"; P="$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Extensions"},
                   @{N="Edge";   P="$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Extensions"})) {
    if (Test-Path $nav.P) {
        $n = @(Get-ChildItem $nav.P -Directory -EA SilentlyContinue).Count
        if ($n -gt 0) { $extInfo += "$($nav.N) : $n extension(s)" }
    }
}

# ============================================================
#  RESTITUTION
# ============================================================
$suspects = @($items | Where-Object { $_.Niveau -eq 1 })
$aVerifier = @($items | Where-Object { $_.Niveau -eq 2 })
$signes = @($items | Where-Object { $_.Niveau -eq 3 })
Write-Log "$($items.Count) entrees : $($suspects.Count) suspectes, $($aVerifier.Count) a verifier, $($signes.Count) signees."

Write-Host ""
if ($suspects.Count -eq 0 -and $aVerifier.Count -eq 0) {
    Write-Host "  Rien de suspect : tout ce qui se lance est signe et a sa place." -ForegroundColor Green
} else {
    Write-Host "  $($suspects.Count) entree(s) suspecte(s), $($aVerifier.Count) a verifier, sur $($items.Count) au total" -ForegroundColor Cyan
}
Write-Host ""
foreach ($g in @(@{L=$suspects;N="SUSPECT - a inspecter en priorite";C="Red"},
                 @{L=$aVerifier;N="A VERIFIER";C="Yellow"})) {
    if ($g.L.Count -eq 0) { continue }
    Write-Host "  --- $($g.N) ---" -ForegroundColor $g.C
    foreach ($it in ($g.L | Sort-Object Source)) {
        Write-Host "   > [$($it.Source)] $($it.Nom)" -ForegroundColor White
        Write-Host "     $($it.Pourquoi)" -ForegroundColor Gray
        if ($it.Chemin) { Write-Host "     $($it.Chemin)" -ForegroundColor DarkGray }
        Write-Host ""
    }
}
Write-Host "  ($($signes.Count) entrees signees et bien rangees, non listees ici.)" -ForegroundColor DarkGray
if ($extInfo.Count) { Write-Host "  Extensions navigateur : $($extInfo -join ' | ')" -ForegroundColor DarkGray }

if ($SansRapport) {
    Write-Host "`n  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# ============================================================
#  RAPPORT HTML
# ============================================================
$machine = $env:COMPUTERNAME
$now     = Get-Date -Format 'dd/MM/yyyy HH:mm'
function Table-Items {
    param($liste, $cls)
    if (-not $liste.Count) { return "" }
    $rows = ($liste | Sort-Object Source | ForEach-Object {
        "<tr><td>$(HtmlEnc $_.Source)</td><td><b>$(HtmlEnc $_.Nom)</b></td><td>$(HtmlEnc $_.Pourquoi)</td><td class='mono'>$(HtmlEnc $_.Chemin)</td></tr>"
    }) -join "`n"
    return "<div class='card $cls'><table><tr><th>Source</th><th>Nom</th><th>Constat</th><th>Emplacement</th></tr>$rows</table></div>"
}
$bloc = ""
if ($suspects.Count)  { $bloc += "<h2>Suspect - a inspecter en priorite</h2>" + (Table-Items $suspects "c1") }
if ($aVerifier.Count) { $bloc += "<h2>A verifier</h2>" + (Table-Items $aVerifier "c2") }
if (-not $suspects.Count -and -not $aVerifier.Count) {
    $bloc = "<div class='card mut'>Rien de suspect : tout ce qui se lance au demarrage est signe numeriquement et lance depuis un emplacement normal.</div>"
}
$extHtml = if ($extInfo.Count) { "<h2>Extensions de navigateur</h2><div class='card mut'>$(HtmlEnc ($extInfo -join ' | ')). Un nombre eleve d'extensions inconnues est une cause frequente de navigateur lent ou detourne.</div>" } else { "" }

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Demarrage $machine</title>
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
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 12px;overflow-x:auto;}
  .c1{border-left:4px solid var(--bad);} .c2{border-left:4px solid var(--warn);}
  table{width:100%;border-collapse:collapse;font-size:13px;} th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top;}
  th{color:var(--mut);font-weight:600;} .mono{font-family:Consolas,monospace;font-size:11px;color:var(--mut);word-break:break-all;}
  .mut{color:var(--mut);}
  .intro{background:rgba(226,59,59,.07);border:1px solid rgba(226,59,59,.28);border-radius:10px;padding:14px 16px;font-size:13px;color:#f3c9c9;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Ce qui se lance au demarrage</div>
</div>
<div class="wrap">
  <div class="intro">Analyse en lecture seule : aucun reglage n'a ete modifie. Sont listes seulement les
  elements suspects ou a verifier ; les $($signes.Count) programmes signes et bien ranges ne sont pas affiches.</div>
  $bloc
  $extHtml
</div>
<div class="foot">Allo Valentin &middot; Genere le $now &middot; Aucune modification effectuee sur la machine</div>
</body></html>
"@
$rapport = "$ReportDir\Demarrage-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host "`n  Rapport : $rapport" -ForegroundColor Green
Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (o/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
