#!/usr/bin/env bash
# ==============================================================================
# macbook-rocky-setup.sh
# Automated setup for Rocky Linux on MacBook Pro 2020 (Intel T2)
# Includes: System update, T2 support, HP RGS Receiver, Oh-My-Bash, LucidLink
# ==============================================================================
# Usage:
#   chmod +x macbook-rocky-setup.sh
#   sudo ./macbook-rocky-setup.sh
#   Or to run only a specific module:
#   sudo ./macbook-rocky-setup.sh --module t2
#   sudo ./macbook-rocky-setup.sh --module hprgs --rgs-installer /path/to/install.sh
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/hansnone/macbook-rocky-setup/refs/heads/main/macbook-rocky-setup.sh)"
# ==============================================================================

set -Eeuo pipefail

# ─── Color codes ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GRN='\033[0;32m'
YEL='\033[1;33m'
BLU='\033[0;34m'
CYN='\033[0;36m'
BLD='\033[1m'
RST='\033[0m'

# ─── Exit codes ───────────────────────────────────────────────────────────────
readonly E_NOT_ROOT=1
readonly E_NOT_ROCKY=2
readonly E_UPDATE_FAIL=3
readonly E_EPEL_FAIL=4
readonly E_T2_REPO_FAIL=10
readonly E_T2_KERNEL_FAIL=11
readonly E_T2_AUDIO_FAIL=12
readonly E_T2_WIFI_FAIL=13
readonly E_T2_TOUCHBAR_FAIL=14
readonly E_T2_GRUB_FAIL=15
readonly E_OMB_FAIL=20
readonly E_RGS_INSTALLER_MISSING=30
readonly E_RGS_PATCHELF_FAIL=31
readonly E_RGS_INSTALL_FAIL=32
readonly E_LUCIDLINK_DOWNLOAD_FAIL=40
readonly E_LUCIDLINK_INSTALL_FAIL=41
readonly E_LUCIDLINK_MOUNT_FAIL=42
readonly E_UNKNOWN=99

# ─── Global state ─────────────────────────────────────────────────────────────
LOG_FILE="/var/log/macbook-rocky-setup.log"
RGS_INSTALLER=""        # set via --rgs-installer flag
LUCIDLINK_FILESPACE=""  # set via --lucidlink-filespace flag
LUCIDLINK_USER=""       # set via --lucidlink-user flag
RUN_MODULE="all"        # set via --module flag

# ─── Logging helpers ──────────────────────────────────────────────────────────
log()  { local ts; ts=$(date '+%Y-%m-%d %H:%M:%S'); echo -e "${ts}  $*" | tee -a "$LOG_FILE"; }
info() { log "${BLU}[INFO ]${RST} $*"; }
ok()   { log "${GRN}[  OK ]${RST} $*"; }
warn() { log "${YEL}[ WARN]${RST} $*"; }
fail() { log "${RED}[FAIL ]${RST} $*"; }

step() {
  echo ""
  echo -e "${BLD}${CYN}══════════════════════════════════════════════════════${RST}"
  echo -e "${BLD}${CYN}  STEP: $*${RST}"
  echo -e "${BLD}${CYN}══════════════════════════════════════════════════════${RST}"
  log "STEP: $*"
}

die() {
  local code=${1:-$E_UNKNOWN}
  local msg="${2:-Unknown error}"
  fail "FATAL (exit code ${code}): ${msg}"
  fail "Check log: ${LOG_FILE}"
  exit "$code"
}

# ─── Auto-retry wrapper ───────────────────────────────────────────────────────
# retry <attempts> <sleep_secs> <exit_code_on_final_fail> <description> <cmd...>
retry() {
  local attempts=$1 sleep_secs=$2 err_code=$3 desc=$4
  shift 4
  local i=0
  until "$@"; do
    i=$((i + 1))
    if [[ $i -ge $attempts ]]; then
      die "$err_code" "${desc} failed after ${attempts} attempts"
    fi
    warn "${desc} failed (attempt ${i}/${attempts}). Retrying in ${sleep_secs}s…"
    sleep "$sleep_secs"
  done
  ok "${desc} succeeded"
}

