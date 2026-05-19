#!/usr/bin/env bash
# ==============================================================================
# macbook-rocky-setup.sh  (v2 — corregido y desatendido)
# Setup automatizado para MacBook Pro 2020 (Intel + chip T2)
# Soporta Rocky Linux 9 / RHEL 9 / Fedora 42-44
# Módulos: System update · T2 · Oh-My-Bash · HP RGS Receiver · LucidLink Classic
# ==============================================================================
# USO:
#   sudo ./macbook-rocky-setup.sh \
#        --rgs-installer /ruta/install.sh \
#        --lucidlink-filespace miempresa.lucid \
#        --lucidlink-user me@empresa.com \
#        --lucidlink-password-b64 "$(echo -n 'MiPasswordSegura' | base64)"
#
#   sudo ./macbook-rocky-setup.sh --module t2
# ==============================================================================

set -Eeuo pipefail
trap 'fail "Error en línea $LINENO (comando: $BASH_COMMAND)"' ERR

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YEL='\033[1;33m'
BLU='\033[0;34m'; CYN='\033[0;36m'; BLD='\033[1m'; RST='\033[0m'

# ─── Códigos de salida ────────────────────────────────────────────────────────
readonly E_NOT_ROOT=1 E_NOT_SUPPORTED=2 E_UPDATE_FAIL=3 E_EPEL_FAIL=4
readonly E_T2_REPO_FAIL=10 E_T2_KERNEL_FAIL=11 E_T2_AUDIO_FAIL=12
readonly E_T2_WIFI_FAIL=13 E_T2_TOUCHBAR_FAIL=14 E_T2_GRUB_FAIL=15
readonly E_OMB_FAIL=20
readonly E_RGS_INSTALLER_MISSING=30 E_RGS_PATCHELF_FAIL=31 E_RGS_INSTALL_FAIL=32
readonly E_LL_DOWNLOAD_FAIL=40 E_LL_INSTALL_FAIL=41 E_LL_MOUNT_FAIL=42
readonly E_UNKNOWN=99

# ─── Estado global ────────────────────────────────────────────────────────────
LOG_FILE="/var/log/macbook-rocky-setup.log"
RGS_INSTALLER=""
LUCIDLINK_FILESPACE=""
LUCIDLINK_USER=""
LUCIDLINK_PASSWORD_B64=""
RUN_MODULE="all"
DISTRO_ID=""
DISTRO_VER=""

# ─── Logging ──────────────────────────────────────────────────────────────────
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
fail "FATAL (exit ${code}): ${msg}"
fail "Log: ${LOG_FILE}"
exit "$code"
}

# ─── Retry wrapper ────────────────────────────────────────────────────────────
retry() {
local attempts=$1 sleep_secs=$2 err_code=$3 desc=$4
shift 4
local i=0
until "$@"; do
  i=$((i + 1))
  if [[ $i -ge $attempts ]]; then
    die "$err_code" "${desc} falló tras ${attempts} intentos"
  fi
  warn "${desc} falló (intento ${i}/${attempts}). Reintentando en ${sleep_secs}s…"
  sleep "$sleep_secs"
done
ok "${desc} OK"
}

# ─── Argumentos ───────────────────────────────────────────────────────────────
parse_args() {
while [[ $# -gt 0 ]]; do
  case "$1" in
    --module)                    RUN_MODULE="$2";              shift 2 ;;
    --rgs-installer)             RGS_INSTALLER="$2";           shift 2 ;;
    --lucidlink-filespace)       LUCIDLINK_FILESPACE="$2";     shift 2 ;;
    --lucidlink-user)            LUCIDLINK_USER="$2";          shift 2 ;;
    --lucidlink-password-b64)    LUCIDLINK_PASSWORD_B64="$2";  shift 2 ;;
    --log)                       LOG_FILE="$2";                shift 2 ;;
    --help|-h)
      cat <<EOF
Uso: sudo $0 [OPCIONES]

