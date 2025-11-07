#!/bin/bash
# =========================================================
# BBR + 网络优化自动配置脚本
# - v5.2: 模块化流程 + IPv6 自适应 + 更严格的错误清理
# - 修改目标：直接修改 /etc/sysctl.conf
# - 支持系统：Debian / Ubuntu / CentOS / AlmaLinux / RockyLinux
# =========================================================
set -euo pipefail
shopt -s extglob

readonly SCRIPT_VERSION="5.2"
readonly LOG_FILE="/var/log/bbr-optimize.log"
readonly SYSCTL_CONF="/etc/sysctl.conf"
readonly VALID_QDISC=("fq" "fq_codel")
QDISC=${1:-fq}

IPERF_SERVER_PID=""

handle_error() {
  local line=$1 cmd=$2
  echo "❌ 发生错误于第 ${line} 行: ${cmd}"
  exit 1
}

cleanup() {
  if [[ -n "${IPERF_SERVER_PID}" ]] && kill -0 "${IPERF_SERVER_PID}" 2>/dev/null; then
    kill "${IPERF_SERVER_PID}" >/dev/null 2>&1 || true
  fi
}

trap 'handle_error ${LINENO} "${BASH_COMMAND}"' ERR
trap cleanup EXIT

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

print_section() {
  printf '\n==== %s ====\n' "$1"
}

print_header() {
  echo "================ $(date) ================"
  echo "🗒️ 日志记录到 $LOG_FILE"
  echo "版本: v${SCRIPT_VERSION}"
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "❌ 请使用 root 权限运行"
    exit 1
  fi
}

