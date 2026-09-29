# VoNR with a Kamailio IMS and an external 5G core

This guide sets up VoNR voice calls between commercial 5G phones. It uses a Kamailio IMS (from docker_open5gs) against an external 5G core. The reference core is SD-Core / IOS-MCN 0.4.1 on Kubernetes, with an OAI gNB.

It applies to any site. All IPs, interfaces and pools are variables that you set once in [section 1](#1-site-values). The steps have been used at two lab sites with different IP plans. Both had working VoNR calls in both directions between Samsung and OnePlus phones.

---

## 1. Site values

The IMS and the core run on **separate hosts with different IPs**. The IMS host must be reachable from the core host over routed IP. In most cases both hosts are on the same LAN.

Fill in this table for your site. Then export the values in every shell you use, on both hosts:

| Variable | Meaning | How to find it | Example |
|---|---|---|---|
| `IMS_HOST_IP` | IP of the IMS host. **It must equal the P-CSCF address that the core SMF gives to phones.** | `ip -br a` on the IMS host; SMF `pcscfInfos` | 192.168.10.10 |
| `CORE_HOST_IP` | Core host IP that the IMS host uses as next hop to reach the UE pools | `ip -br a` on the core host | 192.168.10.20 |
| `CORE_NIC` | Core host interface that faces the IMS host (the one NAT uses) | `ip route get $IMS_HOST_IP` on the core host | eth0 |
| `UPF_N6_IP` | UPF N6 (core) address. The core host routes UE pools to it. | `ip route \| grep 172.25` on the core host | 192.168.250.3 |
| `UE_POOL_IMS` | UE IP pool of DNN `ims` | core helm values (simapp `ip-domains`) | 172.252.0.0/16 |
| `UE_POOL_INTERNET` | UE IP pool of DNN `internet` | core helm values | 172.250.0.0/16 |
| `MCC` / `MNC` | PLMN | core / SIM | 001 / 01 |
| `UE_FIRST` / `UE_LAST` | Subscriber index range in the core | core `ueId-start` / `ueId-end` | 1 / 100 |

```bash
# Example values. Replace with your own.
export IMS_HOST_IP=192.168.10.10 CORE_HOST_IP=192.168.10.20 CORE_NIC=eth0 UPF_N6_IP=192.168.250.3
export UE_POOL_IMS=172.252.0.0/16 UE_POOL_INTERNET=172.250.0.0/16 MCC=001 MNC=01 UE_FIRST=1 UE_LAST=100
```

Values derived from these:

| Item | Value |
|---|---|
| IMS domain | `ims.mnc0<MNC>.mcc<MCC>.3gppnetwork.org` (for MCC 001 / MNC 01: `ims.mnc001.mcc001.3gppnetwork.org`) |
| IMSI for index N | `<MCC><MNC>` followed by N, zero-padded to 15 digits. N=1 → `001010000000001`, N=100 → `001010000000100` |
| MSISDN for index N | `9` followed by N, zero-padded to 10 digits. N=1 → `9000000001`, N=100 → `9000000100` |
| Subscriber keys | K and OPc of your SIMs (the same values as in the core's `subscribers` block), AMF `8000`. Keep them out of version control. |

The IMS-internal Docker bridge `172.22.0.0/24` is the same at every site. It must not overlap any other network on the IMS host.

---

## 2. Topology

```
 Phone ──NR── gNB ──N2── AMF ┐                       (core host, CORE_HOST_IP)
                 └──N3── UPF (N6 = UPF_N6_IP)
                          │ core host routes UE_POOL_IMS → UPF_N6_IP
                          │ LAN, no NAT for UE_POOL_IMS → IMS_HOST_IP
 IMS host (IMS_HOST_IP):  P-CSCF + RTPEngine   (host network, bound to IMS_HOST_IP)
                          I-CSCF / S-CSCF / PyHSS / DNS / MySQL  (Docker bridge 172.22.0.0/24)
                          routes UE_POOL_IMS and UE_POOL_INTERNET via CORE_HOST_IP (mtu 1400)
```

The P-CSCF and RTPEngine run on the host network at `IMS_HOST_IP`. Phones reach them directly at the address the SMF advertises, and the core host needs no route to the Docker bridge.

---

## 3. Install the IMS (on the IMS host)

### 3.1 Source and images

```bash
mkdir -p ~/Kaimilio && cd ~/Kaimilio
git clone https://github.com/herlesupreeth/docker_open5gs
cd docker_open5gs
git checkout 1f3bcf7          # commit this guide was tested with

# Kamailio (prebuilt image, avoids a long compile)
docker pull ghcr.io/herlesupreeth/docker_kamailio:master
docker tag  ghcr.io/herlesupreeth/docker_kamailio:master docker_kamailio

# The rest are built locally (~30-40 min in total, mostly RTPEngine)
for c in dns mysql rtpengine pyhss; do docker build -t docker_$c ./$c; done
```

### 3.2 Apply the P-CSCF fixes and the site configuration

Clone this repo next to `docker_open5gs/`. Its `files/` directory contains `ims-pcscf-fixes.patch`, `ims-only-deploy.yaml`, `configure_site.sh` and `provision_pyhss.sh`. Then run:

```bash
git clone https://github.com/rakeshbb108/vonr-kamailio-ims ~/Kaimilio/vonr-kamailio-ims
cd ~/Kaimilio/docker_open5gs
git apply ../vonr-kamailio-ims/files/ims-pcscf-fixes.patch
cp ../vonr-kamailio-ims/files/{ims-only-deploy.yaml,configure_site.sh,provision_pyhss.sh} .
chmod +x configure_site.sh provision_pyhss.sh

IMS_HOST_IP=$IMS_HOST_IP CORE_HOST_IP=$CORE_HOST_IP \
UE_POOL_IMS=$UE_POOL_IMS UE_POOL_INTERNET=$UE_POOL_INTERNET MCC=$MCC MNC=$MNC \
./configure_site.sh
```

`configure_site.sh` makes these changes. It saves the original file as `.env.orig` and is safe to run again.

| `.env` variable | Set to | Reason |
|---|---|---|
| `DOCKER_HOST_IP`, `PCSCF_IP`, `RTPENGINE_IP` | `IMS_HOST_IP` | The P-CSCF and RTPEngine bind to the address the SMF advertises |
| `UPF_IP` | `CORE_HOST_IP` | The P-CSCF/RTPEngine init scripts add host routes to the UE pools via this next hop |
| `UE_IPV4_IMS`, `UE_IPV4_INTERNET` | the UE pools | Must match the core's DNN pools |
| `MCC`, `MNC`, `IMS_DOMAIN` | PLMN and the domain derived from it | Used by the CSCFs, PyHSS and the compose `extra_hosts` |
| `DOCKER_BRIDGE_GW`, `TZ` | `172.22.0.1`, `Asia/Kolkata` | Used by `ims-only-deploy.yaml` |

It also writes `pcscf/resolv.conf` (`nameserver 172.22.0.15`, the IMS DNS container).

The patch changes the P-CSCF as follows. These fixes are the same at every site.

| File | Change | Reason |
|---|---|---|
| `pcscf/pcscf.cfg` | `##!define WITH_RX` (Rx off, N5 off) | The core PCF has no reliable N5 support, so voice runs on the default QoS flow |
| `pcscf/pcscf.cfg` | `IPSEC_FORWARD_FLAGS 897 → 385` (removes TRYTCP) | Some phones (OnePlus) refuse TCP connections to their protected server port |
| `pcscf/kamailio_pcscf.cfg` | `udp_mtu` / `udp_mtu_try_proto = TCP` commented out | Same reason: don't switch large SIP messages to TCP |
| `pcscf/kamailio_pcscf.cfg` | `tm fr_timer 3000 → 10000` | Gives an idle phone time to be paged before the P-CSCF gives up |
| `pcscf/pcscf_init.sh` | `ip r replace ${UE_IPV4_IMS} via ${UPF_IP} mtu 1400` | Full 1500-byte fragments plus GTP overhead exceed a 1500-byte N3 path, and the UPF drops them |

`ims-only-deploy.yaml` defines dns, mysql, pyhss, icscf, scscf, rtpengine and pcscf. Every IP and domain in it comes from `.env`, so it needs no per-site edits.
- `pcscf` and `rtpengine` use `network_mode: host`.
- `pcscf` mounts `pcscf/resolv.conf` and has `extra_hosts` for the CSCF and HSS names, because `dns:` can't be used with host networking.
- `rtpengine` has `extra_hosts: rtpengine:${RTPENGINE_IP}`, because its CLI listen address is taken from the last line of `/etc/hosts`.

### 3.3 Start the IMS

```bash
cd ~/Kaimilio/docker_open5gs
docker compose -f ims-only-deploy.yaml up -d
sleep 60
docker compose -f ims-only-deploy.yaml ps
```

PyHSS may exit on first boot with `Table 'subscriber' already exists`. This is a race between its services creating the tables at the same time. Start it again:

```bash
docker start pyhss
```

### 3.4 Check the IMS

```bash
# Diameter Cx between the CSCFs and the HSS: expect "State: I_Open"
docker exec icscf kamcmd cdp.list_peers | grep -E "FQDN|State"
docker exec scscf kamcmd cdp.list_peers | grep -E "FQDN|State"

# P-CSCF listens on the host IP (UDP/TCP 5060, IPsec ports 5100/6100); RTPEngine control on 2223
ss -lnup | grep -E "$IMS_HOST_IP:(5060|5100|6100|2223)"

# Host route to the IMS pool, with the MTU cap
ip route get ${UE_POOL_IMS%%/*}        # expect "via $CORE_HOST_IP ... mtu 1400"
```

---

## 4. Provision IMS subscribers (range 1–100)

Every phone must exist in **both** the core (simapp/UDR) and PyHSS, with the same IMSI and K/OPc. PyHSS doesn't sync with the core, so provision the **whole** subscriber range that the core has, not just the phones you're testing now. A phone whose IMSI is missing from PyHSS registers to 5G but never shows the VoLTE/VoNR icon.

```bash
cd ~/Kaimilio/docker_open5gs

# SIM keys: the same K/OPc as in the core's subscriber DB (required)
export KI=<32-hex K> OPC=<32-hex OPc>

# All 100 core subscribers: IMSI 001010000000001..001010000000100 -> MSISDN 9000000001..9000000100
./provision_pyhss.sh 1 100          # or: ./provision_pyhss.sh $UE_FIRST $UE_LAST
```

- **Time:** about 2.5 minutes for 100 subscribers. The script prints one `OK <imsi> -> <msisdn>` line each, or `FAIL ...`.
- **Re-runs are safe:** existing subscribers are skipped. You can add more later with `./provision_pyhss.sh 101 150`, provided the core has them too.
- **Keys are required:** the script stops with `set KI` if `KI`/`OPC` are not set. Every subscriber in the range gets the same K/OPc, which matches how SD-Core provisions a `ueId-start`…`ueId-end` range.
- **PLMN:** MCC/MNC come from `.env`, and the IMSI is always padded to 15 digits. 3-digit MNCs work too.
- **MSISDN pattern:** if your core uses a different one, change it with `MSISDN_PREFIX` and `MSISDN_LEN`. For example, `MSISDN_PREFIX=98 MSISDN_LEN=10` maps N=1 to `9800000001`.
- **A single SIM with its own identity:** run `IMSI=<imsi> MSISDN=<msisdn> KI=<k> OPC=<opc> ./provision_pyhss.sh`.

Check the result:

```bash
docker exec mysql mysql -N -e "select count(*), min(msisdn), max(msisdn) from ims_hss_db.ims_subscriber"
# expected for 1-100:   100   9000000001   9000000100
```

You can also browse and edit subscribers in the PyHSS web UI at `http://$IMS_HOST_IP:8080/docs/`.

---

## 5. Integrate with the core (on the core host)

### 5.1 Core configuration (SD-Core helm values)

Check with `helm get values sd-core -n <namespace>`. These are the IMS-relevant parts:

```yaml
5g-control-plane:
  config:
    amf:  { cfgFiles: { amfcfg.yaml: { configuration: { networkFeatureSupport5GS: { imsVoPS: 1 } } } } }
    smf:
      cfgFiles:
        smfcfg.yaml:
          configuration:
            pcscfInfos: { ipv4: <IMS_HOST_IP> }       # sent to phones in PCO
omec-sub-provision:   # simapp device-group ip-domains
  - dnn: ims       ue-ip-pool: <UE_POOL_IMS>       ...
  - dnn: internet  ue-ip-pool: <UE_POOL_INTERNET>  ...
omec-user-plane:      # upf.jsonc cpiface.dnn_list
  - { dnn: ims,      ue_ip_pool: <UE_POOL_IMS> }
  - { dnn: internet, ue_ip_pool: <UE_POOL_INTERNET> }
```

If you move the IMS to a different host, change `pcscfInfos.ipv4` to the new `IMS_HOST_IP` and run `helm upgrade`. Phones get the new address the next time they set up an `ims` PDU session.

### 5.2 Exempt IMS traffic from NAT (required when the IMS pool is NATed)

List the NAT rules for the UE pools:

```bash
sudo iptables -t nat -S POSTROUTING | grep -E "MASQUERADE|RETURN" | grep -E "${UE_POOL_IMS%%/*}|${UE_POOL_INTERNET%%/*}"
```

If `UE_POOL_IMS` is MASQUERADEd, the P-CSCF sees every phone as `CORE_HOST_IP`, and IMS registration and IPsec fail. Insert a RETURN rule **at position 1** of POSTROUTING, so it always comes before any MASQUERADE rule:

```bash
sudo iptables -t nat -C POSTROUTING -s $UE_POOL_IMS -d $IMS_HOST_IP/32 -j RETURN 2>/dev/null \
  || sudo iptables -t nat -I POSTROUTING 1 -s $UE_POOL_IMS -d $IMS_HOST_IP/32 -j RETURN

sudo iptables -t nat -S POSTROUTING | grep -E "RETURN|MASQUERADE" | grep "${UE_POOL_IMS%%/*}"
# expected: the RETURN line is listed before the MASQUERADE line (if there is one)
#   -A POSTROUTING -s 172.252.0.0/16 -d <IMS_HOST_IP>/32 -j RETURN
#   -A POSTROUTING -s 172.252.0.0/16 -o <CORE_NIC> -j MASQUERADE
```

Notes:
- **Only IMS traffic to the IMS host skips NAT.** Internet traffic from the same pool is still NATed.
- **Pools that share an IP range:** if your core puts `ims` and `internet` in the same pool, use that pool as `UE_POOL_IMS`.
- **An older version of this guide** worked out the insert position with `awk`. When no MASQUERADE rule matched, `$N` was empty and iptables failed with `Invalid rule number 'Chain'`. Position 1 avoids that problem.

> ⚠️ **This rule is not persistent.** Re-run the commands above after every reboot of the core host, or save the rules with `sudo apt install iptables-persistent && sudo netfilter-persistent save`.

### 5.3 Routing

| Where | Route | Status |
|---|---|---|
| Core host | `UE_POOL_IMS via UPF_N6_IP` | Normally already there (SD-Core installs it). Check with `ip route get ${UE_POOL_IMS%%/*}`. |
| IMS host | `UE_POOL_IMS via CORE_HOST_IP mtu 1400` and `UE_POOL_INTERNET via CORE_HOST_IP` | Added by the P-CSCF/RTPEngine init scripts when the containers start |

If the IMS host and core host are on **different subnets**, the IMS host needs a route to `CORE_HOST_IP`. Also check that nothing between the two hosts NATs or filters UDP/TCP 5060, 5100, 6100, UDP 49000–50000 (RTP) or ESP (IP protocol 50).

### 5.4 Check reachability from the core host

Send a SIP OPTIONS from the core host to the P-CSCF. Expect `SIP/2.0 200 OK`.

```bash
IMS_HOST_IP=$IMS_HOST_IP CORE_HOST_IP=$CORE_HOST_IP python3 - <<'EOF'
import os, socket
ims, core = os.environ['IMS_HOST_IP'], os.environ['CORE_HOST_IP']
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3); s.bind(('0.0.0.0', 5099))
m = (f'OPTIONS sip:{ims} SIP/2.0\r\nVia: SIP/2.0/UDP {core}:5099;branch=z9hG4bK1\r\n'
     f'From: <sip:t@{core}>;tag=1\r\nTo: <sip:{ims}>\r\nCall-ID: t1\r\nCSeq: 1 OPTIONS\r\n'
     'Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n')
s.sendto(m.encode(), (ims, 5060)); print(s.recv(2000).decode().splitlines()[0])
EOF
```

---

## 6. gNB requirements

Any 5G SA gNB works if it meets these requirements. An example OAI setup is described in the [appendix](#appendix-a-example-oai-split-gnb-and-du-tuning).
- **N2:** NGAP to the AMF, and `NGSetupResponse` received.
- **N3:** GTP-U to the UPF access address. The N3 path MTU must be at least 1500. The P-CSCF route MTU of 1400 leaves room for GTP overhead.
- **PLMN, TAC and slice** must match the core (for example MCC 001 / MNC 01, TAC 1, SST 1 / SD 000000).

---

## 7. Phone setup

1. **SIM:** the IMSI and K/OPc must exist in **both** the core and PyHSS ([section 4](#4-provision-ims-subscribers-range-1100)).
2. **Calling:** turn on VoLTE / VoNR (5G calling) and turn Wi-Fi calling off. For test PLMNs such as 001/01 these options are often hidden:
   - **Samsung:** enable them through the service menu or a CSC/IMS setting.
   - **OnePlus (Qualcomm):** needs a carrier-config / IMS override.
3. **After adding a subscriber** that an IMS registration previously rejected, **fully reboot** the phone. Samsung phones back off IMS after an HSS reject, and toggling airplane mode is not enough.
4. **Placement:** keep phones at least 1–2 m from the radio unit, with RSRP between about −60 and −90 dBm. A saturated phone (RSRP around −30 dBm) loses its uplink.

---

## 8. Running a VoNR call test

### 8.1 Startup order

1. **Core:** `kubectl -n <namespace> get pods`, and check the NAT exception ([section 5.2](#52-exempt-ims-traffic-from-nat-required-when-the-ims-pool-is-nated)).
2. **IMS:** `cd ~/Kaimilio/docker_open5gs && docker compose -f ims-only-deploy.yaml up -d`. Wait about 60 s, then run the checks in [section 3.4](#34-check-the-ims).
3. **gNB:** start it and confirm the NG setup.
4. **Optional SIP/RTP capture:**
   ```bash
   docker exec -d pcscf sh -c "tcpdump -U -i any -s0 -w /mnt/pcscf/vonr_\$(date +%H%M).pcap 'net $UE_POOL_IMS or net 172.22.0.0/24 or port 5060'"
   ```
   The file appears in `~/Kaimilio/docker_open5gs/pcscf/`. The IPsec uses null encryption, so SIP inside ESP is readable.
5. **Phones:** turn airplane mode off and wait about 30 s for the VoLTE/VoNR icon.

### 8.2 Check registration

```bash
# 5G registration and PDU sessions (core host)
kubectl -n <namespace> logs deploy/amf --since=5m | grep -E "Registration Complete|T3550"
kubectl -n <namespace> logs deploy/smf --since=5m | grep -iE "Dnn:\[ims\]|PCSCF Ip|IP \["

# IMS registration (IMS host). List the MSISDNs of the phones under test.
D=$(grep ^IMS_DOMAIN= ~/Kaimilio/docker_open5gs/.env | cut -d= -f2)
for u in 9000000001 9000000002 9000000006; do echo -n "$u: "
  docker exec scscf kamcmd ulscscf.showimpu sip:$u@$D | grep -m1 -oE "state: [a-z]+"; echo; done
docker exec pcscf kamcmd ulpcscf.status | grep -E "AoR|State"
```

### 8.3 Place the call, then check it

Dial the other phone's MSISDN, for example `9000000006`.

```bash
# SIP call flow at the P-CSCF (docker timestamps are UTC)
docker logs -t --since 5m pcscf 2>&1 | sed "s/\x1b\[[0-9;]*m//g" \
 | grep -aE "<script>: (REQUEST|REPLY): (INVITE|PRACK|ACK|BYE|CANCEL|[1-6][0-9]{2} [^(]*\((INVITE|BYE))" \
 | sed -E 's/^.{11}([0-9:.]{12}).*<script>: /\1 /' | cut -c1-140
# A good call shows: INVITE → 100 → 183 → PRACK/200 → 180 → 200 OK → ACK … BYE → 200 OK

# Media relayed by RTPEngine
docker exec rtpengine rtpengine-ctl -ip $IMS_HOST_IP:9901 list totals | grep -E "relayed packets  |no relayed|Average call"
```

`Total number of streams with no relayed packets : 0` means audio flowed in both directions.

### 8.4 Shut down

```bash
docker exec pcscf pkill -INT tcpdump
cd ~/Kaimilio/docker_open5gs && docker compose -f ims-only-deploy.yaml stop
```

Stop the gNB before the IMS. The core stays up.

---

## 9. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Phone registers to 5G but never shows VoLTE/VoNR | Its IMSI is not in PyHSS | `docker exec mysql mysql -e "select imsi,msisdn from ims_hss_db.ims_subscriber where imsi='<imsi>'"`. If it's missing, run `KI=<k> OPC=<opc> ./provision_pyhss.sh <N> <N>`, then reboot the phone. |
| `iptables: Invalid rule number 'Chain'` | `$N` was empty: no MASQUERADE rule matched the pool in the old `awk` command | Use `-I POSTROUTING 1` ([section 5.2](#52-exempt-ims-traffic-from-nat-required-when-the-ims-pool-is-nated)) |
| Phone gets an `ims` PDU session but IMS registration fails; the P-CSCF sees source `CORE_HOST_IP` | The core host NATs `UE_POOL_IMS` | Add the NAT exception ([section 5.2](#52-exempt-ims-traffic-from-nat-required-when-the-ims-pool-is-nated)) |
| Phone gets an `ims` PDU session but never sends a SIP REGISTER | The SMF doesn't send the P-CSCF address, or `pcscfInfos` ≠ `IMS_HOST_IP` | Check the SMF log (`PCSCF Ip`) and `pcscfInfos` |
| Calls **to** a OnePlus fail: 408, then `500 Server error on LIR select next S-CSCF`, with 64-byte ESP packets repeating | The P-CSCF opens TCP to the phone's protected port | The patch fixes this: `IPSEC_FORWARD_FLAGS 385`, and `udp_mtu_try_proto` off |
| Large SIP messages (NOTIFY, INVITE with SDP) never answered; captures show `ip-proto-50` fragments | Fragment plus GTP overhead exceeds the N3 MTU | Route MTU 1400 (patch). Check with `ip route get ${UE_POOL_IMS%%/*}` |
| Call to an idle phone fails after about 3 s | P-CSCF `fr_timer` is shorter than paging plus service request | `fr_timer 10000` (patch). Runtime change: `docker exec pcscf kamcmd cfg.set_now_int tm fr_timer 10000` |
| P-CSCF container fails; `address already in use` on 5060 | Another SIP service on the IMS host | Stop it. The P-CSCF needs `IMS_HOST_IP:5060/5100/6100` |
| PyHSS container exits on first start | Race on DB table creation | `docker start pyhss` |
| `docker compose` warns that `IMS_DOMAIN` is not set | `configure_site.sh` hasn't been run | Run it ([section 3.2](#32-apply-the-p-cscf-fixes-and-the-site-configuration)) |

Useful logs:
- **IMS:** `docker logs -f pcscf|scscf|icscf|pyhss|rtpengine`
- **Core:** `kubectl -n <namespace> logs -f deploy/amf|deploy/smf`, and `upf-0 -c pfcp-agent|bessd`

---

## 10. Known limitations

1. **No dedicated QoS flows** (5QI 1 for voice, 5QI 2 for video). Voice uses the default flow of the `ims` DNN. This needs N5 from the P-CSCF to the PCF (`WITH_N5`), and support for it in the core PCF.
2. **The NAT exception isn't persistent** unless it is saved ([section 5.2](#52-exempt-ims-traffic-from-nat-required-when-the-ims-pool-is-nated)).
3. **PyHSS and the core subscriber DB are separate.** Add each subscriber to both.

---

## Appendix A: Example OAI split gNB and DU tuning

One of the test sites used an OAI split gNB (CU-CP / CU-UP / DU) with a FHI 7.2 O-RU on n78, 100 MHz, 30 kHz SCS.
- **Start order:** CU-CP first (wait for `NGSetupResponse`), then CU-UP (`E1 connection established`), then DU (`F1 Setup Response`).
- **Stop order:** the reverse.

DU changes that stabilized RACH and fronthaul timing:

| Parameter | Original | Now | Reason |
|---|---|---|---|
| `preambleReceivedTargetPower` | −100 | −90 | Preambles were detected only just above threshold (14–17 dB against 12 dB), so the TA estimate was noisy and Msg3 failed |
| `msg3_DeltaPreamble` | 0 | 2 | +4 dB on Msg3 |
| `powerRampingStep` | 1 (2 dB) | 2 (4 dB) | A retry succeeds sooner |
| `ra_ContentionResolutionTimer` | 4 (40 ms) | 7 (64 ms) | More time for Msg3 retransmissions and Msg4 |
| `pusch_FailureThres` | 10000 | 100 | Dead phones are released instead of staying scheduled |
| `fh_config.Ta4` | (110, 180) | (0, 400) | About 48% of UL U-plane packets were early; now 0% early and ~0.26% late |

Fronthaul health check: in the DU log, `RX Timing` should show `early 0` and `late` close to 0.

---

## Repository contents

| File | Purpose |
|---|---|
| `files/ims-pcscf-fixes.patch` | P-CSCF fixes for docker_open5gs (Rx off, UDP-only toward UEs, `fr_timer`, route MTU) |
| `files/ims-only-deploy.yaml` | Compose file for the IMS only (no core); all IPs and domains come from `.env` |
| `files/configure_site.sh` | Writes the site values into docker_open5gs `.env` |
| `files/provision_pyhss.sh` | Provisions a range of subscribers (for example 1–100) or a single SIM in PyHSS |

## Credits and license

Built on [docker_open5gs](https://github.com/herlesupreeth/docker_open5gs) by Supreeth Herle, which uses Kamailio, PyHSS and RTPEngine. `files/ims-pcscf-fixes.patch` and `files/ims-only-deploy.yaml` are derived from docker_open5gs and are distributed under its BSD 2-Clause license (`files/LICENSE-docker_open5gs`).
