<#
.SYNOPSIS
    Lanceur Allo Valentin - Panneau de choix
.DESCRIPTION
    Point d'entree unique. 6 rubriques :
      1. Diagnostic & optimisation   (rapport seul / optimiser 3 niveaux / rapide / annuler)
      2. Preuve avant / apres        (Verif + Perf, dans l'ordre du protocole)
      3. Analyses lecture seule      (fluidite / securite / configs de jeux)
      4. Carte mere / BIOS / XMP     (XMP, reboot UEFI, appli constructeur)
      5. Tout mettre a jour          (Windows Update + pilotes via catalogue Microsoft + chipset)
      6. Compte-rendu client         (diagnostic -> compte-rendu grand public + devis)
    Les scripts doivent etre dans le MEME dossier que ce lanceur.
.NOTES
    A executer en Administrateur (auto-elevation incluse).
#>

param(
    [string]$Cle = ""   # cle d'intervention : transmise aux outils, jamais laissee sur disque
)

$base        = Split-Path -Parent $PSCommandPath

# Cle d'intervention : le lanceur web (opti.ps1) la depose dans cle.txt le temps
# de passer l'elevation. On la lit une fois, on la garde en memoire, et on
# supprime le fichier tout de suite : rien ne reste en clair sur la machine.
if (-not $Cle) {
    $cleFichier = Join-Path $base "cle.txt"
    if (Test-Path $cleFichier) {
        try { $Cle = ([string](Get-Content $cleFichier -Raw -ErrorAction Stop)).Trim() } catch {}
        Remove-Item $cleFichier -Force -ErrorAction SilentlyContinue
    }
}

# --- Auto-elevation ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $relance = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Cle) { $relance += " -Cle `"$Cle`"" }
    try { Start-Process powershell.exe -ArgumentList $relance -Verb RunAs } catch {}
    exit
}
$scriptDiag  = Join-Path $base "AlloValentin-Diagnostic.ps1"
$scriptSecu  = Join-Path $base "AlloValentin-Securite.ps1"
$scriptVerif = Join-Path $base "AlloValentin-Verif.ps1"
$scriptPerf  = Join-Path $base "AlloValentin-Perf.ps1"
$scriptFluid = Join-Path $base "AlloValentin-Fluidite.ps1"
$scriptCarte = Join-Path $base "AlloValentin-CarteMere.ps1"
$scriptJeux  = Join-Path $base "AlloValentin-Jeux.ps1"
$scriptRapport = Join-Path $base "AlloValentin-RapportClient.ps1"

# Argument cle a passer aux outils qui en ont besoin (optimisation, compte-rendu IA)
$argCle = @(); if ($Cle) { $argCle = @('-Cle', $Cle) }

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host "        _    _ _        __     __    _            _   _       " -ForegroundColor White
    Write-Host "       / \  | | | ___   \ \   / /_ _| | ___ _ __ | |_(_)_ __  " -ForegroundColor White
    Write-Host "      / _ \ | | |/ _ \   \ \ / / _\` | |/ _ \ '_ \| __| | '_ \ " -ForegroundColor White
    Write-Host "     / ___ \| | | (_) |   \ V / (_| | |  __/ | | | |_| | | | |" -ForegroundColor White
    Write-Host "    /_/   \_\_|_|\___/     \_/ \__,_|_|\___|_| |_|\__|_|_| |_|" -ForegroundColor White
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host "        MAINTENANCE & SUPPORT INFORMATIQUE" -ForegroundColor Gray
    Write-Host "  ===============================================" -ForegroundColor Red
    Write-Host ""
}

function Invoke-Outil {
    param([string]$Path, [string]$Nom, [string[]]$ScriptArgs = @())
    if (-not (Test-Path $Path)) {
        Write-Host "`n  [ERREUR] $Nom introuvable :" -ForegroundColor Red
        Write-Host "           $Path" -ForegroundColor DarkGray
        Write-Host "  Les scripts doivent etre dans le meme dossier que ce menu." -ForegroundColor Yellow
    } else {
        Write-Host "`n  Lancement : $Nom..." -ForegroundColor Green
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Path @ScriptArgs
    }
    Write-Host "`n  Retour au menu. Appuie sur Entree..." -ForegroundColor Gray; Read-Host | Out-Null
}

function Sous-Menu {
    param([string]$Titre, [hashtable]$Choix)  # Choix : cle -> @{ Label; Action(scriptblock) }
    Show-Header
    Write-Host "  $Titre`n" -ForegroundColor White
    foreach ($k in ($Choix.Keys | Sort-Object)) {
        Write-Host "    $k. " -ForegroundColor Cyan -NoNewline; Write-Host $Choix[$k].Label -ForegroundColor White
    }
    Write-Host "    R. " -ForegroundColor Cyan -NoNewline; Write-Host "Retour" -ForegroundColor White
    Write-Host ""
    $c = (Read-Host "  Ton choix").ToUpper().Trim()
    if ($c -eq 'R') { return }
    if ($Choix.ContainsKey($c)) { & $Choix[$c].Action }
    else { Write-Host "`n  Choix invalide." -ForegroundColor Yellow; Start-Sleep 1 }
}

