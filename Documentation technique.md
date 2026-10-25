---
tags:
  - linux
  - lin-1
  - doc
Creation date: 2026-09-17 10:37
---

# Documentation technique – Projet LIN1-LABO

Nom : Jimmy LAM
Classe : SI-T1b
Date : 18.10.26
Module : LIN1, CPNV

## 1. Introduction

Dans le module LIN1, on doit monter une petite infrastructure pour l'entreprise fictive LIN1-LABO : un serveur d'infrastructure (DNS, DHCP, annuaire LDAP, routeur), un serveur Nextcloud, un NAS et deux postes clients, un Linux et un Windows. Tout tourne dans VMware Workstation sur mon PC.

Les deux serveurs Debian s'installent avec un script chacun (`SRV-LIN1-01.sh` et `SRV-LIN1-02.sh`). Le NAS est un OpenMediaVault que j'ai configuré une fois pour toutes. Les clients sont des installations normales de Fedora et de Windows 11.

Dans ce document, j'explique comment l'infrastructure est construite, ce que font les scripts, comment on s'en sert au quotidien, ce qu'on fait quand ça ne marche pas, et les limites que je connais. J'ai aussi noté les choix où je me suis écarté de la donnée, avec la raison.

Les versions utilisées :

| Logiciel | Version |
|---|---|
| Hyperviseur | VMware Workstation 25.0.1 |
| Serveurs | Debian 13 (netinst 13.6.0), installation minimale sans interface graphique |
| NAS | OpenMediaVault 8.3.1 |
| Nextcloud | 35 (35.0.1 au moment de mes tests, le script prend toujours la dernière version) |
| Client Linux | Fedora 44 Workstation |
| Client Windows | Windows 11 Pro (25H2) |
| Client Nextcloud Windows | 34.0.4 |

## 2. Schéma du réseau

Le réseau interne `10.10.10.0/24` est le réseau VMware VMnet1 (Host Only), sans le DHCP de VMware : c'est SRV-LIN1-01 qui distribue les adresses. Seul SRV-LIN1-01 a une deuxième carte, en NAT (VMnet8), qui lui donne Internet. Toutes les autres machines sortent sur Internet à travers lui.

```
                              Internet
                                 |
                    NAT de VMware (VMnet8, 192.168.186.0/24)
                                 |
                        WAN, adresse en DHCP
                      +----------------------+
                      |     SRV-LIN1-01      |  dnsmasq (DNS + DHCP)
                      |     10.10.10.11      |  OpenLDAP + LAM
                      |                      |  routeur NAT (iptables)
                      +----------------------+
                        LAN, adresse fixe
                                 |
 ===========  réseau interne 10.10.10.0/24 (VMnet1, Host Only)  ===========
      |                 |                  |               |            |
+-------------+  +--------------+  +-------------+  +-------------+  +------------+
| SRV-LIN1-02 |  | NAS-LIN1-01  |  | Client      |  | Client      |  | PC hôte    |
| 10.10.10.22 |  | 10.10.10.33  |  | Fedora      |  | Windows 11  |  | 10.10.10.1 |
| Nextcloud   |  | OMV, RAID1   |  | DHCP        |  | DHCP        |  | (VMnet1)   |
+-------------+  +--------------+  +-------------+  +-------------+  +------------+
      |                 ^
      |   iSCSI (données de Nextcloud, port 3260)
      +-----------------+
      |   NFS (sauvegardes de nuit, port 2049)
      +-----------------+
```

Le PC hôte a l'adresse `10.10.10.1` sur VMnet1 : c'est VMware qui crée une carte virtuelle sur le PC pour chaque réseau virtuel, et elle prend la première adresse du réseau. Ça ne touche pas à la vraie connexion du PC. C'est pratique pour se connecter en SSH depuis le PC et ouvrir LAM dans le navigateur du PC.

### Machines et adresses

| Nom | Rôle | Adresse IP | OS | RAM | vCPU | Disques | Cartes réseau |
|---|---|---|---|---|---|---|---|
| `srv-lin1-01` | DNS, DHCP, LDAP, LAM, routeur NAT | `10.10.10.11/24` (LAN) + DHCP (WAN) | Debian 13 | 1 Go | 1 | 10 Go | NAT + Host Only |
| `srv-lin1-02` | Nextcloud | `10.10.10.22/24` | Debian 13 | 1 Go | 1 | 10 Go | Host Only |
| `nas-lin1-01` | NAS : RAID1, iSCSI, NFS | `10.10.10.33/24` | OpenMediaVault 8.3.1 | 1 Go | 1 | 10 Go (OS) + 2 × 10 Go (RAID1) + 10 Go (rechange) | Host Only |
| `cli-lin1-fedora` | client Linux | DHCP (`10.10.10.100` à `.200`) | Fedora 44 | 2 Go | 2 | 20 Go | Host Only |
| `cli-lin1-win11` | client Windows | DHCP (`10.10.10.100` à `.200`) | Windows 11 Pro | 4 Go | 2 | 50 Go | Host Only |

Sur les serveurs Debian, les cartes réseau s'appellent `enp0s16` et `enp0s17` (cartes `e1000` de VMware). Les scripts n'écrivent pas ces noms en dur : ils les détectent, comme ça ils marchent aussi sur une autre machine.

### Services et ports

| Machine | Service | Port | Adresse |
|---|---|---|---|
| SRV-LIN1-01 | SSH | 22 | `ssh cpnv@10.10.10.11` |
| SRV-LIN1-01 | DNS (dnsmasq) | 53 | domaine `lin1.local` |
| SRV-LIN1-01 | DHCP (dnsmasq) | 67 | plage `10.10.10.100` à `10.10.10.200`, bail de 12 h |
| SRV-LIN1-01 | LDAP (slapd) | 389 | base `dc=lin1,dc=local` |
| SRV-LIN1-01 | LAM (Apache) | 80 | `http://10.10.10.11/lam` |
| SRV-LIN1-02 | SSH | 22 | `ssh cpnv@10.10.10.22` |
| SRV-LIN1-02 | Nextcloud (Apache) | 443 (80 redirige vers 443) | `https://10.10.10.22/nextcloud` |
| SRV-LIN1-02 | MariaDB | 3306, en local seulement | base `nextcloud` |
| NAS-LIN1-01 | interface web OMV | 80 | `http://10.10.10.33` |
| NAS-LIN1-01 | NFS | 2049 | partage `nfs-lin1` |
| NAS-LIN1-01 | iSCSI (tgt) | 3260 | cible `iqn.2026-10.local.lin1:iscsi1` |

### Annuaire et droits

L'annuaire suit le schéma « Arborescence des données » du cours :

| Groupe | gidNumber | Membres (uidNumber) |
|---|---|---|
| `manager` | 10000 | man01 (11001), man02 (11002) |
| `ingenieur` | 10001 | ing01 (12001), ing02 (12002) |
| `developpeur` | 10002 | dev01 (13001), dev02 (13002, créé pendant le POC) |

| Dossier Nextcloud          | Quota | Groupes                         | Droits                                   |
| -------------------------- | ----- | ------------------------------- | ---------------------------------------- |
| perso (un par utilisateur) | 10 Mo | l'utilisateur lui-même          | lecture et écriture                      |
| `clients`                  | 20 Mo | manager                         | lecture et écriture                      |
| `logiciels`                | 20 Mo | ingenieur, developpeur          | lecture et écriture                      |
| `commun`                   | 30 Mo | manager, ingenieur, developpeur | lecture et écriture pour tous (voir 3.6) |

## 3. Mes choix techniques

### 3.1 dnsmasq plutôt que BIND

La page « Configuration des machines virtuelles » parle de BIND pour le DNS, mais l'annexe du cours « Configurer un serveur dnsmasq » et l'exemple de rapport utilisent dnsmasq. J'ai pris dnsmasq parce qu'il fait le DNS et le DHCP dans un seul service, avec un seul petit fichier de configuration. Avec BIND, il aurait fallu en plus un serveur DHCP séparé (isc-dhcp-server ou Kea), écrire les fichiers de zone à la main avec leurs numéros de série, et faire la zone inverse à part. Pour un réseau de cinq machines, c'était beaucoup de travail pour rien. dnsmasq fait aussi la résolution inverse tout seul à partir des lignes `host-record`, et il enregistre dans le DNS le nom des clients qui reçoivent une adresse en DHCP.

### 3.2 Domaine lin1.local

J'ai repris le domaine `lin1.local` de l'exemple de rapport du cours. L'ancien script qu'on m'avait donné utilisait `cpnv.local`, mais je voulais rester aligné sur le cours. La base LDAP suit le domaine : `dc=lin1,dc=local`. Je sais que `.local` est normalement réservé au multicast DNS (mDNS, Avahi, Bonjour) ; dans ce labo isolé ça ne pose pas de problème, mais en entreprise je prendrais un sous-domaine d'un vrai domaine (par exemple `lin1.mon-entreprise.ch`).