--module <name>                 Sólo un módulo: system|t2|omb|hprgs|lucidlink|all
--rgs-installer <path>          Ruta al install.sh de HP RGS
--lucidlink-filespace <name>    Nombre del filespace (ej: empresa.lucid)
--lucidlink-user <email>        Email de la cuenta LucidLink
--lucidlink-password-b64 <b64>  Password en base64:
                                  --lucidlink-password-b64 \$(echo -n 'pwd' | base64)
--log <path>                    Archivo de log (def: ${LOG_FILE})
EOF
      exit 0 ;;
    *) warn "Argumento desconocido: $1 (ignorado)"; shift ;;
  esac
done
}

# ─── Checks previos ───────────────────────────────────────────────────────────
check_root() {
[[ $EUID -eq 0 ]] || die $E_NOT_ROOT "Debe ejecutarse como root (usa sudo)"
ok "Ejecutando como root"
}

detect_distro() {
[[ -f /etc/os-release ]] || die $E_NOT_SUPPORTED "/etc/os-release no encontrado"
# shellcheck source=/dev/null
source /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_VER="${VERSION_ID:-unknown}"
case "$DISTRO_ID" in
  rocky|rhel|almalinux)
    ok "Detectado ${PRETTY_NAME} (familia RHEL)" ;;
  fedora)
    ok "Detectado ${PRETTY_NAME}" ;;
  *)
    die $E_NOT_SUPPORTED "Distro no soportada: ${PRETTY_NAME:-$DISTRO_ID}" ;;
esac
}

check_internet() {
info "Probando conectividad…"
if ping -c 1 -W 3 8.8.8.8 &>/dev/null || curl -sf --max-time 5 https://example.com &>/dev/null; then
  ok "Internet OK"
else
  warn "Sin internet detectable. Continuando (puede ser red local)."
fi
}

check_hardware() {
step "Identificación de hardware"
lscpu | grep -E 'Model name|Architecture' | tee -a "$LOG_FILE" || true
free -h | tee -a "$LOG_FILE"
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | tee -a "$LOG_FILE"
lspci | grep -i apple | tee -a "$LOG_FILE" || \
  warn "No se detectan PCI Apple (normal antes del kernel T2)"
ok "Hardware identificado"
}

# ─── MODULE 1: Update sistema ────────────────────────────────────────────────
module_system_update() {
step "Actualización de sistema y repos base"

retry 3 10 $E_UPDATE_FAIL "dnf update" dnf update -y

info "Instalando utilidades base + plugin COPR…"
retry 3 10 $E_EPEL_FAIL "instalación base" \
  dnf install -y curl wget git tar xz patchelf \
                 dnf-plugins-core 'dnf-command(copr)' \
                 kernel-devel dkms make gcc

if [[ "$DISTRO_ID" != "fedora" ]]; then
  info "Instalando epel-release…"
  retry 3 10 $E_EPEL_FAIL "EPEL" dnf install -y epel-release || \
    warn "EPEL ya estaba instalado o no aplicable"
  info "Habilitando CRB…"
  dnf config-manager --set-enabled crb 2>/dev/null || \
  dnf config-manager --set-enabled powertools 2>/dev/null || \
    warn "CRB/PowerTools no disponible"
fi

ok "Sistema actualizado"
}

