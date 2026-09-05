#!/bin/sh
set -eu

# One-click EasyTier core installer.
# This script is POSIX sh compatible; bash is not required.
#
# Typical usage on a new macOS/Linux machine:
#   sh install-easytier-core.sh

REPO="${ET_REPO:-EasyTier/EasyTier}"
NETWORK_NAME="${ET_NETWORK_NAME:-}"
ROUTE_CIDR="${ET_ROUTE_CIDR:-}"
INSTALL_DIR="${ET_INSTALL_DIR:-/usr/local/bin}"
SERVICE_NAME="${ET_SERVICE_NAME:-easytier}"
CONFIG_BASENAME="${ET_CONFIG_BASENAME:-easytier-oneclick.toml}"
VERSION="${ET_VERSION:-v2.6.4}"
PEERS_RAW="${ET_PEERS:-}"
CUSTOM_PEERS=0
NO_SERVICE="${ET_NO_SERVICE:-0}"
AUTO_INSTALL_DEPS="${ET_AUTO_INSTALL_DEPS:-1}"
LOCAL_ZIP="${ET_LOCAL_ZIP:-}"
ASSET_URL="${ET_ASSET_URL:-}"
DOWNLOAD_BASE="${ET_DOWNLOAD_BASE:-}"
DRY_RUN=0
SERVICE_MODE=""

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*" >&2
}

usage() {
  cat <<'USAGE'
Usage:
  sh install-easytier-core.sh [options]

No bash is required. Run it with /bin/sh if the machine does not have bash.

Options:
  --ip IPV4             EasyTier virtual IP for this node.
  --hostname NAME       EasyTier node hostname
  --network-name NAME   EasyTier network name
  --peer URI            Add one peer URI, e.g. tcp://<peer-host>:<port>. Can be repeated.
  --peers LIST          Comma- or newline-separated peer URI list.
  --route-cidr CIDR     Route CIDR for this mesh. Default: derived from --ip.
  --version TAG         EasyTier release tag. Default: v2.6.4. Use "latest" to query GitHub API.
  --asset-url URL       Download a specific release zip URL directly.
  --download-base URL   Base URL containing the release zip, useful for mirrors.
  --local-zip PATH      Install from a local EasyTier release zip; no GitHub/download needed.
  --install-dir PATH    Binary install directory. Default: /usr/local/bin
  --config-dir PATH     Config directory. Default: /Library/Application Support/EasyTier on macOS, /etc/easytier on Linux.
  --service-name NAME   Service name. Default: easytier
  --no-service          Install binaries/config only; do not install a startup service.
  --no-install-deps     Do not try package-manager installation for missing curl/wget/unzip.
  --dry-run             Print detected OS/arch/asset/service plan and exit.
  -h, --help            Show this help.

Environment overrides:
  ET_NETWORK_SECRET     Provide the key non-interactively.
  ET_IPV4               Same as --ip.
  ET_HOSTNAME           Same as --hostname.
  ET_NETWORK_NAME       Same as --network-name.
  ET_ROUTE_CIDR         Same as --route-cidr.
  ET_VERSION            Same as --version.
  ET_PEERS              Comma- or newline-separated peer URI list.
  ET_ASSET_URL          Same as --asset-url.
  ET_DOWNLOAD_BASE      Same as --download-base.
  ET_LOCAL_ZIP          Same as --local-zip.
  ET_ARCH               Override detected asset architecture.
  ET_OS                 Override detected asset OS: macos, linux, freebsd.

Compatibility notes:
  - gh/GitHub CLI is not used.
  - Downloader fallback order: curl, wget, fetch, python3 urllib, busybox wget.
  - If no downloader exists, the script tries apt/dnf/yum/apk/pacman/zypper/opkg/pkg/brew.
  - If GitHub is blocked, use --local-zip, --asset-url, or --download-base pointing at a mirror.
  - Network name, peer IP/host, virtual IP, and key are not hardcoded; enter them at runtime or via env vars.
  - The key is never printed. It is written only to the EasyTier config file with 0600 permissions.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ip)
      [ "$#" -ge 2 ] || die '--ip requires a value'
      ET_IPV4="$2"
      shift 2
      ;;
    --hostname)
      [ "$#" -ge 2 ] || die '--hostname requires a value'
      ET_HOSTNAME="$2"
      shift 2
      ;;
    --network-name)
      [ "$#" -ge 2 ] || die '--network-name requires a value'
      NETWORK_NAME="$2"
      shift 2
      ;;
    --peer)
      [ "$#" -ge 2 ] || die '--peer requires a value'
      if [ "$CUSTOM_PEERS" -eq 0 ]; then
        PEERS_RAW="$2"
        CUSTOM_PEERS=1
      else
        PEERS_RAW="${PEERS_RAW}
