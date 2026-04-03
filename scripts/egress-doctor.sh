#!/usr/bin/env bash
set -euo pipefail

DOMAIN="opc.ren"
REPAIR=0
OUTPUT_FILE=""

usage() {
  cat <<'EOF'
Usage:
  egress-doctor.sh [--domain DOMAIN] [--repair] [--output FILE]

Examples:
  ./scripts/egress-doctor.sh --domain opc.ren
  ./scripts/egress-doctor.sh --domain opc.ren --repair --output ./report.txt
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain)
      DOMAIN="${2:-}"
      shift 2
      ;;
    --repair)
      REPAIR=1
      shift
      ;;
    --output)
      OUTPUT_FILE="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${OUTPUT_FILE}" ]]; then
  OUTPUT_FILE="./egress-report-${DOMAIN}-$(date +%Y%m%d-%H%M%S).txt"
fi

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${OUTPUT_FILE}"
}

section() {
  printf '\n========== %s ==========\n' "$*" | tee -a "${OUTPUT_FILE}"
}

run_cmd() {
  local desc="$1"
  shift
  section "${desc}"
  printf '$ %s\n' "$*" | tee -a "${OUTPUT_FILE}"
  if "$@" >>"${OUTPUT_FILE}" 2>&1; then
    log "exit=0"
  else
    log "exit=$?"
  fi
}

probe_dns() {
  local domain="$1"
  local resolver="$2"
  local out=""

  if command -v dig >/dev/null 2>&1; then
    if [[ -n "${resolver}" ]]; then
      out="$(dig @"${resolver}" +short A "${domain}" 2>/dev/null | tr '\n' ' ' | xargs || true)"
    else
      out="$(dig +short A "${domain}" 2>/dev/null | tr '\n' ' ' | xargs || true)"
    fi
  elif command -v nslookup >/dev/null 2>&1; then
    if [[ -n "${resolver}" ]]; then
      out="$(nslookup "${domain}" "${resolver}" 2>/dev/null | awk '/^Address: /{print $2}' | tr '\n' ' ' | xargs || true)"
    else
      out="$(nslookup "${domain}" 2>/dev/null | awk '/^Address: /{print $2}' | tr '\n' ' ' | xargs || true)"
    fi
  fi

  printf '%s' "${out}"
}

flush_dns_cache() {
  section "Repair: DNS Cache Flush"
  local uname_s
  uname_s="$(uname -s)"

  if [[ "${uname_s}" == "Linux" ]]; then
    run_cmd "Flush via resolvectl (if present)" bash -lc 'command -v resolvectl >/dev/null 2>&1 && sudo resolvectl flush-caches || true'
    run_cmd "Flush via systemd-resolve (if present)" bash -lc 'command -v systemd-resolve >/dev/null 2>&1 && sudo systemd-resolve --flush-caches || true'
    run_cmd "Restart nscd (if present)" bash -lc 'sudo systemctl restart nscd 2>/dev/null || true'
    run_cmd "Restart dnsmasq (if present)" bash -lc 'sudo systemctl restart dnsmasq 2>/dev/null || true'
  elif [[ "${uname_s}" == "Darwin" ]]; then
    run_cmd "Flush mDNSResponder cache" sudo dscacheutil -flushcache
    run_cmd "Reload mDNSResponder" sudo killall -HUP mDNSResponder
  else
    log "Unsupported OS for auto-repair: ${uname_s}"
  fi
}

tcp_probe() {
  local host="$1"
  local port="$2"
  if command -v nc >/dev/null 2>&1; then
    nc -vz -w 5 "${host}" "${port}" >>"${OUTPUT_FILE}" 2>&1
  elif command -v telnet >/dev/null 2>&1; then
    timeout 6 telnet "${host}" "${port}" >>"${OUTPUT_FILE}" 2>&1
  else
    echo "No nc/telnet available for TCP probe" >>"${OUTPUT_FILE}"
    return 2
  fi
}

echo "# Network Egress Doctor Report" >"${OUTPUT_FILE}"
echo "# Domain: ${DOMAIN}" >>"${OUTPUT_FILE}"
echo "# GeneratedAt: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"${OUTPUT_FILE}"

section "Host Context"
run_cmd "Basic OS info" uname -a
run_cmd "User and hostname" bash -lc 'id && hostname'
run_cmd "Proxy env" bash -lc 'env | grep -Ei "^(http|https|all|no)_proxy=" || true'
run_cmd "Resolver config (if present)" bash -lc 'cat /etc/resolv.conf 2>/dev/null || true'

section "DNS Comparison"
SYS_A="$(probe_dns "${DOMAIN}" "")"
ALI_A="$(probe_dns "${DOMAIN}" "223.5.5.5")"
N114_A="$(probe_dns "${DOMAIN}" "114.114.114.114")"
CLOUDFLARE_A="$(probe_dns "${DOMAIN}" "1.1.1.1")"
GOOGLE_A="$(probe_dns "${DOMAIN}" "8.8.8.8")"

log "system-resolver A: ${SYS_A:-<empty>}"
log "223.5.5.5 A:      ${ALI_A:-<empty>}"
log "114.114.114.114 A:${N114_A:-<empty>}"
log "1.1.1.1 A:        ${CLOUDFLARE_A:-<empty>}"
log "8.8.8.8 A:        ${GOOGLE_A:-<empty>}"

