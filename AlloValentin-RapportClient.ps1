<#
.SYNOPSIS
    Allo Valentin - Compte-rendu client (marketing / remise en main propre)
.DESCRIPTION
    Transforme les resultats techniques du diagnostic en un compte-rendu clair
    pour le CLIENT (langage grand public, rassurant, avec le benefice concret).

    Source de donnees (aucune collecte nouvelle, on relit ce qui existe deja) :
      - le dernier Diagnostic-*.html      (constats, materiel, recommandations)
      - Perf-Avant / Perf-Apres .json     (mesures avant / apres)
      - Etat-Apres .json                  (optimisations reellement appliquees)

    Redaction :
      - si un serveur Ollama repond (local ou via une adresse https)  -> texte redige par le modele
      - sinon                                                          -> modele de texte a trous (deterministe)
    Dans les deux cas, AUCUN chiffre n'est invente : le modele ne fait que reformuler.

.PARAMETER AppDir      Dossier de donnees Allo Valentin (defaut C:\ProgramData\AlloValentin).
                       Pointer ailleurs si on relit le dossier copie d'un client.
.PARAMETER Source      Chemin d'un Diagnostic-*.html precis. Defaut : le plus recent trouve.
.PARAMETER Client      Nom du client (entete du compte-rendu).
.PARAMETER Technicien  Nom du technicien (defaut : Allo Valentin).
.PARAMETER OllamaUrl   URL du serveur Ollama. Defaut http://localhost:11434
                       Exemple distant : https://ia.mondomaine.fr
.PARAMETER Model       Modele Ollama. Defaut llama3.2 (rapide). Meilleur francais : qwen2.5:7b
.PARAMETER Token       Jeton Bearer si l'API est derriere un proxy d'authentification.
.PARAMETER NoAI        Force le modele de texte a trous, meme si Ollama repond.
.PARAMETER Devis       Ajoute une section devis pre-remplie (cellules modifiables dans le navigateur).
.PARAMETER TauxHoraire Taux horaire pour le devis (defaut 50).
.PARAMETER Ouvrir      Ouvre le compte-rendu dans le navigateur a la fin.
.NOTES
    Ce script tourne sur TA machine ou sur celle du client. Il ne modifie rien.
    ASCII uniquement (convention du projet).
#>

param(
    [string]$AppDir     = "$env:ProgramData\AlloValentin",
    [string]$Source     = "",
    [string]$Client     = "",
    [string]$Technicien = "Allo Valentin",
    [string]$OllamaUrl  = "http://localhost:11434",
    [string]$Model      = "llama3.2",
    [string]$Token      = "",
    [switch]$NoAI,
    [switch]$Devis,
    [int]$TauxHoraire   = 50,
    [switch]$Ouvrir
)

$ErrorActionPreference = "Stop"
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Config par defaut de la passerelle IA distante : ia-client.json a cote du script
#   { "OllamaUrl": "https://ia.allovalentin.fr", "Token": "...", "Model": "qwen2.5:7b" }
# Les parametres passes en ligne de commande restent prioritaires.
$cfgFile = Join-Path $PSScriptRoot "ia-client.json"
if ((Test-Path $cfgFile) -and -not $NoAI) {
    try {
        $c = Get-Content $cfgFile -Raw | ConvertFrom-Json
        if ($OllamaUrl -eq "http://localhost:11434" -and $c.OllamaUrl) { $OllamaUrl = $c.OllamaUrl }
        if (-not $Token -and $c.Token) { $Token = $c.Token }
        if ($Model -eq "llama3.2" -and $c.Model) { $Model = $c.Model }
    } catch {}
}

# Pas de ia-client.json : passerelle IA via la cle d'intervention (cle.txt).
# Le jeton Ollama n'est jamais depose ici : on passe par le relais
# allovalentin.fr/api/ia qui echange la cle contre le vrai jeton, cote serveur.
$script:ViaRelais = $false
if (-not $Token -and -not $NoAI -and $OllamaUrl -eq "http://localhost:11434") {
    $cleI = ""
    foreach ($p in @((Join-Path $PSScriptRoot "cle.txt"),
                     (Join-Path $env:LOCALAPPDATA "AlloValentin-Toolkit\cle.txt"))) {
        if (Test-Path $p) {
            try { $cleI = ([string](Get-Content $p -Raw)).Trim() } catch {}
            if ($cleI) { break }
        }
    }
    if ($cleI) {
        $OllamaUrl = "https://allovalentin.fr/api/ia"
        $Token     = $cleI
        if ($Model -eq "llama3.2") { $Model = "qwen2.5:7b" }
        $script:ViaRelais = $true
    }
}

