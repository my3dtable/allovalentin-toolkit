<#
.SYNOPSIS
    Allo Valentin - Processus actifs (signatures + VirusTotal, lecture seule)
.DESCRIPTION
    L'equivalent natif de Process Explorer (Sysinternals) : ce qui TOURNE en ce moment
    sur la machine, avec pour chaque programme sa signature numerique, son emplacement,
    et - si une cle d'intervention est fournie - un controle sur VirusTotal.

    Complement du script "Ce qui se lance au demarrage" (persistance) : celui-ci montre
    l'etat present. On l'utilise pour reperer un processus inconnu qui mange le CPU ou
    la RAM, ou un malware deja en cours d'execution.

    VirusTotal : seule une EMPREINTE (hash SHA-256) est envoyee au relais Allo Valentin,
    jamais le fichier. Le controle ne porte que sur les programmes NON signes ou lances
    depuis un dossier temporaire / utilisateur (les programmes signes sont de confiance).
    Sans cle d'intervention (ou si VirusTotal n'est pas configure), le script fonctionne
    quand meme : signature + emplacement, sans VirusTotal.

    CE SCRIPT N'ECRIT RIEN sur la machine. Lecture seule, zero risque.

.NOTES
    A executer en Administrateur (auto-elevation incluse). PowerShell 5.1.
#>

param(
    [string]$Cle = "",       # cle d'intervention : debloque le controle VirusTotal
    [switch]$SansRapport
)

# --- Auto-elevation (transmet la cle) ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement en mode Administrateur..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Cle)         { $argList += " -Cle `"$Cle`"" }
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
$LogFile = "$LogDir\Processus-$Stamp.log"

function Write-Log { param([string]$m,[string]$l="INFO") Add-Content -Path $LogFile -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$l] $m" }
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }

# La cle peut aussi venir de cle.txt (depose par le lanceur web), lue une fois.
if (-not $Cle) {
    $cf = Join-Path (Split-Path -Parent $PSCommandPath) 'cle.txt'
    if (Test-Path $cf) { try { $Cle = ([string](Get-Content $cf -Raw -EA Stop)).Trim() } catch {} }
}

Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - Processus actifs" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
Write-Host "  Lecture seule : ce script ne modifie rien." -ForegroundColor DarkGray
Write-Host ""
Write-Host "  Analyse des processus en cours..." -ForegroundColor Cyan

# ============================================================
#  Collecte : un exe unique -> nb d'instances, RAM totale, signature
# ============================================================
$parRam = @{}
try { Get-Process -EA SilentlyContinue | ForEach-Object { if ($_.Path) { $parRam[$_.Path] = ($parRam[$_.Path] + $_.WorkingSet64) } } } catch {}

$procsCim = @()
try { $procsCim = Get-CimInstance Win32_Process -EA SilentlyContinue | Where-Object { $_.ExecutablePath } } catch {}

$exeInfos = @{}   # chemin -> @{ Nom; Nb; RamMB; Cmd }
foreach ($p in $procsCim) {
    $path = $p.ExecutablePath
    if (-not $exeInfos.ContainsKey($path)) {
        $ramB = if ($parRam.ContainsKey($path)) { $parRam[$path] } else { 0 }
        $exeInfos[$path] = @{ Nom = $p.Name; Nb = 0; RamMB = [math]::Round($ramB/1MB,0); Cmd = $p.CommandLine }
    }
    $exeInfos[$path].Nb++
}
Write-Log "$($exeInfos.Count) executables distincts en cours."

