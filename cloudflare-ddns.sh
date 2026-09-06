#!/usr/bin/env bash
# Cloudflare IPv4 DDNS
# 依赖：bash；curl 和 jq 缺失时会自动安装
#
# 直接运行后会交互询问 Cloudflare Token 和需要更新的完整域名。
# Token 仅保存在当前进程内，不会写入脚本或其他文件，可安全上传公开仓库。

set -uo pipefail

API_BASE="https://api.cloudflare.com/client/v4"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
CF_ZONE_ID="${CF_ZONE_ID:-}"
CF_CREATE_RECORD="${CF_CREATE_RECORD:-true}"
CF_PROXIED="${CF_PROXIED:-false}"
CF_TTL="${CF_TTL:-1}"

IP_CHECK_URLS=(
  "https://ddns.oray.com/checkip"
  "https://ip.3322.net"
  "https://4.ipw.cn"
  "https://v4.yinghualuo.cn/bejson"
  "https://myip.ipip.net"
)

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

die() {
  log "错误：$*" >&2
  exit 1
}

install_dependencies() {
  local missing=() command_name
  local run_as_root=()

  for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || missing+=("$command_name")
  done

  if (( ${#missing[@]} == 0 )); then
    log "依赖检查通过：curl、jq 已安装"
    return 0
  fi

  log "检测到缺少依赖：${missing[*]}，准备自动安装"
  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "当前不是 root 用户且系统没有 sudo，无法自动安装依赖"
    run_as_root=(sudo)
  fi

  if command -v apt-get >/dev/null 2>&1; then
    "${run_as_root[@]}" apt-get update || die "更新 apt 软件源失败"
    "${run_as_root[@]}" apt-get install -y curl jq || die "安装 curl、jq 失败"
  elif command -v dnf >/dev/null 2>&1; then
    "${run_as_root[@]}" dnf install -y curl jq || die "安装 curl、jq 失败"
  elif command -v yum >/dev/null 2>&1; then
    "${run_as_root[@]}" yum install -y curl jq || die "安装 curl、jq 失败"
  elif command -v apk >/dev/null 2>&1; then
    "${run_as_root[@]}" apk add --no-cache curl jq || die "安装 curl、jq 失败"
  elif command -v zypper >/dev/null 2>&1; then
    "${run_as_root[@]}" zypper --non-interactive install curl jq || die "安装 curl、jq 失败"
  elif command -v pacman >/dev/null 2>&1; then
    "${run_as_root[@]}" pacman -S --needed --noconfirm curl jq || die "安装 curl、jq 失败"
  else
    die "无法识别系统包管理器，请手动安装：${missing[*]}"
  fi

  for command_name in curl jq; do
    command -v "$command_name" >/dev/null 2>&1 || die "自动安装完成后仍找不到 $command_name"
  done
  log "依赖安装完成"
}

install_dependencies

CF_API_TOKEN=""
CF_DNS_RECORD=""

read -r -s -p "请输入 Cloudflare API Token（输入内容不会显示）: " CF_API_TOKEN
printf '\n'

read -r -p "请输入需要更新的完整域名（例如 home.example.com）: " CF_DNS_RECORD

CF_DNS_RECORD="${CF_DNS_RECORD%.}"
[[ -n "$CF_API_TOKEN" ]] || die "Token 不能为空"
[[ "$CF_DNS_RECORD" == *.* ]] || die "请输入完整域名，例如 home.example.com"
[[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] && (( CHECK_INTERVAL >= 10 )) || die "CHECK_INTERVAL 必须是不小于 10 的整数"
[[ "$HTTP_TIMEOUT" =~ ^[0-9]+$ ]] && (( HTTP_TIMEOUT >= 1 )) || die "HTTP_TIMEOUT 必须是正整数"
[[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "CF_TTL 必须是整数"
(( CF_TTL == 1 || (CF_TTL >= 60 && CF_TTL <= 86400) )) || die "CF_TTL 必须为 1（自动）或 60 到 86400"
[[ "$CF_CREATE_RECORD" == "true" || "$CF_CREATE_RECORD" == "false" ]] || die "CF_CREATE_RECORD 必须是 true 或 false"
[[ "$CF_PROXIED" == "true" || "$CF_PROXIED" == "false" ]] || die "CF_PROXIED 必须是 true 或 false"

valid_public_ipv4() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<<"$ip"
  [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
  (( a <= 255 && b <= 255 && c <= 255 && d <= 255 )) || return 1

  # 排除常见私网、回环、链路本地、组播及保留地址。
  (( a == 0 || a == 10 || a == 127 || a >= 224 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  return 0
}

get_public_ipv4() {
  local url response candidate
  for url in "${IP_CHECK_URLS[@]}"; do
    if ! response="$(curl -4 -fsSL --max-time "$HTTP_TIMEOUT" \
      -A 'cloudflare-ddns/1.0' "$url" 2>/dev/null)"; then
      log "IP 查询接口失败：$url" >&2
      continue
    fi

    candidate="$(grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' <<<"$response" | head -n 1 || true)"
    if [[ -n "$candidate" ]] && valid_public_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
    log "IP 查询接口未返回有效公网 IPv4：$url" >&2
  done
  return 1
}

cf_curl() {
  curl -fsS --max-time "$HTTP_TIMEOUT" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H 'Content-Type: application/json' \
    -A 'cloudflare-ddns/1.0' "$@"
}

check_cf_response() {
  local response="$1" message
  if ! jq -e '.success == true' >/dev/null 2>&1 <<<"$response"; then
    message="$(jq -r '[.errors[]?.message] | join("；")' <<<"$response" 2>/dev/null || true)"
    [[ -n "$message" ]] || message="Cloudflare 返回异常"
    log "Cloudflare API 错误：$message" >&2
    return 1
  fi
}

find_zone_id() {
  local response zone_name zone_id best_id="" best_length=0

  if [[ -n "$CF_ZONE_ID" ]]; then
    printf '%s' "$CF_ZONE_ID"
    return 0
  fi

  if ! response="$(cf_curl -G "$API_BASE/zones" --data-urlencode 'per_page=50')"; then
    log "无法查询 Cloudflare Zone" >&2
    return 1
  fi
  check_cf_response "$response" || return 1

  while IFS=$'\t' read -r zone_name zone_id; do
    if [[ "$CF_DNS_RECORD" == "$zone_name" || "$CF_DNS_RECORD" == *."$zone_name" ]]; then
      if (( ${#zone_name} > best_length )); then
        best_id="$zone_id"
        best_length=${#zone_name}
      fi
    fi
  done < <(jq -r '.result[] | [.name, .id] | @tsv' <<<"$response")

  if [[ -z "$best_id" ]]; then
    log "找不到 $CF_DNS_RECORD 所属 Zone；请增加 Zone Read 权限或设置 CF_ZONE_ID" >&2
    return 1
  fi
  printf '%s' "$best_id"
}

sync_dns() {
  local new_ip="$1" zone_id response count changed record_id old_ip body

  zone_id="$(find_zone_id)" || return 1
  if ! response="$(cf_curl -G "$API_BASE/zones/$zone_id/dns_records" \
    --data-urlencode 'type=A' \
    --data-urlencode "name=$CF_DNS_RECORD" \
    --data-urlencode 'per_page=100')"; then
    log "无法查询 DNS 记录 $CF_DNS_RECORD" >&2
    return 1
  fi
  check_cf_response "$response" || return 1

  count="$(jq '.result | length' <<<"$response")"
  if (( count == 0 )); then
    if [[ "$CF_CREATE_RECORD" != "true" ]]; then
      log "A 记录不存在，且 CF_CREATE_RECORD=false" >&2
      return 1
    fi
    body="$(jq -cn \
      --arg name "$CF_DNS_RECORD" \
      --arg content "$new_ip" \
      --argjson proxied "$CF_PROXIED" \
      --argjson ttl "$CF_TTL" \
      '{type:"A", name:$name, content:$content, proxied:$proxied, ttl:$ttl}')"
    if ! response="$(cf_curl -X POST "$API_BASE/zones/$zone_id/dns_records" --data "$body")"; then
      log "创建 A 记录失败" >&2
      return 1
    fi
    check_cf_response "$response" || return 1
    log "已创建 A 记录：$CF_DNS_RECORD -> $new_ip"
    return 0
  fi

  changed=0
  while IFS=$'\t' read -r record_id old_ip; do
    [[ "$old_ip" == "$new_ip" ]] && continue
    body="$(jq -cn --arg content "$new_ip" '{content:$content}')"
    if ! response="$(cf_curl -X PATCH \
      "$API_BASE/zones/$zone_id/dns_records/$record_id" --data "$body")"; then
      log "更新 A 记录失败：$CF_DNS_RECORD" >&2
      return 1
    fi
    check_cf_response "$response" || return 1
    log "已更新 A 记录：$CF_DNS_RECORD，$old_ip -> $new_ip"
    changed=1
  done < <(jq -r '.result[] | [.id, .content] | @tsv' <<<"$response")

  (( changed == 1 )) || log "DNS 已是最新：$CF_DNS_RECORD -> $new_ip"
}

stopped=false
trap 'stopped=true' INT TERM
last_synced_ip=""

log "DDNS 已启动：域名 $CF_DNS_RECORD，检查间隔 ${CHECK_INTERVAL} 秒"
while [[ "$stopped" == "false" ]]; do
  if current_ip="$(get_public_ipv4)"; then
    if [[ "$current_ip" != "$last_synced_ip" ]]; then
      log "检测到公网 IPv4：$current_ip"
      if sync_dns "$current_ip"; then
        last_synced_ip="$current_ip"
      else
        log "本轮同步失败，${CHECK_INTERVAL} 秒后重试" >&2
      fi
    else
      log "公网 IPv4 未变化：$current_ip"
    fi
  else
    log "所有公网 IPv4 查询接口均失败，${CHECK_INTERVAL} 秒后重试" >&2
  fi

  sleep "$CHECK_INTERVAL" &
  wait $! || true
done

log "DDNS 已停止"