$ReportDir   = Join-Path $AppDir "Reports"
$SnapshotDir = Join-Path $AppDir "Snapshots"
$OutDir      = Join-Path $AppDir "Rapports-Client"
$stamp       = Get-Date -Format "yyyyMMdd-HHmmss"

function Info  { param($m) Write-Host "  $m" -ForegroundColor Gray }
function Ok    { param($m) Write-Host "  $m" -ForegroundColor Green }
function Warn  { param($m) Write-Host "  $m" -ForegroundColor Yellow }
function Stop2 { param($m) Write-Host "`n  [ARRET] $m`n" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------------
#  Helpers texte
# ------------------------------------------------------------------
function To-Ascii {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    try {
        $d = $s.Normalize([Text.NormalizationForm]::FormD)
        $sb = New-Object Text.StringBuilder
        foreach ($c in $d.ToCharArray()) {
            if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
                [void]$sb.Append($c)
            }
        }
        return $sb.ToString().Normalize([Text.NormalizationForm]::FormC)
    } catch { return $s }
}

function Strip-Html {
    param([string]$s)
    if ([string]::IsNullOrEmpty($s)) { return "" }
    $s = $s -replace '<[^>]+>', ' '
    # mojibake UTF-8 double-encode le plus courant -> lettre simple
    $s = $s -replace '&#195;&#169;','e' -replace '&#195;&#168;','e' -replace '&#195;&#170;','e' -replace '&#195;&#171;','e'
    $s = $s -replace '&#195;&#160;','a' -replace '&#195;&#162;','a' -replace '&#195;&#167;','c'
    $s = $s -replace '&#195;&#174;','i' -replace '&#195;&#175;','i' -replace '&#195;&#180;','o'
    $s = $s -replace '&#195;&#187;','u' -replace '&#195;&#185;','u' -replace '&#194;&#160;',' '
    # entites nommees / numeriques usuelles
    $s = $s -replace '&#9888;?','' -replace '&#39;',"'" -replace '&#8217;',"'" -replace '&rsquo;',"'"
    $s = $s -replace '&middot;','-' -replace '&nbsp;',' ' -replace '&#8211;','-' -replace '&#8212;','-'
    $s = $s -replace '&#8230;','...' -replace '&laquo;','"' -replace '&raquo;','"'
    $s = $s -replace '&quot;','"' -replace '&gt;','>' -replace '&lt;','<' -replace '&amp;','&'
    $s = To-Ascii $s
    $s = ($s -replace '\s+', ' ').Trim()
    return $s
}

function Html-Enc {
    param([string]$s)
    if ($null -eq $s) { return "" }
    $s = [string]$s
    $s = $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;' -replace "'",'&#39;'
    return $s
}

function Get-Section {
    param([string]$Html, [string]$Marker)
    $i = $Html.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase)
    if ($i -lt 0) { return "" }
    $start = $Html.IndexOf('</h2>', $i)
    if ($start -lt 0) { $start = $i } else { $start += 5 }
    $end = $Html.IndexOf('<h2', $start)
    if ($end -lt 0) { $end = $Html.Length }
    return $Html.Substring($start, $end - $start)
}

# ------------------------------------------------------------------
#  1. Retrouver le diagnostic source
# ------------------------------------------------------------------
Write-Host ""
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host "     ALLO VALENTIN - COMPTE-RENDU CLIENT" -ForegroundColor White
Write-Host "  ===============================================" -ForegroundColor Red
Write-Host ""

if (-not $Source) {
    if (-not (Test-Path $ReportDir)) { Stop2 "Dossier introuvable : $ReportDir" }
    $cand = Get-ChildItem $ReportDir -Filter "Diagnostic-*.html" -EA SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $cand) { Stop2 "Aucun Diagnostic-*.html dans $ReportDir. Lance d'abord le diagnostic." }
    $Source = $cand.FullName
}
if (-not (Test-Path $Source)) { Stop2 "Fichier source introuvable : $Source" }
Info "Source        : $(Split-Path $Source -Leaf)"

$html = Get-Content $Source -Raw -Encoding UTF8