# ============================================================
#  BOUCLE PRINCIPALE
# ============================================================
$continuer = $true
try {
while ($continuer) {
    Show-Header
    Write-Host "  Que veux-tu faire ?`n" -ForegroundColor White
    Write-Host "    1. " -ForegroundColor Cyan -NoNewline; Write-Host "Diagnostic & optimisation" -ForegroundColor White
    Write-Host "       (rapport seul, ou tweaks 3 niveaux, ou annuler)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    2. " -ForegroundColor Cyan -NoNewline; Write-Host "Preuve avant / apres" -ForegroundColor White
    Write-Host "       (etat machine + gain chiffre : retour a l'etat initial et perfs)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    3. " -ForegroundColor Cyan -NoNewline; Write-Host "Analyses (lecture seule)" -ForegroundColor White
    Write-Host "       (fluidite / FPS, securite / antivirus, configs de jeux)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    4. " -ForegroundColor Cyan -NoNewline; Write-Host "Carte mere / BIOS / XMP" -ForegroundColor White
    Write-Host "       (XMP, ReBAR, Turbo, reboot direct UEFI, appli constructeur ventilo/RGB)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    5. " -ForegroundColor Cyan -NoNewline; Write-Host "Tout mettre a jour" -ForegroundColor White
    Write-Host "       (Windows Update + tous les pilotes via le catalogue Microsoft + chipset)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    6. " -ForegroundColor Cyan -NoNewline; Write-Host "Compte-rendu client" -ForegroundColor White
    Write-Host "       (transforme le dernier diagnostic en compte-rendu clair pour le client + devis)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    Q. " -ForegroundColor Cyan -NoNewline; Write-Host "Quitter" -ForegroundColor White
    Write-Host ""
    $choix = (Read-Host "  Ton choix").ToUpper().Trim()

    switch ($choix) {
        "1" {
            Sous-Menu "Diagnostic & optimisation" @{
                "1" = @{ Label = "Rapport seul (ne modifie rien)"
                         Action = { Invoke-Outil $scriptDiag "Rapport seul" @('-ReportOnly') } }
                "2" = @{ Label = "Optimiser (tweaks - 3 niveaux : FAIBLE / GAMING / EXTREME)"
                         Action = { Invoke-Outil $scriptDiag "Diagnostic & optimisation" $argCle } }
                "3" = @{ Label = "Optimiser en mode RAPIDE (saute sfc/DISM : < 1 min au lieu de 3-8)"
                         Action = { Invoke-Outil $scriptDiag "Diagnostic rapide" (@('-Fast') + $argCle) } }
                "4" = @{ Label = "Annuler l'optimisation (Undo)"
                         Action = { Invoke-Outil $scriptDiag "Annulation (Undo)" @('-Undo') } }
            }
        }
        "2" {
            Sous-Menu "Preuve avant / apres  (suivre l'ordre du protocole)" @{
                "1" = @{ Label = "AVANT  - etat machine + perfs  (avant les tweaks)"
                         Action = { Invoke-Outil $scriptVerif "Verif -Avant" @('-Avant'); Invoke-Outil $scriptPerf "Perf -Avant" @('-Avant') } }
                "2" = @{ Label = "Perf APRES  (a faire AVANT l'Undo)"
                         Action = { Invoke-Outil $scriptPerf "Perf -Apres" @('-Apres') } }
                "3" = @{ Label = "Verif APRES  (a faire APRES l'Undo - verdict retour etat initial)"
                         Action = { Invoke-Outil $scriptVerif "Verif -Apres" @('-Apres') } }
            }
        }
        "3" {
            Sous-Menu "Analyses (lecture seule)" @{
                "1" = @{ Label = "Fluidite / FPS  (ecran, RAM/XMP, PCIe, jeux sur HDD, reseau, overlays... 25 controles)"
                         Action = { Invoke-Outil $scriptFluid "Analyse de fluidite" } }
                "2" = @{ Label = "Securite / antivirus  (etat Defender, scan rapide, quarantaine)"
                         Action = { Invoke-Outil $scriptSecu "Analyse securite" } }
                "3" = @{ Label = "Configs de jeux  (VSync force, super-sampling, pas de frame cap...)"
                         Action = { Invoke-Outil $scriptJeux "Analyse des configs de jeux" } }
            }
        }
        "4" {
            Invoke-Outil $scriptCarte "Carte mere / BIOS / XMP"
        }
        "5" {
            Invoke-Outil $scriptCarte "Tout mettre a jour" @('-Mode','MAJ')
        }
        "6" {
            Sous-Menu "Compte-rendu client" @{
                "1" = @{ Label = "Generer (langage client, avec devis)"
                         Action = { Invoke-Outil $scriptRapport "Compte-rendu client" (@('-Devis','-Ouvrir') + $argCle) } }
                "2" = @{ Label = "Generer sans devis"
                         Action = { Invoke-Outil $scriptRapport "Compte-rendu client" (@('-Ouvrir') + $argCle) } }
            }
        }
        "Q" { $continuer = $false }
        default {
            Write-Host "`n  Choix invalide. Tape 1 a 6, ou Q." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}
}
finally {
    # Ne jamais laisser la cle d'intervention sur la machine.
    $cf = Join-Path $base "cle.txt"
    if (Test-Path $cf) { Remove-Item $cf -Force -ErrorAction SilentlyContinue }
}

Show-Header
Write-Host "  A bientot !" -ForegroundColor Green
Write-Host ""
Start-Sleep -Seconds 1