# ─── MODULE 2: Soporte T2 ─────────────────────────────────────────────────────
module_t2_kernel_params() {
# Aplica parámetros del kernel; común a Fedora y Rocky.
info "Aplicando parámetros de kernel para T2 vía grubby…"
local params="intel_iommu=on iommu=pt pcie_ports=compat pm_async=off"
if command -v grubby &>/dev/null; then
  # shellcheck disable=SC2086
  grubby --update-kernel=ALL --args="${params}" || \
    die $E_T2_GRUB_FAIL "grubby falló aplicando parámetros"
  ok "Parámetros aplicados con grubby: ${params}"
else
  warn "grubby no disponible; editando /etc/default/grub…"
  local gconf=/etc/default/grub
  if grep -q 'intel_iommu=on' "$gconf"; then
    ok "Parámetros ya presentes"
  else
    sed -i "s|^GRUB_CMDLINE_LINUX=\"\(.*\)\"|GRUB_CMDLINE_LINUX=\"\1 ${params}\"|" "$gconf"
    if [[ -d /sys/firmware/efi ]]; then
      grub2-mkconfig -o /boot/grub2/grub.cfg || \
        die $E_T2_GRUB_FAIL "grub2-mkconfig falló"
    else
      grub2-mkconfig -o /boot/grub2/grub.cfg || \
        die $E_T2_GRUB_FAIL "grub2-mkconfig falló"
    fi
  fi
fi
}

module_t2_fedora() {
info "Habilitando COPR sharpenedblade/t2linux…"
retry 2 5 $E_T2_REPO_FAIL "COPR T2" \
  dnf copr enable -y sharpenedblade/t2linux

info "Instalando metapaquete t2linux-release…"
retry 3 15 $E_T2_KERNEL_FAIL "t2linux-release" \
  dnf install -y t2linux-release

info "Forzando actualización del kernel desde el COPR…"
dnf update -y --refresh kernel kernel-core kernel-modules || \
  warn "No se pudo refrescar el kernel; revisa manualmente"

info "Instalando firmware Wi-Fi/BT (Broadcom)…"
if dnf list available apple-bcm-firmware &>/dev/null; then
  dnf install -y apple-bcm-firmware || warn "apple-bcm-firmware falló"
else
  warn "apple-bcm-firmware no disponible. Descargando script t2linux…"
  local fw_script=/tmp/t2-fw-install.sh
  if curl -fsSL "https://wiki.t2linux.org/tools/firmware.sh" -o "$fw_script" 2>/dev/null; then
    bash "$fw_script" || warn "Extracción de firmware requiere partición macOS montada"
  else
    warn "No se pudo descargar el script de firmware. Extracción manual:"
    warn "  https://wiki.t2linux.org/guides/wifi-bluetooth/"
  fi
fi

info "Instalando tiny-dfr (Touch Bar)…"
if dnf list available tiny-dfr &>/dev/null; then
  dnf install -y tiny-dfr
  systemctl enable --now tiny-dfr 2>/dev/null || true
  ok "tiny-dfr instalado"
else
  warn "tiny-dfr no en repos; Touch Bar quedará con defaults"
fi
}

module_t2_rhel_family() {
warn "═════════════════════════════════════════════════════════════"
warn "  Rocky/RHEL NO tiene un COPR T2 oficial."
warn "  Aplicaré los parámetros de kernel y dejaré PipeWire listo,"
warn "  pero el kernel T2 (audio, Wi-Fi, Touch Bar) requiere acción"
warn "  manual. Opciones:"
warn "    1) Migrar a Fedora 42/43 (recomendado)"
warn "    2) Compilar el kernel T2 desde t2linux/linux y empaquetar"
warn "       SRPM contra Rocky."
warn "  Ver: https://wiki.t2linux.org/distributions/"
warn "═════════════════════════════════════════════════════════════"
}

module_t2() {
step "Soporte T2 (kernel, audio, Wi-Fi, Touch Bar)"

module_t2_kernel_params

if [[ "$DISTRO_ID" == "fedora" ]]; then
  module_t2_fedora
else
  module_t2_rhel_family
fi

# PipeWire es estándar en ambos distros modernos
info "Configurando PipeWire…"
if rpm -q pulseaudio &>/dev/null; then
  dnf remove -y pulseaudio || warn "No se pudo eliminar PulseAudio"
fi
dnf install -y pipewire pipewire-pulseaudio wireplumber alsa-utils 2>/dev/null || \
  warn "PipeWire ya instalado o paquetes ausentes"
systemctl --global enable pipewire pipewire-pulse wireplumber 2>/dev/null || true
ok "PipeWire configurado"

warn "⚠  Reinicia para cargar los nuevos parámetros de kernel."
ok "Módulo T2 finalizado"
}