ensure_commands() {
  local missing=()
  for cmd in "$@"; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if (( ${#missing[@]} )); then
    echo "❌ 缺少命令: ${missing[*]}"
    exit 1
  fi
}

validate_qdisc() {
  local candidate=$1
  for valid in "${VALID_QDISC[@]}"; do
    if [[ $candidate == "$valid" ]]; then
      return 0
    fi
  done
  echo "❌ 参数错误，请使用: $0 [fq|fq_codel]"
  exit 1
}

get_public_ip() {
  local ip url
  for url in \
    "https://ipinfo.io/ip" \
    "https://api64.ipify.org" \
    "https://ifconfig.me" \
    "https://icanhazip.com"; do
    ip=$(curl -fsSL --max-time 5 "$url" || true)
    if [[ -n "$ip" && ! "$ip" =~ error ]]; then
      echo "$ip"
      return 0
    fi
  done
  echo "获取失败"
}

check_kernel_version() {
  local kernel_major kernel_minor
  kernel_major=$(uname -r | cut -d. -f1)
  kernel_minor=$(uname -r | cut -d. -f2)
  if [[ $kernel_major -lt 4 ]] || ([[ $kernel_major -eq 4 ]] && [[ $kernel_minor -lt 9 ]]); then
    echo "❌ 当前内核版本过低（$(uname -r)），BBR 需要 ≥ 4.9"
    exit 1
  fi
}

backup_sysctl_conf() {
  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  BACKUP_FILE="${SYSCTL_CONF}.bak-${timestamp}"
  if [[ -f "$SYSCTL_CONF" ]]; then
    cp -a "$SYSCTL_CONF" "$BACKUP_FILE"
    echo "✅ 已备份原 sysctl.conf 到: $BACKUP_FILE"
  else
    BACKUP_FILE=""
    echo "ℹ️ 未检测到现有 sysctl.conf，跳过备份"
    touch "$SYSCTL_CONF"
  fi
}

update_sysctl_param() {
  local key=$1 value=$2 current
  if grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF"; then
    current=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_CONF" | tail -n1)
    current=${current#*=}
    current="${current##*([[:space:]])}"
    current="${current%%*([[:space:]])}"
    if [[ $current == "$value" ]]; then
      echo "保持: ${key} = ${value}"
      return
    fi
    sed -i "s|^[[:space:]]*${key}[[:space:]]*=.*|${key} = ${value}|" "$SYSCTL_CONF"
    echo "更新: ${key} = ${value}"
  else
    printf '%s = %s\n' "$key" "$value" >>"$SYSCTL_CONF"
    echo "添加: ${key} = ${value}"
  fi
}

apply_sysctl_params() {
  local entry key value
  for entry in "$@"; do
    key=${entry%%=*}
    value=${entry#*=}
    update_sysctl_param "$key" "$value"
  done
}

has_ipv6_support() {
  if [[ -f /proc/net/if_inet6 ]]; then
    return 0
  fi

  local disable_ipv6
  disable_ipv6=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)
  [[ "$disable_ipv6" == "0" ]]
}

apply_sysctl_configuration() {
  if ! sysctl -p "$SYSCTL_CONF"; then
    echo "⚠️ 加载 $SYSCTL_CONF 失败，请检查格式"
    exit 1
  fi
  if ! sysctl --system; then
    echo "⚠️ sysctl --system 执行失败，请检查其他配置文件"
    exit 1
  fi
  echo "✅ sysctl 参数应用成功"
}

verify_runtime_state() {
  print_section "验证结果"
  local cc qdisc iface
  cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "未知")
  qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo "未知")
  echo "拥塞控制算法: $cc"
  echo "队列调度算法: $qdisc"

  if [[ "$cc" != "bbr" ]]; then
    echo "⚠️ BBR 未立即生效，尝试加载模块..."
    if modprobe tcp_bbr 2>/dev/null; then
      echo "tcp_bbr" > /etc/modules-load.d/bbr.conf 2>/dev/null || true
      echo "✅ 模块已加载并设为开机自启"
    else
      echo "⚠️ BBR 模块可能已内置或不被支持"
    fi
  fi

  if lsmod | grep -q tcp_bbr; then
    echo "✅ BBR 模块已加载"
  else
    echo "⚠️ 未检测到 tcp_bbr 模块，可能已内置或需重启"
  fi

  iface=$(ip route show default | awk '{print $5}' | head -n1)
  if [[ -n "$iface" ]]; then
    echo "默认网卡: $iface"
    if command -v tc >/dev/null 2>&1 && tc qdisc show dev "$iface" | grep -qE "$QDISC"; then
      echo "✅ $QDISC 已应用"
    else
      echo "⚠️ $QDISC 未检测到，请检查配置"
    fi
  else
    echo "⚠️ 无法识别默认网卡，跳过验证"
  fi
}

install_iperf3() {
  if command -v iperf3 >/dev/null 2>&1; then
    return 0
  fi

  echo "⚠️ iperf3 未安装，尝试安装..."
  if command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get update -y -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q iperf3
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q iperf3
  else
    echo "❌ 无可用包管理器，请手动安装 iperf3"
    return 1
  fi
}

run_bandwidth_test() {
  print_section "可选测速环节"
  if ! install_iperf3; then
    echo "⚠️ 跳过测速（iperf3 不可用）"
    return
  fi

  echo "👉 正在执行本地带宽测试 (3 秒)..."
  iperf3 -s -1 >/dev/null 2>&1 &
  IPERF_SERVER_PID=$!
  sleep 1
  if ! iperf3 -c 127.0.0.1 -t 3; then
    echo "⚠️ 测速失败（可能防火墙阻止 5201 端口）"
  else
    echo "✅ 测速完成"
  fi
}

main() {
  print_header
  ensure_root
  ensure_commands curl ip lscpu sysctl awk sed grep tee uname
  validate_qdisc "$QDISC"

  source /etc/os-release 2>/dev/null || true
  print_section "系统信息"
  echo "系统: ${PRETTY_NAME:-未知}"
  echo "内核: $(uname -r)"
  echo "CPU : $(lscpu | grep 'Model name' | awk -F ':' '{print $2}' | xargs)"
  echo "公网 IP: $(get_public_ip)"
  echo "默认路由:"
  ip route show default || echo "无法获取路由信息"
  echo "---------------------------------------"

  check_kernel_version
  backup_sysctl_conf

  print_section "写入 BBR 及网络优化参数"
  local params=(
    "fs.file-max=6815744"
    "net.ipv4.tcp_no_metrics_save=1"
    "net.ipv4.tcp_ecn=0"
    "net.ipv4.tcp_frto=0"
    "net.ipv4.tcp_mtu_probing=0"
    "net.ipv4.tcp_rfc1337=0"
    "net.ipv4.tcp_sack=1"
    "net.ipv4.tcp_fack=1"
    "net.ipv4.tcp_window_scaling=1"
    "net.ipv4.tcp_adv_win_scale=1"
    "net.ipv4.tcp_moderate_rcvbuf=1"
    "net.core.rmem_max=33554432"
    "net.core.wmem_max=33554432"
    "net.ipv4.tcp_rmem=4096 87380 33554432"
    "net.ipv4.tcp_wmem=4096 65536 33554432"
    "net.ipv4.udp_rmem_min=8192"
    "net.ipv4.udp_wmem_min=8192"
    "net.ipv4.ip_forward=1"
    "net.ipv4.conf.all.route_localnet=1"
    "net.ipv4.conf.all.forwarding=1"
    "net.ipv4.conf.default.forwarding=1"
    "net.core.default_qdisc=${QDISC}"
    "net.ipv4.tcp_congestion_control=bbr"
    "net.ipv4.tcp_fin_timeout=10"
    "net.ipv4.tcp_tw_reuse=1"
    "net.ipv4.tcp_max_syn_backlog=8192"
    "net.ipv4.tcp_synack_retries=2"
    "net.ipv4.tcp_syncookies=1"
    "net.ipv4.tcp_fastopen=3"
  )

  if has_ipv6_support; then
    echo "✅ 检测到 IPv6 支持，将应用相关参数"
    params+=(
      "net.ipv6.conf.all.forwarding=1"
      "net.ipv6.conf.default.forwarding=1"
    )
  else
    echo "⚠️ 未检测到 IPv6 支持，跳过相关参数"
  fi

  apply_sysctl_params "${params[@]}"

  print_section "应用配置"
  apply_sysctl_configuration

  verify_runtime_state
  run_bandwidth_test

  echo
  echo "🎉 BBR 网络优化完成！建议重启系统确保配置完全生效。"
  echo "配置文件: ${SYSCTL_CONF}"
  [[ -n "${BACKUP_FILE:-}" ]] && echo "备份文件: ${BACKUP_FILE}"
  echo "日志: ${LOG_FILE}"
}

main "$@"