run_cmd "AAAA via system resolver" bash -lc "command -v dig >/dev/null 2>&1 && dig +short AAAA ${DOMAIN} || true"

section "L3/L4 Connectivity"
run_cmd "TCP probe ${DOMAIN}:443" tcp_probe "${DOMAIN}" 443
run_cmd "TCP probe ${DOMAIN}:80" tcp_probe "${DOMAIN}" 80

if [[ -n "${ALI_A}" ]]; then
  FIRST_IP="$(printf '%s\n' "${ALI_A}" | awk '{print $1}')"
  run_cmd "TCP probe ${FIRST_IP}:443 (direct IP)" tcp_probe "${FIRST_IP}" 443
  run_cmd "TLS with SNI ${DOMAIN} on ${FIRST_IP}" bash -lc "echo | openssl s_client -connect ${FIRST_IP}:443 -servername ${DOMAIN} 2>/dev/null | openssl x509 -noout -issuer -subject -dates"
  run_cmd "HTTP over direct IP + Host/SNI mapping" curl -sS --max-time 15 -I --resolve "${DOMAIN}:443:${FIRST_IP}" "https://${DOMAIN}"
fi

section "HTTP Checks"
run_cmd "HTTP 80 -> expected redirect" curl -sS --max-time 15 -I "http://${DOMAIN}"
run_cmd "HTTPS 443 -> expected 200/30x" curl -sS --max-time 15 -I "https://${DOMAIN}"
run_cmd "HTTPS 443 direct(no proxy env) -> compare gateway/proxy impact" env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY curl -sS --max-time 15 -I "https://${DOMAIN}"

if [[ ${REPAIR} -eq 1 ]]; then
  flush_dns_cache
  section "Post-Repair Verification"
  SYS_A_AFTER="$(probe_dns "${DOMAIN}" "")"
  log "system-resolver A after repair: ${SYS_A_AFTER:-<empty>}"
  run_cmd "HTTPS check after repair" curl -sS --max-time 15 -I "https://${DOMAIN}"
fi

section "Diagnosis"
HAS_PROXY_ENV=0
if env | grep -qiE '^(http|https|all)_proxy='; then
  HAS_PROXY_ENV=1
fi

HTTPS_WITH_ENV_RC=0
curl -sS --max-time 15 -I "https://${DOMAIN}" >/dev/null 2>&1 || HTTPS_WITH_ENV_RC=$?

HTTPS_DIRECT_RC=0
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY -u all_proxy -u ALL_PROXY -u no_proxy -u NO_PROXY \
  curl -sS --max-time 15 -I "https://${DOMAIN}" >/dev/null 2>&1 || HTTPS_DIRECT_RC=$?

log "diag: has_proxy_env=${HAS_PROXY_ENV} https_with_env_rc=${HTTPS_WITH_ENV_RC} https_direct_rc=${HTTPS_DIRECT_RC}"

if [[ ${HAS_PROXY_ENV} -eq 1 && ${HTTPS_WITH_ENV_RC} -ne 0 && ${HTTPS_DIRECT_RC} -eq 0 ]]; then
  log "Likely company proxy/gateway issue: proxied HTTPS fails while direct HTTPS works."
elif [[ ${HAS_PROXY_ENV} -eq 1 && ${HTTPS_WITH_ENV_RC} -ne 0 ]] && grep -q '200 Connection established' "${OUTPUT_FILE}"; then
  log "Likely HTTPS interception/proxy tunnel issue: CONNECT succeeded but TLS handshake failed."
elif [[ ${HAS_PROXY_ENV} -eq 1 && ${HTTPS_WITH_ENV_RC} -eq 0 && ${HTTPS_DIRECT_RC} -ne 0 ]]; then
  log "Direct egress may be blocked; current proxy path is required/working."
elif [[ -z "${SYS_A}" && -n "${ALI_A}${N114_A}${CLOUDFLARE_A}${GOOGLE_A}" ]]; then
  log "Likely local resolver/cache issue: system DNS failed while public resolvers returned records."
elif [[ -n "${SYS_A}" ]]; then
  if grep -qE 'curl: \([0-9]+\) (Failed to connect|Connection timed out|Could not connect)' "${OUTPUT_FILE}"; then
    log "Likely egress firewall/company gateway issue: DNS resolves but transport fails."
  elif grep -qE 'SSL|certificate|handshake|tls' "${OUTPUT_FILE}"; then
    log "Possible TLS interception or gateway SSL policy issue."
  else
    log "No hard failure reproduced in this run. Keep report and compare with failing network."
  fi
else
  log "Insufficient data: DNS did not return results from any resolver. Check outbound DNS/UDP/TCP 53 policy."
fi

section "Next Actions"
log "1) If local resolver fails, switch DNS to 223.5.5.5 / 114.114.114.114 and retest."
log "2) If DNS works but HTTPS fails, ask network admin to allow ${DOMAIN} and 121.199.8.54:443."
log "3) If only browser fails, clear local DNS cache and browser HSTS cache, then retry."
log "4) Attach this report to escalation ticket."

log "Report written to: ${OUTPUT_FILE}"