# ------------------------------------------------------------------
#  2. Extraire les faits du diagnostic
# ------------------------------------------------------------------
$fait = [ordered]@{
    Machine = "poste"; Date = ""; Niveau = ""
    CPU = ""; CM = ""; RAM = ""; GPU = ""; Windows = ""; BIOS = ""; Reseau = ""
    Alertes = @(); Constats = @(); Tweaks = @()
    NettoyageGo = 0; PlusGrosDossier = ""; MajWindows = 0
}

if ($html -match 'Poste\s*:\s*<b>([^<]+)</b>')          { $fait.Machine = (Strip-Html $Matches[1]) }
if ($html -match '</b>\s*&middot;\s*(.+?)\s*&middot;\s*Diagnostic') { $fait.Date = (Strip-Html $Matches[1]) }
if ($html -match 'Niveau\s*:\s*<b>([^<]+)</b>')         { $fait.Niveau = (Strip-Html $Matches[1]) }

$secMat = Get-Section $html "Synthese materiel"
foreach ($m in [regex]::Matches($secMat, '<div class="kv"><div class="k">([^<]+)</div><div class="v">(.*?)</div></div>', 'Singleline')) {
    $k = (Strip-Html $m.Groups[1].Value); $v = (Strip-Html $m.Groups[2].Value)
    switch -Wildcard ($k) {
        "Processeur*" { $fait.CPU = $v }
        "Carte mere*" { $fait.CM  = $v }
        "Memoire*"    { $fait.RAM = $v }
        "Windows*"    { $fait.Windows = $v }
        "BIOS*"       { $fait.BIOS = $v }
        "Reseau*"     { $fait.Reseau = $v }
    }
}
if ($html -match '(NVIDIA GeForce[^<,"]+|AMD Radeon[^<,"]+|Intel Arc[^<,"]+|Intel\(R\) (?:UHD|Iris)[^<,"]+)') {
    $fait.GPU = (Strip-Html $Matches[1])
}

# alertes prioritaires
foreach ($m in [regex]::Matches($html, "<div class='alertline'>(.*?)</div>", 'Singleline')) {
    $t = Strip-Html $m.Groups[1].Value
    if ($t) { $fait.Alertes += $t }
}

# cartes d'analyse (severite / titre / constat / action)
$rxCard = "<div class='diagcard diag(p1|p2|p3)[^']*'>" +
          "<div class='diaghead'><span class='diagbadge'>([^<]+)</span>\s*(.*?)</div>" +
          "<div class='diagconstat'>(.*?)</div>" +
          "<div class='diagaction'>(.*?)</div>"
foreach ($m in [regex]::Matches($html, $rxCard, 'Singleline')) {
    $fait.Constats += [pscustomobject]@{
        Prio    = @{ p1='critique'; p2='important'; p3='mineur' }[$m.Groups[1].Value]
        Badge   = (Strip-Html $m.Groups[2].Value)
        Titre   = (Strip-Html $m.Groups[3].Value)
        Constat = (Strip-Html $m.Groups[4].Value)
        Action  = (Strip-Html ($m.Groups[5].Value -replace '<b>Action\s*:</b>',''))
    }
}

# tweaks appliques
$secTw = Get-Section $html "Tweaks gaming appliques"
foreach ($m in [regex]::Matches($secTw, '<tr[^>]*>\s*<td[^>]*>(.*?)</td>', 'Singleline')) {
    $t = Strip-Html $m.Groups[1].Value
    if ($t -and $t -notmatch '^(Cle|Element|Reglage|Nom)$') { $fait.Tweaks += $t }
}

# nettoyage : plus gros nombre de Go dans la section "Recuperer de l'espace"
$secClean = Get-Section $html "Recuperer de l'espace"
if (-not $secClean) { $secClean = Get-Section $html "Nettoyage" }
$goMax = 0.0
foreach ($m in [regex]::Matches($secClean, '([0-9]+(?:[.,][0-9]+)?)\s*(Go|Mo)')) {
    $val = [double]($m.Groups[1].Value -replace ',', '.')
    if ($m.Groups[2].Value -eq 'Mo') { $val = $val / 1024 }
    if ($val -gt $goMax) { $goMax = $val }
}
$fait.NettoyageGo = [math]::Round($goMax, 1)

# plus gros dossier
$secPlace = Get-Section $html "Ou est passee la place"
if ($secPlace -match '<td[^>]*>(.*?)</td>\s*<td[^>]*>([0-9.,]+\s*Go)') {
    $fait.PlusGrosDossier = ((Strip-Html $Matches[1]) + " (" + (Strip-Html $Matches[2]) + ")")
}