# ─── MODULE 3: Oh-My-Bash ────────────────────────────────────────────────────
module_omb() {
step "Oh-My-Bash"

local target_user="${SUDO_USER:-root}"
local target_home; target_home=$(getent passwd "$target_user" | cut -d: -f6)

info "Instalando Oh-My-Bash para ${target_user} (${target_home})"

local omb_installer; omb_installer=$(mktemp /tmp/omb-XXXXXX.sh)
retry 3 5 $E_OMB_FAIL "descarga OMB" \
  curl -fsSL "https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh" \
  -o "$omb_installer"
chmod +x "$omb_installer"

# Si .oh-my-bash ya existe, OMB sale con error → lo borramos antes para idempotencia
rm -rf "${target_home}/.oh-my-bash"

if [[ "$target_user" == "root" ]]; then
  bash "$omb_installer" --unattended || die $E_OMB_FAIL "OMB falló (root)"
else
  sudo -u "$target_user" env HOME="$target_home" \
    bash "$omb_installer" --unattended \
    || die $E_OMB_FAIL "OMB falló para ${target_user}"
fi
rm -f "$omb_installer"

local bashrc="${target_home}/.bashrc"
if [[ -f "$bashrc" ]] && grep -q '^OSH_THEME=' "$bashrc"; then
  sed -i 's/^OSH_THEME=.*/OSH_THEME="powerline-multiline"/' "$bashrc"
  chown "${target_user}:${target_user}" "$bashrc"
  ok "Tema OMB → powerline-multiline"
fi
ok "Oh-My-Bash instalado"
}