# ─── Argument parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --module)          RUN_MODULE="$2";           shift 2 ;;
      --rgs-installer)   RGS_INSTALLER="$2";        shift 2 ;;
      --lucidlink-filespace) LUCIDLINK_FILESPACE="$2"; shift 2 ;;
      --lucidlink-user)  LUCIDLINK_USER="$2";       shift 2 ;;
      --log)             LOG_FILE="$2";             shift 2 ;;
      --help|-h)
        echo "Usage: sudo $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --module <name>              Run only one module: system|t2|omb|hprgs|lucidlink"
        echo "  --rgs-installer <path>       Path to HP RGS install.sh"
        echo "  --lucidlink-filespace <name> LucidLink filespace name"
        echo "  --lucidlink-user <email>     LucidLink account email"
        echo "  --log <path>                 Log file path (default: ${LOG_FILE})"
        exit 0
        ;;
      *)
        warn "Unknown argument: $1 (ignored)"
        shift
        ;;
    esac
  done
}

# ─── Prerequisite checks ──────────────────────────────────────────────────────
check_root() {
  [[ $EUID -eq 0 ]] || die $E_NOT_ROOT "This script must be run as root (use sudo)"
  ok "Running as root"
}

check_rocky() {
  if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "$ID" != "rocky" ]]; then
      die $E_NOT_ROCKY "This script is designed for Rocky Linux. Detected: ${PRETTY_NAME:-unknown}"
    fi
    ok "Detected Rocky Linux ${VERSION_ID:-?}"
  else
    die $E_NOT_ROCKY "/etc/os-release not found — cannot verify OS"
  fi
}

check_internet() {
  info "Checking internet connectivity…"
  if ! ping -c 1 -W 3 8.8.8.8 &>/dev/null && ! curl -sf --max-time 5 https://google.com &>/dev/null; then
    warn "No internet detected. Proceeding anyway (you may be on a local network)."
  else
    ok "Internet connectivity confirmed"
  fi
}

check_hardware() {
  step "Hardware identification"
  info "CPU info:"
  lscpu | grep -E 'Model name|Architecture|Socket' | tee -a "$LOG_FILE"
  info "Memory:"
  free -h | tee -a "$LOG_FILE"
  info "Storage:"
  lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | tee -a "$LOG_FILE"
  info "PCI devices (Apple T2 bridge expected):"
  lspci | grep -i apple || warn "No Apple PCI devices detected — T2 bridge may not yet be visible without T2 kernel"
  ok "Hardware identification complete"
}

# ─── MODULE 1: System update ──────────────────────────────────────────────────
module_system_update() {
  step "System update & EPEL"

  info "Updating all packages…"
  retry 3 10 $E_UPDATE_FAIL "dnf update" dnf update -y

  info "Installing EPEL and essential tools…"
  retry 3 10 $E_EPEL_FAIL "EPEL install" \
    dnf install -y epel-release dnf-plugins-core curl wget git patchelf \
                   kernel-devel dkms

  info "Enabling CRB (CodeReady Builder) repository…"
  dnf config-manager --set-enabled crb 2>/dev/null || \
  dnf config-manager --set-enabled powertools 2>/dev/null || \
    warn "CRB/PowerTools repo not found — continuing"

  ok "System update complete"
}