$2"
      fi
      shift 2
      ;;
    --peers)
      [ "$#" -ge 2 ] || die '--peers requires a value'
      PEERS_RAW="$2"
      CUSTOM_PEERS=1
      shift 2
      ;;
    --route-cidr)
      [ "$#" -ge 2 ] || die '--route-cidr requires a value'
      ROUTE_CIDR="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || die '--version requires a value'
      VERSION="$2"
      shift 2
      ;;
    --asset-url)
      [ "$#" -ge 2 ] || die '--asset-url requires a value'
      ASSET_URL="$2"
      shift 2
      ;;
    --download-base)
      [ "$#" -ge 2 ] || die '--download-base requires a value'
      DOWNLOAD_BASE="$2"
      shift 2
      ;;
    --local-zip)
      [ "$#" -ge 2 ] || die '--local-zip requires a value'
      LOCAL_ZIP="$2"
      shift 2
      ;;
    --install-dir)
      [ "$#" -ge 2 ] || die '--install-dir requires a value'
      INSTALL_DIR="$2"
      shift 2
      ;;
    --config-dir)
      [ "$#" -ge 2 ] || die '--config-dir requires a value'
      ET_CONFIG_DIR="$2"
      shift 2
      ;;
    --service-name)
      [ "$#" -ge 2 ] || die '--service-name requires a value'
      SERVICE_NAME="$2"
      shift 2
      ;;
    --no-service)
      NO_SERVICE=1
      shift
      ;;
    --no-install-deps)
      AUTO_INSTALL_DEPS=0
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

has_cmd() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [ "$(id -u)" = "0" ]; then
    "$@"
  elif has_cmd sudo; then
    sudo "$@"
  elif has_cmd doas; then
    doas "$@"
  else
    die "root permission is required. Re-run as root, or install sudo/doas."
  fi
}

detect_os() {
  if [ -n "${ET_OS:-}" ]; then
    printf '%s' "$ET_OS"
    return
  fi

  case "$(uname -s 2>/dev/null || printf unknown)" in
    Darwin) printf 'macos' ;;
    Linux) printf 'linux' ;;
    FreeBSD) printf 'freebsd' ;;
    *) die "unsupported OS: $(uname -s 2>/dev/null || printf unknown)" ;;
  esac
}

detect_arch() {
  if [ -n "${ET_ARCH:-}" ]; then
    printf '%s' "$ET_ARCH"
    return
  fi

  case "$(uname -m 2>/dev/null || printf unknown)" in
    x86_64|amd64) printf 'x86_64' ;;
    arm64|aarch64) printf 'aarch64' ;;
    armv7l|armv7) printf 'armv7' ;;
    armv6l|armv6|arm) printf 'arm' ;;
    riscv64) printf 'riscv64' ;;
    loongarch64) printf 'loongarch64' ;;
    mips) printf 'mips' ;;
    mipsel) printf 'mipsel' ;;
    *) die "unsupported architecture: $(uname -m 2>/dev/null || printf unknown). Set ET_ARCH to override." ;;
  esac
}

