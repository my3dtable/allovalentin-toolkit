<#
.SYNOPSIS
    Analyse securite / antivirus - Allo Valentin
.DESCRIPTION
    Outil dedie a la securite, separe du diagnostic principal :
      - Etat de Windows Defender (protection, signatures, date du dernier scan)
      - Menaces detectees et historique de quarantaine
      - Scan rapide Defender (option)
      - MSRT (Malicious Software Removal Tool) rapide (option)
      - Etat pare-feu et Secure Boot
    Genere un rapport HTML brande Allo Valentin.
.PARAMETER ScanRapide
    Lance directement le scan rapide Defender sans demander.
.NOTES
    A executer en Administrateur (auto-elevation incluse).
    Un scan COMPLET peut durer des heures : ce script ne fait que du RAPIDE.
#>

param([switch]$ScanRapide)

# --- Auto-elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement en mode Administrateur..." -ForegroundColor Yellow
    $a = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($ScanRapide) { $a += " -ScanRapide" }
    try { Start-Process powershell.exe -ArgumentList $a -Verb RunAs } catch { Write-Host "Elevation refusee." -ForegroundColor Red }
    exit
}

$AppDir    = "$env:ProgramData\AlloValentin"
$ReportDir = "$AppDir\Reports"
$LogDir    = "$AppDir\Logs"
New-Item -ItemType Directory -Path $ReportDir, $LogDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$LogDir\Securite-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $color = switch ($Level) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"White"} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}
function Confirm-Action { param([string]$Prompt) return ((Read-Host "$Prompt (O/N)") -match '^[OoYy]') }
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "  ALLO VALENTIN - Analyse securite / antivirus" -ForegroundColor Cyan
Write-Host "===============================================`n" -ForegroundColor Cyan
Write-Log "=== Debut analyse securite ==="

# ============================================================
#  1. ETAT DEFENDER
# ============================================================
$secu = @()
$defStatus = $null
try {
    $defStatus = Get-MpComputerStatus -EA SilentlyContinue
    if ($defStatus) {
        $secu += @{ Item="Protection temps reel"; Etat=if($defStatus.RealTimeProtectionEnabled){"Active"}else{"DESACTIVEE"}; Niveau=if($defStatus.RealTimeProtectionEnabled){"ok"}else{"bad"} }
        $secu += @{ Item="Protection anti-malware"; Etat=if($defStatus.AMServiceEnabled){"Active"}else{"Inactive"}; Niveau=if($defStatus.AMServiceEnabled){"ok"}else{"bad"} }
        $secu += @{ Item="Protection cloud"; Etat=if($defStatus.MAPSReporting -ne 0){"Active"}else{"Desactivee"}; Niveau=if($defStatus.MAPSReporting -ne 0){"ok"}else{"warn"} }
        $ageSig = $defStatus.AntivirusSignatureAge
        $secu += @{ Item="Signatures antivirus"; Etat="v$($defStatus.AntivirusSignatureVersion) (il y a $ageSig j)"; Niveau=if($ageSig -le 3){"ok"}elseif($ageSig -le 7){"warn"}else{"bad"} }
        $lastQuick = $defStatus.QuickScanEndTime
        $secu += @{ Item="Dernier scan rapide"; Etat=if($lastQuick){"$lastQuick"}else{"Jamais"}; Niveau=if($lastQuick -and $lastQuick -gt (Get-Date).AddDays(-7)){"ok"}else{"warn"} }
        $lastFull = $defStatus.FullScanEndTime
        $secu += @{ Item="Dernier scan complet"; Etat=if($lastFull){"$lastFull"}else{"Jamais"}; Niveau="mut" }
        Write-Log "Etat Defender recupere." "OK"
    } else {
        $secu += @{ Item="Windows Defender"; Etat="Non disponible (antivirus tiers ?)"; Niveau="warn" }
        Write-Log "Get-MpComputerStatus indisponible (antivirus tiers installe ?)." "WARN"
    }
} catch { Write-Log "Defender : $_" "WARN" }

# Antivirus tiers eventuel
try {
    $av = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName AntiVirusProduct -EA SilentlyContinue
    foreach ($a in $av) {
        if ($a.displayName -notmatch "Defender") {
            $secu += @{ Item="Antivirus tiers : $($a.displayName)"; Etat="Detecte"; Niveau="ok" }
        }
    }
} catch {}

# Pare-feu + Secure Boot
try {
    Get-NetFirewallProfile -EA SilentlyContinue | ForEach-Object {
        $secu += @{ Item="Pare-feu $($_.Name)"; Etat=if($_.Enabled){"Actif"}else{"DESACTIVE"}; Niveau=if($_.Enabled){"ok"}else{"bad"} }
    }
} catch {}
try {
    $sb = Confirm-SecureBootUEFI -EA SilentlyContinue
    $secu += @{ Item="Secure Boot"; Etat=if($sb){"Active"}else{"Desactive"}; Niveau=if($sb){"ok"}else{"warn"} }
} catch {}

# ============================================================
#  2. HISTORIQUE DES MENACES (quarantaine + detections)
# ============================================================
Write-Log "Recherche des menaces detectees..."
$menaces = @()
try {
    $threats = Get-MpThreatDetection -EA SilentlyContinue | Sort-Object InitialDetectionTime -Descending | Select-Object -First 20
    foreach ($t in $threats) {
        $nom = try { (Get-MpThreat -ThreatID $t.ThreatID -EA SilentlyContinue).ThreatName } catch { "ID $($t.ThreatID)" }
        $menaces += [PSCustomObject]@{
            Date = $t.InitialDetectionTime
            Nom  = if($nom){$nom}else{"Menace $($t.ThreatID)"}
            Action = switch ($t.ThreatStatusID) { 2{"Mise en quarantaine"} 3{"Supprimee"} 6{"Nettoyee"} default{"Detectee (statut $($t.ThreatStatusID))"} }
        }
    }
    Write-Log "$($menaces.Count) detection(s) dans l'historique." "OK"
} catch { Write-Log "Historique menaces : $_" "WARN" }

