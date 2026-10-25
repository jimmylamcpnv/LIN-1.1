# LIN1-LABO – scripts d'installation

Ce dépôt contient les deux scripts de mon projet LIN1. Ils installent et configurent les deux serveurs Debian de la petite infrastructure « LIN1-LABO » :

| Script | Serveur | Ce qu'il fait |
|---|---|---|
| `SRV-LIN1-01.sh` | `srv-lin1-01` (10.10.10.11) | réseau (WAN en DHCP, LAN en 10.10.10.11), routage + NAT avec iptables, DNS et DHCP avec dnsmasq, annuaire OpenLDAP rempli (groupes manager / ingenieur / developpeur, utilisateurs man01, man02, ing01, ing02, dev01), LAM |
| `SRV-LIN1-02.sh` | `srv-lin1-02` (10.10.10.22) | disque iSCSI du NAS pour les données, partage NFS du NAS pour les sauvegardes, MariaDB, Apache en HTTPS (certificat auto-signé), Nextcloud, connexion à l'annuaire LDAP, dossiers de groupe avec quotas, calendrier, sauvegarde de nuit, puis adresse fixe |

Le domaine interne est `lin1.local`, le réseau interne `10.10.10.0/24`. Le NAS (`nas-lin1-01`, 10.10.10.33, OpenMediaVault 8) n'a pas de script : il se configure dans son interface web, c'est décrit dans ma documentation technique.

## Prérequis

- Debian 13 minimal (sans interface graphique), avec un utilisateur qui a le droit d'utiliser `sudo`.
- SRV-LIN1-01 : deux cartes réseau. La première (NAT) doit déjà avoir Internet. Le script trouve tout seul laquelle est le WAN (celle qui a la route par défaut) et laquelle est le LAN.
- SRV-LIN1-02 : une carte réseau sur le réseau interne. Il reçoit d'abord une adresse en DHCP de SRV-LIN1-01, puis le script lui met l'adresse fixe 10.10.10.22 à la toute fin.
- Le NAS doit être prêt avant de lancer `SRV-LIN1-02.sh` : RAID1, partage NFS `nfs-lin1` et cible iSCSI `iqn.2026-10.local.lin1:iscsi1`.

## Utilisation

Toujours dans cet ordre : d'abord SRV-LIN1-01, ensuite SRV-LIN1-02.

Sur SRV-LIN1-01 :

```bash
wget https://raw.githubusercontent.com/<utilisateur>/<depot>/main/SRV-LIN1-01.sh
sudo bash SRV-LIN1-01.sh
```

Compter environ 3 à 4 minutes. À la fin, le script affiche l'état des services (dnsmasq, slapd, apache2) et l'adresse de LAM : `http://10.10.10.11/lam`.

Sur SRV-LIN1-02 (une fois que SRV-LIN1-01 et le NAS tournent) :

```bash
wget https://raw.githubusercontent.com/<utilisateur>/<depot>/main/SRV-LIN1-02.sh
sudo bash SRV-LIN1-02.sh
```

Compter 2 à 3 minutes (téléchargement de Nextcloud compris). Attention : à la fin, la machine passe à l'adresse 10.10.10.22. Si on est connecté en SSH sur l'ancienne adresse, la session se coupe, c'est normal. On se reconnecte avec `ssh cpnv@10.10.10.22`. Nextcloud est ensuite sur `https://10.10.10.22/nextcloud`.

Les deux scripts peuvent être relancés : ils ne réécrasent pas l'annuaire LDAP, ne reformatent pas le disque iSCSI et ne réinstallent pas Nextcloud s'il est déjà là.

## Mots de passe

Les mots de passe par défaut dans les scripts sont ceux imposés par le cours (labo seulement). On peut les remplacer sans toucher au script, en les passant en variable :

```bash
sudo MDP_ADMIN_LDAP='autre' MDP_UTILISATEURS='autre' bash SRV-LIN1-01.sh
sudo MDP_ADMIN_NC='autre' MDP_BASE='autre' MDP_COMPTE_LDAP='autre' bash SRV-LIN1-02.sh
```

Si on change `MDP_NEXTCLOUD` sur SRV-LIN1-01, il faut donner la même valeur à `MDP_COMPTE_LDAP` sur SRV-LIN1-02.

## Ce qui n'est pas dans les scripts

- L'authentification SSH par clé : je l'ai mise en place à la main (`ssh-keygen`, puis copie de la clé publique), c'est expliqué dans la documentation technique.
- La configuration du NAS OpenMediaVault (RAID1, NFS, iSCSI avec `tgt`).
- Les clients Fedora et Windows.
