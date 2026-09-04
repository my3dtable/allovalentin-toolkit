<#
.SYNOPSIS
    Allo Valentin - Preuve de gain chiffree (avant / apres optimisation)
.DESCRIPTION
    Mesure ce que le client RESSENT, avant et apres l'intervention, et produit
    un rapport chiffre : temps de demarrage, programmes au demarrage, ressources
    au repos, espace disque recupere, debit disque.

      -Avant  : mesure de reference. A LANCER AVANT l'optimisation.
      -Apres  : nouvelle mesure + comparaison + rapport HTML de gain.

    Usage type :
      1. AlloValentin-Perf.ps1 -Avant        (idealement juste apres un demarrage)
      2. AlloValentin-Diagnostic.ps1         (nettoyage + optimisation)
      3. Redemarrer
      4. AlloValentin-Perf.ps1 -Apres        (idealement au meme moment du cycle)

    A ne pas confondre avec AlloValentin-Verif.ps1 :
      Verif  = "la machine est-elle revenue a l'etat initial ?"  (on veut IDENTIQUE)
      Perf   = "qu'est-ce que l'intervention a apporte ?"        (on veut MIEUX)
.NOTES
    A executer en Administrateur (auto-elevation incluse). PowerShell 5.1.
    Le temps de demarrage vient du journal Diagnostics-Performance (admin requis).
#>

param(
    [switch]$Avant,
    [switch]$Apres
)

# --- Auto-elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Droits administrateur requis. Relancement en mode Administrateur..." -ForegroundColor Yellow
    $argList = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Avant) { $argList += " -Avant" }
    if ($Apres) { $argList += " -Apres" }
    try { Start-Process powershell.exe -ArgumentList $argList -Verb RunAs }
    catch { Write-Host "Elevation refusee. Le script a besoin des droits admin." -ForegroundColor Red }
    exit
}

$AppDir      = "$env:ProgramData\AlloValentin"
$SnapshotDir = "$AppDir\Snapshots"
$ReportDir   = "$AppDir\Reports"
$LogDir      = "$AppDir\Logs"
New-Item -ItemType Directory -Path $SnapshotDir, $ReportDir, $LogDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$LogDir\Performance-$Stamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    $color = switch ($Level) { "OK"{"Green"} "WARN"{"Yellow"} "ERROR"{"Red"} default{"White"} }
    Write-Host $line -ForegroundColor $color
    Add-Content -Path $LogFile -Value $line
}
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue
function HtmlEnc { param($s) if($null -eq $s){return ""}; return ([System.Web.HttpUtility]::HtmlEncode([string]$s)) }