# ─── MODULE 4: HP RGS Receiver ───────────────────────────────────────────────
module_hprgs() {
step "HP RGS Receiver"

if [[ -z "$RGS_INSTALLER" ]]; then
  info "Buscando install.sh de RGS automáticamente…"
  local search_paths=("$HOME" "/tmp" "/opt" "/root")
  for p in "${search_paths[@]}"; do
    [[ -d "$p" ]] || continue
    local found
    found=$(find "$p" -maxdepth 3 -iname "install.sh" -path "*rgs*" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then RGS_INSTALLER="$found"; break; fi
  done
fi

if [[ -z "$RGS_INSTALLER" || ! -f "$RGS_INSTALLER" ]]; then
  die $E_RGS_INSTALLER_MISSING \
    "Instalador HP RGS no encontrado. Usa --rgs-installer /ruta/install.sh"
fi
info "Usando instalador: ${RGS_INSTALLER}"

command -v patchelf &>/dev/null || \
  retry 2 5 $E_RGS_PATCHELF_FAIL "patchelf" dnf install -y patchelf
ok "patchelf: $(patchelf --version)"

info "Ejecutando instalador HP RGS (con bypass de versión)…"
local installer_dir; installer_dir=$(dirname "$RGS_INSTALLER")
pushd "$installer_dir" >/dev/null
retry 2 15 $E_RGS_INSTALL_FAIL "HP RGS install" \
  env RGS_INSTALL_IGNORE_VERSION_CHECK=1 bash "$RGS_INSTALLER"
popd >/dev/null
ok "HP RGS instalado"

local lib_path="/opt/hpremote/rgreceiver/Extensions/libVideoExtension.so"
if [[ -f "$lib_path" ]]; then
  info "Parchando libVideoExtension.so…"
  cp -f "$lib_path" "${lib_path}.bak"
  patchelf --clear-execstack "$lib_path" || \
    die $E_RGS_PATCHELF_FAIL "patchelf --clear-execstack falló"
  ok "libVideoExtension.so parcheada"
else
  warn "${lib_path} ausente; salto patchelf"
fi

info "Creando launcher /usr/local/bin/rgreceiver-launch…"
cat >/usr/local/bin/rgreceiver-launch <<'EOF'
#!/usr/bin/env bash
# HP RGS Receiver launcher — fuerza X11, deshabilita MIT-SHM
export QT_QPA_PLATFORM=xcb
export QT_X11_NO_MITSHM=1
exec /opt/hpremote/rgreceiver/rgreceiver "$@"
EOF
chmod +x /usr/local/bin/rgreceiver-launch

cat >/usr/share/applications/hp-rgreceiver.desktop <<'EOF'
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
ok ".desktop creado"
info "Logs RGS: ~/.hp/remote/rgreceiver/rg.log"
ok "Módulo HP RGS finalizado"
}

# ─── MODULE 5: LucidLink Classic ─────────────────────────────────────────────
module_lucidlink() {
step "LucidLink Classic"

local target_user="${SUDO_USER:-root}"
local target_home; target_home=$(getent passwd "$target_user" | cut -d: -f6)
local mount_base="${target_home}/LucidLink"
local desktop_dir="${target_home}/Desktop"

# 5a — Descarga RPM
info "Descargando LucidLink RPM…"
local ll_tmp; ll_tmp=$(mktemp -d)
local ll_pkg="${ll_tmp}/lucidinstaller.rpm"
retry 3 10 $E_LL_DOWNLOAD_FAIL "descarga LucidLink" \
  curl -fL --retry 3 -o "$ll_pkg" \
    "https://www.lucidlink.com/download/latest/lin64-rpm/stable/"

# 5b — Instalar
info "Instalando RPM…"
retry 2 5 $E_LL_INSTALL_FAIL "instalación LucidLink" \
  dnf install -y "$ll_pkg"
rm -rf "$ll_tmp"
ok "LucidLink instalado"

# 5c — FUSE
info "Configurando FUSE…"
if [[ -f /etc/fuse.conf ]]; then
  grep -q '^user_allow_other' /etc/fuse.conf || echo 'user_allow_other' >> /etc/fuse.conf
else
  echo 'user_allow_other' > /etc/fuse.conf
fi
if getent group fuse &>/dev/null; then
  usermod -aG fuse "$target_user"
fi
ok "FUSE configurado"

# 5d — Mount point + symlink al escritorio
install -d -o "$target_user" -g "$target_user" "$mount_base"
install -d -o "$target_user" -g "$target_user" "$desktop_dir"
ln -sfn "$mount_base" "${desktop_dir}/LucidLink"
chown -h "${target_user}:${target_user}" "${desktop_dir}/LucidLink"
ok "Symlink desktop → ${mount_base}"

# 5e — Decisión: tenemos credenciales para mount desatendido?
if [[ -z "$LUCIDLINK_FILESPACE" || -z "$LUCIDLINK_USER" || -z "$LUCIDLINK_PASSWORD_B64" ]]; then
  warn "Sin --lucidlink-filespace/--lucidlink-user/--lucidlink-password-b64."
  warn "Salto creación del servicio. Instalación de LucidLink completada."
  return 0
fi

# 5f — Guardar password en archivo seguro (base64 → texto plano, root:root, 0600)
local pwd_file="/etc/lucidlink/${LUCIDLINK_FILESPACE}.pwd"
install -d -m 0700 -o root -g root /etc/lucidlink
echo -n "$LUCIDLINK_PASSWORD_B64" | base64 --decode > "$pwd_file"
chmod 0600 "$pwd_file"
chown root:root "$pwd_file"
ok "Password guardada en ${pwd_file} (root:root, 0600)"

# 5g — systemd unit (desatendida, ejecuta como el usuario destino)
local unit_path="/etc/systemd/system/lucidlink@${target_user}.service"
cat > "$unit_path" <<EOF
[Unit]
Description=LucidLink Filespace daemon (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=%i
Group=%i
ExecStart=/bin/bash -c 'cat ${pwd_file} | /usr/bin/lucid2 daemon \\
--fs ${LUCIDLINK_FILESPACE} \\
--user ${LUCIDLINK_USER} \\
--mount-point ${mount_base} \\
--fuse-allow-other'
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# El usuario tiene que poder leer el password file → grupo dedicado
if ! getent group lucidlink &>/dev/null; then
  groupadd -r lucidlink
fi
usermod -aG lucidlink "$target_user"
chown root:lucidlink "$pwd_file"
chmod 0640 "$pwd_file"

systemctl daemon-reload
systemctl enable --now "lucidlink@${target_user}.service" || \
  die $E_LL_MOUNT_FAIL "No se pudo habilitar lucidlink@${target_user}"

# Espera breve a que monte
info "Esperando montaje (hasta 30s)…"
for _ in {1..30}; do
  if mountpoint -q "$mount_base"; then
    ok "Filespace montado en ${mount_base}"
    break
  fi
  sleep 1
done

ok "LucidLink configurado y arrancado en boot"
}

# ─── Resumen ──────────────────────────────────────────────────────────────────
print_summary() {
echo ""
echo -e "${BLD}${GRN}╔══════════════════════════════════════════════════════╗${RST}"
echo -e "${BLD}${GRN}║             SETUP COMPLETO — RESUMEN                ║${RST}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
echo -e "  Log: ${LOG_FILE}"
echo -e "  Distro: ${DISTRO_ID} ${DISTRO_VER}"
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
echo -e "${GRN}  ✔  Sistema actualizado${RST}"
echo -e "${GRN}  ✔  Parámetros de kernel T2 aplicados (grubby)${RST}"
if [[ "$DISTRO_ID" == "fedora" ]]; then
  echo -e "${GRN}  ✔  Kernel T2 + audio + Touch Bar (COPR)${RST}"
else
  echo -e "${YEL}  ⚠  Kernel T2: requiere build manual en Rocky/RHEL${RST}"
fi
echo -e "${GRN}  ✔  PipeWire activo${RST}"
echo -e "${GRN}  ✔  Oh-My-Bash instalado${RST}"
[[ -n "$RGS_INSTALLER" ]] && echo -e "${GRN}  ✔  HP RGS instalado y parcheado${RST}"
if [[ -n "$LUCIDLINK_FILESPACE" ]]; then
  echo -e "${GRN}  ✔  LucidLink: servicio lucidlink@${SUDO_USER:-root} habilitado${RST}"
else
  echo -e "${YEL}  ⚠  LucidLink instalado, sin credenciales → sin auto-mount${RST}"
fi
echo -e "${BLD}${GRN}╠══════════════════════════════════════════════════════╣${RST}"
echo -e "${YEL}  ⚠  REINICIA para cargar parámetros de kernel${RST}"
echo -e "${BLD}${GRN}╚══════════════════════════════════════════════════════╝${RST}"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
main() {
mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

parse_args "$@"
log "══ macbook-rocky-setup.sh v2 inicio ══"
log "Módulo: ${RUN_MODULE} | RGS: ${RGS_INSTALLER:-—} | LL fs: ${LUCIDLINK_FILESPACE:-—}"

check_root
detect_distro
check_internet
check_hardware

case "$RUN_MODULE" in
  all)
    module_system_update
    module_t2
    module_omb
    if [[ -n "$RGS_INSTALLER" ]]; then
      module_hprgs
    else
      warn "Sin --rgs-installer → salto HP RGS"
    fi
    module_lucidlink
    print_summary
    ;;
  system)    module_system_update ;;
  t2)        module_t2 ;;
  omb)       module_omb ;;
  hprgs)     module_hprgs ;;
  lucidlink) module_lucidlink ;;
  *) die $E_UNKNOWN "Módulo inválido: ${RUN_MODULE}" ;;
esac

log "══ macbook-rocky-setup.sh v2 fin ══"
}

main "$@"