### 3.3 ifupdown pour le réseau des serveurs

Debian minimal utilise déjà `ifupdown` et le fichier `/etc/network/interfaces`. L'ancien script installait NetworkManager en plus, ce qui ne sert à rien sur un serveur sans interface graphique. Je suis resté sur `ifupdown`, comme l'exemple du cours.

### 3.4 iSCSI avec tgt, parce qu'OMV 8 n'a pas de plugin iSCSI

Dans les anciennes versions d'OpenMediaVault, il y avait un plugin iSCSI dans l'interface web. Dans OMV 8, il n'existe plus (ni dans les plugins officiels, ni dans ceux que j'ai trouvés). J'ai donc installé `tgt`, le serveur de cibles iSCSI de Debian, directement sur le NAS en ligne de commande. OMV est une Debian, donc ça cohabite sans souci. La cible est un fichier de 6 Go posé sur le RAID1. Le reste du NAS (RAID, système de fichiers, NFS, adresse IP) est géré normalement par OMV.

### 3.5 Données de Nextcloud sur l'iSCSI, sauvegardes sur le NFS

Le POC demande de monter à la fois un partage iSCSI et un partage NFS sur SRV-LIN1-02. Je me suis servi des deux :

- le disque iSCSI est formaté en ext4 et monté sur `/mnt/iscsi1` ; c'est le dossier de données de Nextcloud. Les fichiers des utilisateurs sont donc physiquement sur le RAID1 du NAS ;
- le partage NFS est monté sur `/mnt/nfs-lin1` ; chaque nuit, une copie de la base de données et de la configuration de Nextcloud y est déposée.

J'ai préféré l'iSCSI pour les données parce que c'est un disque « bloc » : MariaDB et Nextcloud le voient comme un disque local, avec les droits Unix normaux, alors que sur NFS les droits et les verrous de fichiers posent parfois des problèmes.

### 3.6 man01 peut écrire dans Commun (on suit le POC, pas le schéma)

Il y a une contradiction dans la donnée. Le schéma « Arborescence des données » dit que les managers n'ont que la lecture sur Commun. Mais le point 24 du POC demande de se connecter avec man01 et de modifier `test.txt` dans `commun`. Si je suivais le schéma, ce point du POC serait impossible. J'ai donc suivi le POC : les trois groupes ont lecture et écriture sur `commun`. C'est le dernier appel `dossier_de_groupe` du script SRV-LIN1-02.

Si on veut revenir au schéma, il suffit d'une commande sur SRV-LIN1-02 (le numéro du dossier se lit avec `groupfolders:list`, il vaut 3 sur une installation neuve) :

```bash
sudo -u www-data php /var/www/nextcloud/occ groupfolders:group 3 manager read
```

### 3.7 Pas de fichiers d'exemple dans Nextcloud (skeleton désactivé)

À la première connexion, Nextcloud copie normalement des fichiers d'exemple dans le dossier de chaque utilisateur (un manuel PDF, des images, un document). Au premier test, ces fichiers prenaient déjà presque tout le quota de 10 Mo, et l'utilisateur ne pouvait presque plus rien déposer. J'ai donc vidé le « skeleton » : les nouveaux utilisateurs commencent avec un dossier vide.

```bash
occ config:system:set skeletondirectory --value=""
```

J'ai aussi désactivé la fenêtre d'accueil (`firstrunwizard`) et les applications recommandées, pour que la démonstration soit plus fluide.

### 3.8 Dossiers de groupe (Group folders)

Pour `clients`, `logiciels` et `commun`, j'utilise l'application Nextcloud « Group folders » (le nom affiché dans l'interface peut être « Dossiers de groupe » ou « Dossiers d'équipe » selon la version). Un dossier de groupe appartient à Nextcloud et pas à un utilisateur : on lui donne un quota et une liste de groupes avec leurs droits. Les groupes sont ceux de l'annuaire LDAP, donc il n'y a rien à faire dans Nextcloud quand on ajoute quelqu'un dans un groupe : dev02 a eu accès à `logiciels` et `commun` dès sa première connexion.

### 3.9 RAM des clients : 2 Go pour Fedora, 4 Go pour Windows

La donnée demande 1 Go de RAM pour chaque client. Je n'ai pas pu respecter ça :

- Windows 11 demande au minimum 4 Go pour s'installer et tourner. Avec moins, l'installateur refuse, et même en contournant le contrôle, Windows est inutilisable ;
- Fedora 44 Workstation, avec son bureau GNOME et Firefox, est beaucoup trop lent en dessous de 2 Go. Même à 2 Go, on sent que c'est juste quand on ouvre Nextcloud dans Firefox.

Les trois serveurs restent à 1 Go comme demandé : ils n'ont pas d'interface graphique et ça leur suffit (Nextcloud aussi, pour quelques utilisateurs).

Au total ça fait 1 + 1 + 1 + 2 + 4 = 9 Go. Mon PC a 12 Go : ça passe quand tout tourne, mais il faut fermer les autres programmes (voir les limites, chapitre 14).

### 3.10 Compte de service LDAP pour Nextcloud

Nextcloud ne se connecte pas à l'annuaire avec le compte admin LDAP. Le script SRV-LIN1-01 crée un compte `cn=nextcloud,ou=Services,dc=lin1,dc=local` qui sert uniquement à lire l'annuaire. Comme ça, le mot de passe de l'administrateur LDAP n'est pas stocké dans la configuration de Nextcloud.

## 4. Préparation de VMware

Avant d'installer les machines, j'ai réglé les réseaux virtuels de VMware (Édition > Éditeur de réseau virtuel) :

| Réseau | Type | Réglage |
|---|---|---|
| VMnet8 | NAT | `192.168.186.0/24`, DHCP de VMware actif (c'est lui qui donne l'adresse WAN de SRV-LIN1-01) |
| VMnet1 | Host Only | `10.10.10.0/24`, DHCP de VMware **désactivé** (sinon il ferait concurrence à dnsmasq) |

J'ai sauvegardé la configuration réseau de VMware avant de la modifier, pour pouvoir revenir en arrière.

Les VM ont des disques « growable » (ils ne prennent que la place réellement utilisée), des disques SATA et des cartes réseau `e1000`. Leurs fichiers sont sur un disque réseau du PC (`Z:`, 3,7 To) et plus sur le disque C:, qui était trop petit (voir 14.7). Pendant l'installation des systèmes, toutes les VM étaient en NAT pour pouvoir télécharger des paquets. Ensuite, sauf la première carte de SRV-LIN1-01, je les ai toutes passées en Host Only.

J'ai pris un snapshot après chaque étape importante, avec des noms du genre `2026-10-03_1652_fresh-install`. Il y a deux jeux de VM dans VMware : « Labo » (mes machines de travail) et « Demo » (des clones prêts pour la vidéo du POC, avec un snapshot `fresh install`). Les deux jeux utilisent les mêmes adresses : il ne faut jamais les allumer en même temps.

## 5. SRV-LIN1-01 (DNS, DHCP, LDAP, LAM, routeur)

### 5.1 Installation de Debian

Installation de Debian 13 avec l'ISO netinst :

| Question | Réponse |
|---|---|
| Langue, pays, clavier | Français, Suisse, Suisse romand |
| Nom de la machine / domaine | `srv-lin1-01` / `lin1.local` |
| Utilisateur | `cpnv` (avec `sudo`) |
| Partitionnement | assisté, disque entier, une seule partition |
| Logiciels | uniquement « serveur SSH » et « utilitaires usuels du système » (pas de bureau) |

La première carte (NAT) reçoit une adresse en DHCP pendant l'installation, ce qui permet d'avoir Internet dès le début.

### 5.2 Lancer le script

```bash
sudo bash SRV-LIN1-01.sh
```

Le script fait tout en 3 à 4 minutes. Il s'arrête à la première erreur (`set -euo pipefail`) et affiche chaque étape avec une ligne `=== ... ===`. On peut le relancer sans risque : il ne refait pas ce qui est déjà fait et n'efface jamais l'annuaire.

Toutes les valeurs (adresses, plage DHCP, base LDAP, mots de passe) sont regroupées en haut du script. Les mots de passe ont pour valeur par défaut ceux du labo, mais on peut les passer en variable sans modifier le fichier :

```bash
sudo MDP_ADMIN_LDAP='autre-mot-de-passe' bash SRV-LIN1-01.sh
```

### 5.3 Réseau

Le script trouve les cartes tout seul : le WAN est celle qui a la route par défaut (la carte NAT), le LAN est l'autre. Il écrit ensuite `/etc/network/interfaces` :