# maj windows en attente
$secMaj = Get-Section $html "Mises a jour Windows en attente"
$fait.MajWindows = ([regex]::Matches($secMaj, '<tr')).Count
if ($fait.MajWindows -gt 0) { $fait.MajWindows -= 1 }  # entete
if ($fait.MajWindows -lt 0) { $fait.MajWindows = 0 }

Info "Machine       : $($fait.Machine)  ($($fait.Niveau))"
Info "Constats      : $($fait.Constats.Count)   Optimisations : $($fait.Tweaks.Count)"

# ------------------------------------------------------------------
#  3. Mesures avant / apres
# ------------------------------------------------------------------
function Load-Snap {
    param([string]$Filtre)
    $f = Get-ChildItem $SnapshotDir -Filter $Filtre -EA SilentlyContinue |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return @() }
    try {
        $j = Get-Content $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = @()
        foreach ($e in $j) { $out += $e }
        return ,$out
    } catch { return @() }
}

$mesures = @()
$snapAv = Load-Snap "Perf-Avant-*.json"
$snapAp = Load-Snap "Perf-Apres-*.json"
if (@($snapAv).Count -ge 1 -and @($snapAp).Count -ge 1) {
    $garde = @('Demarrage complet','Programmes lances au demarrage','Memoire utilisee',
               'Processus en cours','Services en fonctionnement','Espace libre (C:)')
    foreach ($lib in $garde) {
        $a = $snapAv | Where-Object { $_.Libelle -eq $lib } | Select-Object -First 1
        $b = $snapAp | Where-Object { $_.Libelle -eq $lib } | Select-Object -First 1
        if ($a -and $b -and $a.Valeur -ne $null -and $b.Valeur -ne $null) {
            $va = [double]$a.Valeur; $vb = [double]$b.Valeur
            $delta = [math]::Round($vb - $va, [int]$a.Dec)
            $mieux = if ($a.Sens -eq 'haut') { $vb -gt $va } elseif ($a.Sens -eq 'bas') { $vb -lt $va } else { $null }
            $mesures += [pscustomobject]@{
                Libelle = $lib; Unite = [string]$a.Unite
                Avant = [math]::Round($va, [int]$a.Dec)
                Apres = [math]::Round($vb, [int]$a.Dec)
                Delta = $delta; Mieux = $mieux
            }
        }
    }
    Info "Mesures av/ap : $($mesures.Count) indicateurs"
} else {
    Info "Mesures av/ap : aucune (pas de Perf-Avant/Apres)"
}

# ------------------------------------------------------------------
#  4. Contexte compact pour la redaction
# ------------------------------------------------------------------
$nCrit = @($fait.Constats | Where-Object { $_.Prio -eq 'critique' }).Count
$nImp  = @($fait.Constats | Where-Object { $_.Prio -eq 'important' }).Count
$nMin  = @($fait.Constats | Where-Object { $_.Prio -eq 'mineur' }).Count

$ctx = New-Object Text.StringBuilder
[void]$ctx.AppendLine("Machine: $($fait.Machine) | Niveau: $($fait.Niveau) | Date: $($fait.Date)")
[void]$ctx.AppendLine("Materiel: CPU=$($fait.CPU); Carte mere=$($fait.CM); RAM=$($fait.RAM); GPU=$($fait.GPU); Windows=$($fait.Windows); BIOS=$($fait.BIOS); Reseau=$($fait.Reseau)")
if ($fait.Alertes.Count) {
    [void]$ctx.AppendLine("Alertes prioritaires:")
    foreach ($a in $fait.Alertes) { [void]$ctx.AppendLine(" - $a") }
}
[void]$ctx.AppendLine("Constats ($nCrit critique, $nImp important, $nMin mineur):")
foreach ($c in $fait.Constats) {
    [void]$ctx.AppendLine(" - [$($c.Prio)] $($c.Titre) : $($c.Constat) => action prevue: $($c.Action)")
}
if ($fait.Tweaks.Count) {
    [void]$ctx.AppendLine("Optimisations appliquees ($($fait.Tweaks.Count)): " + (($fait.Tweaks | Select-Object -First 20) -join '; '))
}
if ($fait.NettoyageGo -gt 0)      { [void]$ctx.AppendLine("Nettoyage possible/effectue: environ $($fait.NettoyageGo) Go de fichiers jetables") }
if ($fait.MajWindows -gt 0)       { [void]$ctx.AppendLine("Mises a jour Windows en attente: $($fait.MajWindows)") }
if ($fait.PlusGrosDossier)        { [void]$ctx.AppendLine("Plus gros dossier du disque: $($fait.PlusGrosDossier)") }
foreach ($m in $mesures) {
    [void]$ctx.AppendLine("Mesure $($m.Libelle): $($m.Avant) $($m.Unite) -> $($m.Apres) $($m.Unite)")
}
$contexte = $ctx.ToString()

