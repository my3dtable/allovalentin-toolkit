<#
.SYNOPSIS
    Allo Valentin - Verification avant / apres tweaks
.DESCRIPTION
    Photographie l'etat exact de la machine sur TOUS les points que les tweaks
    peuvent modifier, puis compare pour prouver le retour a l'etat initial.

      -Avant  : photo de reference. A LANCER AVANT d'appliquer les tweaks.
      -Apres  : nouvelle photo + comparaison + rapport HTML de preuve.

    Usage type (aller-retour complet) :
      1. AlloValentin-Verif.ps1 -Avant
      2. AlloValentin-Diagnostic.ps1   -> niveau Extreme
      3. redemarrer, jouer
      4. AlloValentin-Diagnostic.ps1 -Undo
      5. redemarrer
      6. AlloValentin-Verif.ps1 -Apres  -> doit afficher "RETOUR A L'ETAT INITIAL"
.NOTES
    A executer en Administrateur (auto-elevation incluse). PowerShell 5.1.
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
$LogFile = "$LogDir\Verification-$Stamp.log"

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
    Write-Host "    ALLO VALENTIN - Verification avant / apres" -ForegroundColor White
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
    Write-Host ""
}

# ============================================================
#  Lecture d'une valeur de registre (ne leve jamais d'exception)
# ============================================================
function Get-RegVal {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return "(cle absente)" }
    $p = Get-ItemProperty -Path $Path -Name $Name -EA SilentlyContinue
    if ($null -eq $p -or $null -eq $p.PSObject.Properties[$Name]) { return "(absente)" }
    return [string]$p.$Name
}

