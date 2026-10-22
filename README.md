# Suspension automatique d'un pilote Intune

Cette solution surveille les profils **Windows Driver Update** Intune sans modifier
leur mode d'approbation automatique.

À chaque exécution, le script :

1. récupère les profils de pilotes Intune ;
2. recherche le pilote demandé dans chaque inventaire ;
3. ne fait rien si le pilote est absent ;
4. ne fait rien si son `approvalStatus` est déjà `suspended` ;
5. exécute l'action Graph `suspend` uniquement pour les pilotes `approved` ;
6. relit l'inventaire pour confirmer l'état `suspended` ;
7. journalise le contrôle, l'action et son résultat.

Le script est idempotent et peut donc être exécuté toutes les heures.

Intune n'autorise pas la transition directe de `needsReview` ou `declined` vers
`suspended`. Un pilote `needsReview` n'est pas encore autorisé au déploiement.
Ces états, ainsi qu'un état inconnu, provoquent une erreur explicite indiquant
le profil et le pilote concernés, sans appel de suspension pour ces pilotes
et sans approbation automatique. Les pilotes approuvés restent traités dans les
autres profils et dans le même profil. Une erreur globale peut donc correspondre
à un traitement partiel : actualiser le catalogue avant de réessayer.

Après un changement récent, Graph peut refuser une action alors que l'inventaire
affiche déjà un état compatible. Un refus individuel est journalisé, suivi d'une
attente et d'une relecture. Seuls les pilotes encore en échec sont retentés,
avec un maximum de trois appels d'action ; une suspension n'est retentée que si
le pilote est toujours `approved`. Un pilote déjà dans l'état attendu n'est pas
renvoyé. Un pilote introuvable, un état incompatible ou un refus persistant reste
une erreur explicite. Le délai utilise `VerificationDelaySeconds` (cinq secondes
par défaut). Chaque succès reste confirmé par relecture de l'inventaire.

## Fichiers

- `Watch-IntuneDriverPause.ps1` : contrôle et suspension du pilote, ou approbation
  ponctuelle avec `-Action Approve` ;
- `Register-IntuneDriverPauseScheduledTask.ps1` : création d'une tâche Windows
  exécutée toutes les heures par `SYSTEM` ;
- `Get-IntuneDriverPauseCatalog.ps1` : lecture des profils WUfB Drivers et de
  leurs inventaires pour l'interface ;
- `Start-IntuneDriverPauseGui.ps1` : interface graphique WPF facultative ;
- `Test-IntuneDriverActions.ps1` : tests Pester des actions et de l'interface.

Tous les scripts sont regroupés dans le même dossier, à la racine du dépôt.

## Prérequis Microsoft Graph

1. Une licence Intune active sur le tenant.
2. Le module Graph installé :

```powershell
Install-Module Microsoft.Graph.Authentication -Scope AllUsers
```

Trois modes d'authentification sont disponibles :

- **Compte utilisateur** : permission déléguée
  `DeviceManagementConfiguration.ReadWrite.All`. Le compte doit aussi disposer
  des droits Intune nécessaires pour modifier les stratégies de pilotes.
- **Secret client** : application Entra ID avec la permission **Application**
  `DeviceManagementConfiguration.ReadWrite.All` et consentement administrateur.
- **Certificat** : même permission applicative, certificat ajouté à l'application
  et clé privée installée dans `Cert:\LocalMachine\My`.

La tâche planifiée horaire utilise uniquement le mode certificat. Une connexion
utilisateur est interactive et le secret client n'est volontairement pas stocké
dans la tâche.

### Connexion avec un compte utilisateur

```powershell
.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'XXX' `
    -AuthenticationMode Interactive `
    -TenantId '00000000-0000-0000-0000-000000000000' `
    -WhatIf
```

Une fenêtre de connexion Microsoft s'ouvre. Les jetons restent limités au
processus PowerShell courant. Le `TenantId` est facultatif dans ce mode ; sans
valeur, le sélecteur de compte Microsoft détermine le tenant.

### Connexion avec un secret client

```powershell
$secret = Read-Host 'Secret client' -AsSecureString

.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'XXX' `
    -AuthenticationMode ClientSecret `
    -TenantId '00000000-0000-0000-0000-000000000000' `
    -ClientId '11111111-1111-1111-1111-111111111111' `
    -ClientSecret $secret `
    -WhatIf
```

Le secret n'est jamais écrit dans le journal.
Dans Entra ID, utiliser la **valeur** du secret client au moment de sa création,
et non son identifiant.

## Choix du pilote

La comparaison du nom est **exacte par défaut** afin d'éviter de suspendre un
pilote voisin.

Pour cibler sans ambiguïté une publication donnée, ajouter sa version et,
si nécessaire, son fabricant :