# ------------------------------------------------------------------
#  5. Redaction : Ollama si dispo, sinon modele a trous
# ------------------------------------------------------------------
$headers = @{}
if ($Token) { $headers['Authorization'] = "Bearer $Token" }

function Test-Ollama {
    try {
        $r = Invoke-RestMethod -Uri "$OllamaUrl/api/tags" -Headers $headers -TimeoutSec 6
        return @{ Ok = $true; Models = @($r.models.name) }
    } catch { return @{ Ok = $false; Err = $_.Exception.Message } }
}

# L'IA ne REDIGE pas le compte-rendu : elle REFORMULE, phrase par phrase, la version
# deterministe deja produite par Redaction-Trous. Meme nombre d'elements, aucune info
# ajoutee, aucune promesse de resultat, aucun chiffre nouveau. Si le modele s'ecarte
# (nombre d'elements different), on garde la version deterministe.
function Polish-Ollama {
    param($Base)

    $entree = @{
        resume          = [string]$Base.resume
        constats        = @($Base.constats | ForEach-Object { [string]$_.texte })
        actions_faites  = @($Base.actions_faites | ForEach-Object { [string]$_ })
        recommandations = @($Base.recommandations | ForEach-Object { [string]$_ })
    } | ConvertTo-Json -Depth 5

    $prompt = @"
Tu es assistant de redaction pour un depanneur informatique. On te donne un compte-rendu
client deja ecrit, en JSON. Tu REECRIS chaque texte dans un francais plus clair, simple et
courtois pour un particulier non technique.

REGLES ABSOLUES :
- Garde EXACTEMENT le meme nombre d'elements dans chaque liste, dans le meme ordre.
- N'ajoute AUCUNE information, AUCUN chiffre, AUCUN nom de materiel qui n'est pas deja present.
- N'ecris AUCUNE promesse de resultat ou de gain (pas de "vous gagnerez", "plus rapide garanti").
- Reste factuel. Pas de superlatifs commerciaux.
- Ecris SANS accents.
- Reponds STRICTEMENT avec le meme schema JSON, rien d'autre.

COMPTE-RENDU A REECRIRE :
$entree
"@
    $payload = @{
        model  = $Model
        prompt = $prompt
        stream = $false
        format = "json"
        options = @{ temperature = 0.15 }
    } | ConvertTo-Json -Depth 5

    $r = Invoke-RestMethod -Uri "$OllamaUrl/api/generate" -Method Post -Body $payload `
         -ContentType "application/json" -Headers $headers -TimeoutSec 240
    $txt = [string]$r.response
    $i = $txt.IndexOf('{'); $j = $txt.LastIndexOf('}')
    if ($i -ge 0 -and $j -gt $i) { $txt = $txt.Substring($i, $j - $i + 1) }
    $p = $txt | ConvertFrom-Json

    # validation : memes longueurs, sinon on refuse
    if (-not $p.resume) { throw "resume vide" }
    if (@($p.constats).Count       -ne @($Base.constats).Count)       { throw "constats: nombre different" }
    if (@($p.actions_faites).Count -ne @($Base.actions_faites).Count) { throw "actions: nombre different" }
    if (@($p.recommandations).Count -ne @($Base.recommandations).Count) { throw "recommandations: nombre different" }

    $outC = @()
    for ($k = 0; $k -lt @($Base.constats).Count; $k++) {
        $outC += [pscustomobject]@{ titre = $Base.constats[$k].titre; texte = [string]@($p.constats)[$k] }
    }
    return [pscustomobject]@{
        resume          = [string]$p.resume
        constats        = $outC
        actions_faites  = @($p.actions_faites | ForEach-Object { [string]$_ })
        recommandations = @($p.recommandations | ForEach-Object { [string]$_ })
    }
}

function Redaction-Trous {
    $espace = if ($fait.NettoyageGo -gt 0) { "environ $($fait.NettoyageGo) Go de fichiers inutiles ont ete identifies et nettoyes" } else { "les fichiers temporaires ont ete nettoyes" }
    $nopti  = if ($fait.Tweaks.Count -gt 0) { "$($fait.Tweaks.Count) reglages orientes jeu ont ete appliques" } else { "les reglages systeme ont ete verifies et ajustes" }
    $etatTxt = if ($nCrit -gt 0) { "$nCrit point(s) critique(s) et " } else { "" }
    $resume = "Le poste $($fait.Machine) presentait $etatTxt$($fait.Constats.Count) point(s) a corriger au total. " +
              "Nous avons applique les optimisations necessaires, $espace, et installe les mises a jour disponibles. " +
              "Le poste est desormais optimise et stable, et toutes les modifications sont reversibles."

    $constats = @()
    foreach ($c in $fait.Constats) {
        $constats += [pscustomobject]@{ titre = $c.Titre; texte = $c.Constat }
    }
    if (-not $constats.Count) {
        $constats += [pscustomobject]@{ titre = "Aucun probleme majeur"; texte = "Le diagnostic n'a revele aucun defaut critique. L'intervention a porte sur l'optimisation et l'entretien preventif." }
    }

    $actions = @()
    if ($fait.Tweaks.Count -gt 0) { $actions += "Nous avons applique $($fait.Tweaks.Count) optimisations orientees jeu (priorite au jeu, reactivite systeme, reseau)." }
    if ($fait.NettoyageGo -gt 0)  { $actions += "Nous avons libere environ $($fait.NettoyageGo) Go d'espace disque (caches et fichiers temporaires)." }
    if ($fait.MajWindows -gt 0)   { $actions += "Nous avons installe $($fait.MajWindows) mise(s) a jour Windows en attente." }
    $actions += "Nous avons verifie l'antivirus, la sante des disques et les pilotes materiels."
    $actions += "Nous avons conserve une sauvegarde complete des reglages d'origine (retour arriere possible a tout moment)."

    $recos = @()
    foreach ($c in ($fait.Constats | Where-Object { $_.Prio -in @('critique','important') -and $_.Action })) {
        $recos += $c.Action
    }
    if ($fait.PlusGrosDossier) { $recos += "Faire le tri dans le dossier le plus volumineux : $($fait.PlusGrosDossier)." }
    $recos += "Redemarrer le poste apres l'intervention pour appliquer l'ensemble des reglages."
    $recos += "Sauvegarder regulierement vos donnees importantes sur un support externe."

    return [pscustomobject]@{
        resume = $resume
        constats = $constats
        actions_faites = $actions
        recommandations = ($recos | Select-Object -Unique)
    }
}

$modeRedac = "modele de texte"
$red = Redaction-Trous          # base deterministe, toujours calculee
if (-not $NoAI) {
    $probe = Test-Ollama
    if ($probe.Ok) {
        $mOk = $probe.Models | Where-Object { $_ -match ("^" + [regex]::Escape($Model) + "(:|$)") }
        if (-not $mOk) {
            Warn "Ollama repond mais le modele '$Model' n'est pas installe."
            Warn "Sur la machine Ollama : ollama pull $Model"
        } else {
            try {
                Info "Reformulation par Ollama ($Model @ $OllamaUrl)..."
                $poli = Polish-Ollama $red
                $red = $poli
                $modeRedac = "modele de texte, reformule par Ollama / $Model"
            } catch {
                Warn "Reformulation Ollama refusee ($($_.Exception.Message)) - on garde le texte de base."
            }
        }
    } elseif ($script:ViaRelais) {
        Warn "Oups - l'IA n'est pas joignable : la tour est peut-etre eteinte ou en veille."
        Warn "Le compte-rendu sort en modele de texte. Reveille la tour pour la version reformulee."
        try {
            $u = "https://allovalentin.fr/api/ia-offline?cle=" + [uri]::EscapeDataString($Token) +
                 "&client="  + [uri]::EscapeDataString([string]$Client) +
                 "&machine=" + [uri]::EscapeDataString([string]$fait.Machine)
            $n = Invoke-RestMethod -Uri $u -TimeoutSec 10
            if ($n.ok) { Info "Un message a ete envoye a contact@allovalentin.fr." }
        } catch {}
    } else {
        Info "Ollama non joignable ($OllamaUrl) - modele de texte a trous."
    }
}

# normalisation ascii de la sortie modele
function Norm { param($x) if ($x -is [array]) { return @($x | ForEach-Object { To-Ascii ([string]$_) }) } return (To-Ascii ([string]$x)) }
$red.resume = Norm $red.resume

# ------------------------------------------------------------------
#  6. Rendu HTML client
# ------------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$outFile = Join-Path $OutDir ("Compte-rendu-" + ($fait.Machine -replace '[^\w\-]','_') + "-$stamp.html")

$clientLine = if ($Client) { "Client : <b>" + (Html-Enc $Client) + "</b> &middot; " } else { "" }
$dateJour = Get-Date -Format "dd/MM/yyyy"

$sb = New-Object Text.StringBuilder
[void]$sb.Append(@"
<!DOCTYPE html>
<html lang="fr"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Allo Valentin - Compte-rendu $(Html-Enc $fait.Machine)</title>
<style>
  *{box-sizing:border-box;}
  body{margin:0;font-family:'Segoe UI',system-ui,Arial,sans-serif;color:#1f2430;background:#f4f5f7;line-height:1.55;}
  .page{max-width:820px;margin:22px auto;background:#fff;border:1px solid #e0e2e8;border-radius:12px;overflow:hidden;}
  .hd{background:linear-gradient(135deg,#c0281f,#8f1c16);color:#fff;padding:28px 34px;}
  .hd .logo{font-size:26px;font-weight:800;letter-spacing:-.5px;}
  .hd .logo .u{opacity:.7;}
  .hd .sub{font-size:11px;font-weight:700;letter-spacing:.24em;opacity:.85;margin-top:4px;}
  .hd .meta{font-size:13px;opacity:.95;margin-top:14px;}
  .body{padding:26px 34px 34px;}
  h2{font-size:13px;text-transform:uppercase;letter-spacing:.09em;color:#8f1c16;margin:26px 0 10px;border-bottom:2px solid #f0d9d7;padding-bottom:4px;}
  .resume{background:#fbeceb;border:1px solid #f0cfcf;border-left:4px solid #c0281f;border-radius:8px;padding:14px 16px;font-size:15px;}
  ul{margin:8px 0;padding-left:20px;} li{margin:5px 0;}
  .kgrid{display:grid;grid-template-columns:1fr 1fr;gap:8px 18px;font-size:13px;margin-top:6px;}
  .kgrid .k{color:#6b7280;} .kgrid .v{font-weight:600;}
  .cst{border:1px solid #e5e7eb;border-radius:8px;padding:10px 14px;margin:8px 0;}
  .cst .t{font-weight:700;font-size:14px;}
  .cst .x{font-size:13px;color:#374151;margin-top:3px;}
  table{width:100%;border-collapse:collapse;font-size:13px;margin-top:8px;}
  th,td{text-align:left;padding:7px 10px;border-bottom:1px solid #eceef1;}
  th{color:#6b7280;font-weight:600;}
  .up{color:#15803d;font-weight:700;} .down{color:#b45309;font-weight:700;} .flat{color:#6b7280;}
  .note{font-size:12px;color:#6b7280;margin-top:10px;}
  .foot{background:#fafafa;border-top:1px solid #e5e7eb;padding:16px 34px;font-size:12px;color:#6b7280;}
  .dv td[contenteditable]{background:#fffef2;outline:1px dashed #e3d8a0;}
  @media print{ body{background:#fff;} .page{border:0;margin:0;max-width:100%;} .noprint{display:none;} }
</style></head><body>
<div class="page">
  <div class="hd">
    <div class="logo">Allo<span class="u">_</span>Valentin</div>
    <div class="sub">MAINTENANCE &amp; SUPPORT INFORMATIQUE</div>
    <div class="meta">${clientLine}Poste : <b>$(Html-Enc $fait.Machine)</b> &middot; Intervention du $dateJour &middot; Technicien : $(Html-Enc $Technicien)</div>
  </div>
  <div class="body">

    <h2>En resume</h2>
    <div class="resume">$(Html-Enc $red.resume)</div>

    <h2>Votre configuration</h2>
    <div class="kgrid">
"@)
foreach ($p in @(@('Processeur',$fait.CPU),@('Carte mere',$fait.CM),@('Memoire',$fait.RAM),
                 @('Carte graphique',$fait.GPU),@('Systeme',$fait.Windows),@('Reseau',$fait.Reseau))) {
    if ($p[1]) { [void]$sb.Append("      <div class=""k"">$(Html-Enc $p[0])</div><div class=""v"">$(Html-Enc $p[1])</div>`n") }
}
[void]$sb.Append("    </div>`n")

