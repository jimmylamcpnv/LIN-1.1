#!/bin/bash
# =============================================================================
# SRV-LIN1-02.sh
# Installation et configuration du serveur SRV-LIN1-02 (Debian 13, sans interface graphique)
#   - réseau : adresse fixe 10.10.10.22, passerelle et DNS = SRV-LIN1-01
#   - disque iSCSI du NAS monté sur /mnt/iscsi1 : c'est là que Nextcloud range ses fichiers
#   - partage NFS du NAS monté sur /mnt/nfs-lin1 : on y met une sauvegarde de nuit
#   - Nextcloud (Apache + PHP + MariaDB) en HTTPS sur https://10.10.10.22/nextcloud
#   - utilisateurs et groupes pris dans l'annuaire LDAP de SRV-LIN1-01
#   - dossiers de groupe (clients, logiciels, commun) avec quotas et droits
#
# Projet LIN1-LABO - Jimmy LAM
#
# À lancer APRÈS SRV-LIN1-01.sh, quand le NAS est prêt (RAID, NFS et iSCSI) :
#     sudo ./SRV-LIN1-02.sh
#
# Le script peut être relancé sans casser ce qui existe déjà.
# Le SSH n'est volontairement pas géré ici : voir la documentation technique.
# Attention : à la toute fin, l'adresse IP de la machine change (10.10.10.22).
# Si on est connecté en SSH sur l'ancienne adresse, la connexion se coupe : c'est normal.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Paramètres : tout ce qu'on peut vouloir changer est ici
# -----------------------------------------------------------------------------
NOM_HOTE="srv-lin1-02"
DOMAINE="lin1.local"

IP_LAN="10.10.10.22"
PREFIXE_LAN="24"
PASSERELLE="10.10.10.11"      # SRV-LIN1-01 : routeur et DNS
IP_DNS="10.10.10.11"
IP_NAS="10.10.10.33"

CIBLE_ISCSI="iqn.2026-10.local.lin1:iscsi1"   # nom de la cible créée sur le NAS
POINT_ISCSI="/mnt/iscsi1"
POINT_NFS="/mnt/nfs-lin1"
EXPORT_NFS="/nfs-lin1"                         # chemin exporté par le NAS (NFSv4)

BASE_LDAP="dc=lin1,dc=local"
IP_LDAP="10.10.10.11"
COMPTE_LDAP="cn=nextcloud,ou=Services,${BASE_LDAP}"   # compte en lecture seule créé par SRV-LIN1-01.sh

DOSSIER_NC="/var/www/nextcloud"
DONNEES_NC="${POINT_ISCSI}/nextcloud-data"
URL_NC="https://download.nextcloud.com/server/releases/latest.tar.bz2"

# Mots de passe du labo, modifiables en les passant en variable :
#     sudo MDP_ADMIN_NC='autre' ./SRV-LIN1-02.sh
MDP_ADMIN_NC="${MDP_ADMIN_NC:-Pa\$\$w0rd}"      # compte admin de Nextcloud
MDP_BASE="${MDP_BASE:-Pa\$\$w0rd}"              # base de données MariaDB
MDP_COMPTE_LDAP="${MDP_COMPTE_LDAP:-Pa\$\$w0rd}"

# Quotas (demandés dans l'énoncé)
QUOTA_PERSO="10 MB"
QUOTA_CLIENTS="20MB"
QUOTA_LOGICIELS="20MB"
QUOTA_COMMUN="30MB"

# -----------------------------------------------------------------------------
# Petites fonctions
# -----------------------------------------------------------------------------
etape()  { echo; echo "=== $* ==="; }
erreur() { echo "ERREUR : $*" >&2; exit 1; }

# Lance la commande occ de Nextcloud avec l'utilisateur du serveur web
occ() { runuser -u www-data -- php -d memory_limit=512M "${DOSSIER_NC}/occ" "$@"; }

[ "$(id -u)" -eq 0 ] || erreur "il faut lancer ce script en root (sudo ./SRV-LIN1-02.sh)"

export DEBIAN_FRONTEND=noninteractive

# -----------------------------------------------------------------------------
# 2. Vérifications avant de commencer
# -----------------------------------------------------------------------------
etape "Vérifications"

ping -c 1 -W 3 "$IP_LDAP" >/dev/null 2>&1 || erreur "SRV-LIN1-01 ($IP_LDAP) ne répond pas : lancer d'abord SRV-LIN1-01.sh"
ping -c 1 -W 3 "$IP_NAS"  >/dev/null 2>&1 || erreur "le NAS ($IP_NAS) ne répond pas"
ping -c 1 -W 3 deb.debian.org >/dev/null 2>&1 || erreur "pas d'Internet (le routeur SRV-LIN1-01 fait-il son NAT ?)"
echo "SRV-LIN1-01, NAS et Internet : OK"