```
allow-hotplug <WAN>
iface <WAN> inet dhcp

auto <LAN>
iface <LAN> inet static
    address 10.10.10.11/24
```

Il ne redémarre que la carte LAN, pour ne pas couper une session SSH ouverte sur le WAN. Il met aussi le nom de la machine (`hostnamectl`) et une ligne dans `/etc/hosts`.

### 5.4 Routage et NAT

C'est le « partage réseau » demandé dans la donnée : les machines du réseau interne sortent sur Internet à travers SRV-LIN1-01.

```bash
echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-routage.conf
iptables -t nat -A POSTROUTING -o <WAN> -j MASQUERADE
iptables-save > /etc/iptables/rules.v4
```

La règle est enregistrée dans `/etc/iptables/rules.v4` et rechargée au démarrage par le paquet `iptables-persistent`. Le script vérifie d'abord si la règle existe (`iptables -C`), pour ne pas l'ajouter deux fois quand on le relance.

### 5.5 DNS et DHCP avec dnsmasq

Toute la configuration est dans `/etc/dnsmasq.d/lin1.conf` :

```
interface=<LAN>
listen-address=127.0.0.1
bind-interfaces
domain=lin1.local
local=/lin1.local/
expand-hosts
host-record=srv-lin1-01.lin1.local,srv-lin1-01,10.10.10.11
host-record=srv-lin1-02.lin1.local,srv-lin1-02,10.10.10.22
host-record=nas-lin1-01.lin1.local,nas-lin1-01,10.10.10.33
dhcp-range=10.10.10.100,10.10.10.200,255.255.255.0,12h
dhcp-option=option:router,10.10.10.11
dhcp-option=option:dns-server,10.10.10.11
dhcp-authoritative
no-hosts
```

Quelques explications :

- dnsmasq n'écoute que sur le LAN et sur la machine elle-même. Il ne répond pas côté WAN, donc pas de DHCP « sauvage » sur le réseau NAT de VMware ;
- `local=/lin1.local/` : les noms en `lin1.local` ne partent jamais vers les DNS d'Internet ;
- `host-record` crée en même temps le nom court, le nom complet et la résolution inverse (PTR) ;
- `no-hosts` : dnsmasq ne lit pas le `/etc/hosts` de la machine, parce qu'il contient `127.0.1.1 srv-lin1-01` et qu'on aurait alors une mauvaise réponse pour SRV-LIN1-01 ;
- les clients reçoivent SRV-LIN1-01 comme passerelle et comme DNS.

Pour les noms d'Internet, dnsmasq relaie les requêtes vers le DNS qu'il trouve dans `/etc/resolv.conf`, c'est-à-dire celui que le DHCP de VMware a donné à la carte WAN. Le script met `nameserver 127.0.0.1` en premier pour que le serveur lui-même utilise son dnsmasq. Comme la carte WAN est en DHCP, `resolv.conf` est réécrit à chaque renouvellement du bail ; c'est pour ça que le script passe par `/etc/resolv.conf.head` et `/etc/resolv.conf.tail`, que le client DHCP relit à chaque fois.

### 5.6 Annuaire OpenLDAP

Le script répond d'avance aux questions de `slapd` (domaine `lin1.local`, organisation `LIN1-LABO`, mot de passe admin, base MDB) avec `debconf-set-selections`, puis installe le paquet. L'administrateur est `cn=admin,dc=lin1,dc=local`.

Ensuite, si l'unité `ou=People` n'existe pas encore, il ajoute tout l'annuaire d'un coup avec `ldapadd` :

- trois unités : `ou=People` (utilisateurs), `ou=Groups` (groupes), `ou=Services` (compte de Nextcloud) ;
- le compte de service `cn=nextcloud,ou=Services,dc=lin1,dc=local` ;
- les trois groupes `posixGroup` avec leur `gidNumber` et leurs membres (`memberUid`) ;
- les cinq utilisateurs (`inetOrgPerson` + `posixAccount`), avec uid, nom, `uidNumber`, `gidNumber` du groupe principal, dossier `/home/<uid>`, adresse `<uid>@lin1.local`.

Les mots de passe ne sont jamais écrits en clair dans l'annuaire : le script les hache d'abord avec `slappasswd` (format `{SSHA}`). Un utilisateur dans le fichier LDIF ressemble à ça :

```
dn: uid=dev01,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: dev01
cn: Developpeur 01
sn: Developpeur
uidNumber: 13001
gidNumber: 10002
homeDirectory: /home/dev01
loginShell: /bin/bash
mail: dev01@lin1.local
userPassword: {SSHA}...
```

Si l'annuaire est déjà rempli, le script n'y touche pas. L'ancien script faisait un `rm -rf /var/lib/ldap/*` à chaque passage, ce qui effaçait tout ce qu'on avait ajouté entre-temps (dev02 par exemple).

### 5.7 LAM (LDAP Account Manager)

LAM est installé avec le paquet Debian `ldap-account-manager` (il amène Apache et PHP). Le paquet livre une configuration d'exemple pour `dc=my-domain,dc=com`. Le script corrige le fichier `/var/lib/ldap-account-manager/config/lam.conf` avec `sed` : compte admin, base `dc=lin1,dc=local`, groupes dans `ou=Groups`, fuseau horaire `Europe/Zurich`. Comme `sed -i` recrée le fichier, il faut ensuite lui remettre le bon propriétaire (`www-data`), sinon Apache ne peut plus le lire et LAM affiche une erreur.

LAM se trouve sur `http://10.10.10.11/lam`. On s'y connecte avec le compte `admin` et le mot de passe de l'administrateur LDAP. Les onglets « Utilisateurs » et « Groupes » montrent les entrées de l'annuaire.

## 6. NAS-LIN1-01 (OpenMediaVault 8.3.1)

### 6.1 Installation

L'ISO d'OMV est un installateur en mode texte proche de celui de Debian. Réponses : Français, Suisse, clavier suisse romand, nom `nas-lin1-01`, domaine `lin1.local`, mot de passe root. Le système va sur le premier disque (`sda`). Attention, les quatre disques font 10 Go : il faut bien choisir le premier, les autres servent au RAID.

La VM a quatre disques :

| Disque VMware | Nom dans Linux | Rôle |
|---|---|---|
| disque 1 | `sda` | système OMV |
| disque 2 | `sdb` | RAID1 |
| disque 3 | `sdc` | RAID1 (c'est le « disque n° 3 » du POC) |
| disque 4 | `sdd` | disque vierge de rechange pour la reconstruction |

Après l'installation, l'interface web est sur `http://10.10.10.33` (compte `admin`). Le mot de passe par défaut d'OMV est `openmediavault` ; il faut le changer à la première connexion. Je ne note pas le mot de passe actuel ici (à compléter dans mon fichier de mots de passe, qui n'est pas publié).

### 6.2 Configuration

J'ai fait les réglages en ligne de commande sur le NAS, mais le résultat est exactement le même que dans l'interface web. Voici où on les retrouve dans l'interface :

1. Adresse IP fixe `10.10.10.33/24`, passerelle et DNS `10.10.10.11` (Réseau > Interfaces). La carte est ensuite passée en Host Only dans VMware.
2. Plugin RAID : dans OMV 8, la gestion du RAID logiciel est un plugin à installer (`openmediavault-md`, Système > Plugins).
3. RAID1 `md0` avec `sdb` et `sdc` (page RAID ajoutée par le plugin, dans Stockage).
4. Système de fichiers ext4 sur `md0`, monté par OMV (Stockage > Systèmes de fichiers).
5. Dossier partagé `nfs-lin1` sur ce système de fichiers (Stockage > Dossiers partagés).
6. Service NFS activé, partage `nfs-lin1` autorisé pour le réseau `10.10.10.0/24` en lecture et écriture (Services > NFS).
7. Clavier `ch/fr` sur la console.