# ============================================================
#  Signature + classement (meme regle que Demarrage : signe = confiance)
# ============================================================
function Get-Classe {
    param([string]$Chemin)
    $r = [ordered]@{ Niveau = 3; Editeur = ""; Signe = $false; Pourquoi = "" }
    if (-not (Test-Path $Chemin -PathType Leaf -EA SilentlyContinue)) { $r.Niveau = 2; $r.Pourquoi = "fichier introuvable"; return $r }
    # Applications du Microsoft Store : signees au niveau du paquet (AppX), pas dans
    # l'exe. Get-AuthenticodeSignature les voit "non signees" a tort. Elles viennent du
    # Store (validees) : de confiance.
    if ($Chemin -like '*\WindowsApps\*') { $r.Signe = $true; $r.Editeur = "Microsoft Store"; $r.Niveau = 3; $r.Pourquoi = "application du Microsoft Store"; return $r }
    $sig = Get-AuthenticodeSignature $Chemin -EA SilentlyContinue
    if ($sig -and $sig.Status -eq 'Valid') {
        $r.Signe = $true
        if ($sig.SignerCertificate) { $r.Editeur = ($sig.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1').Trim('"') }
        $r.Niveau = 3; $r.Pourquoi = "signe : $($r.Editeur)"
        return $r
    }
    $zones = @('\AppData\Local\Temp\','\AppData\Roaming\','\AppData\Local\','\Downloads\','\Users\Public\','\Temp\','\ProgramData\')
    $louche = $false; foreach ($z in $zones) { if ($Chemin -like "*$z*") { $louche = $true; break } }
    if ($louche) { $r.Niveau = 1; $r.Pourquoi = "non signe, lance depuis un dossier temporaire / utilisateur" }
    else         { $r.Niveau = 2; $r.Pourquoi = "programme non signe numeriquement" }
    return $r
}

$liste = New-Object System.Collections.ArrayList
foreach ($path in $exeInfos.Keys) {
    $c = Get-Classe $path
    $null = $liste.Add([pscustomobject]@{
        Nom = $exeInfos[$path].Nom; Chemin = $path; Nb = $exeInfos[$path].Nb; RamMB = $exeInfos[$path].RamMB
        Niveau = $c.Niveau; Editeur = $c.Editeur; Signe = $c.Signe; Pourquoi = $c.Pourquoi
        Sha256 = ""; VT = ""   # remplis plus bas pour les non-fiables
    })
}

# ============================================================
#  VirusTotal : uniquement les programmes NON fiables (niveau <= 2)
# ============================================================
$aControler = @($liste | Where-Object { $_.Niveau -le 2 })
$vtActif = $false; $vtRaison = ""
if ($aControler.Count -eq 0) {
    $vtRaison = "aucun programme non signe a controler"
} elseif (-not $Cle) {
    $vtRaison = "pas de cle d'intervention : controle VirusTotal non disponible (signature seule)"
} else {
    Write-Host "  Controle VirusTotal des programmes non signes ($($aControler.Count))..." -ForegroundColor Cyan
    $vtActif = $true
    $i = 0
    foreach ($it in $aControler) {
        $i++
        try {
            $h = (Get-FileHash -Path $it.Chemin -Algorithm SHA256 -EA Stop).Hash.ToLower()
            $it.Sha256 = $h
        } catch { $it.VT = "hash impossible"; continue }
        try {
            $u = "https://allovalentin.fr/api/vtcheck?cle=" + [uri]::EscapeDataString($Cle) + "&sha256=" + $h
            $rep = Invoke-RestMethod -Uri $u -TimeoutSec 20 -UseBasicParsing
            if ($rep.ok -and $rep.found) {
                $it.VT = "$($rep.malicious)/$([int]$rep.malicious + [int]$rep.suspicious + [int]$rep.harmless + [int]$rep.undetected)"
                if ([int]$rep.malicious -ge 1) {
                    $it.Niveau = 1
                    $it.Pourquoi = "VirusTotal : $($rep.malicious) antivirus le detectent comme malveillant$(if($rep.label){" ($($rep.label))"})"
                } elseif ([int]$rep.suspicious -ge 1) {
                    $it.Pourquoi += " ; VirusTotal : $($rep.suspicious) detection(s) suspecte(s)"
                } else {
                    $it.Pourquoi += " ; VirusTotal : aucun antivirus ne le signale"
                }
            } elseif ($rep.ok -and -not $rep.found) {
                $it.VT = "inconnu"
                $it.Pourquoi += " ; inconnu de VirusTotal (fichier jamais analyse)"
            } else {
                $it.VT = "indispo"
            }
        } catch {
            $msg = "$($_.Exception.Message)"
            if ($msg -match '403') { $vtActif = $false; $vtRaison = "cle d'intervention refusee : VirusTotal non disponible"; break }
            elseif ($msg -match '503') { $vtActif = $false; $vtRaison = "VirusTotal pas encore configure cote serveur (VT_KEY)"; break }
            else { $it.VT = "erreur" }
        }
        Start-Sleep -Milliseconds 400   # respecte le palier gratuit VirusTotal (4/min large)
    }
}
if ($vtRaison) { Write-Log "VirusTotal : $vtRaison" "WARN" }

# ============================================================
#  RESTITUTION
# ============================================================
$suspects  = @($liste | Where-Object { $_.Niveau -eq 1 } | Sort-Object RamMB -Descending)
$aVerifier = @($liste | Where-Object { $_.Niveau -eq 2 } | Sort-Object RamMB -Descending)
$fiables   = @($liste | Where-Object { $_.Niveau -eq 3 })
$grosRam   = @($liste | Sort-Object RamMB -Descending | Select-Object -First 5)
Write-Log "$($liste.Count) exe : $($suspects.Count) suspects, $($aVerifier.Count) a verifier."

Write-Host ""
if ($suspects.Count -eq 0 -and $aVerifier.Count -eq 0) {
    Write-Host "  Rien de suspect : tous les programmes en cours sont signes." -ForegroundColor Green
} else {
    Write-Host "  $($suspects.Count) processus suspect(s), $($aVerifier.Count) a verifier, sur $($liste.Count) programmes actifs" -ForegroundColor Cyan
}
if (-not $vtActif -and $vtRaison) { Write-Host "  (VirusTotal : $vtRaison)" -ForegroundColor DarkGray }
Write-Host ""
foreach ($g in @(@{L=$suspects;N="SUSPECT - a inspecter";C="Red"}, @{L=$aVerifier;N="A VERIFIER";C="Yellow"})) {
    if ($g.L.Count -eq 0) { continue }
    Write-Host "  --- $($g.N) ---" -ForegroundColor $g.C
    foreach ($it in $g.L) {
        Write-Host "   > $($it.Nom)  ($($it.Nb) instance(s), $($it.RamMB) Mo)$(if($it.VT){"  [VT $($it.VT)]"})" -ForegroundColor White
        Write-Host "     $($it.Pourquoi)" -ForegroundColor Gray
        Write-Host "     $($it.Chemin)" -ForegroundColor DarkGray
        Write-Host ""
    }
}
Write-Host "  Plus gros consommateurs de RAM : $(( $grosRam | ForEach-Object { "$($_.Nom) $($_.RamMB)Mo" }) -join ' | ')" -ForegroundColor DarkGray
Write-Host "  ($($fiables.Count) programmes signes non listes.)" -ForegroundColor DarkGray

if ($SansRapport) { Write-Host "`n  Appuie sur Entree..." -ForegroundColor DarkGray; Read-Host | Out-Null; exit }

# ============================================================
#  RAPPORT HTML
# ============================================================
$machine = $env:COMPUTERNAME; $now = Get-Date -Format 'dd/MM/yyyy HH:mm'
function Tbl { param($l,$cls)
    if (-not $l.Count) { return "" }
    $rows = ($l | ForEach-Object {
        "<tr><td><b>$(HtmlEnc $_.Nom)</b></td><td>$($_.Nb)</td><td>$($_.RamMB) Mo</td><td>$(if($_.VT){HtmlEnc $_.VT}else{'-'})</td><td>$(HtmlEnc $_.Pourquoi)</td><td class='mono'>$(HtmlEnc $_.Chemin)</td></tr>"
    }) -join "`n"
    "<div class='card $cls'><table><tr><th>Programme</th><th>Nb</th><th>RAM</th><th>VirusTotal</th><th>Constat</th><th>Emplacement</th></tr>$rows</table></div>"
}
$bloc = ""
if ($suspects.Count)  { $bloc += "<h2>Suspect - a inspecter</h2>" + (Tbl $suspects "c1") }
if ($aVerifier.Count) { $bloc += "<h2>A verifier</h2>" + (Tbl $aVerifier "c2") }
if (-not $suspects.Count -and -not $aVerifier.Count) { $bloc = "<div class='card mut'>Tous les programmes en cours d'execution sont signes numeriquement. Rien de suspect.</div>" }
$vtNote = if ($vtActif) { "Colonne VirusTotal : nombre d'antivirus qui detectent le fichier sur le total teste (ex. 0/72 = aucun). Seule l'empreinte du fichier a ete envoyee, jamais le fichier." } else { "VirusTotal non utilise ($([string]$vtRaison)). Analyse basee sur la signature numerique et l'emplacement." }

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Processus $machine</title>
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
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Processus actifs</div>
</div>
<div class="wrap">
  <div class="intro">Analyse en lecture seule : aucun programme n'a ete arrete ni modifie. $vtNote</div>
  $bloc
  <h2>Plus gros consommateurs de RAM</h2>
  <div class="card mut">$(( $grosRam | ForEach-Object { HtmlEnc "$($_.Nom) : $($_.RamMB) Mo" }) -join ' &middot; ')</div>
</div>
<div class="foot">Allo Valentin &middot; Genere le $now &middot; Aucune modification effectuee sur la machine</div>
</body></html>
"@
$rapport = "$ReportDir\Processus-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host "`n  Rapport : $rapport" -ForegroundColor Green
Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (o/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
