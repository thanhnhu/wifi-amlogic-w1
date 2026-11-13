#!/bin/sh
# wlan-5g-warmup: one-shot boot helper for the W1 chip on a DFS 5 GHz AP.
#
# After a cold boot the W1 firmware does not transmit on a DFS channel (e.g. ch52):
# every AUTH frame completes with TX status 4 (AGED) and wpa_supplicant loops on
# "CTRL-EVENT-DISCONNECTED reason=0" / SSID-TEMP-DISABLED, for many minutes.
# Once the chip has completed one connection on 2.4 GHz, 5 GHz associates at once.
#
# So, once per wpa_supplicant start:
#   1. already on 5 GHz?                  -> nothing to do
#   2. connect to the 2.4 GHz SSID briefly (warms up the TX path)
#   3. select the 5 GHz SSID              (select_network disables the others)
#   4. KEEP_24G=1 -> re-enable 2.4 GHz as a fallback; otherwise it stays disabled
#
# Runtime only: the wpa_supplicant config file is never rewritten.
# Settings: /etc/default/wlan-5g-warmup (IFACE, SSID_24, SSID_5, KEEP_24G).

IFACE=wlan0
SSID_24=""
SSID_5=""
KEEP_24G=0
[ -r /etc/default/wlan-5g-warmup ] && . /etc/default/wlan-5g-warmup

W="wpa_cli -i $IFACE"
log() { logger -t wlan-5g-warmup "$*"; echo "$*"; }

# network id of an SSID from "id<TAB>ssid<TAB>bssid<TAB>flags"
net_id() { $W list_networks 2>/dev/null | awk -F'\t' -v s="$1" 'NR>1 && $2==s {print $1; exit}'; }
state()  { $W status 2>/dev/null | sed -n 's/^wpa_state=//p'; }
freq()   { $W status 2>/dev/null | sed -n 's/^freq=//p'; }

# wait_for <seconds> <condition...>: poll once per second
wait_for() {
    t=$1; shift
    while [ "$t" -gt 0 ]; do
        "$@" && return 0
        t=$((t - 1)); sleep 1
    done
    return 1
}
ctrl_ready() { $W ping 2>/dev/null | grep -q PONG; }
connected()  { [ "$(state)" = COMPLETED ]; }
on_5g()      { connected && case "$(freq)" in 5*) true;; *) false;; esac; }

if [ -z "$SSID_24" ] || [ -z "$SSID_5" ]; then
    log "SSID_24 / SSID_5 not set in /etc/default/wlan-5g-warmup, nothing to do"
    exit 0
fi

wait_for 60 ctrl_ready || { log "wpa_supplicant on $IFACE not reachable"; exit 0; }

ID24=$(net_id "$SSID_24")
ID5=$(net_id "$SSID_5")
if [ -z "$ID24" ] || [ -z "$ID5" ]; then
    log "network block missing (2.4G id='$ID24', 5G id='$ID5')"
    exit 0
fi

# Give a normal association a short chance first (non-DFS AP, warm reboot...)
if wait_for 15 on_5g; then
    log "already on 5 GHz"
    exit 0
fi

attempt=1
while [ $attempt -le 3 ]; do
    log "attempt $attempt: warming up on '$SSID_24'"
    $W enable_network "$ID24" >/dev/null
    $W select_network "$ID24" >/dev/null
    if wait_for 40 connected; then
        sleep 3
        log "switching to '$SSID_5'"
        $W enable_network "$ID5" >/dev/null
        $W select_network "$ID5" >/dev/null
        if wait_for 40 on_5g; then
            [ "$KEEP_24G" = 1 ] && $W enable_network "$ID24" >/dev/null
            log "connected to '$SSID_5' (freq $(freq)) on attempt $attempt"
            exit 0
        fi
    else
        log "could not connect to '$SSID_24'"
    fi
    attempt=$((attempt + 1))
done

# Give up: leave 5 GHz enabled so wpa_supplicant (autoscan) keeps trying on its own.
$W enable_network "$ID5" >/dev/null
if [ "$KEEP_24G" = 1 ]; then
    $W enable_network "$ID24" >/dev/null
else
    $W disable_network "$ID24" >/dev/null
fi
log "5 GHz not reached after 3 attempts; leaving it to wpa_supplicant"
exit 0