Un piège que j'ai découvert en clonant le NAS : OMV écrit sa configuration réseau dans `/etc/netplan/20-openmediavault-enp0s16.yaml` et la lie à l'**adresse MAC** de la carte (`match: macaddress`). Dès que la MAC change (clone de la VM, import de l'OVA sur un autre PC), la carte n'est plus reconnue et le NAS démarre sans adresse IP. Pour que l'OVA marche partout, j'ai ajouté un petit fichier à moi, `/etc/netplan/90-lin1-secours.yaml`, qui donne la même adresse à la carte en la choisissant par son nom (`en*`) :

```yaml
network:
  version: 2
  ethernets:
    secours:
      match:
        name: "en*"
      addresses: [10.10.10.33/24]
      routes:
        - to: 0.0.0.0/0
          via: 10.10.10.11
          metric: 200
      nameservers:
        addresses: [10.10.10.11]
        search: [lin1.local]
      dhcp4: no
```

Quand la MAC d'origine est là, c'est la configuration d'OMV qui est utilisée (son fichier passe en premier). La métrique 200 évite que netplan se plaigne de deux routes par défaut. Si on change un jour l'adresse IP dans l'interface d'OMV, il faut aussi modifier ce fichier, puis `netplan apply`.

On vérifie le RAID en ligne de commande avec :

```bash
cat /proc/mdstat
mdadm --detail /dev/md0
```

En temps normal, `mdadm --detail` affiche `State : clean`, `Active Devices : 2` et les deux disques `active sync`.

### 6.3 Cible iSCSI avec tgt

Comme expliqué au point 3.4, OMV 8 n'a pas de plugin iSCSI. J'ai installé `tgt` à la main :

```bash
apt install tgt
```

La cible est un fichier de 6 Go sur le système de fichiers du RAID (OMV le monte sous `/srv/dev-disk-by-uuid-...`). La définition de la cible se trouve dans `/etc/tgt/conf.d/` :

```
# Cible iSCSI du labo : un disque de 6 Go (fichier sur le RAID1) pour Nextcloud
<target iqn.2026-10.local.lin1:iscsi1>
    backing-store /srv/dev-disk-by-uuid-50df5c31-fd39-47dd-bac6-7b0fe7b642d8/iscsi/iscsi1.img
    initiator-address 10.10.10.0/24
</target>
```

L'accès est ouvert à tout le réseau `10.10.10.0/24` et pas seulement à `10.10.10.22` : au moment où le script de SRV-LIN1-02 se connecte au disque, la machine a encore son adresse DHCP.

Le nom `iqn.2026-10.local.lin1:iscsi1` suit la règle des noms iSCSI : `iqn.<année-mois>.<domaine à l'envers>:<nom>`. Pour appliquer et vérifier :

```bash
systemctl enable --now tgt
tgt-admin --update ALL
tgt-admin --show
```

`tgt-admin --show` doit montrer la cible avec un LUN 1 de 6 Go. L'accès est limité par adresse IP, sans mot de passe CHAP (voir les limites).

## 7. SRV-LIN1-02 (Nextcloud)

### 7.1 Installation de Debian

Même installation que SRV-LIN1-01 (nom `srv-lin1-02`), avec une seule carte réseau. Au premier démarrage, la machine reçoit une adresse en DHCP de SRV-LIN1-01 (entre `.100` et `.200`) : c'est avec cette adresse qu'on lance le script, et c'est le script qui met l'adresse fixe à la fin.

### 7.2 Lancer le script

```bash
sudo bash SRV-LIN1-02.sh
```

Il faut que SRV-LIN1-01 et le NAS tournent. Le script le vérifie au début (ping de SRV-LIN1-01, du NAS et de `deb.debian.org`) et s'arrête avec un message clair si ce n'est pas le cas. Il dure 2 à 3 minutes chez moi (2 minutes pendant la répétition du POC), un peu plus si Internet est lent : le plus long, c'est le téléchargement de Nextcloud et des paquets PHP. À la fin, l'adresse passe à `10.10.10.22` : une session SSH ouverte sur l'ancienne adresse se coupe, c'est normal.

### 7.3 Disque iSCSI

```bash
iscsiadm -m discovery -t sendtargets -p 10.10.10.33
iscsiadm -m node -T iqn.2026-10.local.lin1:iscsi1 -p 10.10.10.33 --login
iscsiadm -m node -T iqn.2026-10.local.lin1:iscsi1 -p 10.10.10.33 -o update -n node.startup -v automatic
```

La dernière commande fait que la connexion se refait toute seule au démarrage. Le disque apparaît sous `/dev/disk/by-path/...iscsi1-lun-1` (en général `/dev/sdb`). Le script ne le formate en ext4 que s'il est vide (`blkid` ne trouve rien) : on ne risque pas d'effacer les données en relançant le script.

Le montage est dans `/etc/fstab`, avec l'UUID du disque et les options `_netdev,nofail` : `_netdev` attend que le réseau soit prêt, et `nofail` évite que le serveur reste bloqué au démarrage si le NAS est éteint.

```
UUID=<uuid> /mnt/iscsi1 ext4 _netdev,nofail,defaults 0 0
```

Le script ajoute aussi une petite règle systemd (`RequiresMountsFor=/mnt/iscsi1`) pour Apache et MariaDB : ils ne démarrent qu'une fois le disque monté. Sans ça, Nextcloud démarrait parfois avant le disque et ne trouvait plus ses données.

### 7.4 Partage NFS

```
10.10.10.33:/nfs-lin1 /mnt/nfs-lin1 nfs4 _netdev,nofail,defaults 0 0
```

OMV exporte ses partages en NFSv4 avec `/export` comme racine, c'est pour ça que le chemin côté client est `/nfs-lin1` et non `/export/nfs-lin1`. Le script affiche aussi `showmount -e 10.10.10.33` au passage.

### 7.5 MariaDB

Le script crée la base `nextcloud` (en `utf8mb4`) et l'utilisateur `nextcloud@localhost` avec tous les droits sur cette base seulement. MariaDB n'écoute qu'en local (réglage par défaut de Debian), donc la base n'est pas joignable depuis le réseau.

### 7.6 Téléchargement de Nextcloud

Le script télécharge `latest.tar.bz2` depuis `download.nextcloud.com` et vérifie la somme de contrôle SHA-256 avant de décompresser l'archive dans `/var/www/nextcloud`. Si la somme ne correspond pas, il s'arrête. Si Nextcloud est déjà là, il ne le retélécharge pas.

### 7.7 PHP, Apache et certificat SSL

Les réglages PHP conseillés par Nextcloud (mémoire 512 Mo, taille des envois, OPcache, APCu en ligne de commande) sont dans `/etc/php/<version>/mods-available/nextcloud.ini`. Le script lit la version de PHP lui-même, il n'y a rien d'écrit en dur.

Le certificat est auto-signé, valable 825 jours, pour les noms `srv-lin1-02.lin1.local`, `srv-lin1-02` et l'adresse `10.10.10.22` :

```bash
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout /etc/ssl/lin1/srv-lin1-02.key -out /etc/ssl/lin1/srv-lin1-02.crt \
    -subj "/C=CH/O=LIN1-LABO/CN=srv-lin1-02.lin1.local" \
    -addext "subjectAltName=DNS:srv-lin1-02.lin1.local,DNS:srv-lin1-02,IP:10.10.10.22"
```

Le site Apache `/etc/apache2/sites-available/nextcloud.conf` contient deux parties :

- le port 80 renvoie tout vers HTTPS (redirection 301) ;
- le port 443 sert Nextcloud sous `/nextcloud`, avec le certificat, l'en-tête HSTS conseillé par Nextcloud, et une redirection de `https://10.10.10.22/` vers `/nextcloud/`.

Les sites par défaut d'Apache sont désactivés.

### 7.8 Installation et réglages de Nextcloud

L'installation se fait en ligne de commande avec `occ maintenance:install` (base MariaDB, compte `admin`, dossier de données `/mnt/iscsi1/nextcloud-data`). Dans tout ce document, `occ` veut dire :

```bash
sudo -u www-data php /var/www/nextcloud/occ
```

Ensuite le script règle :

- les adresses autorisées (`trusted_domains`) : `10.10.10.22`, `srv-lin1-02` et `srv-lin1-02.lin1.local` ;
- la langue `fr`, la région `fr_CH`, l'indicatif téléphonique `CH` et le fuseau `Europe/Zurich` ;
- le cache APCu ;
- les tâches de fond par `cron` toutes les 5 minutes (`/etc/cron.d/nextcloud`), comme le recommande Nextcloud ;
- pas de fichiers d'exemple et pas de fenêtre d'accueil (voir 3.7).

### 7.9 Connexion à l'annuaire LDAP

L'application `user_ldap` est activée et configurée avec `occ ldap:set-config` :

| Réglage | Valeur |
|---|---|
| Serveur | `ldap://10.10.10.11`, port 389 |
| Compte de lecture | `cn=nextcloud,ou=Services,dc=lin1,dc=local` |
| Utilisateurs | `ou=People`, filtre `(objectClass=inetOrgPerson)` |
| Connexion | avec l'`uid` (filtre `(&(objectClass=inetOrgPerson)(uid=%uid))`) |
| Nom interne | l'`uid` (le dossier de dev01 s'appelle donc bien `dev01`) |
| Nom affiché / courriel | `cn` / `mail` |
| Groupes | `ou=Groups`, filtre `(objectClass=posixGroup)`, membres par `memberUid` |
| Quota par défaut | 10 Mo |