normalize_version() {
  case "$1" in
    latest) printf 'latest' ;;
    v*) printf '%s' "$1" ;;
    *) printf 'v%s' "$1" ;;
  esac
}

asset_name_for() {
  os_name="$1"
  arch_name="$2"
  tag="$3"

  if [ -n "${ET_ASSET_NAME:-}" ]; then
    printf '%s' "$ET_ASSET_NAME"
    return
  fi

  case "${os_name}:${arch_name}" in
    macos:x86_64|macos:aarch64)
      printf 'easytier-%s-%s-%s.zip' "$os_name" "$arch_name" "$tag"
      ;;
    linux:x86_64|linux:aarch64|linux:arm|linux:armhf|linux:armv7|linux:armv7hf|linux:loongarch64|linux:mips|linux:mipsel|linux:riscv64)
      printf 'easytier-%s-%s-%s.zip' "$os_name" "$arch_name" "$tag"
      ;;
    freebsd:x86_64)
      printf 'easytier-freebsd-13.2-x86_64-%s.zip' "$tag"
      ;;
    *)
      die "unsupported EasyTier asset for ${os_name}/${arch_name}. Set ET_ASSET_NAME or --asset-url."
      ;;
  esac
}

toml_escape() {
  printf '%s' "$1" | tr -d '\r\n' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

xml_escape() {
  printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g; s/"/\&quot;/g'
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

normalize_peers() {
  printf '%s\n' "$1" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; /^[[:space:]]*$/d'
}

download_stdout() {
  url="$1"
  if has_cmd curl; then
    curl -fsSL --connect-timeout 20 "$url"
  elif has_cmd wget; then
    wget -qO- "$url"
  elif has_cmd fetch; then
    fetch -qo - "$url"
  elif has_cmd python3; then
    python3 - "$url" <<'PY'
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=30) as r:
    sys.stdout.buffer.write(r.read())
PY
  elif has_cmd busybox; then
    busybox wget -qO- "$url"
  else
    return 127
  fi
}

download_file() {
  url="$1"
  dest="$2"
  if has_cmd curl; then
    curl -fL --retry 3 --connect-timeout 20 -o "$dest" "$url"
  elif has_cmd wget; then
    wget -O "$dest" "$url"
  elif has_cmd fetch; then
    fetch -o "$dest" "$url"
  elif has_cmd python3; then
    python3 - "$url" "$dest" <<'PY'
import sys
from urllib.request import urlopen

with urlopen(sys.argv[1], timeout=30) as r:
    data = r.read()
with open(sys.argv[2], "wb") as f:
    f.write(data)
PY
  elif has_cmd busybox; then
    busybox wget -O "$dest" "$url"
  else
    return 127
  fi
}

install_packages() {
  [ "$AUTO_INSTALL_DEPS" = "1" ] || return 1

  if has_cmd apt-get; then
    as_root apt-get update
    as_root apt-get install -y curl wget unzip ca-certificates
  elif has_cmd dnf; then
    as_root dnf install -y curl wget unzip ca-certificates
  elif has_cmd yum; then
    as_root yum install -y curl wget unzip ca-certificates
  elif has_cmd apk; then
    as_root apk add --no-cache curl wget unzip ca-certificates
  elif has_cmd pacman; then
    as_root pacman -Sy --noconfirm curl wget unzip ca-certificates
  elif has_cmd zypper; then
    as_root zypper --non-interactive install curl wget unzip ca-certificates
  elif has_cmd opkg; then
    as_root opkg update
    as_root opkg install curl wget unzip ca-bundle ca-certificates || as_root opkg install wget unzip ca-bundle
  elif has_cmd pkg; then
    as_root pkg install -y curl wget unzip ca_root_nss
  elif [ "$OS_NAME" = "macos" ] && has_cmd brew; then
    brew install curl unzip
  else
    return 1
  fi
}

ensure_download_tool() {
  if has_cmd curl || has_cmd wget || has_cmd fetch || has_cmd python3 || has_cmd busybox; then
    return
  fi

  log 'No downloader found; trying to install curl/wget with the system package manager'
  install_packages || die 'missing curl/wget/fetch/python3/busybox, and automatic package installation failed'

  if has_cmd curl || has_cmd wget || has_cmd fetch || has_cmd python3 || has_cmd busybox; then
    return
  fi
  die 'could not install a downloader. Use --local-zip or install curl/wget manually.'
}

ensure_extract_tool() {
  if has_cmd unzip || has_cmd python3 || has_cmd busybox; then
    return
  fi

  log 'No unzip/python3 found; trying to install unzip'
  install_packages || die 'missing unzip/python3/busybox, and automatic package installation failed'

  if has_cmd unzip || has_cmd python3 || has_cmd busybox; then
    return
  fi
  die 'could not install an unzip tool'
}

extract_zip() {
  zip_file="$1"
  dest="$2"

  mkdir -p "$dest"
  if has_cmd unzip; then
    unzip -q "$zip_file" -d "$dest"
  elif has_cmd python3; then
    python3 -m zipfile -e "$zip_file" "$dest"
  elif has_cmd busybox; then
    busybox unzip "$zip_file" -d "$dest"
  else
    die 'missing unzip/python3/busybox; cannot extract EasyTier release zip'
  fi
}

latest_tag() {
  api_url="https://api.github.com/repos/${REPO}/releases/latest"
  json="$(download_stdout "$api_url")" || die 'could not query GitHub latest release. Use --version vX.Y.Z, --local-zip, or --asset-url.'
  tag="$(printf '%s\n' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)"
  [ -n "$tag" ] || die 'could not parse latest EasyTier release tag'
  printf '%s' "$tag"
}

choose_default_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || printf 'easytier-node'
}