# ─── MODULE 2: T2 kernel & hardware support ───────────────────────────────────
module_t2() {
  step "T2 Mac hardware support (kernel, audio, Wi-Fi, Touch Bar)"

  # Rocky Linux uses RPM, not apt — we adapt the Ubuntu T2 guide to COPR/manual
  info "Adding T2 Linux COPR repository for Rocky/Fedora…"
  # The official t2linux community maintains a COPR
  retry 2 5 $E_T2_REPO_FAIL "T2 COPR repo" \
    dnf copr enable -y t2linux/t2linux

  info "Installing T2 kernel…"
  retry 3 15 $E_T2_KERNEL_FAIL "T2 kernel install" \
    dnf install -y kernel-t2

  info "Installing Apple T2 audio configuration…"
  if dnf list available apple-t2-audio-config &>/dev/null; then
    retry 2 5 $E_T2_AUDIO_FAIL "T2 audio config" \
      dnf install -y apple-t2-audio-config
  else
    warn "apple-t2-audio-config not in repo. Fetching config manually…"
    local audio_conf_url="https://github.com/t2linux/apple-t2-audio-config/releases/latest/download/apple-t2-audio-config.tar.gz"
    local tmp_audio; tmp_audio=$(mktemp -d)
    retry 2 5 $E_T2_AUDIO_FAIL "T2 audio config download" \
      curl -fsSL "$audio_conf_url" -o "${tmp_audio}/audio.tar.gz"
    tar -xzf "${tmp_audio}/audio.tar.gz" -C "${tmp_audio}"
    find "${tmp_audio}" -name "*.conf" -exec install -Dm644 {} /etc/alsa/conf.d/ \;
    ok "T2 audio config installed manually"
  fi

  info "Configuring PipeWire (replacing PulseAudio if present)…"
  if rpm -q pulseaudio &>/dev/null; then
    dnf remove -y pulseaudio || warn "Could not remove PulseAudio"
  fi
  dnf install -y pipewire pipewire-pulseaudio wireplumber || \
    warn "PipeWire install failed — audio may need manual configuration"
  systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
  ok "PipeWire configured"

  info "Installing Wi-Fi firmware for Apple T2…"
  # Requires firmware extraction from macOS or use of apple-firmware package
  if dnf list available apple-bcm-firmware &>/dev/null; then
    retry 2 5 $E_T2_WIFI_FAIL "T2 WiFi firmware" \
      dnf install -y apple-bcm-firmware
  else
    warn "apple-bcm-firmware not found in repos."
    warn "You need to manually extract Wi-Fi firmware from macOS."
    warn "See: https://wiki.t2linux.org/guides/wifi-bluetooth/"
    warn "After extracting, place *.blob files in /lib/firmware/brcm/"
  fi

  info "Installing tiny-dfr (Touch Bar daemon)…"
  if dnf list available tiny-dfr &>/dev/null; then
    retry 2 5 $E_T2_TOUCHBAR_FAIL "tiny-dfr install" \
      dnf install -y tiny-dfr
    info "Configuring tiny-dfr…"
    mkdir -p /etc/tiny-dfr
    if [[ -f /usr/share/tiny-dfr/config.toml ]]; then
      cp /usr/share/tiny-dfr/config.toml /etc/tiny-dfr/config.toml
      ok "tiny-dfr config copied to /etc/tiny-dfr/config.toml — edit as needed"
    fi
    systemctl enable --now tiny-dfr || warn "tiny-dfr service could not be enabled"
  else
    warn "tiny-dfr not available in current repos — Touch Bar will use defaults"
  fi

  info "Adding required kernel parameters to GRUB: intel_iommu=on iommu=pt pm_async=off"
  local grub_conf="/etc/default/grub"
  if grep -q "intel_iommu=on" "$grub_conf"; then
    ok "Kernel params already present in GRUB"
  else
    local params="intel_iommu=on iommu=pt pm_async=off"
    if grep -q '^GRUB_CMDLINE_LINUX=' "$grub_conf"; then
      sed -i "s/\(GRUB_CMDLINE_LINUX=\"[^\"]*\)\"/\1 ${params}\"/" "$grub_conf"
    else
      echo "GRUB_CMDLINE_LINUX=\"${params}\"" >> "$grub_conf"
    fi
    info "Regenerating GRUB config…"
    if [[ -d /sys/firmware/efi ]]; then
      grub2-mkconfig -o /boot/efi/EFI/rocky/grub.cfg 2>/dev/null || \
      grub2-mkconfig -o /boot/efi/EFI/BOOT/grub.cfg 2>/dev/null || \
        die $E_T2_GRUB_FAIL "grub2-mkconfig failed for UEFI"
    else
      grub2-mkconfig -o /boot/grub2/grub.cfg || \
        die $E_T2_GRUB_FAIL "grub2-mkconfig failed"
    fi
    ok "GRUB updated with T2 kernel parameters"
  fi

  warn "⚠  A REBOOT is required to load the T2 kernel and apply all changes."
  ok "T2 support module complete"
}