Le script termine par `occ ldap:test-config s01`, qui doit répondre que la configuration est valide et que la connexion a réussi.

### 7.10 Dossiers de groupe et calendrier

Le script installe les applications `groupfolders` et `calendar`, puis crée les trois dossiers avec une petite fonction :

```bash
dossier_de_groupe clients    20MB manager
dossier_de_groupe logiciels  20MB ingenieur developpeur
dossier_de_groupe commun     30MB manager ingenieur developpeur
```

Pour chaque dossier, la fonction le crée s'il n'existe pas, règle le quota, active les droits avancés (ACL) et donne lecture, écriture et suppression aux groupes indiqués. Un utilisateur qui n'est dans aucun de ces groupes ne voit tout simplement pas le dossier.

### 7.11 Sauvegarde de nuit

Le script installe `/usr/local/sbin/sauvegarde-nextcloud.sh`, lancé chaque nuit à 2 h 30 par `/etc/cron.d/sauvegarde-nextcloud`. Il dépose dans `/mnt/nfs-lin1/sauvegardes/` :

- un export de la base (`nextcloud-base_<date>.sql.gz`, fait avec `mariadb-dump --single-transaction`) ;
- une archive du dossier `config` de Nextcloud (`nextcloud-config_<date>.tar.gz`).

Il garde les 7 dernières de chaque. Si le partage NFS n'est pas monté, il s'arrête sans rien écrire (sinon il remplirait le disque local de SRV-LIN1-02). Le script en fait une première tout de suite, pour vérifier que ça marche.

Les fichiers des utilisateurs ne sont pas copiés : ils sont déjà sur le RAID1 du NAS. Un RAID protège contre la panne d'un disque, mais pas contre une suppression ou une erreur. C'est une limite que je note au chapitre 14.

### 7.12 Adresse fixe

En tout dernier, le script écrit `/etc/network/interfaces` (adresse `10.10.10.22/24`, passerelle `10.10.10.11`) et `/etc/resolv.conf` (`search lin1.local`, `nameserver 10.10.10.11`). Il applique la nouvelle adresse en tâche de fond 3 secondes après la fin, pour laisser le temps d'afficher le résumé. Avant, il arrête le client DHCP (`dhcpcd`) lancé à l'installation : sinon celui-ci garde l'ancienne adresse et, quand il s'arrête au redémarrage suivant, il réécrit `/etc/resolv.conf` sans serveur DNS. Pour la même raison, `resolv.conf` est réécrit une dernière fois tout à la fin. C'est fait en dernier exprès : pendant tout le reste du script, la machine garde son adresse DHCP et la session SSH ne se coupe pas.

## 8. Clients

### 8.1 Fedora 44 (cli-lin1-fedora)

Installation depuis l'ISO « Live » de Fedora 44 Workstation : langue Français (Suisse), disque entier en automatique. Au premier démarrage, j'ai créé le compte local `cpnv` (administrateur). Ensuite :

```bash
sudo hostnamectl set-hostname cli-lin1-fedora
sudo localectl set-x11-keymap ch fr
```

La carte est en Host Only et en DHCP (réglage par défaut de NetworkManager). La machine reçoit une adresse entre `10.10.10.100` et `10.10.10.200`, la passerelle et le DNS `10.10.10.11`, et le domaine `lin1.local`.

Le client de synchronisation Nextcloud n'est pas installé sur Fedora, parce que le POC ne le teste que sur Windows. Si on en a besoin, il est dans les dépôts de Fedora : `sudo dnf install nextcloud-client`.

### 8.2 Windows 11 Pro (cli-lin1-win11)

La VM n'a pas de puce TPM virtuelle (un TPM virtuel oblige VMware à chiffrer toute la VM). Pour passer les contrôles de Windows 11, l'installation utilise les clés de registre bien connues `BypassTPMCheck`, `BypassSecureBootCheck`, `BypassCPUCheck` et `BypassRAMCheck` dans `HKLM\SYSTEM\Setup\LabConfig`. J'ai mis ces commandes dans un fichier de réponses `autounattend.xml`, avec la création du compte local `cpnv` (sans compte Microsoft, qui n'a de toute façon rien à faire dans un labo). La machine est hors domaine, comme demandé.