prompt_required() {
  label="$1"
  current="$2"
  prompt="$3"

  if [ -n "$current" ]; then
    printf '%s' "$current"
    return
  fi

  if [ -t 0 ]; then
    printf '%s: ' "$prompt" >&2
    IFS= read -r value
    [ -n "$value" ] || die "${label} cannot be empty"
    printf '%s' "$value"
  else
    die "${label} is required in non-interactive mode"
  fi
}

derive_route_cidr() {
  printf '%s\n' "$1" | awk -F. '
    NF == 4 {
      printf "%s.%s.%s.0/24", $1, $2, $3
      exit 0
    }
    { exit 1 }
  '
}

is_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF == 4 {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      exit 0
    }
    { exit 1 }
  '
}

make_tmp_dir() {
  base="${TMPDIR:-/tmp}"
  if tmp="$(mktemp -d "${base%/}/easytier.XXXXXX" 2>/dev/null)"; then
    printf '%s' "$tmp"
  elif tmp="$(mktemp -d 2>/dev/null)"; then
    printf '%s' "$tmp"
  else
    tmp="${base%/}/easytier.$$"
    mkdir -p "$tmp"
    printf '%s' "$tmp"
  fi
}

install_file_root() {
  src="$1"
  dest="$2"
  mode="$3"
  dest_dir="$(dirname "$dest")"

  if mkdir -p "$dest_dir" 2>/dev/null && cp "$src" "$dest" 2>/dev/null && chmod "$mode" "$dest" 2>/dev/null; then
    return
  fi

  as_root mkdir -p "$dest_dir"
  as_root cp "$src" "$dest"
  as_root chmod "$mode" "$dest"
}

write_systemd_service() {
  unit_tmp="$TMP_DIR/${SERVICE_NAME}.service"
  unit_path="/etc/systemd/system/${SERVICE_NAME}.service"
  cat >"$unit_tmp" <<EOF
[Unit]
Description=EasyTier mesh node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${CONFIG_DIR}
ExecStart=${INSTALL_DIR}/easytier-core --config-file ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  install_file_root "$unit_tmp" "$unit_path" 0644
  as_root systemctl daemon-reload
  as_root systemctl enable "$SERVICE_NAME"
  as_root systemctl restart "$SERVICE_NAME"
  SERVICE_MODE="systemd"
}