# ─── MODULE 3: Oh My Bash ─────────────────────────────────────────────────────
module_omb() {
  step "Oh My Bash installation"

  # OMB installer must run as the target (non-root) user
  local target_user="${SUDO_USER:-}"
  if [[ -z "$target_user" ]]; then
    warn "SUDO_USER not set. Attempting to install OMB for root (not recommended)."
    target_user="root"
  fi
  local target_home
  target_home=$(eval echo "~${target_user}")

  info "Installing Oh My Bash for user: ${target_user} (home: ${target_home})"

  # Download installer to a temp file so we can inspect/run it
  local omb_installer; omb_installer=$(mktemp /tmp/omb-install-XXXXXX.sh)
  retry 3 5 $E_OMB_FAIL "OMB installer download" \
    curl -fsSL "https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh" \
    -o "$omb_installer"
  chmod +x "$omb_installer"

  # Run as target user, unattended (--unattended skips interactive prompts)
  if [[ "$target_user" == "root" ]]; then
    bash "$omb_installer" --unattended || die $E_OMB_FAIL "OMB install failed"
  else
    sudo -u "$target_user" bash "$omb_installer" --unattended \
      HOME="$target_home" \
      || die $E_OMB_FAIL "OMB install failed for user ${target_user}"
  fi

  rm -f "$omb_installer"
  ok "Oh My Bash installed for ${target_user}"

  # Optionally set a theme
  local bashrc="${target_home}/.bashrc"
  if [[ -f "$bashrc" ]] && grep -q 'OSH_THEME=' "$bashrc"; then
    sed -i 's/^OSH_THEME=.*/OSH_THEME="powerline-multiline"/' "$bashrc"
    ok "OMB theme set to powerline-multiline"
  fi
}

# ─── MODULE 4: HP Remote Graphics Software (RGS) Receiver ────────────────────
module_hprgs() {
  step "HP RGS Receiver installation & configuration"

  # ── 4a. Locate installer ──
  if [[ -z "$RGS_INSTALLER" ]]; then
    # Try to find it in common locations
    local search_paths=("$HOME" "/tmp" "/opt" "/root")
    for p in "${search_paths[@]}"; do
      local found; found=$(find "$p" -maxdepth 3 -name "install.sh" -path "*/rgs*" 2>/dev/null | head -1 || true)
      if [[ -n "$found" ]]; then
        RGS_INSTALLER="$found"
        info "Auto-detected RGS installer: ${RGS_INSTALLER}"
        break
      fi
    done
  fi

  if [[ -z "$RGS_INSTALLER" ]] || [[ ! -f "$RGS_INSTALLER" ]]; then
    die $E_RGS_INSTALLER_MISSING \
      "HP RGS installer not found. Pass --rgs-installer /path/to/install.sh"
  fi
  info "Using RGS installer: ${RGS_INSTALLER}"

  # ── 4b. Install patchelf if not present ──
  if ! command -v patchelf &>/dev/null; then
    info "Installing patchelf…"
    retry 2 5 $E_RGS_PATCHELF_FAIL "patchelf install" \
      dnf install -y patchelf
  fi
  ok "patchelf available: $(patchelf --version 2>&1)"

  # ── 4c. Run installer bypassing version check ──
  info "Running HP RGS installer (version check bypassed)…"
  local installer_dir; installer_dir=$(dirname "$RGS_INSTALLER")
  pushd "$installer_dir" > /dev/null
  retry 2 15 $E_RGS_INSTALL_FAIL "HP RGS install" \
    env RGS_INSTALL_IGNORE_VERSION_CHECK=1 bash "$RGS_INSTALLER"
  popd > /dev/null
  ok "HP RGS installed"

  # ── 4d. Patch libVideoExtension.so ──
  local lib_path="/opt/hpremote/rgreceiver/Extensions/libVideoExtension.so"
  if [[ -f "$lib_path" ]]; then
    info "Patching libVideoExtension.so (clearing execstack)…"
    cp "${lib_path}" "${lib_path}.bak"
    retry 2 3 $E_RGS_PATCHELF_FAIL "patchelf clear-execstack" \
      patchelf --clear-execstack "$lib_path"
    ok "libVideoExtension.so patched"
  else
    warn "${lib_path} not found — skipping patchelf step"
  fi

  # ── 4e. Create launcher wrapper script ──
  info "Creating /usr/local/bin/rgreceiver-launch wrapper…"
  cat > /usr/local/bin/rgreceiver-launch << 'EOF'
#!/usr/bin/env bash
# HP RGS Receiver launcher — forces X11, disables MIT-SHM
export QT_QPA_PLATFORM=xcb
export QT_X11_NO_MITSHM=1
exec /opt/hpremote/rgreceiver/rgreceiver "$@"
EOF
  chmod +x /usr/local/bin/rgreceiver-launch
  ok "Launcher created: rgreceiver-launch"

  # ── 4f. Create .desktop entry ──
  local apps_dir="/usr/share/applications"
  mkdir -p "$apps_dir"
  cat > "${apps_dir}/hp-rgreceiver.desktop" << 'EOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=HP RGS Receiver
Comment=HP Remote Graphics Software Receiver
Exec=/usr/local/bin/rgreceiver-launch
Icon=/opt/hpremote/rgreceiver/rgreceiver.png
Terminal=false
Categories=Network;RemoteAccess;
EOF
  ok ".desktop entry created"

  # ── 4g. Log diagnostic hints ──
  info "Log file for RGS sessions: ~/.hp/remote/rgreceiver/rg.log"
  info "If remote desktop appears black: disable 'Enable monitor blanking on Sender' in HP RGS Sender settings."
  info "If still black: try windowed mode and avoid fullscreen."

  ok "HP RGS module complete. Run: rgreceiver-launch"
}