# ============================================================
#  3. SCAN RAPIDE (option)
# ============================================================
$scanResultat = "Non lance"
$faireScan = $ScanRapide
if (-not $ScanRapide) {
    Write-Host "`nUn scan rapide Defender prend generalement 1 a 5 minutes." -ForegroundColor Gray
    $faireScan = Confirm-Action "Lancer un scan rapide Defender maintenant ?"
}
if ($faireScan -and $defStatus) {
    Write-Host "`n>> Scan rapide en cours... (patiente, ca peut prendre quelques minutes)" -ForegroundColor Cyan
    Write-Log "Lancement scan rapide Defender..."
    try {
        Start-MpScan -ScanType QuickScan -EA Stop
        # Relit l'etat apres scan
        $apres = Get-MpComputerStatus -EA SilentlyContinue
        $nbApres = @(Get-MpThreatDetection -EA SilentlyContinue).Count
        $scanResultat = "Termine le $(Get-Date -Format 'HH:mm') - $nbApres detection(s) au total dans l'historique"
        Write-Log "Scan rapide termine." "OK"
    } catch { $scanResultat = "Erreur : $_"; Write-Log "Scan : $_" "ERROR" }
}

# ============================================================
#  4. MSRT (Malicious Software Removal Tool) - option
# ============================================================
$msrtResultat = "Non lance"
if ($faireScan) {   # on ne propose MSRT que si l'utilisateur veut deja scanner
    Write-Host "`nMSRT est l'outil Microsoft anti-malware (deja lance chaque mois par Windows Update)." -ForegroundColor Gray
    if (Confirm-Action "Lancer aussi un scan MSRT rapide ?") {
        Write-Host ">> MSRT en cours..." -ForegroundColor Cyan
        Write-Log "Lancement MSRT (mrt.exe /Q scan rapide)..."
        try {
            # /Q = silencieux ; on lance un scan et on attend
            Start-Process "mrt.exe" -ArgumentList "/Q" -Wait -EA Stop
            $msrtResultat = "Termine le $(Get-Date -Format 'HH:mm')"
            Write-Log "MSRT termine." "OK"
        } catch { $msrtResultat = "Erreur ou indisponible : $_"; Write-Log "MSRT : $_" "WARN" }
    }
}

# ============================================================
#  RAPPORT HTML
# ============================================================
Write-Log "Generation du rapport securite..."
$reportFile = "$ReportDir\Securite-$Stamp.html"
$now = Get-Date -Format 'dddd dd MMMM yyyy - HH:mm'
$machine = $env:COMPUTERNAME

$secuRows = ($secu | ForEach-Object { "<tr><td>$(HtmlEnc $_.Item)</td><td class='$($_.Niveau)'>$(HtmlEnc $_.Etat)</td></tr>" }) -join "`n"
$menaceRows = if($menaces){($menaces | ForEach-Object { "<tr><td>$($_.Date)</td><td>$(HtmlEnc $_.Nom)</td><td>$(HtmlEnc $_.Action)</td></tr>" }) -join "`n"}else{"<tr><td colspan='3'><span class='ok'>Aucune menace dans l'historique</span></td></tr>"}

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Securite $machine</title>
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
  .grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:12px;}
  .kv{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:14px 16px;}
  .kv .k{color:var(--mut);font-size:12px;} .kv .v{font-size:15px;font-weight:700;margin-top:2px;}
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;overflow-x:auto;}
  table{width:100%;border-collapse:collapse;font-size:13px;} th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);}
  th{color:var(--mut);font-weight:600;}
  .ok{color:var(--ok);font-weight:600;} .warn{color:var(--warn);font-weight:600;} .bad{color:var(--bad);font-weight:600;} .mut{color:var(--mut);}
  .note{background:rgba(226,59,59,.08);border:1px solid rgba(226,59,59,.3);border-radius:8px;padding:12px 14px;font-size:13px;color:#f3b0b0;margin-top:12px;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Analyse securite</div>
</div>
<div class="wrap">

  <h2>Etat de la protection</h2>
  <div class="card"><table><tr><th>Element</th><th>Etat</th></tr>$secuRows</table></div>

  <h2>Scans effectues</h2>
  <div class="grid">
    <div class="kv"><div class="k">Scan rapide Defender</div><div class="v">$scanResultat</div></div>
    <div class="kv"><div class="k">MSRT (Microsoft)</div><div class="v">$msrtResultat</div></div>
  </div>

  <h2>Historique des menaces</h2>
  <div class="card">
    <table><tr><th>Date</th><th>Menace</th><th>Action</th></tr>$menaceRows</table>
    <div class="note">Les menaces "en quarantaine" ou "supprimees" ont deja ete neutralisees par Defender. Une entree ici n'est pas une infection active : c'est la preuve que la protection a fait son travail.</div>
  </div>

</div>
<div class="foot">Genere par Allo Valentin &middot; Maintenance &amp; Support Informatique &middot; Log : $LogFile</div>
</body></html>
"@

$html | Out-File -FilePath $reportFile -Encoding UTF8
Write-Log "Rapport genere : $reportFile" "OK"
Write-Log "=== Fin analyse securite ==="
Start-Process $reportFile

Write-Host "`nAnalyse terminee. Rapport ouvert dans le navigateur." -ForegroundColor Green
Write-Host "Appuie sur Entree pour fermer..." -ForegroundColor Gray; Read-Host