```powershell
.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'Contoso - Firmware - 1.2.3.4' `
    -DriverVersion '1.2.3.4' `
    -Manufacturer 'Contoso' `
    -AuthenticationMode CurrentContext `
    -WhatIf
```

Les modes `Contains` et `Wildcard` sont disponibles avec `-NameMatchMode`, mais
ils peuvent sélectionner plusieurs pilotes. Le paramètre `-DriverId` permet
également un ciblage direct quand l'identifiant Graph est connu.

Sans `-ProfileId` ni `-ProfileName`, tous les profils sont analysés. Ces deux
paramètres permettent de limiter explicitement le périmètre.

## Interface graphique facultative

Lancer l'interface depuis PowerShell :

```powershell
.\Start-IntuneDriverPauseGui.ps1
```

L'interface permet de :

- se connecter avec un compte utilisateur, un secret client ou un certificat ;
- charger les profils WUfB Drivers existants et leur inventaire en une seule
  session Graph ;
- sélectionner un profil source pour afficher automatiquement ses drivers ;
- sélectionner directement un driver dans la liste ;
- utiliser à la place une saisie manuelle avec correspondance exacte, partielle
  ou caractères génériques ;
- effectuer une simulation `-WhatIf` ;
- suspendre immédiatement le pilote dans tous les profils après confirmation ;
- approuver le driver sélectionné sur le profil source ou sur tous les profils
  où il est présent, pour un déploiement immédiat et après confirmation ;
- retrouver dans l'onglet **Profils du driver** tous les profils contenant un
  driver choisi, avec son état et le mode d'approbation de chaque profil ;
- consulter dans un onglet dédié tous les drivers en pause et les profils où ils
  sont présents ;
- repérer en jaune un driver présent dans un nouveau profil, ou dont la
  suspension est incomplète, puis compléter uniquement les profils manquants ;
- créer ou remplacer la tâche planifiée horaire, avec élévation UAC si nécessaire ;
- ouvrir le journal ;
- consulter l'onglet **Aide**, accessible hors connexion, pour les prérequis,
  les permissions, le parcours utilisateur et le dépannage.

Les opérations Graph sont exécutées dans un espace d'exécution PowerShell
persistant, sur un thread dédié dans le processus de l'application. Le même
contexte Graph est réutilisé pour toute la session, sans bloquer l'interface.
Seule l'installation nécessitant une élévation UAC utilise un processus séparé.
Les messages d'information et avertissements Graph restent visibles dans
**Résultat**, séparément des données JSON du catalogue : ils ne sont jamais
transmis au lecteur JSON. Une réponse de catalogue invalide continue à produire
une erreur explicite.
Les paramètres non sensibles sont mémorisés dans :

```text
%LOCALAPPDATA%\IntuneDriverPause\GuiSettings.json
```

L'interface ne persiste aucun secret, jeton ni clé privée sur disque. Un secret
client est transmis à l'espace d'exécution sous forme de `SecureString`, jamais
dans la commande ou dans une variable d'environnement de l'interface. Elle
enregistre uniquement les paramètres non sensibles et l'empreinte du certificat
sélectionné.

Après une connexion réussie, l'interface conserve la connexion Graph et la session
d'authentification en mémoire jusqu'à sa fermeture ou jusqu'à la modification du
mode, du tenant, de l'Application ID ou du certificat. Les actualisations,
simulations, suspensions et approbations réutilisent ce contexte via
`CurrentContext`, sans nouvelle connexion interactive. Cliquer à nouveau sur
**Se connecter et lister les profils** recharge le catalogue si la session est
déjà active. Les paramètres d'identité sont verrouillés pendant une opération.

Le SDK Graph peut renouveler silencieusement les jetons utilisateur et certificat.
Une stratégie Entra ID, une révocation ou une demande d'interaction peut néanmoins
imposer une nouvelle authentification : fermer puis relancer l'application pour
se reconnecter ou changer de compte utilisateur. Pour le mode secret client, le
secret reste sous forme de `SecureString` en mémoire et sert à renouveler le jeton
automatiquement à chaque opération, sans saisie supplémentaire ; les droits de
lecture seule sont revérifiés à cette occasion.

La fermeture déconnecte Graph et libère l'espace d'exécution. Elle n'arrête pas
les tâches planifiées. L'utilisation autonome des scripts et les tâches horaires
conservent leur comportement de connexion/déconnexion par exécution ;
`-KeepGraphConnection` est réservé à l'interface qui gère le cycle de vie.

### Aide intégrée