# ─── MODULE 5: LucidLink Classic ─────────────────────────────────────────────
module_lucidlink() {
  step "LucidLink Classic installation & desktop mount"

  local target_user="${SUDO_USER:-$(whoami)}"
  local target_home; target_home=$(eval echo "~${target_user}")
  local desktop_dir="${target_home}/Desktop"
  local mount_base="${target_home}/LucidLink"

  # ── 5a. Download LucidLink RPM ──
  info "Downloading LucidLink Classic for Linux…"
  local ll_tmp; ll_tmp=$(mktemp -d)
  local ll_url="https://www.lucidlink.com/download/latest/lnx/stable/"
  local ll_pkg="${ll_tmp}/lucidlink.rpm"

  # Try to find the direct RPM link (LucidLink serves it as a redirect)
  local actual_url
  actual_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$ll_url" 2>/dev/null || echo "$ll_url")

  retry 3 10 $E_LUCIDLINK_DOWNLOAD_FAIL "LucidLink download" \
    curl -fsSL -o "$ll_pkg" "$actual_url"

  # ── 5b. Install ──
  info "Installing LucidLink RPM…"
  retry 2 5 $E_LUCIDLINK_INSTALL_FAIL "LucidLink RPM install" \
    dnf install -y "$ll_pkg"
  rm -rf "$ll_tmp"
  ok "LucidLink installed"

  # ── 5c. Enable & start daemon ──
  info "Enabling lucidlink daemon…"
  systemctl enable --now lucid 2>/dev/null || \
  systemctl enable --now lucidlink 2>/dev/null || \
    warn "lucidlink systemd service not found — daemon may be user-managed"

  # ── 5d. Fix FUSE permissions ──
  info "Configuring FUSE permissions for non-root mount…"
  # Allow non-root users to mount FUSE filesystems
  if [[ -f /etc/fuse.conf ]]; then
    if ! grep -q '^user_allow_other' /etc/fuse.conf; then
      echo "user_allow_other" >> /etc/fuse.conf
      ok "user_allow_other added to /etc/fuse.conf"
    fi
  else
    echo "user_allow_other" > /etc/fuse.conf
    ok "/etc/fuse.conf created with user_allow_other"
  fi

  # Add user to fuse group if it exists
  if getent group fuse &>/dev/null; then
    usermod -aG fuse "$target_user"
    ok "${target_user} added to fuse group"
  fi

  # ── 5e. Create mount point ──
  mkdir -p "$mount_base"
  chown "${target_user}:${target_user}" "$mount_base"
  ok "Mount point created: ${mount_base}"

  # ── 5f. Create Desktop symlink / launcher ──
  mkdir -p "$desktop_dir"
  chown "${target_user}:${target_user}" "$desktop_dir"

  # Symlink so it appears on the desktop
  ln -sfn "$mount_base" "${desktop_dir}/LucidLink"
  chown -h "${target_user}:${target_user}" "${desktop_dir}/LucidLink"
  ok "Desktop symlink created: ${desktop_dir}/LucidLink → ${mount_base}"

  # ── 5g. Create autostart mount script ──
  local autostart_dir="${target_home}/.config/autostart"
  mkdir -p "$autostart_dir"

  # Build mount command; prompt for filespace if not provided
  local mount_cmd
  if [[ -n "$LUCIDLINK_FILESPACE" ]] && [[ -n "$LUCIDLINK_USER" ]]; then
    mount_cmd="lucid2 daemon start --fs ${LUCIDLINK_FILESPACE} --user ${LUCIDLINK_USER} --mount-point ${mount_base} --allow-other"
  else
    warn "No --lucidlink-filespace / --lucidlink-user provided."
    warn "Creating a generic mount script. Edit ${target_home}/.config/lucidlink-mount.sh manually."
    mount_cmd="# lucid2 daemon start --fs YOUR_FILESPACE --user YOUR_EMAIL --mount-point ${mount_base} --allow-other"
  fi

  cat > "${target_home}/.config/lucidlink-mount.sh" << EOF
#!/usr/bin/env bash
# LucidLink auto-mount script
# Edit the line below with your filespace and credentials, then re-run.
${mount_cmd}
EOF
  chmod +x "${target_home}/.config/lucidlink-mount.sh"
  chown "${target_user}:${target_user}" "${target_home}/.config/lucidlink-mount.sh"

  # .desktop autostart entry
  cat > "${autostart_dir}/lucidlink-mount.desktop" << EOF
[Desktop Entry]
Type=Application
Name=LucidLink Mount
Exec=${target_home}/.config/lucidlink-mount.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Comment=Auto-mount LucidLink filespace on login
EOF
  chown "${target_user}:${target_user}" "${autostart_dir}/lucidlink-mount.desktop"
  ok "Autostart entry created for LucidLink"

  info "To mount manually right now run:"
  info "  lucid2 daemon start --fs YOUR_FILESPACE --user YOUR_EMAIL --mount-point ${mount_base} --allow-other"
  ok "LucidLink module complete"
}

