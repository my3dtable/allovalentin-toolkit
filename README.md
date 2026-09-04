# Allo Valentin - Toolkit d'optimisation PC

Boite a outils PowerShell utilisee par **Allo Valentin** (depannage informatique, Colmar)
pour diagnostiquer, optimiser et nettoyer un PC Windows, et produire un compte-rendu clair
pour le client.

## Lancement rapide

Dans une fenetre PowerShell (le script demande les droits administrateur lui-meme) :

```powershell
irm https://allovalentin.fr/opti.ps1 | iex
```

Ca telecharge la derniere version du toolkit dans
`%LOCALAPPDATA%\AlloValentin-Toolkit` et ouvre le menu.

### Diagnostic gratuit / optimisation sur cle

- **Sans cle** : le diagnostic complet est libre (lecture seule, ne modifie rien).
- **Avec la cle d'intervention** remise par Allo Valentin, l'optimisation
  (nettoyage + reglages, entierement reversible) se debloque :

  ```powershell
  irm "https://allovalentin.fr/opti.ps1?cle=VOTRE_CLE" | iex
  ```

  La cle est validee en ligne au moment d'optimiser. Sans elle, le script
  produit uniquement le diagnostic.

## Contenu

| Script | Role |
|---|---|
| `AlloValentin-Menu.ps1` | Point d'entree unique (6 rubriques) |
| `AlloValentin-Diagnostic.ps1` | Diagnostic + optimisation (reglages reversibles) + nettoyage |
| `AlloValentin-Verif.ps1` | Etat machine avant / apres (preuve de reversibilite) |
| `AlloValentin-Perf.ps1` | Mesures de performance avant / apres |
| `AlloValentin-Fluidite.ps1` | Analyse fluidite / FPS (lecture seule, ~25 controles) |
| `AlloValentin-Securite.ps1` | Etat Defender, scan rapide (lecture seule) |
| `AlloValentin-Jeux.ps1` | Verification des configs de jeux (lecture seule) |
| `AlloValentin-CarteMere.ps1` | Carte mere / BIOS / XMP, mise a jour des pilotes |
| `AlloValentin-RapportClient.ps1` | Compte-rendu grand public + devis a partir du dernier diagnostic |

## Principes

- **Rien n'est modifie sans choix explicite** dans le menu.
- Les reglages d'optimisation sont **reversibles** (option "Annuler l'optimisation").
- Aucun tweak noyau risque (VBS/HVCI, minuteries, priorites IFEO...) : hors perimetre.
- Le compte-rendu client **n'invente aucun chiffre** et ne promet aucun gain.
- Les donnees restent sur la machine. Le compte-rendu peut, en option, etre reformule
  par une IA hebergee par Allo Valentin (fichier `ia-client.json`, non fourni ici) ;
  sans ce fichier, le compte-rendu est genere par un modele de texte deterministe.

## Prerequis

- Windows 10 / 11
- Windows PowerShell 5.1 (inclus dans Windows)

## Licence

Code proprietaire Allo Valentin. Fourni pour transparence et reutilisation par le client
sur son propre materiel. Pas de garantie.