# Liste fixe des valeurs touchees par les tweaks Gaming + Extreme.
# Fixe volontairement : la photo "Avant" est prise quand aucun manifeste
# n'existe encore, on ne peut donc pas deduire la liste des tweaks appliques.
$CiblesRegistre = @(
    @{Cat="Game DVR / captures"; P='HKCU:\System\GameConfigStore'; N='GameDVR_Enabled'},
    @{Cat="Game DVR / captures"; P='HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; N='AllowGameDVR'},
    @{Cat="Game DVR / captures"; P='HKCU:\System\GameConfigStore'; N='GameDVR_DSEBehavior'},
    @{Cat="Game DVR / captures"; P='HKCU:\System\GameConfigStore'; N='GameDVR_FSEBehaviorMode'},
    @{Cat="Game DVR / captures"; P='HKCU:\System\GameConfigStore'; N='GameDVR_HonorUserFSEBehaviorMode'},
    @{Cat="Interface Windows";   P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; N='VisualFXSetting'},
    @{Cat="Interface Windows";   P='HKCU:\Control Panel\Desktop'; N='MenuShowDelay'},
    @{Cat="Interface Windows";   P='HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'; N='DesktopProcess'},
    @{Cat="GPU / affichage";     P='HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; N='HwSchMode'},
    @{Cat="GPU / affichage";     P='HKLM:\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak'; N='OglShaderCacheSize'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; N='SystemResponsiveness'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N='GPU Priority'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N='Priority'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N='Scheduling Category'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games'; N='SFIO Priority'},
    @{Cat="Ordonnancement CPU";  P='HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'; N='Win32PrioritySeparation'},
    @{Cat="Memoire";             P='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'; N='DisablePagingExecutive'},
    @{Cat="Reseau";              P='HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'; N='NetworkThrottlingIndex'},
    @{Cat="Souris";              P='HKCU:\Control Panel\Mouse'; N='MouseSpeed'},
    @{Cat="Souris";              P='HKCU:\Control Panel\Mouse'; N='MouseThreshold1'},
    @{Cat="Souris";              P='HKCU:\Control Panel\Mouse'; N='MouseThreshold2'}
)

# GUID des reglages d'alimentation. On les lit dans le registre plutot que de
# parser la sortie de powercfg : insensible a la langue de Windows.
$SUB_PROCESSOR = '54533251-82be-4824-96c1-47b60b740d00'
$CPMINCORES    = '0cc5b647-c1df-3f11-8e4f-00d4b93d1d24'
$IDLEDISABLE   = '5d76a2ca-e8c0-402f-a133-2158492d58ad'
$SUB_USB       = '2a737441-1930-4402-8d77-b2bebba308a3'
$USBSELECTIVE  = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'
$NomsSchemas   = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Equilibre'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'Performances elevees'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Economies d energie'
    'e9a42b02-d5df-448d-aa00-03f14749eb61' = 'Performances ultimes'
}

# ============================================================
#  MESURE COMPLETE DE L'ETAT MACHINE
# ============================================================
function Get-EtatMachine {
    $etat = New-Object System.Collections.ArrayList

    function Add-Mesure {
        param([string]$Categorie, [string]$Element, $Valeur)
        $null = $etat.Add([pscustomobject]@{
            Categorie = $Categorie
            Element   = $Element
            Valeur    = [string]$Valeur
        })
    }

    # --- 1. Valeurs de registre ciblees par les tweaks ---
    foreach ($c in $CiblesRegistre) {
        Add-Mesure $c.Cat "$($c.P)\$($c.N)" (Get-RegVal $c.P $c.N)
    }

    # --- 2. Nagle / TCPNoDelay sur chaque interface reseau ---
    $ifs = Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -EA SilentlyContinue
    foreach ($i in $ifs) {
        $p = $i.PSPath -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''
        $p = $p -replace '^HKEY_LOCAL_MACHINE', 'HKLM:'
        foreach ($n in @('TcpAckFrequency','TCPNoDelay')) {
            Add-Mesure "Reseau" "Interface $($i.PSChildName) - $n" (Get-RegVal $p $n)
        }
    }

    # --- 3. MSI Mode (GPU + cartes reseau PCI) ---
    try {
        $pnp = Get-CimInstance Win32_PnPEntity -EA SilentlyContinue |
               Where-Object { $_.PNPDeviceID -like "PCI*" -and
                              ($_.Name -match "Ethernet|GbE|Network|Wi-?Fi|Wireless" -or $_.PNPClass -eq "Display") }
        foreach ($d in $pnp) {
            $msi = "HKLM:\SYSTEM\CurrentControlSet\Enum\$($d.PNPDeviceID)\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties"
            Add-Mesure "MSI Mode" "$($d.Name) - MSISupported" (Get-RegVal $msi 'MSISupported')
        }
    } catch { Write-Log "MSI Mode : $_" "WARN" }

    # --- 4. Services ---
    foreach ($nom in @('SysMain','DiagTrack')) {
        $svc = Get-Service -Name $nom -EA SilentlyContinue
        if ($svc) {
            $wmi = Get-CimInstance Win32_Service -Filter "Name='$nom'" -EA SilentlyContinue
            $dem = if ($wmi) { $wmi.StartMode } else { "?" }
            Add-Mesure "Services" "$nom (demarrage / etat)" "$dem / $($svc.Status)"
        } else {
            Add-Mesure "Services" "$nom (demarrage / etat)" "(service absent)"
        }
    }

    # --- 5. Alimentation ---
    $schemas = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes'
    $actif   = (Get-ItemProperty $schemas -Name ActivePowerScheme -EA SilentlyContinue).ActivePowerScheme
    if ($actif) {
        $nomSchema = if ($NomsSchemas.ContainsKey($actif)) { $NomsSchemas[$actif] } else { "Personnalise" }
        Add-Mesure "Alimentation" "Plan actif" "$nomSchema ($actif)"
        $reglages = @(
            @{G=$CPMINCORES;   L='Core parking - coeurs mini (CPMINCORES)'; Sub=$SUB_PROCESSOR},
            @{G=$IDLEDISABLE;  L='Inactivite CPU desactivee (IDLEDISABLE)'; Sub=$SUB_PROCESSOR},
            @{G=$USBSELECTIVE; L='Suspension selective USB';                Sub=$SUB_USB}
        )
        foreach ($s in $reglages) {
            $k = "$schemas\$actif\$($s.Sub)\$($s.G)"
            Add-Mesure "Alimentation" $s.L (Get-RegVal $k 'ACSettingIndex')
        }
    } else {
        Add-Mesure "Alimentation" "Plan actif" "(illisible)"
    }

    # --- 6. Taches planifiees de telemetrie ---
    $taches = @(
        @{Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='Consolidator'},
        @{Path='\Microsoft\Windows\Customer Experience Improvement Program\'; Name='UsbCeip'},
        @{Path='\Microsoft\Windows\Application Experience\';                  Name='Microsoft Compatibility Appraiser'}
    )
    foreach ($t in $taches) {
        $tache = Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -EA SilentlyContinue
        $v = if ($tache) { [string]$tache.State } else { "(tache absente)" }
        Add-Mesure "Taches planifiees" $t.Name $v
    }

    # --- 7. LSO reseau (par carte physique active) ---
    try {
        Get-NetAdapter -Physical -EA SilentlyContinue | Where-Object { $_.Status -eq "Up" } | ForEach-Object {
            $lso = Get-NetAdapterLso -Name $_.Name -EA SilentlyContinue
            $v = if ($lso) { "IPv4=$($lso.IPv4Enabled)" } else { "(non supporte)" }
            Add-Mesure "Reseau" "LSO - $($_.Name)" $v
        }
    } catch { Write-Log "LSO : $_" "WARN" }

    return $etat.ToArray()
}

# ============================================================
#  MODE INTERACTIF si aucun parametre
# ============================================================
if (-not $Avant -and -not $Apres) {
    Show-Header
    Write-Host "  Que veux-tu faire ?`n" -ForegroundColor White
    Write-Host "    1. " -ForegroundColor Cyan -NoNewline; Write-Host "Photo AVANT (a faire avant d'appliquer les tweaks)" -ForegroundColor White
    Write-Host "    2. " -ForegroundColor Cyan -NoNewline; Write-Host "Photo APRES + comparaison (apres l'Undo et le redemarrage)" -ForegroundColor White
    Write-Host ""
    switch ((Read-Host "  Ton choix").Trim()) {
        "1" { $Avant = $true }
        "2" { $Apres = $true }
        default { Write-Host "`n  Choix invalide." -ForegroundColor Yellow; exit }
    }
}

# ============================================================
#  MODE AVANT : photo de reference
# ============================================================
if ($Avant) {
    Show-Header
    Write-Log "=== Photo AVANT ==="
    Write-Host "  Mesure de l'etat de la machine..." -ForegroundColor Cyan
    $etat = Get-EtatMachine
    $fichier = "$SnapshotDir\Etat-Avant-$Stamp.json"
    ConvertTo-Json -InputObject @($etat) -Depth 4 | Set-Content -Path $fichier -Encoding UTF8

    Write-Host ""
    Write-Log "$($etat.Count) mesures enregistrees." "OK"
    Write-Host "  Photo de reference : " -NoNewline -ForegroundColor Gray
    Write-Host $fichier -ForegroundColor White
    Write-Host ""
    Write-Host "  Prochaine etape :" -ForegroundColor Cyan
    Write-Host "    1. AlloValentin-Diagnostic.ps1  -> niveau Extreme" -ForegroundColor Gray
    Write-Host "    2. Redemarrer, jouer, verifier que tout va bien" -ForegroundColor Gray
    Write-Host "    3. AlloValentin-Diagnostic.ps1 -Undo" -ForegroundColor Gray
    Write-Host "    4. Redemarrer" -ForegroundColor Gray
    Write-Host "    5. AlloValentin-Verif.ps1 -Apres" -ForegroundColor Gray
    Write-Host ""
    Write-Log "=== Fin photo AVANT ==="
    Write-Host "  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# ============================================================
#  MODE APRES : nouvelle photo + comparaison
# ============================================================
Show-Header
Write-Log "=== Photo APRES + comparaison ==="

$ref = Get-ChildItem $SnapshotDir -Filter "Etat-Avant-*.json" -EA SilentlyContinue |
       Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $ref) {
    Write-Host "  Aucune photo AVANT trouvee dans $SnapshotDir" -ForegroundColor Red
    Write-Host "  Lance d'abord : AlloValentin-Verif.ps1 -Avant" -ForegroundColor Yellow
    Write-Log "Aucune photo AVANT : comparaison impossible." "ERROR"
    Write-Host "`n  Appuie sur Entree..." -ForegroundColor DarkGray; Read-Host | Out-Null
    exit
}

# PS 5.1 : "... | ConvertFrom-Json" emet le tableau comme UN SEUL objet.
# On assigne avant d'entourer de @() pour recuperer les vrais elements.
$parsed    = ConvertFrom-Json (Get-Content $ref.FullName -Raw -Encoding UTF8)
$avantEtat = @($parsed)
Write-Log "Photo de reference : $($ref.Name) ($($avantEtat.Count) mesures, $($ref.LastWriteTime))"

Write-Host "  Mesure de l'etat actuel..." -ForegroundColor Cyan
$apresEtat = Get-EtatMachine
ConvertTo-Json -InputObject @($apresEtat) -Depth 4 | Set-Content -Path "$SnapshotDir\Etat-Apres-$Stamp.json" -Encoding UTF8

# --- Comparaison, indexee par Categorie + Element ---
$idxAvant = @{}
foreach ($m in $avantEtat) { $idxAvant["$($m.Categorie)|$($m.Element)"] = $m.Valeur }
$idxApres = @{}
foreach ($m in $apresEtat) { $idxApres["$($m.Categorie)|$($m.Element)"] = $m.Valeur }

$lignes = New-Object System.Collections.ArrayList
foreach ($m in $apresEtat) {
    $cle = "$($m.Categorie)|$($m.Element)"
    if ($idxAvant.ContainsKey($cle)) {
        $va = $idxAvant[$cle]
        $statut = if ($va -eq $m.Valeur) { "IDENTIQUE" } else { "DIFFERENT" }
    } else {
        $va = "(non mesure avant)"
        $statut = "NOUVEAU"
    }
    $null = $lignes.Add([pscustomobject]@{
        Categorie = $m.Categorie; Element = $m.Element
        Avant = $va; Apres = $m.Valeur; Statut = $statut
    })
}
# Elements presents avant mais disparus depuis (materiel debranche, etc.)
foreach ($m in $avantEtat) {
    $cle = "$($m.Categorie)|$($m.Element)"
    if (-not $idxApres.ContainsKey($cle)) {
        $null = $lignes.Add([pscustomobject]@{
            Categorie = $m.Categorie; Element = $m.Element
            Avant = $m.Valeur; Apres = "(disparu)"; Statut = "DISPARU"
        })
    }
}

$ecarts   = @($lignes | Where-Object { $_.Statut -ne "IDENTIQUE" })
$nbOk     = @($lignes | Where-Object { $_.Statut -eq "IDENTIQUE" }).Count
$conforme = ($ecarts.Count -eq 0)

# --- Sortie console ---
Write-Host ""
if ($conforme) {
    Write-Host "  ###############################################" -ForegroundColor Green
    Write-Host "   RETOUR A L'ETAT INITIAL CONFIRME" -ForegroundColor Green
    Write-Host "   $nbOk mesures identiques, aucun ecart." -ForegroundColor Green
    Write-Host "  ###############################################" -ForegroundColor Green
    Write-Log "Conformite totale : $nbOk mesures identiques." "OK"
} else {
    Write-Host "  ###############################################" -ForegroundColor Yellow
    Write-Host "   $($ecarts.Count) ECART(S) DETECTE(S)" -ForegroundColor Yellow
    Write-Host "   $nbOk mesures identiques." -ForegroundColor Gray
    Write-Host "  ###############################################" -ForegroundColor Yellow
    Write-Host ""
    foreach ($e in $ecarts) {
        Write-Host "   [$($e.Statut)] " -ForegroundColor Red -NoNewline
        Write-Host "$($e.Element)" -ForegroundColor White
        Write-Host "      avant : $($e.Avant)" -ForegroundColor Gray
        Write-Host "      apres : $($e.Apres)" -ForegroundColor Yellow
    }
    Write-Log "$($ecarts.Count) ecart(s) detecte(s) apres Undo." "WARN"
}

# --- Rapport HTML ---
$machine = $env:COMPUTERNAME
$now     = Get-Date -Format 'dd/MM/yyyy HH:mm'
$verdictHtml = if ($conforme) {
    "<div class='verdict ok'><div class='vtitre'>Retour a l'etat initial confirme</div><div class='vsub'>$nbOk mesures comparees, aucun ecart. La machine est exactement dans l'etat ou elle etait avant l'intervention.</div></div>"
} else {
    "<div class='verdict bad'><div class='vtitre'>$($ecarts.Count) ecart(s) detecte(s)</div><div class='vsub'>$nbOk mesures identiques. Les points ci-dessous n'ont pas retrouve leur valeur d'origine.</div></div>"
}

$ecartsHtml = if ($ecarts.Count -eq 0) {
    "<div class='card mut'>Aucun ecart. Rien a signaler.</div>"
} else {
    "<div class='card'><table><tr><th>Statut</th><th>Element</th><th>Avant</th><th>Apres</th></tr>" +
    (($ecarts | ForEach-Object {
        "<tr><td class='bad'>$(HtmlEnc $_.Statut)</td><td class='mono'>$(HtmlEnc $_.Element)</td><td>$(HtmlEnc $_.Avant)</td><td class='warn'>$(HtmlEnc $_.Apres)</td></tr>"
    }) -join "`n") + "</table></div>"
}

$detailHtml = ""
foreach ($cat in ($lignes | Select-Object -ExpandProperty Categorie -Unique | Sort-Object)) {
    $rows = ($lignes | Where-Object { $_.Categorie -eq $cat } | ForEach-Object {
        $cls = if ($_.Statut -eq "IDENTIQUE") { "ok" } else { "bad" }
        "<tr><td class='$cls'>$(HtmlEnc $_.Statut)</td><td class='mono'>$(HtmlEnc $_.Element)</td><td>$(HtmlEnc $_.Avant)</td><td>$(HtmlEnc $_.Apres)</td></tr>"
    }) -join "`n"
    $detailHtml += "<h2>$(HtmlEnc $cat)</h2><div class='card'><table><tr><th>Statut</th><th>Element</th><th>Avant</th><th>Apres</th></tr>$rows</table></div>"
}

$html = @"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Verification $machine</title>
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
  .mono{font-family:Consolas,monospace;font-size:11px;color:var(--mut);word-break:break-all;}
  .ok{color:var(--ok);font-weight:600;} .warn{color:var(--warn);font-weight:600;} .bad{color:var(--bad);font-weight:600;} .mut{color:var(--mut);}
  .verdict{border-radius:12px;padding:22px 24px;margin-bottom:8px;border:1px solid var(--line);}
  .verdict.ok{background:rgba(74,222,128,.08);border-color:rgba(74,222,128,.35);}
  .verdict.bad{background:rgba(248,113,113,.08);border-color:rgba(248,113,113,.35);}
  .vtitre{font-size:22px;font-weight:800;} .verdict.ok .vtitre{color:var(--ok);} .verdict.bad .vtitre{color:var(--bad);}
  .vsub{color:var(--mut);font-size:13px;margin-top:6px;}
  .foot{color:var(--mut);font-size:12px;padding:20px 32px;border-top:1px solid var(--line);margin-top:20px;}
</style></head><body>
<div class="header">
  <div class="logo">Allo<span class="u">_</span>Valentin<span class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</span></div>
  <div class="meta">Poste : <b>$machine</b> &middot; $now &middot; Verification avant / apres intervention</div>
</div>
<div class="wrap">
  $verdictHtml
  <h2>Reference</h2>
  <div class="card mut">Photo AVANT : <span class="mono">$(HtmlEnc $ref.Name)</span> du $($ref.LastWriteTime.ToString('dd/MM/yyyy HH:mm')) &middot; $($avantEtat.Count) mesures<br>
  Photo APRES : <span class="mono">Etat-Apres-$Stamp.json</span> &middot; $($apresEtat.Count) mesures</div>
  <h2>Ecarts</h2>
  $ecartsHtml
  $detailHtml
</div>
<div class="foot">Allo Valentin &middot; Rapport de verification genere le $now &middot; Ce document atteste de l'etat de la machine avant et apres intervention.</div>
</body></html>
"@

$rapport = "$ReportDir\Verification-$Stamp.html"
Set-Content -Path $rapport -Value $html -Encoding UTF8
Write-Host ""
Write-Log "Rapport HTML : $rapport" "OK"
Write-Log "=== Fin verification ==="

Write-Host ""
$rep = Read-Host "  Ouvrir le rapport ? (O/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
