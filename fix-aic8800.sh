#!/bin/bash
#
# fix-aic8800.sh — Instala driver WiFi + Bluetooth para adaptadores
# baseados no chip AIC8800D80 (ex.: dongles USB a69c:5721, a69c:8d81,
# "Pandora" 1111:1111) no CachyOS / Arch.
#
# Repositório: https://github.com/shenmintao/aic8800d80  (branch: bluetooth)
#   -> Essa branch fornece WiFi E Bluetooth (o aic_load_fw carrega o firmware BT
#      e o btusb nativo do kernel assume a interface Bluetooth).
#
# Por que um script próprio em vez do install.sh do repo?
#   * dkms não está instalado no CachyOS; instalamos direto com `make install`
#     (mais rápido e sem precisar instalar o pacote dkms).
#   * Compatível com o kernel 7.1.x do CachyOS (testado 7.1.3-2-cachyos-deckify).
#   * Faz o mode-switch (eject) inclusive no dispositivo já plugado como
#     Mass Storage (a69c:5721), carrega os módulos e verifica wlan/hci0.
#
# Uso:
#   sudo bash ~/fix-aic8800.sh            # instala/carrega
#   sudo bash ~/fix-aic8800.sh --uninstall
#   sudo bash ~/fix-aic8800.sh --rebuild <kver>   # usado pelo hook do pacman
#
set -euo pipefail