hostnamectl set-hostname "$NOM_HOTE"
grep -q "$NOM_HOTE" /etc/hosts || echo "127.0.1.1 ${NOM_HOTE}.${DOMAINE} ${NOM_HOTE}" >> /etc/hosts

# -----------------------------------------------------------------------------
# 3. Installation des paquets
# -----------------------------------------------------------------------------
etape "Installation des paquets"

apt-get update -q
apt-get install -y -q \
    apache2 libapache2-mod-php mariadb-server \
    php-gd php-mysql php-curl php-mbstring php-intl php-gmp php-bcmath \
    php-xml php-zip php-ldap php-apcu php-bz2 \
    open-iscsi nfs-common ldap-utils bind9-dnsutils \
    openssl curl bzip2 unzip acl jq

PHP_VERSION="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"

# -----------------------------------------------------------------------------
# 4. Disque iSCSI du NAS : monté sur /mnt/iscsi1
# -----------------------------------------------------------------------------
etape "Disque iSCSI"

systemctl enable --now iscsid >/dev/null 2>&1

# On découvre les cibles du NAS, puis on se connecte (si ce n'est pas déjà fait)
iscsiadm -m discovery -t sendtargets -p "$IP_NAS" >/dev/null
if ! iscsiadm -m session 2>/dev/null | grep -q "$CIBLE_ISCSI"; then
    iscsiadm -m node -T "$CIBLE_ISCSI" -p "$IP_NAS" --login
fi
# La connexion se refait toute seule au démarrage
iscsiadm -m node -T "$CIBLE_ISCSI" -p "$IP_NAS" -o update -n node.startup -v automatic

# Le disque apparaît avec un nom du genre /dev/disk/by-path/...-lun-1
DISQUE=""
for i in $(seq 1 20); do
    DISQUE="$(ls /dev/disk/by-path/*"${CIBLE_ISCSI}"*-lun-1 2>/dev/null | head -n 1 || true)"
    [ -n "$DISQUE" ] && break
    sleep 1
done
[ -n "$DISQUE" ] || erreur "je ne vois pas le disque iSCSI (voir 'lsblk' et 'iscsiadm -m session')"
echo "Disque iSCSI : $(readlink -f "$DISQUE")"

# On formate seulement si le disque est vide (jamais sur un disque qui contient déjà des données)
blkid "$DISQUE" >/dev/null 2>&1 || mkfs.ext4 -q -L nextcloud "$DISQUE"

mkdir -p "$POINT_ISCSI"
UUID_ISCSI="$(blkid -s UUID -o value "$DISQUE")"
grep -q "$UUID_ISCSI" /etc/fstab \
    || echo "UUID=${UUID_ISCSI} ${POINT_ISCSI} ext4 _netdev,nofail,defaults 0 0" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$POINT_ISCSI" || mount "$POINT_ISCSI"

# Apache et MariaDB ne démarrent qu'une fois le disque monté
for service in apache2 mariadb; do
    mkdir -p "/etc/systemd/system/${service}.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$POINT_ISCSI" > "/etc/systemd/system/${service}.service.d/iscsi.conf"
done
systemctl daemon-reload

# -----------------------------------------------------------------------------
# 5. Partage NFS du NAS : monté sur /mnt/nfs-lin1 (pour les sauvegardes)
# -----------------------------------------------------------------------------
etape "Partage NFS"

showmount -e "$IP_NAS"
mkdir -p "$POINT_NFS"
grep -q "${IP_NAS}:${EXPORT_NFS}" /etc/fstab \
    || echo "${IP_NAS}:${EXPORT_NFS} ${POINT_NFS} nfs4 _netdev,nofail,defaults 0 0" >> /etc/fstab
systemctl daemon-reload
mountpoint -q "$POINT_NFS" || mount "$POINT_NFS"

# -----------------------------------------------------------------------------
# 6. Base de données MariaDB
# -----------------------------------------------------------------------------
etape "Base de données"

mariadb <<EOF
CREATE DATABASE IF NOT EXISTS nextcloud CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE USER IF NOT EXISTS 'nextcloud'@'localhost' IDENTIFIED BY '${MDP_BASE}';
ALTER USER 'nextcloud'@'localhost' IDENTIFIED BY '${MDP_BASE}';
GRANT ALL PRIVILEGES ON nextcloud.* TO 'nextcloud'@'localhost';
FLUSH PRIVILEGES;
EOF