write_openwrt_service() {
  init_tmp="$TMP_DIR/${SERVICE_NAME}.init"
  init_path="/etc/init.d/${SERVICE_NAME}"
  cat >"$init_tmp" <<EOF
#!/bin/sh /etc/rc.common
START=99
STOP=10
USE_PROCD=1

start_service() {
  procd_open_instance
  procd_set_param command "${INSTALL_DIR}/easytier-core" --config-file "${CONFIG_FILE}"
  procd_set_param respawn
  procd_close_instance
}
EOF
  install_file_root "$init_tmp" "$init_path" 0755
  as_root "$init_path" enable
  as_root "$init_path" restart
  SERVICE_MODE="openwrt"
}

write_launchd_service() {
  label="com.easytier.${SERVICE_NAME}"
  plist_tmp="$TMP_DIR/${label}.plist"
  plist_path="/Library/LaunchDaemons/${label}.plist"
  cat >"$plist_tmp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$(xml_escape "$label")</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml_escape "${INSTALL_DIR}/easytier-core")</string>
    <string>--config-file</string>
    <string>$(xml_escape "$CONFIG_FILE")</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$(xml_escape "$CONFIG_DIR")</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/${SERVICE_NAME}.out.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/${SERVICE_NAME}.err.log</string>
</dict>
</plist>
EOF
  install_file_root "$plist_tmp" "$plist_path" 0644
  as_root launchctl bootout system "$plist_path" >/dev/null 2>&1 || true
  as_root launchctl bootstrap system "$plist_path"
  as_root launchctl enable "system/${label}" >/dev/null 2>&1 || true
  as_root launchctl kickstart -k "system/${label}" >/dev/null 2>&1 || true
  SERVICE_MODE="launchd"
}

write_background_runner() {
  runner_path="${INSTALL_DIR}/${SERVICE_NAME}-run"
  runner_tmp="$TMP_DIR/${SERVICE_NAME}-run"
  pid_file="${CONFIG_DIR}/${SERVICE_NAME}.pid"
  log_file="${CONFIG_DIR}/${SERVICE_NAME}.log"
  start_tmp="$TMP_DIR/${SERVICE_NAME}-start-background"

  cat >"$runner_tmp" <<EOF
#!/bin/sh
exec $(shell_quote "${INSTALL_DIR}/easytier-core") --config-file $(shell_quote "$CONFIG_FILE")
EOF
  install_file_root "$runner_tmp" "$runner_path" 0755

  cat >"$start_tmp" <<EOF
#!/bin/sh
set -eu
runner=$(shell_quote "$runner_path")
pid_file=$(shell_quote "$pid_file")
log_file=$(shell_quote "$log_file")
log_dir=\$(dirname "\$log_file")
mkdir -p "\$log_dir"
if [ -f "\$pid_file" ]; then
  old_pid=\$(sed -n '1p' "\$pid_file" 2>/dev/null | tr -cd '0-9' || true)
  if [ -n "\$old_pid" ] && kill -0 "\$old_pid" 2>/dev/null; then
    kill "\$old_pid" 2>/dev/null || true
    sleep 1
  fi
fi
if command -v nohup >/dev/null 2>&1; then
  nohup "\$runner" >> "\$log_file" 2>&1 &
else
  "\$runner" >> "\$log_file" 2>&1 &
fi
printf '%s\n' "\$!" > "\$pid_file"
chmod 600 "\$pid_file" "\$log_file" 2>/dev/null || true
EOF
  as_root sh "$start_tmp"

  if has_cmd crontab; then
    cron_tmp="$TMP_DIR/${SERVICE_NAME}-install-cron"
    marker="# easytier-oneclick service: ${SERVICE_NAME}"
    cron_cmd="@reboot $(shell_quote "$runner_path") >> $(shell_quote "$log_file") 2>&1"
    cat >"$cron_tmp" <<EOF
#!/bin/sh
set -eu
tmp=\$(mktemp)
marker=$(shell_quote "$marker")
runner=$(shell_quote "$runner_path")
crontab -l 2>/dev/null | awk -v marker="\$marker" -v runner="\$runner" '\$0 != marker && index(\$0, runner) == 0 { print }' > "\$tmp" || true
printf '%s\n%s\n' "\$marker" $(shell_quote "$cron_cmd") >> "\$tmp"
crontab "\$tmp"
rm -f "\$tmp"
EOF
    if as_root sh "$cron_tmp"; then
      log "Installed crontab @reboot fallback for ${SERVICE_NAME}"
    else
      log "Could not install crontab @reboot fallback; EasyTier is running now but may need manual restart after reboot"
    fi
  else
    log "crontab not found; EasyTier is running now but may need manual restart after reboot"
  fi

  SERVICE_MODE="background"
}