REPO_URL="https://github.com/shenmintao/aic8800d80.git"
REPO_BRANCH="bluetooth"
WORKDIR="/usr/src/aic8800d80-src"

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YLW=$'\033[1;33m'; CYN=$'\033[0;36m'; NC=$'\033[0m'
info()  { printf "${CYN}[INFO]${NC} %s\n"  "$*"; }
ok()    { printf "${GRN}[ OK ]${NC} %s\n"  "$*"; }
warn()  { printf "${YLW}[WARN]${NC} %s\n"  "$*"; }
die()   { printf "${RED}[ERR ]${NC} %s\n" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "Rode com sudo: sudo bash $0"

KVER="$(uname -r)"
# Permite que um hook do pacman chame "build/install para um kernel novo"
# que ainda não é o em execução. Se vazio, usa KVER (kernel corrente).
TARGET_KVER="${TARGET_KVER:-${KVER}}"
MODDIR="/lib/modules/${TARGET_KVER}/kernel/drivers/net/wireless/aic8800"
FW_DEST_BASE="/lib/firmware"
RULES_DIR="/usr/lib/udev/rules.d"
MODESWITCH_DIR="/etc/usb_modeswitch.d"
HOOK_DIR="/etc/pacman.d/hooks"
HOOK_FILE="${HOOK_DIR}/aic8800-rebuild.hook"

require() { command -v "$1" >/dev/null 2>&1 || die "Comando necessário não encontrado: $1"; }

install_deps() {
  info "Verificando dependências de build e runtime..."
  local missing=()
  pkg_installed() { pacman -Qs "^${1}\$" >/dev/null 2>&1; }
  for pkg in git usb_modeswitch bluez bluez-utils rfkill; do
    pkg_installed "$pkg" || missing+=("$pkg")
  done
  # rfkill às vezes vem do util-linux; a verificação é pela ferramenta.
  command -v rfkill >/dev/null 2>&1 || missing+=("rfkill")
  # linux-headers: no CachyOS os headers seguem o pacote do kernel (-headers)
  if [ ! -d "/lib/modules/${KVER}/build" ]; then
    missing+=("linux-cachyos-deckify-headers")
  fi
  if ! pkg_installed linux-cachyos-deckify-headers && ! pkg_installed linux-cachyos-headers && ! pkg_installed linux-headers; then
    missing+=("linux-cachyos-deckify-headers")
  fi
  if [ "${#missing[@]}" -gt 0 ]; then
    info "Instalando: ${missing[*]}"
    pacman -Sy --noconfirm "${missing[@]}" || die "Falha ao instalar dependências"
  else
    ok "Dependências já presentes."
  fi
  require gcc; require make; require git; require modprobe; require depmod
  [ -d "/lib/modules/${KVER}/build" ] || die "Headers do kernel ausentes para ${KVER}"
}

clone_or_update() {
  if [ -d "${WORKDIR}/.git" ]; then
    info "Atualizando repositório em ${WORKDIR}..."
    git -C "${WORKDIR}" fetch --quiet origin "${REPO_BRANCH}"
    git -C "${WORKDIR}" checkout "${REPO_BRANCH}"
    git -C "${WORKDIR}" reset --hard origin/"${REPO_BRANCH}"
  else
    info "Clonando branch '${REPO_BRANCH}' de ${REPO_URL}..."
    rm -rf "${WORKDIR}"
    git clone --depth 1 -b "${REPO_BRANCH}" "${REPO_URL}" "${WORKDIR}"
  fi
}

build_driver() {
  local kv="${TARGET_KVER}"
  info "Compilando driver para kernel ${kv} (pode levar alguns minutos)..."
  make -C "${WORKDIR}/drivers/aic8800" clean >/dev/null 2>&1 || true
  make -C "${WORKDIR}/drivers/aic8800" KVER="${kv}" -j"$(nproc)" 2>&1 | tail -20 || die "Compilação falhou (kernel ${kv})"
  [ -f "${WORKDIR}/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko" ] || die "aic8800_fdrv.ko não gerado"
  [ -f "${WORKDIR}/drivers/aic8800/aic_load_fw/aic_load_fw.ko"  ] || die "aic_load_fw.ko não gerado"
  ok "Módulos compilados para ${kv}."
}

install_driver() {
  local kv="${TARGET_KVER}"
  local moddir="/lib/modules/${kv}/kernel/drivers/net/wireless/aic8800"
  info "Instalando módulos em ${moddir}..."
  mkdir -p "${moddir}"
  install -p -m 644 "${WORKDIR}/drivers/aic8800/aic8800_fdrv/aic8800_fdrv.ko" "${moddir}/"
  install -p -m 644 "${WORKDIR}/drivers/aic8800/aic_load_fw/aic_load_fw.ko"   "${moddir}/"
  depmod -a "${kv}"
  ok "Módulos instalados e depmod atualizado para ${kv}."
}

install_firmware() {
  info "Instalando firmware AIC em ${FW_DEST_BASE}..."
  # Remove firmware antigo/conflictivo (recomendação do README do repo).
  rm -rf "${FW_DEST_BASE}"/aic8800*
  for fwdir in "${WORKDIR}/fw"/aic8800*; do
    [ -d "${fwdir}" ] || continue
    cp -r "${fwdir}" "${FW_DEST_BASE}/$(basename "${fwdir}")"
  done
  ok "Firmware copiado ($(ls -d "${FW_DEST_BASE}"/aic8800* 2>/dev/null | wc -l) variantes)."
}

install_rules_modeswitch() {
  info "Instalando regras udev e config do usb_modeswitch..."
  install -p -m 644 "${WORKDIR}/aic.rules" "${RULES_DIR}/aic.rules"
  mkdir -p "${MODESWITCH_DIR}"
  # No repo o arquivo chama-se 1111_1111 (sem dois-pontos, inválido no Windows).
  # Precisa ser 1111:1111 para o usb_modeswitch do Linux casar pelo VID:PID.
  install -p -m 644 "${WORKDIR}/usb_modeswitch/1111_1111" "${MODESWITCH_DIR}/1111:1111"
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  ok "udev + usb_modeswitch configurados."
}

# Hook do pacman: quando o pacote do kernel é atualizado (instala novo kernel),
# o hook chama este script com --rebuild <novo-kver> para recompilar o driver
# automaticamente. Isto substitui o DKMS sem precisar instalar o pacote dkms.
install_pacman_hook() {
  info "Instalando hook do pacman para auto-rebuild em atualizações de kernel..."
  mkdir -p "${HOOK_DIR}"
  cat > "${HOOK_FILE}" <<'EOF'
# Auto-rebuild AIC8800D80 WiFi+BT driver when kernel packages are updated.
# Gerado por fix-aic8800.sh — não editar manualmente.
[Trigger]
Operation = Install
Operation = Upgrade
Type = Package
Target = linux-cachyos-deckify
Target = linux-cachyos
Target = linux-cachyos-deckify-headers
Target = linux-cachyos-headers

[Action]
Description = Recompilando driver AIC8800D80 para o novo kernel...
When = PostTransaction
Exec = /usr/bin/bash /home/deck/fix-aic8800.sh --rebuild
EOF
  ok "Hook instalado: ${HOOK_FILE}"
}

remove_stale_configs() {
  # Issue #53 do repo: configs antigos apontavam para aic_btusb (módulo que
  # não existe nesta branch), causando HCI_Reset timeout (-110).
  if [ -f /etc/modprobe.d/aic8800-bt.conf ]; then
    warn "Removendo /etc/modprobe.d/aic8800-bt.conf (resquistro de versão antiga)..."
    rm -f /etc/modprobe.d/aic8800-bt.conf
  fi
  # blacklists comuns desses dongles podem bloquear o btusb nativo.
  for f in /etc/modprobe.d/*.conf; do
    [ -f "$f" ] || continue
    if grep -qiE "blacklist\s+(btusb|bluetooth)\b" "$f"; then
      warn "Encontrado blacklist de btusb em $f — recomendado remover manualmente."
    fi
  done
}

# Mode-switch do dispositivo que já está plugado como Mass Storage.
modeswitch_plugged() {
  # Procura dongles AIC em modo "Aic MSC" (a69c:5721/5722/5723/...) montados como disco.
  local switched=0
  if command -v eject >/dev/null 2>&1; then
    # Itera pelos block devices e sobe na árvore USB até achar idVendor=idProduct.
    for blk in /sys/block/* ; do
      [ -e "${blk}" ] || continue
      local name; name="$(basename "${blk}")"
      case "${name}" in sd*|sr*) ;; *) continue ;; esac
      local parent="${blk}"
      local vid="" pid=""
      while [ "${parent}" != "/" ]; do
        if [ -r "${parent}/idVendor" ]; then
          vid="$(cat "${parent}/idVendor" 2>/dev/null)"
          pid="$(cat "${parent}/idProduct" 2>/dev/null)"
          break
        fi
        parent="$(readlink -f "${parent}/..")"
      done
      if [ "${vid}" = "a69c" ]; then
        local devnode="/dev/${name}"
        info "Mode-switch: eject em ${devnode} (USB a69c:${pid})..."
        umount "${devnode}" 2>/dev/null || umount "${devnode}1" 2>/dev/null || true
        eject "${devnode}" 2>/dev/null || true
        switched=1
      fi
    done
  fi
  # Caso seja o clone "Pandora" (1111:1111):
  if lsusb 2>/dev/null | grep -qi "1111:1111"; then
    info "Mode-switch: usb_modeswitch para 1111:1111..."
    usb_modeswitch -c "${MODESWITCH_DIR}/1111:1111" 2>/dev/null || true
    switched=1
  fi
  if [ "${switched}" -eq 1 ]; then
    ok "Mode-switch disparado. Aguardando 4s o re-enumerar..."
    sleep 4
  else
    info "Nenhum dispositivo em modo Mass Storage para alternar agora."
  fi
}

load_modules() {
  info "Carregando módulos..."
  modprobe -r aic8800_fdrv 2>/dev/null || true
  modprobe -r aic_load_fw  2>/dev/null || true
  modprobe aic_load_fw    || warn "Falha carregando aic_load_fw"
  modprobe aic8800_fdrv   || warn "Falha carregando aic8800_fdrv"
  # btusb nativo assume a interface Bluetooth após o firmware ser carregado.
  modprobe btusb          || warn "Falha carregando btusb (Bluetooth nativo)"
  sleep 2
}

verify() {
  info "Verificando interfaces..."
  echo "  -- lsusb (AIC) --"; lsusb | grep -iE "a69c|368b|1111" || echo "  (nenhum AIC visível)"
  echo "  -- módulos --";     lsmod | grep -iE "aic8800_fdrv|aic_load_fw|btusb" || true
  echo "  -- WiFi --";        ip link show 2>/dev/null | grep -E "wlan|wlp" || iwconfig 2>/dev/null | grep -E "wlan|IEEE" || echo "  (sem interface wlan ainda)"
  echo "  -- Bluetooth --";   bluetoothctl list 2>/dev/null || true
  if lsusb | grep -qiE "a69c:(8d8[0-9a-f])"; then ok "Dongle em modo operacional."; else warn "Dongle ainda não trocou de modo — tente reconectar/remover e plugar."; fi
}

uninstall() {
  info "Removendo driver AIC8800..."
  modprobe -r aic8800_fdrv 2>/dev/null || true
  modprobe -r aic_load_fw  2>/dev/null || true
  rm -rf "${MODDIR}" "${WORKDIR}"
  rm -f  "${RULES_DIR}/aic.rules" "${MODESWITCH_DIR}/1111:1111" "${HOOK_FILE}"
  rm -rf "${FW_DEST_BASE}"/aic8800*
  depmod -a "${KVER}" 2>/dev/null || true
  ok "Driver removido (firmware, regras, hook e módulos)."
}

# Reconstrói o driver para TODOS os kernels instalados que têm build tree.
# Usado pelo hook do pacman após uma atualização de kernel: quando o pacman
# instalar um novo linux-cachyos-deckify, este função compila e instala os
# .ko para a versão nova, mesmo que ela ainda não seja o kernel em execução.
rebuild_for_all_kernels() {
  info "Recompilando driver para todos os kernels com headers disponíveis..."
  local any=0
  local built=0
  for kdir in /lib/modules/*/build; do
    [ -d "${kdir}" ] || continue
    local kv; kv="$(basename "$(dirname "${kdir}")")"
    [ "${kv}" = "$(uname -r)" ] && continue   # o corrente já foi feito no install normal
    any=1
    if ! [ -e "${kdir}/Makefile" ]; then
      warn "  -> kernel ${kv}: build tree incompleta, pulando (faltam headers?)"
      continue
    fi
    export TARGET_KVER="${kv}"
    info "  -> kernel ${kv}"
    if build_driver && install_driver; then
      built=$((built+1))
    else
      warn "  -> kernel ${kv}: falhou; verifique /usr/src/aic8800d80-src"
    fi
  done
  unset TARGET_KVER
  if [ "${any}" -eq 0 ]; then info "  (nenhum kernel adicional encontrado)"; fi
  ok "Rebuild: ${built} kernel(ns) compilado(s) com sucesso."
}

main() {
  echo "${CYN}════════════════════════════════════════════════════════════${NC}"
  echo "${CYN} AIC8800D80 WiFi+BT — instalador (CachyOS/Arch)   ${NC}"
  echo "${CYN} Kernel: ${KVER}   Repo: shenmintao/aic8800d80@bluetooth ${NC}"
  echo "${CYN}════════════════════════════════════════════════════════════${NC}"

  case "${1:-}" in
    --uninstall)
      uninstall
      exit 0
      ;;
    --rebuild)
      # Chamado pelo hook do pacman. Aguarda; o pacman passa os pacotes
      # atualizados na stdin (NeedsTargets), lemos apenas nada disto,
      # pois reconstruímos para todo kernel com /lib/modules/*/build.
      info "Modo --rebuild (hook do pacman)..."
      clone_or_update
      rebuild_for_all_kernels
      ok "Rebuild completo."
      exit 0
      ;;
  esac

  install_deps
  clone_or_update
  build_driver
  install_driver
  install_firmware
  install_rules_modeswitch
  install_pacman_hook
  remove_stale_configs
  modeswitch_plugged
  load_modules
  verify

  echo
  ok "Instalação concluída."
  echo "        Se wlan/hci0 não apareceu, DESCONECTE e RECONECTE o dongle USB"
  echo "        (o udev agora faz o mode-switch e vincula os drivers automaticamente)."
  echo "        O hook do pacman recompila o driver automaticamente após"
  echo "        atualizações de kernel (linux-cachyos-deckify)."
  echo "        Diagnóstico Bluetooth: sudo bash ${WORKDIR}/diagnose_bt.sh"
  echo "        WiFi:  nmcli device wifi list && nmcli device wifi connect \"SSID\" password \"SENHA\""
  echo "        BT:    bluetoothctl -> 'power on' -> 'scan on'"
  echo
}

main "$@"