# -----------------------------------------------------------------------------
# 7. Téléchargement de Nextcloud
# -----------------------------------------------------------------------------
etape "Nextcloud : téléchargement"

if [ ! -f "${DOSSIER_NC}/occ" ]; then
    cd /tmp
    curl -fsSL -o nextcloud.tar.bz2 "$URL_NC"
    curl -fsSL -o nextcloud.tar.bz2.sha256 "${URL_NC}.sha256"
    # On vérifie que le fichier n'est pas corrompu avant de l'ouvrir
    somme_attendue="$(awk '{print $1; exit}' nextcloud.tar.bz2.sha256)"
    somme_reelle="$(sha256sum nextcloud.tar.bz2 | awk '{print $1}')"
    [ "$somme_attendue" = "$somme_reelle" ] || erreur "la somme de contrôle de Nextcloud ne correspond pas"
    tar -xjf nextcloud.tar.bz2 -C /var/www
    rm -f nextcloud.tar.bz2 nextcloud.tar.bz2.sha256
fi
chown -R www-data:www-data "$DOSSIER_NC"

# -----------------------------------------------------------------------------
# 8. PHP et Apache en HTTPS
# -----------------------------------------------------------------------------
etape "PHP, Apache et certificat SSL"

cat > "/etc/php/${PHP_VERSION}/mods-available/nextcloud.ini" <<EOF
; Réglages conseillés par Nextcloud
memory_limit = 512M
upload_max_filesize = 512M
post_max_size = 512M
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.memory_consumption = 128
opcache.save_comments = 1
opcache.revalidate_freq = 60
apc.enable_cli = 1
EOF
phpenmod nextcloud

