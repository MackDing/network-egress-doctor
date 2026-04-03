#!/usr/bin/env bash
set -euo pipefail

DOMAIN="${1:-opc.ren}"
IP="${2:-121.199.8.54}"
DNS1="${DNS1:-223.5.5.5}"
DNS2="${DNS2:-114.114.114.114}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/repair-wsl-egress.sh [domain] [ip]"
  exit 1
fi

echo "[1/6] Backup /etc/wsl.conf and /etc/resolv.conf"
cp -a /etc/wsl.conf "/etc/wsl.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
cp -a /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

echo "[2/6] Disable WSL auto resolv.conf generation"
cat >/etc/wsl.conf <<'EOF'
[network]
generateResolvConf = false
EOF

echo "[3/6] Set stable public DNS resolvers"
cat >/etc/resolv.conf <<EOF
nameserver ${DNS1}
nameserver ${DNS2}
EOF
chmod 644 /etc/resolv.conf

echo "[4/6] Pin hosts entry for ${DOMAIN} -> ${IP}"
if grep -qE "[[:space:]]${DOMAIN}([[:space:]]|$)" /etc/hosts; then
  sed -i -E "s#^[0-9.]+([[:space:]]+.*\\b${DOMAIN}\\b.*)#${IP}\\1#g" /etc/hosts
else
  printf "%s %s\n" "${IP}" "${DOMAIN}" >> /etc/hosts
fi

echo "[5/6] Persist no_proxy/no_PROXY bypass in shell profile"
TARGET_PROFILE="/etc/profile.d/network-egress-doctor.sh"
cat >"${TARGET_PROFILE}" <<EOF
# Added by network-egress-doctor
export no_proxy="\${no_proxy:+\${no_proxy},}${DOMAIN},${IP}"
export NO_PROXY="\${NO_PROXY:+\${NO_PROXY},}${DOMAIN},${IP}"
EOF
chmod 644 "${TARGET_PROFILE}"

echo "[6/6] Flush local DNS cache if available"
command -v resolvectl >/dev/null 2>&1 && resolvectl flush-caches || true
command -v systemd-resolve >/dev/null 2>&1 && systemd-resolve --flush-caches || true

echo "Done."
echo "Next:"
echo "  1) Restart WSL from Windows PowerShell: wsl --shutdown"
echo "  2) Re-open terminal and verify:"
echo "     curl -I https://${DOMAIN}"