# constats
[void]$sb.Append("`n    <h2>Ce que nous avons constate</h2>`n")
if ($red.constats -and @($red.constats).Count) {
    foreach ($c in $red.constats) {
        [void]$sb.Append("    <div class=""cst""><div class=""t"">$(Html-Enc (To-Ascii ([string]$c.titre)))</div><div class=""x"">$(Html-Enc (To-Ascii ([string]$c.texte)))</div></div>`n")
    }
} else {
    [void]$sb.Append("    <p>Aucun defaut majeur detecte.</p>`n")
}

# actions
[void]$sb.Append("`n    <h2>Ce que nous avons fait</h2>`n    <ul>`n")
foreach ($a in @($red.actions_faites)) { [void]$sb.Append("      <li>$(Html-Enc (To-Ascii ([string]$a)))</li>`n") }
[void]$sb.Append("    </ul>`n")

# mesures
if ($mesures.Count) {
    [void]$sb.Append("`n    <h2>Mesures avant / apres</h2>`n    <table><tr><th>Indicateur</th><th>Avant</th><th>Apres</th><th>Evolution</th></tr>`n")
    foreach ($m in $mesures) {
        $mot = if ($m.Apres -gt $m.Avant) { "en hausse" } elseif ($m.Apres -lt $m.Avant) { "en baisse" } else { "stable" }
        $cls = if ($m.Mieux -eq $true) { "up" } elseif ($m.Mieux -eq $false) { "down" } else { "flat" }
        if ($m.Mieux -eq $true) { $mot = "ameliore" }
        $ev = "<span class=""$cls"">$mot</span>"
        [void]$sb.Append("      <tr><td>$(Html-Enc $m.Libelle)</td><td>$($m.Avant) $(Html-Enc $m.Unite)</td><td>$($m.Apres) $(Html-Enc $m.Unite)</td><td>$ev</td></tr>`n")
    }
    [void]$sb.Append("    </table>`n    <div class=""note"">Les mesures de demarrage varient d'un allumage a l'autre ; la desactivation du 'demarrage rapide' de Windows peut allonger le demarrage mais fiabilise le chargement des pilotes.</div>`n")
}