L'onglet **Aide** est disponible sans connexion Graph et ne nécessite pas d'accès
Internet pour sa consultation. Il décrit l'installation du module, les trois
modes d'authentification, les permissions et le consentement administrateur,
la sélection d'un driver, les simulations et le périmètre des actions, les vues
de consultation, la tâche horaire sous `SYSTEM`, les journaux, les erreurs
courantes et la confidentialité. Aucun numéro de version de l'application
n'y est affiché.

Le parcours recommandé dans l'interface est :

1. choisir le mode de connexion et cliquer sur **Se connecter et lister les profils** ;
2. sélectionner un profil WUfB Drivers comme source du catalogue ;
3. sélectionner un driver affiché, ou activer **Saisie manuelle** ;
4. simuler, suspendre immédiatement, approuver le driver sélectionné ou installer
   la tâche horaire.

Les boutons **Approuver sur le profil sélectionné** et **Approuver sur tous les
profils** de l'onglet **Actions sur les drivers** ciblent exclusivement le driver
choisi dans la liste, par son identifiant Graph (pas les critères de saisie
manuelle). L'approbation utilise l'action Graph `approve` avec la date UTC
courante comme date de déploiement. Les drivers déjà approuvés ne sont pas
modifiés ; chaque modification est journalisée puis vérifiée par relecture
de l'inventaire. Après succès, la liste et le suivi des drivers en pause sont
mis à jour. En cas d'échec, des profils peuvent avoir été partiellement traités :
utiliser **Actualiser profils et drivers** pour recharger l'état réel avant
de réessayer.

**Attention :** l'approbation ne supprime ni ne désactive la tâche horaire de
suspension. Si elle cible ce driver, elle pourra le suspendre à nouveau lors
de sa prochaine exécution. Désactiver ou adapter cette tâche dans le Planificateur
de tâches Windows pour conserver l'approbation.

Le bouton **Actualiser profils et drivers** recharge le catalogue complet avec
la session en mémoire, sans redemander le secret ou l'authentification.

L'onglet **Profils du driver**, situé juste à droite d'**Actions sur les drivers**,
propose une liste de tous les drivers du catalogue, pas uniquement ceux en pause.
Le nom, la version, le fabricant et l'identifiant Graph permettent de les
distinguer. Choisir un driver affiche un profil par ligne, avec son nom, son
identifiant, son mode d'approbation et l'état du driver (`approved`, `suspended`,
etc.). Le rapprochement utilise l'identifiant Graph, jamais le seul nom du driver.
La sélection d'un driver dans l'onglet d'actions est automatiquement reprise ici ;
choisir un autre driver dans cet onglet de consultation ne change pas la cible
des actions.

Cette vue est disponible en lecture seule et réutilise le catalogue en mémoire,
sans nouvel appel Graph lors du choix d'un driver. Les actions vérifiées sur un
driver sélectionné mettent son état à jour dans cette vue. Pour récupérer les
changements externes, les nouveaux profils ou le résultat d'une suspension par
saisie manuelle, utiliser **Actualiser profils et drivers**, puis choisir à
nouveau le driver.

Le bouton **Actualiser la vue** de l'onglet de suivi effectue le même
rechargement. La vue regroupe les inventaires par identifiant de driver. Dès
qu'un driver suspendu apparaît comme non suspendu dans un autre profil, sa ligne
est mise en surbrillance et le bouton **Compléter la pause** cible uniquement
les profils concernés.

Quand un driver est choisi dans la liste, son identifiant Graph est utilisé afin
d'éviter toute ambiguïté. Le profil sélectionné sert uniquement à afficher le
catalogue source et à cibler l'approbation sur un seul profil. La simulation,
la suspension immédiate et la tâche horaire
analysent tous les profils WUfB Drivers, y compris ceux créés ultérieurement.

Pour une connexion par secret client, l'interface vérifie les rôles présents
dans le jeton. Si `DeviceManagementConfiguration.ReadWrite.All` est absent, la
session reste utilisable en lecture et pour les simulations, mais le bouton de
suspension et les boutons d'approbation sont désactivés avec une indication explicite.

L'approbation ponctuelle est également disponible en ligne de commande :

```powershell
.\Watch-IntuneDriverPause.ps1 `
    -DriverId 'identifiant-du-driver' `
    -ProfileId 'identifiant-du-profil' `
    -Action Approve `
    -AuthenticationMode CurrentContext `
    -WhatIf
```

Retirer `-WhatIf` pour appliquer l'approbation, ou omettre `-ProfileId` pour
cibler tous les profils où le driver est présent. Sans `-Action`, le comportement
reste la suspension, notamment pour les tâches planifiées existantes.

## Test interactif recommandé

Commencer par un contrôle en mode simulation :

```powershell
Connect-MgGraph -Scopes DeviceManagementConfiguration.ReadWrite.All

.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'XXX' `
    -AuthenticationMode CurrentContext `
    -WhatIf
