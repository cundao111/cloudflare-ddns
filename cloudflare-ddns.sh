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
TELEGRAM_SERVER_NAME="AWS--新加坡--1"
RUN_MODE="${1:-start}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")"
if (( EUID == 0 )); then
  DEFAULT_LOG_FILE="/var/log/cloudflare-ddns.log"
  DEFAULT_PID_FILE="/run/cloudflare-ddns.pid"
  DEFAULT_COUNT_STATE_FILE="/var/lib/cloudflare-ddns/ip-update-count"
else
  DEFAULT_LOG_FILE="$SCRIPT_DIR/cloudflare-ddns.log"
  DEFAULT_PID_FILE="$SCRIPT_DIR/.cloudflare-ddns.pid"
  DEFAULT_COUNT_STATE_FILE="$SCRIPT_DIR/.cloudflare-ddns-ip-update-count"
fi
LOG_FILE="${DDNS_LOG_FILE:-$DEFAULT_LOG_FILE}"
PID_FILE="${DDNS_PID_FILE:-$DEFAULT_PID_FILE}"
COUNT_STATE_FILE="${DDNS_COUNT_STATE_FILE:-$DEFAULT_COUNT_STATE_FILE}"

IP_CHECK_URLS=(
  "https://ddns.oray.com/checkip"
  "https://ip.3322.net"
  "https://4.ipw.cn"
  "https://v4.yinghualuo.cn/bejson"
  "https://myip.ipip.net"
)

log() {
  # 即使系统设置失败，DDNS 日志仍按北京时间显示。
  printf '%s %s\n' "$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')" "$*"
}

prepare_daily_log() {
  LOG_DAY="$(TZ=Asia/Shanghai date '+%Y-%m-%d')"
  # 如果日志中没有当天记录，说明它来自前一天或更早，启动时直接清空。
  if [[ -s "$LOG_FILE" ]] && ! grep -q "^${LOG_DAY} " "$LOG_FILE" 2>/dev/null; then
    : >"$LOG_FILE"
  fi
}

clear_log_after_midnight() {
  local today
  today="$(TZ=Asia/Shanghai date '+%Y-%m-%d')"
  if [[ "$today" != "$LOG_DAY" ]]; then
    : >"$LOG_FILE"
    LOG_DAY="$today"
    log "已清理前一天日志；当前只保留当天日志"
  fi
}

die() {
  log "错误：$*" >&2
  exit 1
}

running_pid() {
  local pid=""
  [[ -f "$PID_FILE" ]] || return 1
  read -r pid <"$PID_FILE" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

case "$RUN_MODE" in
  --status)
    if pid="$(running_pid)"; then
      log "DDNS 正在后台运行，PID：$pid，日志：$LOG_FILE"
      exit 0
    fi
    log "DDNS 当前没有运行"
    exit 1
    ;;
  --stop)
    if pid="$(running_pid)"; then
      kill -TERM "$pid" || die "无法停止 PID $pid"
      log "已发送停止信号，PID：$pid"
      exit 0
    fi
    rm -f -- "$PID_FILE"
    log "DDNS 当前没有运行"
    exit 0
    ;;
  start|--daemon-child)
    ;;
  *)
    die "未知参数：$RUN_MODE；可用参数：--status、--stop"
    ;;
esac