# recommandations
if (@($red.recommandations).Count) {
    [void]$sb.Append("`n    <h2>Nos recommandations</h2>`n    <ul>`n")
    foreach ($r in @($red.recommandations)) { [void]$sb.Append("      <li>$(Html-Enc (To-Ascii ([string]$r)))</li>`n") }
    [void]$sb.Append("    </ul>`n")
}

# devis
if ($Devis) {
    $dureeSug = [math]::Min(4.0, [math]::Max(1.0, [math]::Round(1.0 + 0.5*$nCrit + 0.25*($nImp+$nMin) + 0.5*[bool]($fait.MajWindows -gt 0), 1)))
    $montant = [math]::Round($dureeSug * $TauxHoraire, 2)
    [void]$sb.Append(@"

    <h2>Devis <span class="note">(cliquez sur les cases jaunes pour modifier avant impression)</span></h2>
    <table class="dv">
      <tr><th>Prestation</th><th>Duree</th><th>Montant</th></tr>
      <tr>
        <td contenteditable="true">Diagnostic complet + optimisation ($($fait.Niveau)) + nettoyage + mises a jour</td>
        <td contenteditable="true">$dureeSug h</td>
        <td contenteditable="true">$montant EUR</td>
      </tr>
      <tr><td contenteditable="true">Deplacement</td><td contenteditable="true">-</td><td contenteditable="true">0 EUR</td></tr>
      <tr><td><b>Total</b></td><td></td><td contenteditable="true"><b>$montant EUR</b></td></tr>
    </table>
    <div class="note">Taux horaire de reference : $TauxHoraire EUR/h. Devis indicatif, a valider avec le client.</div>
"@)
}

[void]$sb.Append(@"

  </div>
  <div class="foot">
    Toutes les optimisations sont reversibles : une sauvegarde du registre et le journal des modifications
    sont conserves ($([System.IO.Path]::GetFileName($AppDir))\Backups). Un retour a l'etat initial peut etre
    demande a tout moment. Intervention realisee dans le cadre de la decharge signee par le client.
    <br>Compte-rendu genere le $dateJour - redaction : $modeRedac.
  </div>
</div>
</body></html>
"@)

$sb.ToString() | Set-Content -Path $outFile -Encoding UTF8

Write-Host ""
Ok "Compte-rendu genere : $outFile"
Info "Redaction         : $modeRedac"
Write-Host ""

if ($Ouvrir) { Start-Process $outFile }