```

Retirer `-WhatIf` pour effectuer puis vérifier la suspension :

```powershell
.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'XXX' `
    -AuthenticationMode CurrentContext
```

## Mise en production toutes les heures

Ouvrir Windows PowerShell en tant qu'administrateur, puis enregistrer la tâche :

```powershell
.\Register-IntuneDriverPauseScheduledTask.ps1 `
    -DriverName 'XXX' `
    -TenantId '00000000-0000-0000-0000-000000000000' `
    -ClientId '11111111-1111-1111-1111-111111111111' `
    -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'
```

La tâche :

- démarre immédiatement après sa création ;
- se répète toutes les heures ;
- refuse les exécutions simultanées ;
- retente jusqu'à trois fois après un échec ;
- est limitée à 30 minutes par exécution.

Pour limiter la surveillance à quelques profils :

```powershell
.\Register-IntuneDriverPauseScheduledTask.ps1 `
    -DriverName 'XXX' `
    -ProfileName 'Pilotes - Production', 'Pilotes - Préproduction' `
    -TenantId '00000000-0000-0000-0000-000000000000' `
    -ClientId '11111111-1111-1111-1111-111111111111' `
    -CertificateThumbprint '0123456789ABCDEF0123456789ABCDEF01234567'
```

## Azure Automation

Le script principal peut aussi être appelé par un runbook PowerShell planifié
toutes les heures. Une identité managée doit alors recevoir la permission
applicative Graph `DeviceManagementConfiguration.ReadWrite.All`.

```powershell
.\Watch-IntuneDriverPause.ps1 `
    -DriverName 'XXX' `
    -AuthenticationMode ManagedIdentity
```

Pour une identité managée affectée par l'utilisateur, ajouter son identifiant
client avec `-ClientId`.

## Journalisation

Le journal par défaut est :

```text
C:\ProgramData\IntuneDriverPause\Logs\IntuneDriverPause.log
```

Il contient notamment les événements `NO_MATCH`, `ALREADY_SUSPENDED`,
`SUSPEND_REQUEST`, `SUSPEND_CONFIRMED`, `PROFILE_ERROR` et `RUN_SUMMARY`.
Pour l'approbation, il contient `ALREADY_APPROVED`, `APPROVE_REQUEST` et
`APPROVE_CONFIRMED`. Une approbation sans aucun pilote correspondant échoue
explicitement.
La rotation intervient à 10 Mo et conserve cinq archives par défaut.

Une erreur de lecture, d'action ou de vérification fait échouer l'exécution afin
qu'elle soit visible dans l'historique de la tâche planifiée. Les autres profils
continuent néanmoins d'être traités.

## API utilisée

La gestion des pilotes Intune est exposée par Microsoft Graph **beta**. Cette API
est prise en charge, mais peut évoluer plus fréquemment que `v1.0`.

- Inventaires :
  `GET /beta/deviceManagement/windowsDriverUpdateProfiles/{profileId}/driverInventories`
- Suspension et approbation :
  `POST /beta/deviceManagement/windowsDriverUpdateProfiles/{profileId}/executeAction`
- Corps de l'action :

```json
{
  "actionName": "suspend",
  "driverIds": [
    "identifiant-du-pilote"
  ]
}
```

Pour approuver, le corps utilise `actionName: "approve"` et ajoute
`deploymentDate` au format ISO 8601 UTC (date courante pour un déploiement
immédiat).

## Validation locale

Les tests Pester simulent Microsoft Graph sans modifier le tenant :

```powershell
Invoke-Pester .\Test-IntuneDriverActions.ps1
.\Start-IntuneDriverPauseGui.ps1 -ValidateOnly -AutomatedTest
```

Exécuter ces validations sous Windows PowerShell 5.1 en mode STA, avec Pester
et `Microsoft.Graph.Authentication` installés. Elles vérifient l'approbation
sur un profil et sur tous les profils, la suspension par défaut, l'idempotence,
la simulation, les erreurs Graph, le ciblage de l'interface, la consultation
des profils par identifiant de driver, la réutilisation de la session Graph,
la fermeture de l'espace d'exécution et le contenu de l'aide intégrée.

Références Microsoft :

- [windowsDriverUpdateProfile](https://learn.microsoft.com/graph/api/resources/intune-softwareupdate-windowsdriverupdateprofile?view=graph-rest-beta)
- [windowsDriverUpdateInventory](https://learn.microsoft.com/graph/api/resources/intune-softwareupdate-windowsdriverupdateinventory?view=graph-rest-beta)
- [executeAction](https://learn.microsoft.com/graph/api/intune-softwareupdate-windowsdriverupdateprofile-executeaction?view=graph-rest-beta)
