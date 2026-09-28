#!/bin/bash
# Configure docker_open5gs .env for an IMS-only deployment against an external 5G core.
#
# Usage (run in the docker_open5gs directory):
#   IMS_HOST_IP=<ip> CORE_HOST_IP=<ip> ./configure_site.sh
#
# Required:
#   IMS_HOST_IP   IP of this host. Must equal the P-CSCF address the core SMF gives to phones (PCO).
#   CORE_HOST_IP  Next hop from this host towards the UE IP pools (core host / UPF N6 router).
# Optional (defaults in brackets):
#   MCC [001]  MNC [01]
#   UE_POOL_IMS [172.252.0.0/16]  UE_POOL_INTERNET [172.250.0.0/16]  (must match the core's DNN pools)
#   TZ [Asia/Kolkata]

set -e
: "${IMS_HOST_IP:?set IMS_HOST_IP}" "${CORE_HOST_IP:?set CORE_HOST_IP}"
MCC=${MCC:-001}
MNC=${MNC:-01}
UE_POOL_IMS=${UE_POOL_IMS:-172.252.0.0/16}
UE_POOL_INTERNET=${UE_POOL_INTERNET:-172.250.0.0/16}
TZ=${TZ:-Asia/Kolkata}

[ ${#MNC} == 3 ] && IMS_DOMAIN="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || IMS_DOMAIN="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"

[ -f .env.orig ] || cp .env .env.orig

# set_var NAME VALUE: replace NAME=... (also a commented-out #NAME=...) or append it
set_var() {
	if grep -qE "^#?$1=" .env; then
		sed -i -E "s|^#?$1=.*|$1=$2|" .env
	else
		echo "$1=$2" >> .env
	fi
}

set_var TZ "$TZ"
set_var MCC "$MCC"
set_var MNC "$MNC"
set_var DOCKER_HOST_IP "$IMS_HOST_IP"
set_var PCSCF_IP "$IMS_HOST_IP"
set_var RTPENGINE_IP "$IMS_HOST_IP"
set_var UPF_IP "$CORE_HOST_IP"
set_var UE_IPV4_IMS "$UE_POOL_IMS"
set_var UE_IPV4_INTERNET "$UE_POOL_INTERNET"
set_var DOCKER_BRIDGE_GW 172.22.0.1
set_var IMS_DOMAIN "$IMS_DOMAIN"

# P-CSCF runs on the host network, so it resolves IMS names via the IMS DNS container
DNS_IP=$(grep -E "^DNS_IP=" .env | cut -d= -f2)
echo "nameserver $DNS_IP" > pcscf/resolv.conf

echo "Configured .env:"
grep -E "^(TZ|MCC|MNC|DOCKER_HOST_IP|PCSCF_IP|RTPENGINE_IP|UPF_IP|UE_IPV4_IMS|UE_IPV4_INTERNET|DOCKER_BRIDGE_GW|IMS_DOMAIN)=" .env