# ─── Summary ──────────────────────────────────────────────────────────────────
print_summary() {
  echo ""
  echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════╗${RST}"
  echo -e "${BLD}${GRN}║             SETUP COMPLETE — SUMMARY                ║${RST}"
  echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
  echo -e "${BLD}${GRN}║ Full log saved to: ${LOG_FILE}${RST}"
  echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
  echo -e "${GRN}  ✔  System updated & EPEL enabled${RST}"
  echo -e "${GRN}  ✔  T2 kernel & hardware support configured${RST}"
  echo -e "${GRN}  ✔  Oh My Bash installed${RST}"
  echo -e "${GRN}  ✔  HP RGS Receiver installed & patched${RST}"
  echo -e "${GRN}  ✔  LucidLink Classic installed, desktop mount ready${RST}"
  echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
  echo -e "${YEL}  ⚠  REBOOT REQUIRED to load T2 kernel${RST}"
  echo -e "${YEL}  ⚠  After reboot: verify T2 devices with 'lspci | grep Apple'${RST}"
  echo -e "${YEL}  ⚠  Wi-Fi firmware may need manual extraction from macOS${RST}"
  echo -e "${YEL}  ⚠  LucidLink mount: edit ~/.config/lucidlink-mount.sh${RST}"
  echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════╝${RST}"
  echo ""
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
  # Ensure log directory exists
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"

  parse_args "$@"

  log "══ macbook-rocky-setup.sh started ══"
  log "Module: ${RUN_MODULE} | RGS installer: ${RGS_INSTALLER:-not set}"

  check_root
  check_rocky
  check_internet
  check_hardware

  case "$RUN_MODULE" in
    all)
      module_system_update
      module_t2
      module_omb
      [[ -n "$RGS_INSTALLER" ]] && module_hprgs || \
        warn "Skipping HP RGS (no --rgs-installer provided)"
      module_lucidlink
      print_summary
      ;;
    system) module_system_update ;;
    t2)     module_t2 ;;
    omb)    module_omb ;;
    hprgs)  module_hprgs ;;
    lucidlink) module_lucidlink ;;
    *)
      die $E_UNKNOWN "Unknown module: ${RUN_MODULE}. Valid: all|system|t2|omb|hprgs|lucidlink"
      ;;
  esac

  log "══ macbook-rocky-setup.sh finished ══"
}

main "$@"