# Certificat auto-signé valable pour l'adresse IP et les noms du serveur
mkdir -p /etc/ssl/lin1
if [ ! -f /etc/ssl/lin1/srv-lin1-02.crt ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout /etc/ssl/lin1/srv-lin1-02.key -out /etc/ssl/lin1/srv-lin1-02.crt \
        -subj "/C=CH/O=LIN1-LABO/CN=${NOM_HOTE}.${DOMAINE}" \
        -addext "subjectAltName=DNS:${NOM_HOTE}.${DOMAINE},DNS:${NOM_HOTE},IP:${IP_LAN}" 2>/dev/null
    chmod 640 /etc/ssl/lin1/srv-lin1-02.key
    chgrp www-data /etc/ssl/lin1/srv-lin1-02.key
fi

cat > /etc/apache2/sites-available/nextcloud.conf <<EOF
# Fichier écrit par SRV-LIN1-02.sh
# Tout ce qui arrive en HTTP est renvoyé en HTTPS
<VirtualHost *:80>
    ServerName ${NOM_HOTE}.${DOMAINE}
    ServerAlias ${NOM_HOTE} ${IP_LAN}
    RewriteEngine On
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${NOM_HOTE}.${DOMAINE}
    ServerAlias ${NOM_HOTE} ${IP_LAN}
    DocumentRoot /var/www/html

    SSLEngine on
    SSLCertificateFile    /etc/ssl/lin1/srv-lin1-02.crt
    SSLCertificateKeyFile /etc/ssl/lin1/srv-lin1-02.key

    Header always set Strict-Transport-Security "max-age=15552000; includeSubDomains"

    # https://10.10.10.22/ tout court renvoie vers Nextcloud
    RedirectMatch ^/$ /nextcloud/

    Alias /nextcloud "${DOSSIER_NC}/"
    <Directory ${DOSSIER_NC}/>
        Require all granted
        AllowOverride All
        Options FollowSymLinks MultiViews
        <IfModule mod_dav.c>
            Dav off
        </IfModule>
    </Directory>
</VirtualHost>
EOF

a2enmod -q ssl rewrite headers env dir mime setenvif
a2dissite -q 000-default default-ssl 2>/dev/null || true
a2ensite -q nextcloud
systemctl enable apache2 >/dev/null 2>&1
systemctl restart apache2

# -----------------------------------------------------------------------------
# 9. Installation de Nextcloud (une seule fois)
# -----------------------------------------------------------------------------
etape "Nextcloud : installation"

mkdir -p "$DONNEES_NC"
chown www-data:www-data "$DONNEES_NC"
chmod 750 "$DONNEES_NC"

if ! occ status 2>/dev/null | grep -q 'installed: true'; then
    occ maintenance:install \
        --database=mysql --database-name=nextcloud \
        --database-user=nextcloud --database-pass="$MDP_BASE" \
        --admin-user=admin --admin-pass="$MDP_ADMIN_NC" \
        --data-dir="$DONNEES_NC"
else
    echo "Nextcloud est déjà installé."
fi

# Réglages : adresses autorisées, langue, cache, tâches de fond avec cron
occ config:system:set trusted_domains 1 --value="$IP_LAN"
occ config:system:set trusted_domains 2 --value="$NOM_HOTE"
occ config:system:set trusted_domains 3 --value="${NOM_HOTE}.${DOMAINE}"
occ config:system:set overwrite.cli.url --value="https://${IP_LAN}/nextcloud"
occ config:system:set htaccess.RewriteBase --value="/nextcloud"
occ config:system:set default_language --value="fr"
occ config:system:set default_locale --value="fr_CH"
occ config:system:set default_phone_region --value="CH"
occ config:system:set default_timezone --value="Europe/Zurich"
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ maintenance:update:htaccess
occ background:cron
{ echo "# Tâches de fond de Nextcloud"; echo "*/5 * * * * www-data php -f ${DOSSIER_NC}/cron.php"; } > /etc/cron.d/nextcloud

# Pas de fichiers d'exemple pour les nouveaux utilisateurs : le manuel PDF et les images
# remplissent déjà les 10 Mo de quota de chacun
occ config:system:set skeletondirectory --value=""

# Pas de fenêtre d'accueil à la première connexion (plus simple pour la démonstration)
occ app:disable firstrunwizard >/dev/null 2>&1 || true
occ app:disable recommendedapps >/dev/null 2>&1 || true

# -----------------------------------------------------------------------------
# 10. Utilisateurs et groupes : annuaire LDAP de SRV-LIN1-01
# -----------------------------------------------------------------------------
etape "Connexion à l'annuaire LDAP"

occ app:enable user_ldap
if [ -z "$(occ ldap:show-config 2>/dev/null | grep -o 's01' | head -n 1)" ]; then
    occ ldap:create-empty-config >/dev/null
fi
ldap() { occ ldap:set-config s01 "$1" "$2" >/dev/null; }

ldap ldapHost                  "ldap://${IP_LDAP}"
ldap ldapPort                  389
ldap ldapBase                  "$BASE_LDAP"
ldap ldapBaseUsers             "ou=People,${BASE_LDAP}"
ldap ldapBaseGroups            "ou=Groups,${BASE_LDAP}"
ldap ldapAgentName             "$COMPTE_LDAP"
ldap ldapAgentPassword         "$MDP_COMPTE_LDAP"
ldap ldapUserFilter            "(objectClass=inetOrgPerson)"
ldap ldapUserFilterObjectclass inetOrgPerson
ldap ldapLoginFilter           "(&(objectClass=inetOrgPerson)(uid=%uid))"
ldap ldapLoginFilterUsername   1
ldap ldapLoginFilterAttributes uid
ldap ldapUserDisplayName       cn
ldap ldapExpertUsernameAttr    uid
ldap ldapEmailAttribute        mail
ldap ldapGroupFilter           "(objectClass=posixGroup)"
ldap ldapGroupFilterObjectclass posixGroup
ldap ldapGroupDisplayName      cn
ldap ldapGroupMemberAssocAttr  memberUid
ldap ldapQuotaDefault          "$QUOTA_PERSO"
ldap ldapConfigurationActive   1

occ ldap:test-config s01

# -----------------------------------------------------------------------------
# 11. Dossiers de groupe : clients, logiciels, commun (quotas + droits)
# -----------------------------------------------------------------------------
etape "Dossiers de groupe et calendrier"

occ app:install groupfolders >/dev/null 2>&1 || occ app:enable groupfolders
occ app:install calendar     >/dev/null 2>&1 || occ app:enable calendar

# Crée le dossier s'il n'existe pas, règle le quota et donne les droits aux groupes
# Utilisation : dossier_de_groupe <nom> <quota> <groupe1> [groupe2 ...]
dossier_de_groupe() {
    local nom="$1" quota="$2"; shift 2
    local id
    # Selon la version de l'app, le champ s'appelle mount_point ou mountPoint : on accepte les deux
    id="$(occ groupfolders:list --output=json | jq -r --arg n "$nom" '.[] | select((.mount_point // .mountPoint)==$n) | .id' | head -n 1)"
    [ -n "$id" ] || id="$(occ groupfolders:create "$nom")"
    occ groupfolders:quota "$id" "$quota" >/dev/null
    occ groupfolders:permissions "$id" --enable >/dev/null 2>&1 || true   # droits avancés (ACL)
    for groupe in "$@"; do
        occ groupfolders:group "$id" "$groupe" read write delete >/dev/null
    done
    echo "dossier ${nom} (n° ${id}) : quota ${quota}, groupes : $*"
}

dossier_de_groupe clients    "$QUOTA_CLIENTS"    manager
dossier_de_groupe logiciels  "$QUOTA_LOGICIELS"  ingenieur developpeur
# Commun : tout le monde peut écrire (choix pour le POC, voir la documentation)
dossier_de_groupe commun     "$QUOTA_COMMUN"     manager ingenieur developpeur

# -----------------------------------------------------------------------------
# 12. Sauvegarde de nuit sur le partage NFS du NAS
# -----------------------------------------------------------------------------
etape "Sauvegarde de nuit"

cat > /usr/local/sbin/sauvegarde-nextcloud.sh <<EOF
#!/bin/bash
# Sauvegarde la base de données et la configuration de Nextcloud sur le NAS (NFS)
# Garde les 7 dernières sauvegardes. Les fichiers eux-mêmes sont déjà sur le RAID1 du NAS (iSCSI).
set -euo pipefail
mountpoint -q ${POINT_NFS} || exit 1
DEST="${POINT_NFS}/sauvegardes"
mkdir -p "\$DEST"
DATE="\$(date +%Y-%m-%d_%H%M)"
mariadb-dump --single-transaction nextcloud | gzip > "\$DEST/nextcloud-base_\${DATE}.sql.gz"
tar -czf "\$DEST/nextcloud-config_\${DATE}.tar.gz" -C ${DOSSIER_NC} config
ls -1t "\$DEST"/nextcloud-base_*.sql.gz   | tail -n +8 | xargs -r rm -f
ls -1t "\$DEST"/nextcloud-config_*.tar.gz | tail -n +8 | xargs -r rm -f
EOF
chmod 750 /usr/local/sbin/sauvegarde-nextcloud.sh
echo "30 2 * * * root /usr/local/sbin/sauvegarde-nextcloud.sh" > /etc/cron.d/sauvegarde-nextcloud
/usr/local/sbin/sauvegarde-nextcloud.sh && echo "première sauvegarde faite dans ${POINT_NFS}/sauvegardes"

# -----------------------------------------------------------------------------
# 13. Réseau : adresse fixe (en dernier, car l'adresse change)
# -----------------------------------------------------------------------------
etape "Réseau"

CARTE="$(ip -o link show | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n 1)"

cat > /etc/network/interfaces <<EOF
# Fichier écrit par SRV-LIN1-02.sh
auto lo
iface lo inet loopback

# Adresse fixe, SRV-LIN1-01 est la passerelle
auto ${CARTE}
iface ${CARTE} inet static
    address ${IP_LAN}/${PREFIXE_LAN}
    gateway ${PASSERELLE}
EOF

# Plus de DHCP : on écrit nous-mêmes le DNS (SRV-LIN1-01) et le domaine de recherche
printf 'search %s\nnameserver %s\n' "$DOMAINE" "$IP_DNS" > /etc/resolv.conf

echo
echo "=== Terminé ==="
echo "Nextcloud : https://${IP_LAN}/nextcloud   (compte admin / mot de passe du labo)"
echo "Données   : ${DONNEES_NC} (disque iSCSI du NAS)"
echo "Utilisateurs : ceux de l'annuaire LDAP (man01, man02, ing01, ing02, dev01, ...)"
echo

# On applique l'adresse fixe en tâche de fond, pour laisser le temps d'afficher ce texte.
# Attention : il faut d'abord arrêter le client DHCP (dhcpcd) lancé à l'installation.
# Sinon il garde l'ancienne adresse et, quand il s'arrête (au redémarrage), il réécrit
# /etc/resolv.conf sans serveur DNS. C'est pour ça qu'on réécrit resolv.conf à la fin.
if ! ip -4 addr show dev "$CARTE" | grep -q "${IP_LAN}/"; then
    echo "L'adresse de la machine va passer à ${IP_LAN} dans quelques secondes."
    nohup setsid bash -c "sleep 3
        dhcpcd -x ${CARTE} 2>/dev/null; pkill -x dhcpcd 2>/dev/null; sleep 1
        ip addr flush dev ${CARTE}
        ifup --force ${CARTE}
        printf 'search %s\nnameserver %s\n' '${DOMAINE}' '${IP_DNS}' > /etc/resolv.conf" >/dev/null 2>&1 &
fi
