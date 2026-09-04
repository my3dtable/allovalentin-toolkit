<#
.SYNOPSIS
    Allo Valentin - Analyse des configs de jeux (LECTURE SEULE)
.DESCRIPTION
    Ne MODIFIE aucun fichier de jeu (risque anti-cheat, ecrasement, non reversible).
    Lit les fichiers de config connus et signale les reglages qui plombent les FPS :
      - VSync force dans la config
      - Motion blur active
      - Resolution scale / super-sampling au-dessus de 100 %
      - Resolution interne superieure au bureau
      - Aucune limite d'images sur un ecran haut rafraichissement

    Le placement des jeux (SSD vs HDD) est traite par l'analyse de Fluidite.

    Produit un rapport HTML dans C:\ProgramData\AlloValentin\Reports\.
.NOTES
    PowerShell 5.1. Pas d'elevation requise (lecture seule). Sans accents.
#>

$AppDir    = "$env:ProgramData\AlloValentin"
$ReportDir = "$AppDir\Reports"
$LogDir    = "$AppDir\Logs"
New-Item -ItemType Directory -Path $ReportDir, $LogDir -Force | Out-Null
$Stamp   = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogFile = "$LogDir\Jeux-$Stamp.log"
Add-Type -AssemblyName System.Web -EA SilentlyContinue
function HtmlEnc { param($s) if ($null -eq $s) { return "" }; [System.Web.HttpUtility]::HtmlEncode([string]$s) }
function Log {
    param([string]$m, [string]$lvl = "INFO")
    $line = "[$(Get-Date -Format 'HH:mm:ss')] [$lvl] $m"
    $c = switch ($lvl) { "OK"{"Green"} "WARN"{"Yellow"} "TITRE"{"Cyan"} default{"Gray"} }
    Write-Host $line -ForegroundColor $c
    Add-Content -Path $LogFile -Value $line
}

Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "    ALLO VALENTIN - CONFIGS DE JEUX (lecture seule)" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host ""

# --- Ecran : resolution + rafraichissement ---
$scrW = 0; $scrH = 0; $hz = 0
try {
    $vm = Get-CimInstance Win32_VideoController -EA SilentlyContinue | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
    $scrW = [int]$vm.CurrentHorizontalResolution; $scrH = [int]$vm.CurrentVerticalResolution; $hz = [int]$vm.CurrentRefreshRate
} catch {}
if ($scrW) { Log "Ecran : ${scrW}x${scrH} a $hz Hz" }

