.pragma library

// `nmcli dev wifi connect … password` only speaks WPA-PSK; an 802.1X network (eduroam, campus
// Wi-Fi) needs a profile that carries an EAP identity. PEAP + MSCHAPv2 is what eduroam and most
// university networks expect. A failed join deletes the profile so the next try asks again
// instead of NetworkManager replaying the bad credentials.
// Values travel as positional args ($1 ssid, $2 identity, $3 password), never spliced into the script.
var script =
    'nmcli con delete id "$1" >/dev/null 2>&1; '
  + 'nmcli con add type wifi con-name "$1" ssid "$1" '
  + 'wifi-sec.key-mgmt wpa-eap 802-1x.eap peap 802-1x.phase2-auth mschapv2 '
  + '802-1x.identity "$2" 802-1x.password "$3" >/dev/null || exit 1; '
  + 'nmcli --wait 25 con up id "$1" 2>&1 && exit 0; '
  + 'nmcli con delete id "$1" >/dev/null 2>&1; exit 1';

function isEnterprise(security) { return ("" + (security || "")).indexOf("802.1X") >= 0 }

function joinCmd(ssid, identity, password) {
    return ["sh", "-c", script, "sea-wifi-eap", ssid, identity, password];
}