configure_beijing_time() {
  local run_as_root=()
  local timezone_set=false

  if (( EUID != 0 )); then
    command -v sudo >/dev/null 2>&1 || die "当前不是 root 用户且系统没有 sudo，无法设置北京时间"
    run_as_root=(sudo)
  fi

  log "正在设置系统时区为北京时间（Asia/Shanghai）"
  if command -v timedatectl >/dev/null 2>&1; then
    if "${run_as_root[@]}" timedatectl set-timezone Asia/Shanghai; then
      timezone_set=true
      if ! "${run_as_root[@]}" timedatectl set-ntp true; then
        log "已设置北京时间，但未能启用 NTP 自动校时；请检查服务器的时间同步服务" >&2
      fi
    fi
  fi

  # 适配 Docker、OpenVZ 等没有 systemd 的 Linux 环境。
  if [[ "$timezone_set" != "true" ]]; then
    [[ -e /usr/share/zoneinfo/Asia/Shanghai ]] || die "系统缺少 Asia/Shanghai 时区数据"
    "${run_as_root[@]}" ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime || die "无法设置系统时区"
    log "已设置北京时间；当前环境不支持 timedatectl，NTP 需由宿主机或系统服务维护" >&2
  else
    log "系统时区已设为北京时间，并已请求启用 NTP 自动校时"
  fi
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

CF_API_TOKEN=""
CF_DNS_RECORD=""
TELEGRAM_BOT_TOKEN=""
TELEGRAM_CHAT_ID=""

if [[ "$RUN_MODE" == "--daemon-child" ]]; then
  CF_API_TOKEN="${DDNS_CF_API_TOKEN:-}"
  CF_DNS_RECORD="${DDNS_CF_DNS_RECORD:-}"
  TELEGRAM_BOT_TOKEN="${DDNS_TELEGRAM_BOT_TOKEN:-}"
  TELEGRAM_CHAT_ID="${DDNS_TELEGRAM_CHAT_ID:-}"
  unset DDNS_CF_API_TOKEN DDNS_CF_DNS_RECORD DDNS_TELEGRAM_BOT_TOKEN DDNS_TELEGRAM_CHAT_ID
else
  configure_beijing_time
  install_dependencies
  read -r -s -p "请输入 Cloudflare API Token（输入内容不会显示）: " CF_API_TOKEN
  printf '\n'
  read -r -p "请输入需要更新的完整域名（例如 home.example.com）: " CF_DNS_RECORD
  read -r -s -p "请输入 Telegram Bot Token（留空则不发送提醒）: " TELEGRAM_BOT_TOKEN
  printf '\n'
  if [[ -n "$TELEGRAM_BOT_TOKEN" ]]; then
    read -r -p "请输入 Telegram Chat ID: " TELEGRAM_CHAT_ID
  fi
fi

CF_DNS_RECORD="${CF_DNS_RECORD%.}"
[[ -n "$CF_API_TOKEN" ]] || die "Token 不能为空"
[[ "$CF_DNS_RECORD" == *.* ]] || die "请输入完整域名，例如 home.example.com"
[[ -z "$TELEGRAM_BOT_TOKEN" || -n "$TELEGRAM_CHAT_ID" ]] || die "已填写 Telegram Bot Token 时必须填写 Chat ID"
[[ "$CHECK_INTERVAL" =~ ^[0-9]+$ ]] && (( CHECK_INTERVAL >= 10 )) || die "CHECK_INTERVAL 必须是不小于 10 的整数"
[[ "$HTTP_TIMEOUT" =~ ^[0-9]+$ ]] && (( HTTP_TIMEOUT >= 1 )) || die "HTTP_TIMEOUT 必须是正整数"
[[ "$CF_TTL" =~ ^[0-9]+$ ]] || die "CF_TTL 必须是整数"
(( CF_TTL == 1 || (CF_TTL >= 60 && CF_TTL <= 86400) )) || die "CF_TTL 必须为 1（自动）或 60 到 86400"
[[ "$CF_CREATE_RECORD" == "true" || "$CF_CREATE_RECORD" == "false" ]] || die "CF_CREATE_RECORD 必须是 true 或 false"
[[ "$CF_PROXIED" == "true" || "$CF_PROXIED" == "false" ]] || die "CF_PROXIED 必须是 true 或 false"

if [[ "$RUN_MODE" != "--daemon-child" ]]; then
  if pid="$(running_pid)"; then
    die "DDNS 已经在运行，PID：$pid"
  fi
  rm -f -- "$PID_FILE"
  umask 077
  : >>"$LOG_FILE" || die "无法写入日志文件：$LOG_FILE"

  DDNS_CF_API_TOKEN="$CF_API_TOKEN" \
  DDNS_CF_DNS_RECORD="$CF_DNS_RECORD" \
  DDNS_TELEGRAM_BOT_TOKEN="$TELEGRAM_BOT_TOKEN" \
  DDNS_TELEGRAM_CHAT_ID="$TELEGRAM_CHAT_ID" \
  DDNS_LOG_FILE="$LOG_FILE" \
  DDNS_PID_FILE="$PID_FILE" \
  DDNS_COUNT_STATE_FILE="$COUNT_STATE_FILE" \
    nohup "$SCRIPT_PATH" --daemon-child >>"$LOG_FILE" 2>&1 </dev/null &
  child_pid=$!
  printf '%s\n' "$child_pid" >"$PID_FILE" || die "无法写入 PID 文件：$PID_FILE"
  sleep 1
  if ! kill -0 "$child_pid" 2>/dev/null; then
    rm -f -- "$PID_FILE"
    die "后台启动失败，请查看日志：$LOG_FILE"
  fi
  log "DDNS 已转入后台运行，PID：$child_pid"
  log "日志文件：$LOG_FILE"
  log "查看状态：sudo $SCRIPT_PATH --status"
  log "停止服务：sudo $SCRIPT_PATH --stop"
  exit 0
fi

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

verify_a_record() {
  local zone_id="$1" record_id="$2" expected_ip="$3" response actual_ip
  if ! response="$(cf_curl -X GET "$API_BASE/zones/$zone_id/dns_records/$record_id")"; then
    log "无法核验 Cloudflare A 记录" >&2
    return 1
  fi
  check_cf_response "$response" || return 1
  actual_ip="$(jq -r '.result.content // empty' <<<"$response")"
  if [[ "$actual_ip" != "$expected_ip" ]]; then
    log "Cloudflare A 记录核验失败：期望 $expected_ip，实际 ${actual_ip:-空}" >&2
    return 1
  fi
  return 0
}

increment_daily_update_count() {
  local today saved_day="" saved_count=0 next_count state_dir temporary_file
  today="$(TZ=Asia/Shanghai date '+%Y-%m-%d')"

  if [[ -s "$COUNT_STATE_FILE" ]]; then
    IFS=$'\t' read -r saved_day saved_count <"$COUNT_STATE_FILE" || true
  fi
  if [[ "$saved_day" != "$today" ]] || [[ ! "$saved_count" =~ ^[0-9]+$ ]]; then
    saved_count=0
  fi
  next_count=$((saved_count + 1))

  state_dir="$(dirname -- "$COUNT_STATE_FILE")"
  mkdir -p "$state_dir" || { log "无法创建 Telegram 计数状态目录：$state_dir" >&2; return 1; }
  umask 077
  temporary_file="${COUNT_STATE_FILE}.$$"
  printf '%s\t%s\n' "$today" "$next_count" >"$temporary_file" || { log "无法保存 Telegram 每日计数" >&2; return 1; }
  mv -f -- "$temporary_file" "$COUNT_STATE_FILE" || { log "无法更新 Telegram 每日计数" >&2; return 1; }
  printf '%s' "$next_count"
}

send_telegram_notification() {
  local update_count="$1" message response error_message
  [[ -n "$TELEGRAM_BOT_TOKEN" ]] || return 0

  message="服务器：${TELEGRAM_SERVER_NAME}
更换了IP：${update_count}次"
  if ! response="$(curl -sS --max-time "$HTTP_TIMEOUT" -X POST \
    "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${message}")"; then
    log "Telegram 消息发送失败：网络请求异常" >&2
    return 1
  fi
  if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"$response"; then
    error_message="$(jq -r '.description // "未知错误"' <<<"$response" 2>/dev/null || true)"
    log "Telegram 消息发送失败：${error_message:-未知错误}" >&2
    return 1
  fi
  log "Telegram 提醒已发送：第 ${update_count} 次 IP 更换"
  return 0
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
    record_id="$(jq -r '.result.id // empty' <<<"$response")"
    [[ -n "$record_id" ]] || { log "新建 A 记录后未返回记录 ID" >&2; return 1; }
    verify_a_record "$zone_id" "$record_id" "$new_ip" || return 1
    log "已创建并核验 A 记录：$CF_DNS_RECORD -> $new_ip"
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
    verify_a_record "$zone_id" "$record_id" "$new_ip" || return 1
    log "已更新并核验 A 记录：$CF_DNS_RECORD，$old_ip -> $new_ip"
    changed=1
  done < <(jq -r '.result[] | [.id, .content] | @tsv' <<<"$response")

  if (( changed == 1 )); then
    if update_count="$(increment_daily_update_count)"; then
      send_telegram_notification "$update_count" || true
    else
      log "DNS 已更新，但无法记录 Telegram 每日更换次数，因此未发送提醒" >&2
    fi
  else
    log "DNS 已是最新：$CF_DNS_RECORD -> $new_ip"
  fi
}

stopped=false
trap 'stopped=true' INT TERM
last_synced_ip=""

prepare_daily_log
log "DDNS 已启动：域名 $CF_DNS_RECORD，检查间隔 ${CHECK_INTERVAL} 秒"
while [[ "$stopped" == "false" ]]; do
  clear_log_after_midnight
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
    log "本轮未能确认公网 IPv4，${CHECK_INTERVAL} 秒后重试" >&2
  fi

  sleep "$CHECK_INTERVAL" &
  wait $! || true
done

log "DDNS 已停止"
rm -f -- "$PID_FILE"