# --- Jeux installes (pour le contexte) ---
$jeux = @()
foreach ($vdf in @("${env:ProgramFiles(x86)}\Steam\steamapps\libraryfolders.vdf", "${env:ProgramFiles}\Steam\steamapps\libraryfolders.vdf")) {
    if (-not (Test-Path $vdf)) { continue }
    $libs = ([regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' })
    foreach ($lib in $libs) {
        $sa = Join-Path $lib "steamapps"
        Get-ChildItem $sa -Filter "appmanifest_*.acf" -EA SilentlyContinue | ForEach-Object {
            $c = Get-Content $_.FullName -Raw
            if ($c -match '"name"\s+"([^"]+)"') { $jeux += $Matches[1] }
        }
    }
}
if ($jeux.Count) { Log "$($jeux.Count) jeu(x) Steam detecte(s) : $((@($jeux) | Select-Object -First 8) -join ', ')$(if ($jeux.Count -gt 8) { '...' })" }
else { Log "Aucun jeu Steam detecte (ou Steam absent)." "WARN" }

# --- Fichiers de config a scanner : GameUserSettings.ini (Unreal, tres repandu)
#     + quelques configs connues. On ignore les dossiers moteur/templates. ---
$roots = @(
    [IO.Path]::Combine([Environment]::GetFolderPath('MyDocuments'), 'My Games'),
    "$env:LOCALAPPDATA",
    "$env:USERPROFILE\Saved Games"
) | Where-Object { Test-Path $_ }
$ignore = 'CoalescedSourceConfigs|\\Engine\\|\\Templates\\|\\Intermediate\\|DefaultGame|BaseGame|\\Plugins\\'

$cfgFiles = @()
foreach ($r in $roots) {
    $cfgFiles += Get-ChildItem $r -Recurse -Depth 6 -Filter 'GameUserSettings.ini' -File -EA SilentlyContinue
}
$cfgFiles = $cfgFiles | Where-Object { $_.FullName -notmatch $ignore -and $_.Length -lt 256KB } | Sort-Object FullName -Unique | Select-Object -First 60
Log "$($cfgFiles.Count) fichier(s) GameUserSettings.ini a analyser."

function Get-JeuNom {
    param([string]$Path)
    $p = $Path -replace '\\', '/'
    if ($p -match '/My Games/([^/]+)/')                                { return $Matches[1] }
    if ($p -match '/LocalLow/[^/]+/([^/]+)/')                          { return $Matches[1] }
    if ($p -match '/([^/]+)/Saved/Config/')                            { return $Matches[1] }
    if ($p -match '/AppData/Local/([^/]+)/Saved/')                     { return $Matches[1] }
    return (Split-Path (Split-Path (Split-Path $Path -Parent) -Parent) -Leaf)
}

# --- Analyse : un constat par (jeu, type) au maximum ---
$constats = New-Object System.Collections.ArrayList
$vus = @{}
function Add-Constat {
    param([string]$Jeu, [string]$Type, [string]$Fichier, [string]$Probleme, [string]$Action)
    $k = "$Jeu|$Type"
    if ($vus.ContainsKey($k)) { return }
    $vus[$k] = $true
    $null = $constats.Add([pscustomobject]@{ Jeu = $Jeu; Fichier = $Fichier; Probleme = $Probleme; Action = $Action })
}

foreach ($f in $cfgFiles) {
    $txt = Get-Content $f.FullName -Raw -EA SilentlyContinue
    if (-not $txt) { continue }
    # ne traiter que les vrais fichiers de reglages video
    if ($txt -notmatch '(?im)ResolutionSizeX|sg\.|FullscreenMode|bUseVSync') { continue }
    $jeu = Get-JeuNom $f.FullName

    if ($txt -match '(?im)^\s*bUseVSync\s*=\s*True') {
        Add-Constat $jeu 'vsync' $f.Name "VSync activee : ajoute de la latence (input lag) et peut plafonner les FPS." "Desactiver la VSync dans les options video. Preferer une limite d'images ~3 sous la frequence ecran, ou G-Sync/FreeSync si dispo."
    }
    if ($txt -match '(?im)^\s*bMotionBlur\s*=\s*True' -or $txt -match '(?im)MotionBlurAmount\s*=\s*(0*[1-9])') {
        Add-Constat $jeu 'blur' $f.Name "Motion blur active : cout GPU + flou en mouvement." "Le couper dans les options video."
    }
    $rqm = [regex]::Match($txt, '(?im)^\s*sg\.ResolutionQuality\s*=\s*([\d.]+)')
    if ($rqm.Success -and [double]$rqm.Groups[1].Value -gt 100) {
        Add-Constat $jeu 'resscale' $f.Name "Echelle de resolution a $([int][double]$rqm.Groups[1].Value) % : rendu interne plus grand que l'ecran, tres couteux." "Remettre l'echelle de resolution a 100 % dans les options."
    }
    $mx = [regex]::Match($txt, '(?im)^\s*ResolutionSizeX\s*=\s*(\d+)')
    if ($mx.Success -and $scrW -gt 0 -and [int]$mx.Groups[1].Value -gt $scrW) {
        Add-Constat $jeu 'resint' $f.Name "Resolution interne $($mx.Groups[1].Value)px alors que l'ecran fait ${scrW}px : super-sampling." "Regler la resolution du jeu sur ${scrW}x${scrH}."
    }
    if ($hz -ge 144) {
        $fr = [regex]::Match($txt, '(?im)^\s*FrameRateLimit\s*=\s*([\d.]+)')
        if (-not $fr.Success -or [double]$fr.Groups[1].Value -le 0) {
            Add-Constat $jeu 'nocap' $f.Name "Pas de limite d'images (ecran $hz Hz) : GPU/CPU a 100 %, chauffe, coil whine, frametimes moins stables." "Fixer une limite a ~$($hz-3) FPS (jeu, pilote NVIDIA, ou RTSS)."
        }
    }
}

Write-Host ""
if ($constats.Count -eq 0) {
    Log "Aucun reglage problematique detecte dans les GameUserSettings lus." "OK"
} else {
    Log "$($constats.Count) point(s) releve(s) sur $(@($constats.Jeu | Sort-Object -Unique).Count) jeu(x) :" "WARN"
    $constats | ForEach-Object { Write-Host "   - [$($_.Jeu)] $($_.Probleme)" -ForegroundColor Yellow }
}
Log "Rappel : le plus gros levier FPS reste les reglages IN-GAME (ombres, foliage, RT, textures)." "INFO"
Log "Le placement SSD/HDD des jeux est traite par l'analyse de Fluidite (menu 3 > 1)." "INFO"

# --- Rapport HTML ---
$rows = ($constats | ForEach-Object {
    "<tr><td>$(HtmlEnc $_.Jeu)</td><td>$(HtmlEnc $_.Fichier)</td><td>$(HtmlEnc $_.Probleme)</td><td>$(HtmlEnc $_.Action)</td></tr>"
}) -join "`n"
$rapport = "$ReportDir\Jeux-$Stamp.html"
@"
<!DOCTYPE html><html lang="fr"><head><meta charset="UTF-8"><title>Allo Valentin - Configs de jeux</title>
<style>body{margin:0;font-family:'Segoe UI',system-ui,sans-serif;background:#1b1e24;color:#f2f3f5;line-height:1.5}
.h{background:linear-gradient(160deg,#2b2f37,#1b1e24);padding:32px;border-bottom:1px solid #3a3f4a}
.l{font-size:30px;font-weight:800}.l span{color:#e23b3b}.wrap{padding:24px 32px;max-width:1100px}
.m{color:#9aa1ac;font-size:13px;margin-top:10px}
table{border-collapse:collapse;width:100%;margin-top:14px;font-size:13px}
th,td{border:1px solid #3a3f4a;padding:9px 11px;text-align:left;vertical-align:top}
th{background:#2b2f37;color:#9aa1ac;text-transform:uppercase;font-size:11px;letter-spacing:.06em}
.ok{background:rgba(74,222,128,.08);border:1px solid rgba(74,222,128,.3);border-radius:10px;padding:14px 16px;margin-top:14px}
.foot{color:#9aa1ac;font-size:12px;padding:20px 32px;border-top:1px solid #3a3f4a;margin-top:20px}</style></head><body>
<div class="h"><div class="l">Allo<span>_</span>Valentin</div>
<div class="m">Configs de jeux &middot; $env:COMPUTERNAME &middot; $(Get-Date -Format 'dd/MM/yyyy HH:mm') &middot; lecture seule, aucun fichier modifie</div></div>
<div class="wrap">
<p class="m">Ecran : ${scrW}x${scrH} a $hz Hz &middot; $($jeux.Count) jeu(x) Steam &middot; $($cfgFiles.Count) config(s) analysee(s)</p>
$(if ($constats.Count -eq 0) { "<div class='ok'>Aucun reglage problematique detecte dans les fichiers de config lus. Les leviers restants sont dans les menus in-game.</div>" } else {
"<table><tr><th>Jeu</th><th>Fichier</th><th>Probleme</th><th>Quoi faire (dans le jeu, PAS dans le fichier)</th></tr>$rows</table>" })
<p class="m">Le placement SSD/HDD des jeux : voir l'analyse de Fluidite. Rien n'a ete ecrit par cet outil.</p>
</div><div class="foot">Allo Valentin &middot; genere le $(Get-Date -Format 'dd/MM/yyyy HH:mm') &middot; lecture seule</div></body></html>
"@ | Out-File -FilePath $rapport -Encoding UTF8
Log "Rapport : $rapport" "OK"

$rep = Read-Host "`n  Ouvrir le rapport ? (O/N)"
if ($rep -match '^[OoYy]') { Start-Process $rapport }
Write-Host "`n  Appuie sur Entree pour fermer..." -ForegroundColor DarkGray
try { Read-Host | Out-Null } catch {}