manual_service_install() {
  log 'EasyTier service helper failed; trying OS-specific service fallback'
  if [ "$OS_NAME" = "linux" ] && has_cmd systemctl && [ -d /run/systemd/system ]; then
    write_systemd_service
  elif [ "$OS_NAME" = "linux" ] && [ -f /etc/rc.common ] && [ -d /etc/init.d ]; then
    write_openwrt_service
  elif [ "$OS_NAME" = "macos" ] && has_cmd launchctl; then
    write_launchd_service
  else
    log 'No supported service manager found; starting EasyTier with nohup background fallback'
    write_background_runner
  fi
}

install_service() {
  log "Installing ${SERVICE_NAME} service"
  as_root "${INSTALL_DIR}/easytier-cli" service --name "$SERVICE_NAME" stop >/dev/null 2>&1 || true
  as_root "${INSTALL_DIR}/easytier-cli" service --name "$SERVICE_NAME" uninstall >/dev/null 2>&1 || true

  if as_root "${INSTALL_DIR}/easytier-cli" service --name "$SERVICE_NAME" install \
    --core-path "${INSTALL_DIR}/easytier-core" \
    --service-work-dir "$CONFIG_DIR" \
    -- \
    --config-file "$CONFIG_FILE"; then
    if as_root "${INSTALL_DIR}/easytier-cli" service --name "$SERVICE_NAME" start; then
      SERVICE_MODE="easytier-service"
      return
    fi
  fi

  manual_service_install
}

OS_NAME="$(detect_os)"
ARCH_NAME="$(detect_arch)"
VERSION="$(normalize_version "$VERSION")"

case "$OS_NAME" in
  macos)
    CONFIG_DIR="${ET_CONFIG_DIR:-/Library/Application Support/EasyTier}"
    ;;
  linux|freebsd)
    CONFIG_DIR="${ET_CONFIG_DIR:-/etc/easytier}"
    ;;
  *)
    die "unsupported OS: $OS_NAME"
    ;;
esac

CONFIG_FILE="${CONFIG_DIR}/${CONFIG_BASENAME}"
HOSTNAME_VALUE="${ET_HOSTNAME:-$(choose_default_hostname)}"
if [ "$DRY_RUN" = "1" ]; then
  IPV4_VALUE="${ET_IPV4:-[interactive]}"
  PEERS="$(normalize_peers "$PEERS_RAW" 2>/dev/null || true)"
  [ -n "$PEERS" ] || PEERS='[interactive]'
  [ -n "$NETWORK_NAME" ] || NETWORK_NAME='[interactive]'
  if [ -z "$ROUTE_CIDR" ]; then
    if [ "${IPV4_VALUE}" != '[interactive]' ] && is_ipv4 "$IPV4_VALUE"; then
      ROUTE_CIDR="$(derive_route_cidr "$IPV4_VALUE")"
    else
      ROUTE_CIDR='[derived from --ip]'
    fi
  fi
