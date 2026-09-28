#!/bin/bash
# Provision IMS subscribers in PyHSS to match the 5G core's subscribers.
#
# Range mode (default mapping, same as SD-Core simapp ranges):
#   KI=<k> OPC=<opc> ./provision_pyhss.sh <first> <last>   e.g. ... ./provision_pyhss.sh 1 100
#   index N -> IMSI  <MCC><MNC><MSIN padded to 15 digits>   (N=1   -> 001010000000001, N=100 -> 001010000000100)
#           -> MSISDN <MSISDN_PREFIX><N padded to MSISDN_LEN> (N=1 -> 9000000001,     N=100 -> 9000000100)
#
# Single SIM with its own identity/keys:
#   IMSI=<imsi> MSISDN=<msisdn> KI=<k> OPC=<opc> ./provision_pyhss.sh
#
# Required env: KI OPC (the same K/OPc as in the core subscriber DB)
# Optional env: AMF API MCC MNC MSISDN_PREFIX MSISDN_LEN
# MCC/MNC default to the values in .env. Existing subscribers are skipped.

cd "$(dirname "$0")"
env_val() { grep -E "^$1=" .env 2>/dev/null | cut -d= -f2; }

API=${API:-http://127.0.0.1:8080}
KI=${KI:?set KI (SIM key K, 32 hex digits), e.g. KI=<k> OPC=<opc> $0 1 100}
OPC=${OPC:?set OPC (SIM OPc, 32 hex digits)}
AMF=${AMF:-8000}
MCC=${MCC:-$(env_val MCC)}; MCC=${MCC:-001}
MNC=${MNC:-$(env_val MNC)}; MNC=${MNC:-01}
MSISDN_PREFIX=${MSISDN_PREFIX:-9}
MSISDN_LEN=${MSISDN_LEN:-10}
[ ${#MNC} == 3 ] && REALM="ims.mnc${MNC}.mcc${MCC}.3gppnetwork.org" || REALM="ims.mnc0${MNC}.mcc${MCC}.3gppnetwork.org"

curl -s -o /dev/null "$API/apn/list?page=0&page_size=1" || { echo "PyHSS API not reachable at $API"; exit 1; }

put() { curl -s -X PUT "$API/$1/" -H 'Content-Type: application/json' -d "$2"; }
json() { python3 -c "import sys,json
try: print(json.load(sys.stdin).get('$1',''))
except Exception: print('')"; }

apn_id() {
	curl -s "$API/apn/list?page=0&page_size=100" | python3 -c "import sys,json;print(next((a['apn_id'] for a in json.load(sys.stdin) if a['apn']=='$1'),''))"
}

for apn in internet ims; do
	[ -z "$(apn_id $apn)" ] && put apn "{\"apn\":\"$apn\",\"apn_ambr_dl\":0,\"apn_ambr_ul\":0}" >/dev/null
done
INTERNET_ID=$(apn_id internet)
IMS_ID=$(apn_id ims)

provision() {
	local imsi=$1 msisdn=$2 auc_id
	if [ ${#imsi} -ne 15 ]; then echo "SKIP $imsi: IMSI must be 15 digits"; return; fi

	auc_id=$(curl -s "$API/auc/imsi/$imsi" | json auc_id)
	[ -z "$auc_id" ] && auc_id=$(put auc "{\"ki\":\"$KI\",\"opc\":\"$OPC\",\"amf\":\"$AMF\",\"sqn\":0,\"imsi\":\"$imsi\"}" | json auc_id)
	[ -z "$auc_id" ] && { echo "FAIL $imsi: could not create AUC"; return; }

	[ -z "$(curl -s "$API/subscriber/imsi/$imsi" | json subscriber_id)" ] && \
		put subscriber "{\"imsi\":\"$imsi\",\"enabled\":true,\"auc_id\":$auc_id,\"default_apn\":$INTERNET_ID,\"apn_list\":\"$INTERNET_ID,$IMS_ID\",\"msisdn\":\"$msisdn\",\"ue_ambr_dl\":0,\"ue_ambr_ul\":0}" >/dev/null

	[ -z "$(curl -s "$API/ims_subscriber/ims_subscriber_imsi/$imsi" | json ims_subscriber_id)" ] && \
		put ims_subscriber "{\"imsi\":\"$imsi\",\"msisdn\":\"$msisdn\",\"sh_profile\":\"string\",\"scscf_peer\":\"scscf.$REALM\",\"msisdn_list\":\"[$msisdn]\",\"ifc_path\":\"default_ifc.xml\",\"scscf\":\"sip:scscf.$REALM:6060\",\"scscf_realm\":\"$REALM\"}" >/dev/null

	if [ -n "$(curl -s "$API/ims_subscriber/ims_subscriber_imsi/$imsi" | json ims_subscriber_id)" ]; then
		echo "OK   $imsi -> $msisdn"
	else
		echo "FAIL $imsi -> $msisdn (check: docker logs pyhss)"
	fi
}

if [ -n "$IMSI" ]; then
	provision "$IMSI" "$MSISDN"
else
	FIRST=${1:-1}; LAST=${2:-$FIRST}
	PLMN="$MCC$MNC"
	for i in $(seq "$FIRST" "$LAST"); do
		provision "$(printf "%s%0$((15 - ${#PLMN}))d" "$PLMN" "$i")" \
		          "$(printf "%s%0$((MSISDN_LEN - ${#MSISDN_PREFIX}))d" "$MSISDN_PREFIX" "$i")"
	done
fi