Le client Nextcloud pour Windows se télécharge sur le site de Nextcloud (j'ai testé la version 34.0.4, fichier `.msi` signé par Nextcloud GmbH). À la connexion, il faut indiquer le serveur `https://10.10.10.22/nextcloud` et accepter le certificat auto-signé. Les fichiers sont synchronisés dans `C:\Users\cpnv\Nextcloud`.

## 9. Authentification SSH par clé

Le SSH n'est volontairement pas dans les scripts : la clé publique est une information propre à l'administrateur et à son poste, elle n'a rien à faire dans un script publié sur GitHub. Je l'ai mis en place à la main, une fois, sur SRV-LIN1-01 et SRV-LIN1-02.

Sur mon PC (Windows, OpenSSH est livré avec Windows 11), j'ai créé une paire de clés réservée au labo :

```powershell
ssh-keygen -t ed25519 -f $HOME\.ssh\id_ed25519_lin1 -C "lin1"
```

J'ai pris `ed25519` plutôt que RSA 4096 comme dans le support : c'est plus court, plus rapide et au moins aussi sûr. J'ai choisi une clé sans phrase de passe, pour que la connexion se fasse vraiment sans rien taper, comme le décrit le POC. La clé privée ne quitte jamais mon PC.

Windows n'a pas `ssh-copy-id`. On fait la même chose à la main (le mot de passe de `cpnv` est demandé une dernière fois) :

```powershell
type $HOME\.ssh\id_ed25519_lin1.pub | ssh cpnv@10.10.10.11 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Depuis Linux, la commande du cours `ssh-copy-id -i ~/.ssh/id_ed25519_lin1.pub cpnv@10.10.10.11` fait exactement ça. Même chose pour SRV-LIN1-02. La clé est liée au compte `cpnv`, pas à l'adresse IP : elle reste valable quand SRV-LIN1-02 passe à `10.10.10.22`.

Connexion :

```powershell
ssh -i $HOME\.ssh\id_ed25519_lin1 cpnv@10.10.10.11
ssh -i $HOME\.ssh\id_ed25519_lin1 cpnv@10.10.10.22
```

Pour ne pas devoir taper `-i` à chaque fois, on peut ajouter ceci dans `$HOME\.ssh\config` :

```
Host 10.10.10.11 10.10.10.22 srv-lin1-01 srv-lin1-02
    User cpnv
    IdentityFile ~/.ssh/id_ed25519_lin1
```

J'ai laissé la connexion par mot de passe active sur les serveurs (voir les limites). Pour la couper, comme le conseille l'annexe du cours, on met `PasswordAuthentication no` dans `/etc/ssh/sshd_config` puis `sudo systemctl restart ssh`, mais seulement après avoir vérifié que la clé marche, sinon on s'enferme dehors.

## 10. Exemples d'utilisation

### 10.1 Réseau, DNS et Internet

Sur SRV-LIN1-01 :

```bash
ip -br addr                          # la carte LAN doit avoir 10.10.10.11/24
ping -c 3 www.google.com             # Internet par la carte WAN
sudo iptables -t nat -L -n -v        # la règle MASQUERADE et ses compteurs
cat /var/lib/misc/dnsmasq.leases     # les clients qui ont reçu une adresse
```

Depuis SRV-LIN1-02 ou un client :

```bash
nslookup srv-lin1-01                 # -> 10.10.10.11
nslookup nas-lin1-01.lin1.local      # -> 10.10.10.33
nslookup 10.10.10.22                 # résolution inverse -> srv-lin1-02.lin1.local
ping -c 3 www.google.com             # Internet à travers le NAT de SRV-LIN1-01
```

Sous Windows : `ipconfig /all` (adresse, passerelle `10.10.10.11`, DNS `10.10.10.11`, suffixe `lin1.local`).

### 10.2 Annuaire LDAP

Lister les utilisateurs ou un groupe (lecture anonyme, sans mot de passe) :

```bash
ldapsearch -x -b dc=lin1,dc=local '(objectClass=inetOrgPerson)' uid cn uidNumber gidNumber
ldapsearch -x -b dc=lin1,dc=local '(cn=developpeur)' memberUid
```

Ajouter un utilisateur, par exemple dev02 dans le groupe developpeur (c'est ce qu'on fait au POC). On écrit un fichier `dev02.ldif` :

```
dn: uid=dev02,ou=People,dc=lin1,dc=local
objectClass: inetOrgPerson
objectClass: posixAccount
uid: dev02
cn: Developpeur 02
sn: Developpeur
uidNumber: 13002
gidNumber: 10002
homeDirectory: /home/dev02
loginShell: /bin/bash
mail: dev02@lin1.local

dn: cn=developpeur,ou=Groups,dc=lin1,dc=local
changetype: modify
add: memberUid
memberUid: dev02
```

La première partie crée l'utilisateur avec `developpeur` comme groupe principal (`gidNumber: 10002`), la deuxième l'ajoute aussi comme membre du groupe (c'est ce que Nextcloud regarde). Puis :

```bash
ldapadd -x -D cn=admin,dc=lin1,dc=local -W -f dev02.ldif
ldappasswd -x -D cn=admin,dc=lin1,dc=local -W -s secret uid=dev02,ou=People,dc=lin1,dc=local
ldapsearch -x -b dc=lin1,dc=local '(uid=dev02)'
```

`-W` demande le mot de passe de l'administrateur LDAP. `ldappasswd` met le mot de passe `secret` sous forme hachée. On peut aussi tout faire dans LAM : Utilisateurs > Nouvel utilisateur, identifiant `dev02`, groupe principal `developpeur` dans l'onglet Unix, puis « Définir le mot de passe ».

Changer le mot de passe d'un utilisateur ou supprimer un compte :

```bash
ldappasswd -x -D cn=admin,dc=lin1,dc=local -W -S uid=ing02,ou=People,dc=lin1,dc=local
ldapdelete -x -D cn=admin,dc=lin1,dc=local -W uid=dev02,ou=People,dc=lin1,dc=local
```

(Pour une suppression, il faut aussi retirer la ligne `memberUid` du groupe.)

### 10.3 Stockage

Sur SRV-LIN1-02 :

```bash
sudo iscsiadm -m session                 # la session vers iqn.2026-10.local.lin1:iscsi1
lsblk                                    # le disque iSCSI (6 Go) monté sur /mnt/iscsi1
df -h /mnt/iscsi1 /mnt/nfs-lin1          # les deux montages et la place libre
showmount -e 10.10.10.33                 # les partages NFS proposés par le NAS
ls /mnt/nfs-lin1/sauvegardes             # les sauvegardes de nuit
```

Sur le NAS :

```bash
cat /proc/mdstat
mdadm --detail /dev/md0
tgt-admin --show
```

### 10.4 Nextcloud

Dans le navigateur : `https://10.10.10.22/nextcloud`. Le navigateur prévient que le certificat n'est pas reconnu (il est auto-signé) : on clique sur « Avancé » puis on accepte le risque. En cliquant sur le cadenas, on voit le certificat `srv-lin1-02.lin1.local` émis par `LIN1-LABO`.

Commandes utiles sur SRV-LIN1-02 :

```bash
sudo -u www-data php /var/www/nextcloud/occ status                 # version, installé, mode maintenance
sudo -u www-data php /var/www/nextcloud/occ ldap:test-config s01   # connexion à l'annuaire
sudo -u www-data php /var/www/nextcloud/occ user:list              # utilisateurs connus
sudo -u www-data php /var/www/nextcloud/occ user:info dev01        # groupes et quota de dev01
sudo -u www-data php /var/www/nextcloud/occ groupfolders:list      # dossiers de groupe, quotas, groupes
```

Retrouver un fichier sur le disque (preuve que les fichiers sont bien sur le stockage du NAS) :

```bash
sudo ls -l /mnt/iscsi1/nextcloud-data/dev01/files
sudo find /mnt/iscsi1/nextcloud-data -name test.txt
```

Les fichiers perso sont dans `nextcloud-data/<utilisateur>/files`, ceux des dossiers de groupe dans `nextcloud-data/__groupfolders/<numéro>/`.

## 11. Dépannage

| Problème | Cause probable | Ce que je fais |
|---|---|---|
| SRV-LIN1-01 n'a pas `10.10.10.11` | script pas encore passé, ou carte LAN débranchée dans VMware | `ip -br addr`, `cat /etc/network/interfaces`, `sudo ifup <LAN>` ; vérifier dans VMware que la 2e carte est en Host Only et connectée |
| Le script SRV-LIN1-01 dit « je ne trouve pas les deux cartes » | une seule carte, ou pas de route par défaut (pas d'Internet sur la carte NAT) | vérifier les cartes dans VMware, `ip route` ; on peut forcer : `sudo WAN=enp0s16 LAN=enp0s17 bash SRV-LIN1-01.sh` (noms à adapter selon `ip a`) |
| Les clients n'ont pas d'adresse | dnsmasq arrêté, ou le DHCP de VMware actif sur VMnet1 | `systemctl status dnsmasq`, `journalctl -u dnsmasq` ; vérifier que le DHCP de VMnet1 est désactivé ; sur le client `sudo nmcli con up <connexion>` ou `ipconfig /renew` |
| Les clients ont une adresse mais pas Internet | routage ou NAT absent | sur SRV-LIN1-01 : `sysctl net.ipv4.ip_forward` (doit valoir 1), `sudo iptables -t nat -L -n -v`, `ping www.google.com` depuis SRV-LIN1-01 lui-même |
| `nslookup srv-lin1-01` ne répond pas | mauvais DNS sur la machine | `cat /etc/resolv.conf` (doit contenir `nameserver 10.10.10.11`) ; `nslookup srv-lin1-01 10.10.10.11` pour interroger dnsmasq directement |
| SRV-LIN1-01 ne résout plus Internet après un moment | `resolv.conf` réécrit par le client DHCP | vérifier que `/etc/resolv.conf.head` contient `nameserver 127.0.0.1` |
| LAM affiche une erreur de configuration | `lam.conf` illisible par Apache | `sudo chown www-data:root /var/lib/ldap-account-manager/config/lam.conf` |
| `ldapadd` répond « Invalid credentials (49) » | mauvais mot de passe admin LDAP, souvent à cause du `$` | taper le mot de passe au clavier avec `-W` ; en ligne de commande, le mettre entre apostrophes simples (`'Pa$$w0rd'`), sinon le shell remplace `$$` |
| `ldapadd` répond « Already exists (68) » | l'entrée existe déjà | rien à faire, ou `ldapsearch` pour vérifier |
| Le script SRV-LIN1-02 s'arrête à « Vérifications » | SRV-LIN1-01 ou le NAS éteint, ou pas d'Internet | démarrer les machines dans l'ordre : SRV-LIN1-01, NAS, puis SRV-LIN1-02 |
| « je ne vois pas le disque iSCSI » | tgt arrêté sur le NAS, ou adresse refusée | sur le NAS : `tgt-admin --show` ; sur SRV-LIN1-02 : `sudo iscsiadm -m discovery -t sendtargets -p 10.10.10.33` |
| Nextcloud affiche une erreur après un redémarrage | disque iSCSI pas monté (NAS démarré après SRV-LIN1-02) | `df -h /mnt/iscsi1` ; démarrer le NAS, puis `sudo iscsiadm -m node --loginall=automatic`, `sudo mount -a`, `sudo systemctl restart mariadb apache2` |
| « Accès par un domaine non approuvé » | adresse ou nom pas dans `trusted_domains` | `occ config:system:set trusted_domains 4 --value=<nom>` |
| Un utilisateur LDAP ne peut pas se connecter à Nextcloud | LDAP injoignable, ou mauvais mot de passe | `occ ldap:test-config s01`, `occ ldap:search dev` ; tester le mot de passe avec `ldapwhoami -x -D uid=dev01,ou=People,dc=lin1,dc=local -W` |
| Un utilisateur ne voit pas un dossier de groupe | il n'est pas `memberUid` du groupe | `ldapsearch -x -b dc=lin1,dc=local '(cn=developpeur)' memberUid`, `occ user:info dev02` |
| Envoi refusé, « quota dépassé » (erreur 507 en WebDAV) | quota atteint, c'est voulu | supprimer des fichiers ou augmenter le quota (`occ groupfolders:quota`, ou le quota de l'utilisateur dans l'administration) |
| Le client Windows refuse de se connecter | certificat auto-signé | dans la fenêtre du client, cocher « faire confiance à ce certificat » ; vérifier que l'adresse est bien `https://10.10.10.22/nextcloud` |
| SSH : « REMOTE HOST IDENTIFICATION HAS CHANGED » | la machine a été réinstallée ou un autre jeu de VM a la même adresse | `ssh-keygen -R 10.10.10.11` sur le PC, puis se reconnecter |
| SSH demande un mot de passe | clé pas installée ou mauvais fichier de clé | `ssh -v -i $HOME\.ssh\id_ed25519_lin1 cpnv@10.10.10.11` ; sur le serveur, droits de `~/.ssh` (700) et de `authorized_keys` (600) |
| Le NAS démarre sans adresse IP (la console n'affiche pas d'adresse sous « workbench ») | la MAC de la carte a changé (clone, OVA) et le fichier de secours manque | se connecter en root sur la console, `ip a` pour le nom de la carte, recréer `/etc/netplan/90-lin1-secours.yaml` (voir 6.2), `netplan apply` |
| SSH vers `10.10.10.11` ou `.22` : « Connection timed out » juste après avoir changé de jeu de VM (Labo ↔ Demo) | le PC garde en mémoire l'adresse MAC de l'autre VM (cache ARP) | attendre 30 s à 1 min et réessayer |
| Après un redémarrage, SRV-LIN1-02 n'a plus de DNS (`resolv.conf` « Generated by dhcpcd » sans `nameserver`) | ancienne version du script : le client DHCP de l'installation tournait encore | corrigé dans le script (il arrête `dhcpcd`). À la main : `printf 'search lin1.local\nnameserver 10.10.10.11\n' \| sudo tee /etc/resolv.conf` |
| `grub rescue>` au démarrage d'une VM, « disk needs repair » dans VMware | disque virtuel abîmé (voir 14.7) | revenir au dernier snapshot, puis relancer le script si besoin |

## 12. Maintenance

### 12.1 Remplacer un disque du RAID1

C'est la manipulation du POC (point 33), et c'est aussi ce qu'on ferait pour un vrai disque en panne. On travaille sur la console du NAS en root.

1. Contrôler l'état et repérer le disque en panne :

   ```bash
   cat /proc/mdstat
   mdadm --detail /dev/md0
   lsblk
   ```

2. Marquer le disque comme défectueux (au POC, c'est le « disque n° 3 », donc `sdc`), puis le retirer du RAID :

   ```bash
   mdadm --manage /dev/md0 --fail /dev/sdc
   mdadm --detail /dev/md0        # State : clean, degraded ; sdc en « faulty »
   mdadm --manage /dev/md0 --remove /dev/sdc
   ```

   À ce moment, le RAID fonctionne en mode dégradé, sur un seul disque. Les données restent accessibles : Nextcloud continue de marcher.

3. Mettre le disque neuf. Dans ma VM, il y a déjà un disque vierge de rechange (`sdd`). Avec une vraie machine, on change le disque physique, puis on vérifie son nom avec `lsblk`. Ensuite :

   ```bash
   mdadm --manage /dev/md0 --add /dev/sdd
   ```

4. Suivre la reconstruction :

   ```bash
   mdadm --detail /dev/md0        # State : clean, degraded, recovering ; Rebuild Status : xx% complete
   watch -n 2 cat /proc/mdstat    # barre de progression, Ctrl+C pour quitter
   ```

   Quand c'est fini, `mdadm --detail /dev/md0` affiche à nouveau `State : clean` avec deux disques `active sync`. Sur des disques de 10 Go, ça a pris 66 secondes pendant la répétition du POC. Attention : la reconstruction réécrit tout le disque neuf, donc le fichier du disque virtuel grossit de 10 Go sur le PC hôte.

On peut aussi suivre l'état dans l'interface web d'OMV, sur la page RAID du plugin. Si un disque contient d'anciennes données (signature RAID ou système de fichiers), il faut d'abord l'effacer (`wipefs -a /dev/sdX`) avant de l'ajouter. Je ne le fais jamais sans avoir vérifié trois fois le nom du disque avec `lsblk`.

Si on veut ensuite revenir à la configuration de départ (sdb + sdc), on refait la même chose dans l'autre sens. Dans le labo, le plus simple est de revenir au snapshot du NAS.

### 12.2 Ajouter un utilisateur ou changer ses droits

Tout se passe dans l'annuaire, sur SRV-LIN1-01 (voir 10.2) ou dans LAM. Il faut choisir un `uidNumber` libre : je garde la logique 11xxx pour les managers, 12xxx pour les ingénieurs et 13xxx pour les développeurs. Pour donner l'accès à un dossier de groupe, il suffit d'ajouter l'utilisateur comme `memberUid` du bon groupe. Dans Nextcloud il n'y a rien à faire, l'utilisateur apparaît à sa première connexion.

### 12.3 Sauvegarde et restauration de Nextcloud

Lancer une sauvegarde à la main :

```bash
sudo /usr/local/sbin/sauvegarde-nextcloud.sh
ls -l /mnt/nfs-lin1/sauvegardes
```

Restaurer la base et la configuration (exemple avec la sauvegarde du 4 octobre à 2 h 30) :

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --on
zcat /mnt/nfs-lin1/sauvegardes/nextcloud-base_2026-10-04_0230.sql.gz | sudo mariadb nextcloud
sudo tar -xzf /mnt/nfs-lin1/sauvegardes/nextcloud-config_2026-10-04_0230.tar.gz -C /var/www/nextcloud
sudo -u www-data php /var/www/nextcloud/occ maintenance:mode --off
```

Si des fichiers ont été déposés directement dans le dossier de données, on demande à Nextcloud de les relire : `occ files:scan --all`.

### 12.4 Mises à jour

Debian, sur les deux serveurs :

```bash
sudo apt update && sudo apt upgrade
```

Nextcloud ne vient pas d'un paquet Debian, il se met à jour avec son propre outil :

```bash
sudo -u www-data php /var/www/nextcloud/updater/updater.phar
sudo -u www-data php /var/www/nextcloud/occ upgrade
```

OMV se met à jour dans son interface (Système > Gestion des mises à jour). Avant chaque mise à jour, je prends un snapshot de la VM.

### 12.5 Certificat

Le certificat est valable 825 jours. Pour le renouveler, on efface les deux fichiers de `/etc/ssl/lin1/` et on relance le script SRV-LIN1-02 (il recrée le certificat s'il manque et ne touche pas au reste), puis `sudo systemctl reload apache2`.

### 12.6 Snapshots

Je prends un snapshot avant chaque manipulation risquée (mise à jour, script, RAID), VM de préférence éteinte. Je supprime les vieux snapshots de temps en temps : chaque snapshot garde un disque de différences qui grossit et prend de la place sur le PC.

## 13. Bonnes pratiques

Ce que j'ai essayé d'appliquer, et ce que je conseille si on reprend le projet :

- Les scripts sont relançables. Ils vérifient avant d'agir (annuaire déjà rempli, règle iptables déjà là, disque déjà formaté, Nextcloud déjà installé). Ça m'a sauvé quand j'ai dû reconstruire SRV-LIN1-02 après l'incident du disque plein (14.7) : j'ai juste relancé le script.
- Toutes les valeurs sont en haut des scripts, et les mots de passe peuvent être passés en variable. On ne devrait jamais garder les mots de passe du labo en production.
- Un compte de service en lecture seule pour Nextcloud plutôt que le compte admin LDAP.
- Les mots de passe des utilisateurs sont hachés dans l'annuaire (`{SSHA}`).
- Les services n'écoutent que là où il faut : dnsmasq sur le LAN, MariaDB en local.
- On démarre toujours dans l'ordre SRV-LIN1-01, puis le NAS, puis SRV-LIN1-02, puis les clients. On éteint dans l'ordre inverse.
- On éteint les VM proprement (`sudo poweroff`, ou « Arrêter le système invité » dans VMware) et jamais en éteignant le PC avec les VM allumées.
- On met les VM sur un disque qui a de la place et on surveille la place libre avant de les démarrer (Windows 11 peut prendre 15 Go d'un coup). Dans mon cas, après l'incident du chapitre 14.7, j'ai déplacé tout le projet sur un disque réseau de 3,7 To.
- Snapshot avant chaque changement, avec un nom daté et parlant.
- Un fichier de mots de passe tenu à part, jamais publié sur GitHub (le `.gitignore` du dépôt l'exclut).

## 14. Limites et avertissements

### 14.1 Certificat auto-signé

Le certificat de Nextcloud n'est signé par aucune autorité reconnue : chaque navigateur et chaque client affiche un avertissement, et il faut l'accepter à la main. La connexion est bien chiffrée, mais l'utilisateur ne peut pas vérifier qu'il parle au bon serveur. En vrai, il faudrait un certificat d'une autorité interne (installée sur les postes) ou de Let's Encrypt avec un vrai nom de domaine. L'en-tête HSTS n'aide pas ici : un navigateur qui a mémorisé le site refusera plus tard un autre certificat sans passer par l'avertissement.

### 14.2 Mots de passe du labo

Les mots de passe sont ceux imposés par le cours (`Pa$$w0rd` pour les comptes système et admin, `secret` pour les utilisateurs LDAP) et ils sont identiques sur toutes les machines. Ils sont aussi la valeur par défaut dans les scripts. Quelqu'un qui en connaît un les connaît tous. C'est acceptable dans un labo isolé, pas ailleurs. Le mot de passe de configuration de LAM (pages « LAM configuration ») est resté celui livré par le paquet Debian : il faudrait le changer.

### 14.3 SSH

La connexion par clé marche, mais la connexion par mot de passe est restée active (j'ai préféré ne pas risquer de m'enfermer dehors pendant les tests). La clé n'a pas de phrase de passe : quelqu'un qui copie le fichier de clé privée de mon PC peut se connecter aux deux serveurs. La procédure pour couper les mots de passe est au chapitre 9.

### 14.4 iSCSI sans CHAP

La cible iSCSI est filtrée uniquement par adresse IP, sans authentification CHAP. Une machine du réseau interne qui prendrait une adresse autorisée pourrait se connecter au disque. Il ne faut jamais connecter ce disque à deux machines en même temps : ext4 n'est pas fait pour ça et les données seraient abîmées.

### 14.5 LDAP sans chiffrement

Nextcloud parle à l'annuaire en `ldap://` simple, sans TLS. Quand un utilisateur se connecte, son mot de passe passe en clair sur le réseau interne entre SRV-LIN1-02 et SRV-LIN1-01. Il faudrait activer `ldaps://` ou StartTLS. Par défaut, l'annuaire Debian peut aussi être lu de façon anonyme (sauf les mots de passe), ce qui est pratique pour `ldapsearch` mais montre la liste des utilisateurs à tout le réseau.

### 14.6 Les sauvegardes contiennent des secrets

L'archive de configuration contient `config.php`, avec le mot de passe de la base, le mot de passe du compte LDAP de Nextcloud et les clés internes de Nextcloud. L'export de la base contient les comptes. Le partage NFS est ouvert à tout le réseau `10.10.10.0/24` : n'importe quelle machine du réseau peut le monter et lire ces fichiers. Il faudrait limiter l'export NFS à `10.10.10.22` ou chiffrer les sauvegardes. Les fichiers des utilisateurs ne sont pas sauvegardés du tout, seulement protégés par le RAID1, qui ne protège pas contre une suppression.

### 14.7 Ressources du PC et incident du disque plein

Mon PC a 12 Go de RAM. Les cinq VM prennent 9 Go. Avec moins d'environ 1 Go de libre, Fedora devient très lent. Il faut fermer les autres programmes, et je n'allume jamais le jeu « Labo » et le jeu « Demo » en même temps (de toute façon ils ont les mêmes adresses IP).

J'ai aussi vécu un vrai incident. Au démarrage, Windows 11 a fait une mise à jour qui a écrit environ 15 Go d'un coup dans son disque virtuel. Le disque C: du PC est tombé à zéro octet libre. VMware a mis les serveurs en pause (« disk full »), Windows 11 a planté, et la veille, le PC avait déjà été éteint avec des VM allumées. Résultat : les disques virtuels « courants » (les fichiers de différences après le dernier snapshot) de SRV-LIN1-01, SRV-LIN1-02 et du NAS étaient abîmés, et les deux serveurs Debian s'arrêtaient sur `grub rescue>`. Les disques des snapshots étaient intacts. J'ai remis chaque VM à son dernier snapshot propre et relancé le script de SRV-LIN1-02. Je n'ai rien perdu d'important parce que j'avais des snapshots et des scripts relançables.

Ce que j'en retiens :

- surveiller la place libre du disque du PC avant de démarrer les VM (au moins 25 Go libres sur C: avec Windows 11) ;
- éteindre proprement les VM avant d'éteindre le PC ;
- prendre des snapshots réguliers, et les garder sur un autre disque quand c'est possible ;
- ne pas laisser Windows Update tourner dans une VM de labo quand la place est juste.

Ensuite, j'ai déplacé tout le projet (VM, ISO, OVA, documents) sur un disque réseau du PC (`Z:`, 3,7 To dont environ 1 To libre). Copie avec `robocopy`, comparaison de chaque fichier (somme de contrôle MD5) entre l'ancien et le nouvel emplacement, et seulement ensuite suppression sur C:. Deux réglages ajoutés dans chaque fichier `.vmx` :

- `uuid.action = "keep"` : sans ça, VMware voit que la VM a changé de dossier et demande si elle a été « déplacée ou copiée ». Si on répond « copiée », il lui donne un nouvel identifiant et une nouvelle adresse MAC, et le NAS perd son adresse IP (voir 11). Avec ce réglage, il ne pose plus la question et garde la même MAC. Je l'ai testé sur une VM d'essai, aussi après un retour à un ancien snapshot ;
- `mainMem.useNamedFile = "FALSE"` : VMware n'écrit pas la mémoire de la VM dans un fichier `.vmem` sur le partage réseau (c'est ce que VMware conseille pour des VM sur un partage).

VMware ouvre les VM par le chemin réseau (`\\host.lan\Data\LIN1\...`) et pas par la lettre `Z:`, parce que la lettre est parfois « déconnectée » au démarrage de Windows. La limite : si le partage réseau ne répond plus, les VM ne démarrent pas, ou se figent si elles tournaient.

### 14.8 Autres limites

- Le script SRV-LIN1-02 télécharge toujours la dernière version de Nextcloud (`latest.tar.bz2`). J'ai testé avec Nextcloud 35. Une version future pourrait changer une commande `occ` ou une application (Group folders) et faire échouer le script. Pour figer la version, il suffit de remplacer l'adresse dans `URL_NC`.
- Les scripts ont besoin d'Internet (paquets Debian, Nextcloud, applications Nextcloud).
- Il n'y a qu'un seul serveur pour chaque service : si SRV-LIN1-01 tombe, plus de DNS, de DHCP, d'annuaire ni d'Internet pour tout le réseau.
- Aucune alerte n'est configurée : si un disque du RAID lâche, personne n'est prévenu (OMV peut envoyer des courriels, mais il faut un serveur d'envoi).
- Il n'y a pas de pare-feu sur les serveurs eux-mêmes (seulement le NAT sur SRV-LIN1-01).
- Le client de synchronisation Nextcloud n'est installé que sur Windows.
- Les clients ont plus de RAM que demandé (voir 3.9).

## 15. Fichiers modifiés par les scripts

Pour savoir où regarder quand on dépanne :

| Serveur | Fichier | Rôle |
|---|---|---|
| SRV-LIN1-01 | `/etc/network/interfaces` | cartes WAN et LAN |
| SRV-LIN1-01 | `/etc/sysctl.d/99-routage.conf` | routage IPv4 activé |
| SRV-LIN1-01 | `/etc/iptables/rules.v4` | règle de NAT |
| SRV-LIN1-01 | `/etc/dnsmasq.d/lin1.conf` | DNS et DHCP |
| SRV-LIN1-01 | `/etc/resolv.conf`, `.head`, `.tail` | DNS du serveur lui-même |
| SRV-LIN1-01 | `/var/lib/ldap-account-manager/config/lam.conf` | configuration de LAM |
| SRV-LIN1-02 | `/etc/fstab` | montages iSCSI et NFS |
| SRV-LIN1-02 | `/etc/systemd/system/apache2.service.d/iscsi.conf` (et `mariadb`) | attendre le disque iSCSI |
| SRV-LIN1-02 | `/etc/php/<version>/mods-available/nextcloud.ini` | réglages PHP |
| SRV-LIN1-02 | `/etc/ssl/lin1/` | certificat et clé |
| SRV-LIN1-02 | `/etc/apache2/sites-available/nextcloud.conf` | site HTTPS |
| SRV-LIN1-02 | `/var/www/nextcloud/config/config.php` | configuration de Nextcloud |
| SRV-LIN1-02 | `/etc/cron.d/nextcloud`, `/etc/cron.d/sauvegarde-nextcloud` | tâches planifiées |
| SRV-LIN1-02 | `/usr/local/sbin/sauvegarde-nextcloud.sh` | script de sauvegarde |
| SRV-LIN1-02 | `/etc/network/interfaces`, `/etc/resolv.conf` | adresse fixe et DNS |

## 16. Sources

- Pages Moodle du module LIN1 (CPNV) : travaux évalués, schéma de l'infrastructure, arborescence des données, configuration des machines virtuelles, authentification SSH par clef, POC.
- Annexes du cours : support Debian, transformer Debian en routeur, configurer un serveur dnsmasq, OpenLDAP, Nextcloud, DAS/SAN/NAS, iSCSI, exemple de rapport.
- Documentation officielle : Nextcloud (manuel d'administration, commandes `occ`, LDAP), dnsmasq (`man dnsmasq`), OpenMediaVault, `tgt` (`man targets.conf`), `mdadm` (`man mdadm`).

Je me suis aidé d'une IA (Claude) pour écrire les scripts et pour la mise en forme de cette documentation. J'ai testé tout ce qui est décrit ici sur mes machines.