else
  NETWORK_NAME="$(prompt_required 'ET_NETWORK_NAME/--network-name' "$NETWORK_NAME" 'Enter EasyTier network name')"
  PEERS_RAW="$(prompt_required 'ET_PEERS/--peer' "$PEERS_RAW" 'Enter EasyTier peer URI(s), comma-separated, e.g. tcp://<peer-host>:<port>')"
  IPV4_VALUE="$(prompt_required 'ET_IPV4/--ip' "${ET_IPV4:-}" 'Enter this node EasyTier virtual IPv4')"
  is_ipv4 "$IPV4_VALUE" || die "invalid IPv4: ${IPV4_VALUE}"
  PEERS="$(normalize_peers "$PEERS_RAW")"
  [ -n "$PEERS" ] || die 'at least one peer URI is required'
  if [ -z "$ROUTE_CIDR" ]; then
    ROUTE_CIDR="$(derive_route_cidr "$IPV4_VALUE")" || die "could not derive route CIDR from ${IPV4_VALUE}; pass --route-cidr explicitly"
  fi
fi

if [ "$VERSION" = "latest" ]; then
  ensure_download_tool
  log "Resolving latest EasyTier release from ${REPO}"
  VERSION="$(latest_tag)"
fi

ASSET_NAME="$(asset_name_for "$OS_NAME" "$ARCH_NAME" "$VERSION")"
if [ -z "$ASSET_URL" ] && [ -z "$LOCAL_ZIP" ]; then
  if [ -n "$DOWNLOAD_BASE" ]; then
    ASSET_URL="${DOWNLOAD_BASE%/}/${ASSET_NAME}"
  else
    ASSET_URL="https://github.com/${REPO}/releases/download/${VERSION}/${ASSET_NAME}"
  fi
fi

if [ "$DRY_RUN" = "1" ]; then
  printf 'OS: %s\n' "$OS_NAME"
  printf 'Arch: %s\n' "$ARCH_NAME"
  printf 'Version: %s\n' "$VERSION"
  printf 'Asset: %s\n' "$ASSET_NAME"
  if [ -n "$LOCAL_ZIP" ]; then
    printf 'Local zip: %s\n' "$LOCAL_ZIP"
  else
    printf 'Download URL: %s\n' "$ASSET_URL"
  fi
  printf 'Network: %s\n' "$NETWORK_NAME"
  printf 'Virtual IP: %s\n' "$IPV4_VALUE"
  printf 'Route CIDR: %s\n' "$ROUTE_CIDR"
  printf 'Config: %s\n' "$CONFIG_FILE"
  printf 'Install dir: %s\n' "$INSTALL_DIR"
  printf 'Service: %s\n' "$SERVICE_NAME"
  printf 'Peers:\n%s\n' "$PEERS"
  exit 0
fi

if [ -z "${ET_NETWORK_SECRET:-}" ]; then
  if [ -t 0 ]; then
    printf 'Enter EasyTier network_secret/key: ' >&2
    stty_state="$(stty -g 2>/dev/null || true)"
    stty -echo 2>/dev/null || true
    IFS= read -r ET_NETWORK_SECRET
    if [ -n "$stty_state" ]; then
      stty "$stty_state" 2>/dev/null || true
    else
      stty echo 2>/dev/null || true
    fi
    printf '\n' >&2
  else
    die 'ET_NETWORK_SECRET is required in non-interactive mode'
  fi
fi
[ -n "$ET_NETWORK_SECRET" ] || die 'network_secret/key cannot be empty'

TMP_DIR="$(make_tmp_dir)"
trap 'rm -rf "$TMP_DIR"' 0 1 2 3 15

if [ -n "$LOCAL_ZIP" ]; then
  [ -f "$LOCAL_ZIP" ] || die "local zip not found: $LOCAL_ZIP"
  ZIP_FILE="$LOCAL_ZIP"
