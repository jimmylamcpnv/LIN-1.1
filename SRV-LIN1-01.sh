#!/bin/bash
# =============================================================================
# SRV-LIN1-01.sh
# Installation et configuration du serveur SRV-LIN1-01 (Debian 13, sans interface graphique)
#   - réseau : une patte WAN (DHCP, vers Internet) et une patte LAN (10.10.10.11)
#   - partage de la connexion Internet (routage + NAT)
#   - DNS et DHCP avec dnsmasq
#   - annuaire LDAP (OpenLDAP) rempli avec les groupes et les utilisateurs
#   - LAM (LDAP Account Manager) pour gérer l'annuaire dans un navigateur
#
# Projet LIN1-LABO - Nom : xxx
#
# Je me suis aidé d'une IA (Claude) pour écrire ce script. Je l'ai relu et testé
# sur une VM Debian toute neuve, et je peux expliquer chaque partie.
#
# Utilisation (sur une Debian 13 fraîchement installée, avec Internet sur la 1re carte) :
#     sudo ./SRV-LIN1-01.sh
#
# Le script peut être relancé sans casser ce qui existe déjà.
# Le SSH n'est volontairement pas géré ici : voir la documentation technique.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# 1. Paramètres : tout ce qu'on peut vouloir changer est ici
# -----------------------------------------------------------------------------
NOM_HOTE="srv-lin1-01"
DOMAINE="lin1.local"

IP_LAN="10.10.10.11"          # adresse de ce serveur sur le réseau interne
PREFIXE_LAN="24"
DHCP_DEBUT="10.10.10.100"     # plage distribuée aux clients
DHCP_FIN="10.10.10.200"
IP_SRV2="10.10.10.22"         # SRV-LIN1-02 (Nextcloud)
IP_NAS="10.10.10.33"          # NAS-LIN1-01 (OpenMediaVault)

# Noms des cartes réseau. Si on laisse vide, le script les trouve tout seul :
# WAN = celle qui a la route par défaut, LAN = l'autre.
WAN="${WAN:-}"
LAN="${LAN:-}"

BASE_LDAP="dc=lin1,dc=local"
ADMIN_LDAP="cn=admin,${BASE_LDAP}"

# Mots de passe du labo. On peut les surcharger en les passant en variable :
#     sudo MDP_ADMIN_LDAP='autre' ./SRV-LIN1-01.sh
# (les valeurs par défaut sont celles du labo, à ne jamais garder en production)
MDP_ADMIN_LDAP="${MDP_ADMIN_LDAP:-Pa\$\$w0rd}"
MDP_UTILISATEURS="${MDP_UTILISATEURS:-secret}"
MDP_NEXTCLOUD="${MDP_NEXTCLOUD:-Pa\$\$w0rd}"     # compte de lecture utilisé par Nextcloud

