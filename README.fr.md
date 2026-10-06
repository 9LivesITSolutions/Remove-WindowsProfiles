# Remove-WindowsProfiles

> Outil PowerShell de suppression sûre de profils utilisateur Windows, avec exclusions par SID, suppression ciblée et support WinRM multi-machines.

[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-3.9.0-informational.svg)](CHANGELOG.md)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B%20%7C%207%2B-blue.svg)](https://github.com/PowerShell/PowerShell)

[English version](README.md)

---

## Présentation

`Remove-WindowsProfiles.ps1` supprime des profils utilisateur Windows via CIM `Win32_UserProfile`. Il fonctionne selon trois modes :

- **Local** — s'exécute directement sur la machine courante
- **Distant unique** — se connecte à une machine via une CimSession WinRM
- **Multi-machines** — sessions WinRM parallèles sur une liste de cibles, avec un journal par machine et un rapport CSV

Les comptes système et intégrés sont toujours protégés par la structure de leur SID, jamais par leur nom : fonctionne quelle que soit la langue de Windows (français, anglais, etc.).

---

## Fonctionnalités

- **Exclusion par SID** — comptes système identifiés par SID connus et RID intégrés (500/501/503/504), jamais par nom
- **HashSet d'exclusion précalculé** — `Win32_UserAccount` interrogé une seule fois ; recherche en O(1) par profil
- **Suppression ciblée** — `-Username` limite la suppression à des comptes ou SID précis (jokers acceptés)
- **Exclusions flexibles** — `-Exclude` accepte des SID et des jokers de noms pour protéger des comptes supplémentaires
- **Multi-machines** — sessions WinRM parallèles avec limite configurable, journal par machine, rapport CSV consolidé
- **Auto-déploiement** — se copie sur les cibles distantes via `Copy-Item -ToSession` et nettoie après exécution
- **WhatIf** — simulation sous forme de simple switch, sans propagation de `SupportsShouldProcess`
- **Mode interactif** — confirmation Oui/Non/Quitter par profil quand `-All` n'est pas précisé
- **PS5.1 et PS7** — testé sur les deux ; utilise `Get-CimInstance` et `Remove-CimInstance`

---

## Prérequis

| Dépendance | Version                                                      |
| ---------- | ------------------------------------------------------------ |
| PowerShell | 5.1 ou 7+                                                    |
| CIM/WMI    | Intégré (`Win32_UserProfile`, `Win32_UserAccount`)           |
| Privilèges | Administrateur local, ou administrateur distant avec accès WinRM |

WinRM doit être activé sur les cibles distantes :

```
# À exécuter en administrateur sur chaque cible, ou à déployer par GPO
Enable-PSRemoting -Force
```

---

## Installation

```
git clone https://github.com/9LivesITSolutions/Remove-WindowsProfiles.git
cd Remove-WindowsProfiles
```

Aucune dépendance externe. Le script est autonome.

---

## Utilisation

```
# Simulation sur la machine locale
.\Remove-WindowsProfiles.ps1 -WhatIf

# Supprimer un profil précis en local
.\Remove-WindowsProfiles.ps1 -Username "jdoe" -All

# Supprimer un profil précis sur une machine distante
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Username "jdoe" -All

# Prévisualiser la suppression sur une machine distante
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Username "jdoe" -WhatIf

# Suppression en masse sur une machine distante, hors comptes de service
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -All -Exclude "svc_*"

# Mode interactif (confirmation profil par profil)
.\Remove-WindowsProfiles.ps1 -ComputerName "WORKSTATION-01" -Exclude "svc_*"

# Multi-machines depuis une liste en ligne
.\Remove-WindowsProfiles.ps1 -ComputerName "PC-001","PC-002","PC-003" -All -Exclude "svc_*"

# Multi-machines depuis un fichier, avec identifiants
.\Remove-WindowsProfiles.ps1 -TargetList ".\targets.txt" -All `
    -Exclude "svc_*" -Credential (Get-Credential) -ThrottleLimit 5
```

---

## Paramètres

| Paramètre         | Type           | Description                                                                                                |
| ----------------- | -------------- | ---------------------------------------------------------------------------------------------------------- |
| `-ComputerName`   | `string[]`     | Nom(s) d'hôte cible(s). Un seul = mode distant unique ; deux ou plus = mode multi-machines WinRM. Défaut : machine locale. |
| `-TargetList`     | `string`       | Chemin d'un fichier texte avec un nom d'hôte par ligne (lignes `#` ignorées). Active le mode multi-machines. |
| `-Username`       | `string[]`     | Limite la suppression à des noms de comptes ou SID précis. Jokers acceptés.                                |
| `-Exclude`        | `string[]`     | Noms de comptes (jokers) ou SID à toujours ignorer.                                                        |
| `-All`            | `switch`       | Supprime tous les candidats sans confirmation par profil. Obligatoire en exécution non interactive.        |
| `-WhatIf`         | `switch`       | Simule sans supprimer. Liste tous les candidats qui seraient supprimés.                                    |
| `-Credential`     | `PSCredential` | Identifiants explicites pour les sessions distantes (défaut : Kerberos).                                   |
| `-ThrottleLimit`  | `int`          | Nombre maximal de sessions WinRM simultanées en mode multi-machines (défaut : 10, max : 50).               |
| `-LogPath`        | `string`       | Dossier des journaux par machine et du rapport CSV en mode multi-machines (défaut : `.\Logs`).             |
| `-RemoteTempPath` | `string`       | Dossier de transit sur les machines distantes (défaut : `C:\Windows\Temp`).                                |
| `-Verbose`        | `switch`       | Affiche le détail du précalcul des SID.                                                                    |

---

## Fonctionnement

```
Phase 1 -- Build-ExcludedSIDSet()  [une seule fois, avant toute modification de profil]
  |- Charge les SID connus NT AUTHORITY dans un HashSet
  |- Interroge Win32_UserAccount (LocalAccount=True, SIDType=1)
  |- Filtre par RID intégrés {500, 501, 503, 504} -> injecte les vrais SID dans le HashSet
  '- Injecte les SID explicites de -Exclude

Phase 2 -- Charge Win32_UserProfile  [une seule requête CIM]

Phase 3 -- Classe chaque profil
  |- ExcludedSIDs.Contains(SID)  -> O(1) -> SYSTEM, ignoré
  |- Test-IsSystemByPrefix()     -> filet de sécurité pour NT SERVICE, IIS, Hyper-V
  |- Resolve-AccountName()       -> uniquement pour les profils non système
  |- Applique les motifs de noms de -Exclude
  |- Applique le filtre -Username -> restreint les candidats si précisé
  '- Applique -All / interactif / -WhatIf à la liste finale de candidats
```

Les comptes intégrés sont exclus par RID quel que soit leur nom d'affichage : RID 500 (Administrator/Administrateur/...), 501 (Guest/Invité/...), 503 (DefaultAccount), 504 (WDAGUtilityAccount).

---

## Sorties (multi-machines)

- **Console** — une ligne d'état par machine (Success / PartialFailure / Unreachable) avec les nombres de profils supprimés/en échec/ignorés
- **Fichiers journal** — `Logs\<ComputerName>_<timestamp>.log` pour chaque machine
- **Rapport CSV** — `Logs\report_<timestamp>.csv` avec tous les résultats consolidés

---

## Structure du projet

```
Remove-WindowsProfiles/
|-- Remove-WindowsProfiles.ps1   # Script principal (local, distant unique, multi-machines)
|-- targets.txt                  # Exemple de liste de cibles pour -TargetList
|-- README.md
|-- README.fr.md
|-- CHANGELOG.md
|-- LICENSE
'-- .gitignore
```

---

## Voir aussi

[Invoke-ProfilePurge](https://github.com/9LivesITSolutions/Invoke-ProfilePurge) supprime les profils inactifs selon leur ancienneté sur un parc de serveurs (rapport HTML, journal d'événements). `Remove-WindowsProfiles` cible au contraire des comptes ou des SID précis.

---

## Contribuer

1. Forker le dépôt
2. Créer une branche (`git checkout -b feature/ma-fonctionnalite`)
3. Commiter (`git commit -m 'feat: add ma-fonctionnalite'`)
4. Pousser la branche (`git push origin feature/ma-fonctionnalite`)
5. Ouvrir une Pull Request

Merci de suivre les [Conventional Commits](https://www.conventionalcommits.org/) pour les messages de commit.

---

## Licence

Ce projet est distribué sous licence MIT. Voir le fichier [LICENSE](LICENSE).

---

Maintenu par **9 Lives IT Solutions** — Informatique de santé & automatisation d'infrastructure.