function Show-Header {
    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host "    ALLO VALENTIN - Preuve de gain chiffree" -ForegroundColor White
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================
#  COLLECTE DES MESURES
# ============================================================
# Sens : 'bas'  = plus petit c'est mieux
#        'haut' = plus grand c'est mieux
#        'info' = affiche mais jamais compte comme gain/perte
function Get-MesuresPerf {
    $m = New-Object System.Collections.ArrayList
    # Seuil = ecart en dessous duquel on considere que c'est du bruit de mesure.
    # 3 % convient aux compteurs stables (programmes, processus, espace disque).
    # Le benchmark disque, lui, varie naturellement de +/- 10 % d'une execution a
    # l'autre : sans seuil propre, chaque rapport afficherait un faux RECUL.
    function Add-M {
        param([string]$Groupe, [string]$Libelle, $Valeur, [string]$Unite, [string]$Sens, [int]$Dec = 0, [double]$Seuil = 3.0)
        $null = $m.Add([pscustomobject]@{
            Groupe = $Groupe; Libelle = $Libelle
            Valeur = $(if ($null -eq $Valeur) { $null } else { [double]$Valeur })
            Texte  = $null
            Unite  = $Unite; Sens = $Sens; Dec = $Dec; Seuil = $Seuil
        })
    }
    function Add-Info {
        param([string]$Groupe, [string]$Libelle, [string]$Texte)
        $null = $m.Add([pscustomobject]@{
            Groupe = $Groupe; Libelle = $Libelle
            Valeur = $null; Texte = $Texte
            Unite = ""; Sens = "texte"; Dec = 0; Seuil = 0.0
        })
    }

    # --- Demarrage : journal Diagnostics-Performance, evenement 100 ---
    Write-Host "  - temps de demarrage..." -ForegroundColor DarkGray
    try {
        $evt = Get-WinEvent -LogName 'Microsoft-Windows-Diagnostics-Performance/Operational' `
                            -FilterXPath "*[System[(EventID=100)]]" -MaxEvents 1 -EA Stop
        $xml = [xml]$evt.ToXml()
        function Get-EvtData {
            param([string]$Nom)
            $d = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $Nom }
            if ($d) { return [double]$d.'#text' }
            return $null
        }
        $bt  = Get-EvtData 'BootTime'
        $mp  = Get-EvtData 'MainPathBootTime'
        $pb  = Get-EvtData 'BootPostBootTime'
        if ($null -ne $bt) { Add-M "Demarrage" "Demarrage complet"            ($bt/1000) "s" "bas" 1 }
        if ($null -ne $mp) { Add-M "Demarrage" "Jusqu'a l'ouverture du bureau" ($mp/1000) "s" "bas" 1 }
        if ($null -ne $pb) { Add-M "Demarrage" "Finition apres le bureau"      ($pb/1000) "s" "bas" 1 }
        # Horodatage : sert a detecter l'absence de redemarrage entre les 2 mesures
        Add-Info "Demarrage" "Demarrage mesure le" $evt.TimeCreated.ToString('dd/MM/yyyy HH:mm:ss')
        Write-Log "Temps de demarrage lu (evenement 100 du $($evt.TimeCreated))." "OK"
    } catch {
        Write-Log "Temps de demarrage indisponible : $($_.Exception.Message)" "WARN"
        Add-Info "Demarrage" "Temps de demarrage" "(journal Diagnostics-Performance illisible)"
    }

    # --- Programmes lances au demarrage ---
    Write-Host "  - programmes au demarrage..." -ForegroundColor DarkGray
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
        if (Test-Path $f) {
            $nbDem += @(Get-ChildItem $f -File -EA SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count
        }
    }
    Add-M "Demarrage" "Programmes lances au demarrage" $nbDem "" "bas" 0

    # --- Ressources ---
    Write-Host "  - ressources..." -ForegroundColor DarkGray
    $os = Get-CimInstance Win32_OperatingSystem
    $ramTotGo  = $os.TotalVisibleMemorySize / 1MB
    $ramLibGo  = $os.FreePhysicalMemory / 1MB
    Add-M "Ressources" "Memoire utilisee"          ($ramTotGo - $ramLibGo) "Go" "bas" 1
    Add-M "Ressources" "Processus en cours"        (@(Get-Process -EA SilentlyContinue).Count) "" "bas" 0
    Add-M "Ressources" "Services en fonctionnement" (@(Get-Service -EA SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count) "" "bas" 0

    # Uptime : sert a prevenir si les 2 mesures ne sont pas comparables
    $up = (Get-Date) - $os.LastBootUpTime
    Add-M "Ressources" "Allume depuis" ([math]::Round($up.TotalHours,1)) "h" "info" 1

    # --- Disque systeme ---
    Write-Host "  - espace disque..." -ForegroundColor DarkGray
    $sys = $env:SystemDrive
    $vol = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -EA SilentlyContinue
    if ($vol) {
        Add-M "Disque" "Espace libre ($sys)" ($vol.FreeSpace/1GB) "Go" "haut" 1
    }

    Write-Host "  - debit disque (50 Mo)..." -ForegroundColor DarkGray
    try {
        # Meme methode que le Diagnostic : ecriture WriteThrough puis lecture en bloc
        $testFile = "$env:TEMP\avperf_bench.tmp"
        $data = New-Object byte[] (50MB); (New-Object Random).NextBytes($data)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $fs = [System.IO.File]::Create($testFile, 1MB, [System.IO.FileOptions]::WriteThrough)
        $fs.Write($data, 0, $data.Length); $fs.Flush($true); $fs.Close()
        $sw.Stop(); $writeMs = [math]::Max($sw.ElapsedMilliseconds,1)
        $sw.Restart()
        $read = [System.IO.File]::ReadAllBytes($testFile)
        $sw.Stop(); $readMs = [math]::Max($sw.ElapsedMilliseconds,1)
        $read = $null
        Remove-Item $testFile -Force -EA SilentlyContinue
        Add-M "Disque" "Debit en ecriture" (50 / ($writeMs/1000)) "Mo/s" "haut" 0 15.0
        Add-M "Disque" "Debit en lecture"  (50 / ($readMs/1000))  "Mo/s" "haut" 0 15.0
    } catch { Write-Log "Benchmark disque : $_" "WARN" }

    return $m.ToArray()
}

# ============================================================
#  MODE INTERACTIF si aucun parametre
# ============================================================
if (-not $Avant -and -not $Apres) {
    Show-Header
    Write-Host "  Que veux-tu faire ?`n" -ForegroundColor White
    Write-Host "    1. " -ForegroundColor Cyan -NoNewline; Write-Host "Mesure AVANT (a faire avant l'optimisation)" -ForegroundColor White
    Write-Host "    2. " -ForegroundColor Cyan -NoNewline; Write-Host "Mesure APRES + rapport de gain" -ForegroundColor White
    Write-Host ""
    switch ((Read-Host "  Ton choix").Trim()) {
        "1" { $Avant = $true }
        "2" { $Apres = $true }
        default { Write-Host "`n  Choix invalide." -ForegroundColor Yellow; exit }
    }
}

# ============================================================
#  MODE AVANT
# ============================================================
if ($Avant) {
    Show-Header
    Write-Log "=== Mesure AVANT ==="
    $mes = Get-MesuresPerf
    $fichier = "$SnapshotDir\Perf-Avant-$Stamp.json"
    ConvertTo-Json -InputObject @($mes) -Depth 4 | Set-Content -Path $fichier -Encoding UTF8
    Write-Host ""
    Write-Log "$($mes.Count) mesures enregistrees." "OK"
    Write-Host "  Reference : " -NoNewline -ForegroundColor Gray
    Write-Host $fichier -ForegroundColor White
    Write-Host ""
    Write-Host "  Valeurs relevees :" -ForegroundColor Cyan
    foreach ($x in $mes) {
        if ($x.Sens -eq 'texte') { "    {0,-34} {1}" -f $x.Libelle, $x.Texte | Write-Host -ForegroundColor Gray }
        else { "    {0,-34} {1} {2}" -f $x.Libelle, [math]::Round($x.Valeur, $x.Dec), $x.Unite | Write-Host -ForegroundColor Gray }
    }
    Write-Host ""
    Write-Host "  Prochaine etape : optimiser, REDEMARRER, puis AlloValentin-Perf.ps1 -Apres" -ForegroundColor Cyan
    Write-Log "=== Fin mesure AVANT ==="
    Write-Host "`n  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# ============================================================
#  MODE APRES : comparaison
# ============================================================
Show-Header
Write-Log "=== Mesure APRES + comparaison ==="

$ref = Get-ChildItem $SnapshotDir -Filter "Perf-Avant-*.json" -EA SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $ref) {
    Write-Host "  Aucune mesure AVANT trouvee dans $SnapshotDir" -ForegroundColor Red
    Write-Host "  Lance d'abord : AlloValentin-Perf.ps1 -Avant" -ForegroundColor Yellow
    Write-Log "Aucune mesure AVANT : comparaison impossible." "ERROR"
    Write-Host "`n  Appuie sur Entree..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# PS 5.1 : "... | ConvertFrom-Json" emet le tableau comme UN SEUL objet.
$parsed    = ConvertFrom-Json (Get-Content $ref.FullName -Raw -Encoding UTF8)
$avantMes  = @($parsed)
Write-Log "Reference : $($ref.Name) ($($avantMes.Count) mesures, $($ref.LastWriteTime))"

$apresMes = Get-MesuresPerf
ConvertTo-Json -InputObject @($apresMes) -Depth 4 | Set-Content -Path "$SnapshotDir\Perf-Apres-$Stamp.json" -Encoding UTF8

$idxAvant = @{}
foreach ($x in $avantMes) { $idxAvant["$($x.Groupe)|$($x.Libelle)"] = $x }

$comp = New-Object System.Collections.ArrayList
foreach ($a in $apresMes) {
    $cle = "$($a.Groupe)|$($a.Libelle)"
    $av  = $idxAvant[$cle]

    $ligne = [pscustomobject]@{
        Groupe = $a.Groupe; Libelle = $a.Libelle; Unite = $a.Unite; Sens = $a.Sens; Dec = $a.Dec
        Avant = $null; Apres = $null; AvantTxt = ""; ApresTxt = ""
        Pct = $null; Verdict = "NON COMPARABLE"
    }

    if ($a.Sens -eq 'texte') {
        $ligne.ApresTxt = $a.Texte
        $ligne.AvantTxt = $(if ($av) { $av.Texte } else { "(non mesure)" })
        $ligne.Verdict  = "INFO"
    }
    elseif ($null -ne $av -and $null -ne $av.Valeur -and $null -ne $a.Valeur) {
        $ligne.Avant = [double]$av.Valeur
        $ligne.Apres = [double]$a.Valeur
        $ligne.AvantTxt = "$([math]::Round($ligne.Avant, $a.Dec)) $($a.Unite)".Trim()
        $ligne.ApresTxt = "$([math]::Round($ligne.Apres, $a.Dec)) $($a.Unite)".Trim()
        if ($a.Sens -eq 'info') {
            $ligne.Verdict = "INFO"
        } else {
            $diff = $ligne.Apres - $ligne.Avant
            $ligne.Pct = $(if ($ligne.Avant -ne 0) { ($diff / [math]::Abs($ligne.Avant)) * 100 } else { $null })
            $ampleur = $(if ($null -ne $ligne.Pct) { [math]::Abs($ligne.Pct) } else { 0 })
            # Seuil propre a la mesure (les anciens releves n'en ont pas : on retombe sur 3 %)
            $seuil = $(if ($null -ne $a.PSObject.Properties['Seuil'] -and $null -ne $a.Seuil) { [double]$a.Seuil } else { 3.0 })
            if ($ampleur -lt $seuil) { $ligne.Verdict = "STABLE" }
            elseif (($a.Sens -eq 'bas' -and $diff -lt 0) -or ($a.Sens -eq 'haut' -and $diff -gt 0)) { $ligne.Verdict = "GAIN" }
            else { $ligne.Verdict = "RECUL" }
        }
    }
    else {
        $ligne.ApresTxt = $(if ($null -ne $a.Valeur) { "$([math]::Round($a.Valeur, $a.Dec)) $($a.Unite)".Trim() } else { "(non mesure)" })
        $ligne.AvantTxt = "(non mesure)"
    }
    $null = $comp.Add($ligne)
}

$gains  = @($comp | Where-Object { $_.Verdict -eq "GAIN" }  | Sort-Object { -[math]::Abs($_.Pct) })
$reculs = @($comp | Where-Object { $_.Verdict -eq "RECUL" } | Sort-Object { -[math]::Abs($_.Pct) })

# --- Avertissements d'honnetete sur la comparabilite ---
$avertissements = @()
$btAvant = $avantMes | Where-Object { $_.Libelle -eq "Demarrage mesure le" } | Select-Object -First 1
$btApres = $apresMes | Where-Object { $_.Libelle -eq "Demarrage mesure le" } | Select-Object -First 1
if ($btAvant -and $btApres -and $btAvant.Texte -eq $btApres.Texte) {
    $avertissements += "La machine n'a pas redemarre entre les deux mesures : le temps de demarrage est forcement identique. Redemarre puis relance -Apres."
}
$upA = $avantMes | Where-Object { $_.Libelle -eq "Allume depuis" } | Select-Object -First 1
$upB = $apresMes | Where-Object { $_.Libelle -eq "Allume depuis" } | Select-Object -First 1
if ($upA -and $upB -and $null -ne $upA.Valeur -and $null -ne $upB.Valeur) {
    if ([math]::Abs([double]$upB.Valeur - [double]$upA.Valeur) -gt 4) {
        $avertissements += "Les deux mesures n'ont pas ete prises au meme moment du cycle (allume depuis $([math]::Round($upA.Valeur,1)) h contre $([math]::Round($upB.Valeur,1)) h). Memoire et processus sont donc peu comparables."
    }
}

# --- Sortie console ---
Write-Host ""
Write-Host "  ###############################################" -ForegroundColor Cyan
Write-Host "   $($gains.Count) gain(s), $($reculs.Count) recul(s)" -ForegroundColor Cyan
Write-Host "  ###############################################" -ForegroundColor Cyan
Write-Host ""
foreach ($l in $comp) {
    $couleur = switch ($l.Verdict) { "GAIN"{"Green"} "RECUL"{"Red"} "STABLE"{"Gray"} default{"DarkGray"} }
    $pct = $(if ($null -ne $l.Pct) { "  ({0:+0.0;-0.0;0}%)" -f $l.Pct } else { "" })
    Write-Host ("   {0,-34} {1,14}  ->  {2,-14}{3}" -f $l.Libelle, $l.AvantTxt, $l.ApresTxt, $pct) -ForegroundColor $couleur
}
if ($avertissements.Count) {
    Write-Host ""
    foreach ($a in $avertissements) { Write-Host "   [!] $a" -ForegroundColor Yellow; Write-Log $a "WARN" }
}
Write-Log "$($gains.Count) gain(s), $($reculs.Count) recul(s)." "OK"

# --- Rapport HTML ---
$machine = $env:COMPUTERNAME
$now     = Get-Date -Format 'dd/MM/yyyy HH:mm'

$cartes = ""
foreach ($g in ($gains | Select-Object -First 3)) {
    $cartes += "<div class='gcard'><div class='glib'>$(HtmlEnc $g.Libelle)</div>" +
               "<div class='gval'>$(HtmlEnc $g.AvantTxt) <span class='fleche'>&rarr;</span> <b>$(HtmlEnc $g.ApresTxt)</b></div>" +
               "<div class='gpct'>$('{0:+0.0;-0.0;0}' -f $g.Pct) %</div></div>"
}
if (-not $cartes) { $cartes = "<div class='card mut'>Aucun gain significatif mesure.</div>" }

$avertHtml = ""
if ($avertissements.Count) {
    $avertHtml = "<div class='note'>" + (($avertissements | ForEach-Object { "&#9888; $(HtmlEnc $_)" }) -join "<br>") + "</div>"
}

$detail = ""
foreach ($grp in ($comp | Select-Object -ExpandProperty Groupe -Unique)) {
    $rows = ($comp | Where-Object { $_.Groupe -eq $grp } | ForEach-Object {
        $cls = switch ($_.Verdict) { "GAIN"{"ok"} "RECUL"{"bad"} "STABLE"{"mut"} default{"mut"} }
        $pct = $(if ($null -ne $_.Pct) { "{0:+0.0;-0.0;0} %" -f $_.Pct } else { "" })
        "<tr><td>$(HtmlEnc $_.Libelle)</td><td>$(HtmlEnc $_.AvantTxt)</td><td><b>$(HtmlEnc $_.ApresTxt)</b></td><td class='$cls'>$(HtmlEnc $pct)</td><td class='$cls'>$(HtmlEnc $_.Verdict)</td></tr>"
    }) -join "`n"
    $detail += "<h2>$(HtmlEnc $grp)</h2><div class='card'><table><tr><th>Mesure</th><th>Avant</th><th>Apres</th><th>Ecart</th><th>Verdict</th></tr>$rows</table></div>"
}

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Gains $machine</title>
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
  .card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px;overflow-x:auto;}
  table{width:100%;border-collapse:collapse;font-size:13px;} th,td{text-align:left;padding:7px 10px;border-bottom:1px solid var(--line);vertical-align:top;}
  th{color:var(--mut);font-weight:600;}
  .ok{color:var(--ok);font-weight:600;} .warn{color:var(--warn);font-weight:600;} .bad{color:var(--bad);font-weight:600;} .mut{color:var(--mut);}
  .gwrap{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px;}
  .gcard{background:rgba(74,222,128,.07);border:1px solid rgba(74,222,128,.32);border-radius:12px;padding:18px 20px;}
  .glib{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.06em;}
  .gval{font-size:19px;font-weight:700;margin-top:6px;} .gval b{color:var(--ok);} .fleche{color:var(--mut);margin:0 4px;}
  .gpct{color:var(--ok);font-size:26px;font-weight:800;margin-top:4px;}
  .note{background:rgba(251,191,36,.08);border:1px solid rgba(251,191,36,.32);border-radius:8px;padding:12px 14px;font-size:13px;color:#f5d78e;margin-top:14px;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Bilan avant / apres intervention</div>
</div>
<div class="wrap">
  <h2>Principaux gains</h2>
  <div class="gwrap">$cartes</div>
  $avertHtml
  $detail
  <h2>Comment lire ce rapport</h2>
  <div class="card mut">Un ecart trop faible pour etre significatif est note STABLE : le seuil est de 3 % pour les compteurs stables, et de 15 % pour le debit disque, qui varie naturellement d'une mesure a l'autre.
  Le temps de demarrage provient du journal de performances de Windows : il correspond au demarrage reel le plus recent, pas a une estimation.
  Memoire et processus dependent de ce qui etait ouvert au moment de la mesure : ils ne sont comparables que si les deux releves ont ete faits au meme moment du cycle d'utilisation.</div>
</div>
<div class="foot">Allo Valentin &middot; Bilan genere le $now &middot; Mesure de reference : $(HtmlEnc $ref.Name) du $($ref.LastWriteTime.ToString('dd/MM/yyyy HH:mm'))</div>
</body></html>
"@

$rapport = "$ReportDir\Gains-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host ""
Write-Log "Rapport HTML : $rapport" "OK"
Write-Log "=== Fin comparaison ==="

Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (O/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