# -----------------------------------------------------------------------------
# Petites fonctions
# -----------------------------------------------------------------------------
etape()  { echo; echo "=== $* ==="; }
erreur() { echo "ERREUR : $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erreur "il faut lancer ce script en root (sudo ./SRV-LIN1-01.sh)"

export DEBIAN_FRONTEND=noninteractive   # apt ne pose aucune question

# -----------------------------------------------------------------------------
# 2. Cartes réseau et nom de la machine
# -----------------------------------------------------------------------------
etape "Cartes réseau et nom de la machine"

[ -n "$WAN" ] || WAN="$(ip route show default | awk '{print $5; exit}')"
[ -n "$LAN" ] || LAN="$(ip -o link show | awk -F': ' '{print $2}' | grep -v -E "^(lo|${WAN})$" | head -n 1)"
[ -n "$WAN" ] && [ -n "$LAN" ] || erreur "je ne trouve pas les deux cartes réseau (voir 'ip a')"
echo "WAN (Internet) : $WAN"
echo "LAN (interne)  : $LAN"

hostnamectl set-hostname "$NOM_HOTE"
grep -q "$NOM_HOTE" /etc/hosts || echo "127.0.1.1 ${NOM_HOTE}.${DOMAINE} ${NOM_HOTE}" >> /etc/hosts

# -----------------------------------------------------------------------------
# 3. Installation des paquets
# -----------------------------------------------------------------------------
etape "Installation des paquets"

# Réponses aux questions que posent slapd et iptables-persistent
debconf-set-selections <<EOF
slapd slapd/password1 password ${MDP_ADMIN_LDAP}
slapd slapd/password2 password ${MDP_ADMIN_LDAP}
slapd slapd/domain string ${DOMAINE}
slapd shared/organization string LIN1-LABO
slapd slapd/backend select MDB
slapd slapd/purge_database boolean false
iptables-persistent iptables-persistent/autosave_v4 boolean false
iptables-persistent iptables-persistent/autosave_v6 boolean false
EOF

apt-get update -q
apt-get install -y -q dnsmasq iptables iptables-persistent slapd ldap-utils ldap-account-manager

# -----------------------------------------------------------------------------
# 4. Configuration réseau (fichier /etc/network/interfaces)
# -----------------------------------------------------------------------------
etape "Configuration réseau"

cat > /etc/network/interfaces <<EOF
# Fichier écrit par SRV-LIN1-01.sh
auto lo
iface lo inet loopback

# WAN : on reçoit l'adresse en DHCP (NAT de VMware)
allow-hotplug ${WAN}
iface ${WAN} inet dhcp

# LAN : adresse fixe, c'est nous la passerelle des autres machines
auto ${LAN}
iface ${LAN} inet static
    address ${IP_LAN}/${PREFIXE_LAN}
EOF

# On ne redémarre que la carte LAN : la carte WAN (et donc la session SSH) ne bouge pas
ifdown "$LAN" 2>/dev/null || true
ifup "$LAN"

# -----------------------------------------------------------------------------
# 5. Routage et NAT : les machines du LAN sortent sur Internet par ce serveur
# -----------------------------------------------------------------------------
etape "Routage et NAT"

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/99-routage.conf
sysctl -q -p /etc/sysctl.d/99-routage.conf

# On ajoute la règle seulement si elle n'existe pas déjà
iptables -t nat -C POSTROUTING -o "$WAN" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$WAN" -j MASQUERADE
iptables-save > /etc/iptables/rules.v4     # règle gardée après un redémarrage

# -----------------------------------------------------------------------------
# 6. DNS et DHCP avec dnsmasq
# -----------------------------------------------------------------------------
etape "DNS et DHCP (dnsmasq)"

cat > /etc/dnsmasq.d/lin1.conf <<EOF
# Fichier écrit par SRV-LIN1-01.sh
# On écoute sur le LAN et sur la machine elle-même
interface=${LAN}
listen-address=127.0.0.1
bind-interfaces

# DNS : nom de domaine local, jamais envoyé aux DNS d'Internet
domain=${DOMAINE}
local=/${DOMAINE}/
expand-hosts

# Les noms des serveurs (dnsmasq en déduit aussi la résolution inverse)
host-record=${NOM_HOTE}.${DOMAINE},${NOM_HOTE},${IP_LAN}
host-record=srv-lin1-02.${DOMAINE},srv-lin1-02,${IP_SRV2}
host-record=nas-lin1-01.${DOMAINE},nas-lin1-01,${IP_NAS}

# DHCP : plage, passerelle (nous) et DNS (nous)
dhcp-range=${DHCP_DEBUT},${DHCP_FIN},255.255.255.0,12h
dhcp-option=option:router,${IP_LAN}
dhcp-option=option:dns-server,${IP_LAN}
dhcp-authoritative
EOF

# dnsmasq ne doit pas lire le /etc/hosts de la machine (il contient 127.0.1.1 pour elle-même)
grep -q '^no-hosts' /etc/dnsmasq.d/lin1.conf || echo "no-hosts" >> /etc/dnsmasq.d/lin1.conf

systemctl enable dnsmasq >/dev/null 2>&1
systemctl restart dnsmasq

# Ce serveur interroge maintenant son propre dnsmasq en premier.
# dhcpcd lit ces deux fichiers à chaque renouvellement du bail : notre réglage reste.
echo "nameserver 127.0.0.1" > /etc/resolv.conf.head
echo "search ${DOMAINE}"    > /etc/resolv.conf.tail
DNS_AMONT="$(grep '^nameserver' /etc/resolv.conf | grep -v '127.0.0.1' || true)"
[ -n "$DNS_AMONT" ] || DNS_AMONT="nameserver 1.1.1.1"
{ cat /etc/resolv.conf.head; echo "$DNS_AMONT"; cat /etc/resolv.conf.tail; } > /etc/resolv.conf.neuf
mv /etc/resolv.conf.neuf /etc/resolv.conf

# -----------------------------------------------------------------------------
# 7. Annuaire LDAP : on le remplit seulement s'il est encore vide
# -----------------------------------------------------------------------------
etape "Annuaire LDAP (OpenLDAP)"

# Crée l'entrée d'un utilisateur : identifiant, nom complet, nom, uidNumber, gidNumber
utilisateur() {
cat <<EOF

dn: uid=$1,ou=People,${BASE_LDAP}
objectClass: inetOrgPerson
objectClass: posixAccount
uid: $1
cn: $2
sn: $3
uidNumber: $4
gidNumber: $5
homeDirectory: /home/$1
loginShell: /bin/bash
mail: $1@${DOMAINE}
userPassword: ${HASH_UTILISATEURS}
EOF
}

if ldapsearch -x -H ldap://localhost -D "$ADMIN_LDAP" -w "$MDP_ADMIN_LDAP" \
        -b "ou=People,${BASE_LDAP}" -s base dn >/dev/null 2>&1; then
    echo "L'annuaire est déjà rempli, je n'y touche pas."
else
    HASH_UTILISATEURS="$(slappasswd -s "$MDP_UTILISATEURS")"
    HASH_NEXTCLOUD="$(slappasswd -s "$MDP_NEXTCLOUD")"

    {
    cat <<EOF
dn: ou=People,${BASE_LDAP}
objectClass: organizationalUnit
ou: People

dn: ou=Groups,${BASE_LDAP}
objectClass: organizationalUnit
ou: Groups

dn: ou=Services,${BASE_LDAP}
objectClass: organizationalUnit
ou: Services

# Compte en lecture seule pour Nextcloud (on évite de lui donner le compte admin)
dn: cn=nextcloud,ou=Services,${BASE_LDAP}
objectClass: organizationalRole
objectClass: simpleSecurityObject
cn: nextcloud
userPassword: ${HASH_NEXTCLOUD}

dn: cn=manager,ou=Groups,${BASE_LDAP}
objectClass: posixGroup
cn: manager
gidNumber: 10000
memberUid: man01
memberUid: man02

dn: cn=ingenieur,ou=Groups,${BASE_LDAP}
objectClass: posixGroup
cn: ingenieur
gidNumber: 10001
memberUid: ing01
memberUid: ing02

dn: cn=developpeur,ou=Groups,${BASE_LDAP}
objectClass: posixGroup
cn: developpeur
gidNumber: 10002
memberUid: dev01
EOF
    utilisateur man01 "Manager 01"     Manager     11001 10000
    utilisateur man02 "Manager 02"     Manager     11002 10000
    utilisateur ing01 "Ingenieur 01"   Ingenieur   12001 10001
    utilisateur ing02 "Ingenieur 02"   Ingenieur   12002 10001
    utilisateur dev01 "Developpeur 01" Developpeur 13001 10002
    } > /tmp/annuaire.ldif

    ldapadd -x -H ldap://localhost -D "$ADMIN_LDAP" -w "$MDP_ADMIN_LDAP" -f /tmp/annuaire.ldif
    rm -f /tmp/annuaire.ldif
fi

# -----------------------------------------------------------------------------
# 8. LAM (LDAP Account Manager) : interface web de l'annuaire
# -----------------------------------------------------------------------------
etape "LAM"

LAM_CONF="/var/lib/ldap-account-manager/config/lam.conf"

# Le paquet livre un lam.conf d'exemple (dc=my-domain,dc=com). On remplace par nos valeurs :
# compte admin, base de l'annuaire, où se trouvent les utilisateurs et les groupes, fuseau horaire.
sed -i \
    -e "s#\"Admins\": \".*\"#\"Admins\": \"${ADMIN_LDAP}\"#" \
    -e "s#dc=my-domain,dc=com#${BASE_LDAP}#g" \
    -e "s#ou=group,#ou=Groups,#" \
    -e "s#\"treeViewSuffix\": \".*\"#\"treeViewSuffix\": \"${BASE_LDAP}\"#" \
    -e 's#Europe\\/London#Europe\\/Zurich#' \
    "$LAM_CONF"

# sed a recréé le fichier : on remet le bon propriétaire, sinon Apache ne peut plus le lire
chown www-data:root "$LAM_CONF"
chmod 600 "$LAM_CONF"

# -----------------------------------------------------------------------------
# 9. Résumé
# -----------------------------------------------------------------------------
etape "Terminé"
systemctl is-active dnsmasq slapd apache2
echo
echo "Adresse LAN      : ${IP_LAN}/${PREFIXE_LAN} (${LAN})"
echo "LAM              : http://${IP_LAN}/lam"
echo "Test de l'annuaire : ldapsearch -x -b ${BASE_LDAP} '(uid=dev01)'"