else
  ensure_download_tool
  ZIP_FILE="${TMP_DIR}/${ASSET_NAME}"
  log "Downloading ${ASSET_NAME}"
  download_file "$ASSET_URL" "$ZIP_FILE" || die "download failed: $ASSET_URL. If GitHub is blocked, use --local-zip, --asset-url, or --download-base."
fi

ensure_extract_tool
log 'Extracting release'
extract_zip "$ZIP_FILE" "${TMP_DIR}/extract"
CORE_BIN="$(find "${TMP_DIR}/extract" -type f -name 'easytier-core' | head -n 1)"
CLI_BIN="$(find "${TMP_DIR}/extract" -type f -name 'easytier-cli' | head -n 1)"
[ -n "$CORE_BIN" ] || die 'easytier-core not found in release asset'
[ -n "$CLI_BIN" ] || die 'easytier-cli not found in release asset'
chmod +x "$CORE_BIN" "$CLI_BIN"

log "Installing binaries to ${INSTALL_DIR}"
install_file_root "$CORE_BIN" "${INSTALL_DIR}/easytier-core" 0755
install_file_root "$CLI_BIN" "${INSTALL_DIR}/easytier-cli" 0755

CONFIG_TMP="${TMP_DIR}/${CONFIG_BASENAME}"
{
  printf 'hostname = "%s"\n' "$(toml_escape "$HOSTNAME_VALUE")"
  printf 'ipv4 = "%s"\n' "$(toml_escape "$IPV4_VALUE")"
  printf 'listeners = []\n'
  printf 'routes = ["%s"]\n' "$(toml_escape "$ROUTE_CIDR")"
  printf 'tcp_whitelist = []\n'
  printf 'udp_whitelist = []\n\n'
  printf '[network_identity]\n'
  printf 'network_name = "%s"\n' "$(toml_escape "$NETWORK_NAME")"
  printf 'network_secret = "%s"\n\n' "$(toml_escape "$ET_NETWORK_SECRET")"
  printf '%s\n' "$PEERS" | while IFS= read -r peer; do
    [ -n "$peer" ] || continue
    printf '[[peer]]\n'
    printf 'uri = "%s"\n\n' "$(toml_escape "$peer")"
  done
  printf '[flags]\n'
  printf 'enable_ipv6 = false\n'
} >"$CONFIG_TMP"

log "Writing EasyTier config to ${CONFIG_FILE}"
install_file_root "$CONFIG_TMP" "$CONFIG_FILE" 0600

if [ "$NO_SERVICE" = "1" ]; then
  log 'Skipping service installation because --no-service was set'
  log 'Installed binary version'
  "${INSTALL_DIR}/easytier-core" --version || true
else
  install_service
  sleep 2

  if [ "$SERVICE_MODE" = "background" ]; then
    log 'Background runner status'
    pid_file="${CONFIG_DIR}/${SERVICE_NAME}.pid"
    if [ -f "$pid_file" ]; then
      pid="$(sed -n '1p' "$pid_file" 2>/dev/null | tr -cd '0-9' || true)"
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        printf 'EasyTier is running in background with PID %s\n' "$pid" >&2
      else
        printf 'EasyTier background PID file exists, but the process is not running\n' >&2
      fi
    else
      printf 'EasyTier background PID file was not found\n' >&2
    fi
  else
    log 'Service status'
    "${INSTALL_DIR}/easytier-cli" service --name "$SERVICE_NAME" status || true
  fi

  log 'Node info'
  "${INSTALL_DIR}/easytier-cli" node info || true

  log 'Peer list'
  "${INSTALL_DIR}/easytier-cli" peer list || true
fi

printf '\nDone.\n' >&2
printf 'Network: %s\n' "$NETWORK_NAME" >&2
printf 'Virtual IP: %s\n' "$IPV4_VALUE" >&2
printf 'Config: %s\n' "$CONFIG_FILE" >&2
printf 'Secret was hidden during input and is stored only in the EasyTier config file.\n' >&2
