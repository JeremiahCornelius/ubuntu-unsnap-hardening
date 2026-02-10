# MIT License
# 
# Copyright (c) 2026 Jeremiah Cornelius (jeremiah.e.cornelius@gmail.com)
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#!/usr/bin/env bash
set -u -o pipefail

# ubuntu-unsnap-hardening.sh (V2 CLEANED)
#
# Goals:
#  - Remove ALL snaps + snapd + residues
#  - Block snapd (and snap store / app center) from returning
#  - Replace Snap Store / Ubuntu App Center with APT/Flatpak-first workflow:
#       * remove snap store / app center artifacts
#       * install gnome-software + gnome-software-plugin-flatpak
#       * remove gnome-software-plugin-snap (if present)
#       * install flatpak + add Flathub remote
#  - Install Firefox as a real .deb from Mozilla official APT repo (packages.mozilla.org)
#  - Install Thunderbird as a real .deb from Mozilla Team PPA (ppa:mozillateam/ppa)
#  - Explicit APT pinning:
#       * firefox* MUST prefer packages.mozilla.org
#       * thunderbird* MUST prefer mozillateam PPA
#       * prevent mozillateam PPA from supplying firefox*
#  - Remove/disable Canonical & Ubuntu telemetry/reporting (best-effort)
#  - Purge ubuntu-advantage-tools (UA/Pro) and prevent re-installation via APT policy
#  - Post-upgrade reinforcement hooks:
#       * Always: DPkg::Post-Invoke (after installs/upgrades)
#       * Optional: APT::Update::Post-Invoke (after apt update) via --enable-post-update-hook
#
# Behavior:
#  - Continues on errors: failures are trapped, printed at runtime, and summarized at completion.
#  - Idempotent best-effort (safe to re-run).
#
# Usage:
#  sudo bash ubuntu-unsnap-hardening.sh
#  sudo bash ubuntu-unsnap-hardening.sh --enable-post-update-hook
#  sudo bash ubuntu-unsnap-hardening.sh --disable-post-update-hook
#
# Notes:
#  - This script writes pins/holds/masks in fixed file paths and is designed to be safely re-runnable.
#  - It includes explicit detection for the mozillateam PPA to avoid duplicate source entries.

LOG_FILE="/var/log/unsnap-hardening.log"
ERRORS=()

# Hook control (default: OFF for apt update post-invoke)
ENABLE_POST_UPDATE_HOOK=0

log()   { echo "[$(date -Is)] $*" | tee -a "$LOG_FILE" >&2; }
have()  { command -v "$1" >/dev/null 2>&1; }

record_error() {
  local msg="$1"
  ERRORS+=("$msg")
  log "ERROR (non-fatal): $msg"
}

run() {
  local desc="$1"; shift
  log "RUN: $desc"
  if "$@"; then
    return 0
  else
    local rc=$?
    record_error "$desc (exit=$rc): $*"
    return $rc
  fi
}

step() {
  local name="$1"; shift
  log "==== STEP: $name ===="
  if "$@"; then
    log "==== STEP OK: $name ===="
    return 0
  else
    local rc=$?
    record_error "Step failed: $name (exit=$rc)"
    log "==== STEP FAILED (continuing): $name ===="
    return $rc
  fi
}

die() { log "FATAL: $*"; exit 1; }

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}

source_os_release() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release
  : "${ID:?}" "${VERSION_ID:?}"
}

ver_ge() { dpkg --compare-versions "$1" ge "$2"; }

detect_release_tuning() {
  UB_VER="$VERSION_ID"
  UB_ID="$ID"
  UB_CODENAME="${VERSION_CODENAME:-unknown}"
  ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"

  USE_DEB822=0
  if ver_ge "$UB_VER" "24.04"; then
    USE_DEB822=1
  fi

  log "Detected OS: ID=$UB_ID VERSION_ID=$UB_VER CODENAME=$UB_CODENAME ARCH=$ARCH (deb822=$USE_DEB822)"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --enable-post-update-hook)
        ENABLE_POST_UPDATE_HOOK=1
        shift
        ;;
      --disable-post-update-hook)
        ENABLE_POST_UPDATE_HOOK=0
        shift
        ;;
      -h|--help)
        cat <<EOF
Usage:
  sudo bash $(basename "$0") [--enable-post-update-hook|--disable-post-update-hook]

Defaults:
  --disable-post-update-hook (only DPkg::Post-Invoke is enabled)

EOF
        exit 0
        ;;
      *)
        record_error "Unknown arg ignored: $1"
        shift
        ;;
    esac
  done
}

apt_update() { run "APT update" apt-get update -y; }

ensure_tools() {
  apt_update
  run "Install prerequisite tools" apt-get install -y --no-install-recommends \
    ca-certificates gnupg wget curl coreutils lsb-release software-properties-common
}

remove_all_snaps() {
  if ! have snap; then
    log "snap command not present; skipping snap removals."
    return 0
  fi

  run "snap list (pre-removal)" bash -c 'snap list | tee -a "'"$LOG_FILE"'"'

  for s in app-center snap-store snapd-desktop-integration gnome-3-38-2004 gnome-42-2204 gnome-46-2404 core core18 core20 core22; do
    run "Remove snap (best-effort): $s" snap remove --purge "$s"
  done

  local snaps
  snaps="$(snap list 2>/dev/null | awk 'NR>1 {print $1}' | grep -vE '^(snapd)$' || true)"
  [[ -z "${snaps// }" ]] && return 0

  for s in firefox thunderbird; do
    if echo "$snaps" | grep -qx "$s"; then
      run "Remove snap: $s" snap remove --purge "$s"
    fi
  done

  while read -r s; do
    [[ -z "$s" ]] && continue
    [[ "$s" == "firefox" || "$s" == "thunderbird" ]] && continue
    run "Remove snap: $s" snap remove --purge "$s"
  done <<<"$snaps"

  return 0
}

stop_and_disable_snapd() {
  if systemctl list-unit-files 2>/dev/null | grep -q '^snapd\.service'; then
    run "Stop snapd.service" systemctl stop snapd.service
    run "Stop snapd.socket"  systemctl stop snapd.socket
    run "Disable snapd.service" systemctl disable snapd.service
    run "Disable snapd.socket"  systemctl disable snapd.socket
    run "Mask snapd.service" systemctl mask snapd.service
    run "Mask snapd.socket"  systemctl mask snapd.socket
  else
    log "snapd systemd units not found (ok)."
  fi
}

purge_snapd_and_residue() {
  if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx snapd; then
    run "APT purge snapd" apt-get purge -y snapd
  else
    log "snapd package not installed (ok)."
  fi

  run "APT autoremove" apt-get autoremove -y

  run "Remove snap residue dirs" rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd
  for d in /home/*/snap; do
    [[ -d "$d" ]] && run "Remove user snap dir: $d" rm -rf "$d"
  done

  run "Remove snap-related apt conf (best-effort)" bash -c 'rm -f /etc/apt/apt.conf.d/*snap* 2>/dev/null || true'
}

prevent_snapd_reinstall() {
  run "Write APT pin: no-snapd" bash -c 'cat >/etc/apt/preferences.d/no-snapd <<EOF
Package: snapd
Pin: release *
Pin-Priority: -10
EOF'

  run "apt-mark hold snapd (best-effort)" apt-mark hold snapd
}

block_store_transition_packages() {
  local pkgs=(snap-store ubuntu-app-center app-center gnome-software-plugin-snap)

  for p in "${pkgs[@]}"; do
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx "$p"; then
      run "APT purge $p" apt-get purge -y "$p"
    fi
  done

  run "Write APT pin: no-ubuntu-snap-store" bash -c 'cat >/etc/apt/preferences.d/no-ubuntu-snap-store <<EOF
Package: snap-store ubuntu-app-center app-center gnome-software-plugin-snap
Pin: release *
Pin-Priority: -10
EOF'

  for p in "${pkgs[@]}"; do
    run "apt-mark hold $p (best-effort)" apt-mark hold "$p"
  done
}

remove_store_desktop_entries_leftovers() {
  run "Remove snap-store.desktop (best-effort)" rm -f /usr/share/applications/snap-store.desktop
  run "Remove ubuntu-app-center.desktop (best-effort)" rm -f /usr/share/applications/ubuntu-app-center.desktop
  run "Remove app-center.desktop (best-effort)" rm -f /usr/share/applications/app-center.desktop
  run "Remove snap desktop entry (best-effort)" rm -f /var/lib/snapd/desktop/applications/snap-store_snap-store.desktop
  run "Remove snap desktop entry (best-effort)" rm -f /var/lib/snapd/desktop/applications/app-center_app-center.desktop
}

install_apt_flatpak_gnome_software() {
  ensure_tools
  apt_update

  run "Install flatpak + gnome-software + gnome-software-plugin-flatpak" \
    apt-get install -y --no-install-recommends flatpak gnome-software gnome-software-plugin-flatpak

  if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx gnome-software-plugin-snap; then
    run "APT purge gnome-software-plugin-snap" apt-get purge -y gnome-software-plugin-snap
  fi

  if have flatpak; then
    run "Add Flathub remote" flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
  fi
}

# ---- Canonical/Ubuntu telemetry & reporting removal/disable ----
disable_ubuntu_telemetry_reporting() {
  ensure_tools

  if systemctl list-unit-files 2>/dev/null | grep -q '^whoopsie\.service'; then
    run "Stop whoopsie.service" systemctl stop whoopsie.service
    run "Disable whoopsie.service" systemctl disable whoopsie.service
    run "Mask whoopsie.service" systemctl mask whoopsie.service
  fi

  if [[ -f /etc/default/apport ]]; then
    run "Disable apport in /etc/default/apport" bash -c \
      "sed -ri 's/^enabled=.*/enabled=0/' /etc/default/apport || true; grep -q '^enabled=0' /etc/default/apport || echo 'enabled=0' >> /etc/default/apport"
  else
    run "Create /etc/default/apport with enabled=0" bash -c 'printf "enabled=0\n" >/etc/default/apport'
  fi

  if systemctl list-unit-files 2>/dev/null | grep -q '^apport\.service'; then
    run "Stop apport.service" systemctl stop apport.service
    run "Disable apport.service" systemctl disable apport.service
    run "Mask apport.service" systemctl mask apport.service
  fi

  if [[ -f /etc/default/motd-news ]]; then
    run "Disable motd-news in /etc/default/motd-news" bash -c \
      "sed -ri 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news || true; grep -q '^ENABLED=0' /etc/default/motd-news || echo 'ENABLED=0' >> /etc/default/motd-news"
  else
    # create file to avoid repeated “missing file” behavior
    run "Create /etc/default/motd-news (ENABLED=0)" bash -c 'printf "ENABLED=0\n" >/etc/default/motd-news'
  fi

  for f in /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-livepatch; do
    [[ -e "$f" ]] && run "Disable MOTD script (chmod -x): $f" chmod -x "$f"
  done

  local purge_pkgs=(
    ubuntu-report
    popularity-contest
    whoopsie
    apport
    apport-gtk
    apport-symptoms
  )

  local to_purge=()
  for p in "${purge_pkgs[@]}"; do
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx "$p"; then
      to_purge+=("$p")
    fi
  done

  if ((${#to_purge[@]} > 0)); then
    run "APT purge telemetry/reporting pkgs: ${to_purge[*]}" apt-get purge -y "${to_purge[@]}"
    run "APT autoremove (after telemetry purge)" apt-get autoremove -y
  fi

  for unit in ua-timer.timer ua-timer.service ubuntu-advantage.service ubuntu-advantage.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
      run "Stop $unit (best-effort)" systemctl stop "$unit"
      run "Disable $unit (best-effort)" systemctl disable "$unit"
      run "Mask $unit (best-effort)" systemctl mask "$unit"
    fi
  done
}

# ---- Purge & pin ubuntu-advantage-tools ----
purge_and_block_ubuntu_advantage_tools() {
  ensure_tools

  # Stop/mask timers/services if present
  for unit in ua-timer.timer ua-timer.service ubuntu-advantage.service ubuntu-advantage.timer; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
      run "Stop $unit (best-effort)" systemctl stop "$unit"
      run "Disable $unit (best-effort)" systemctl disable "$unit"
      run "Mask $unit (best-effort)" systemctl mask "$unit"
    fi
  done

  # Purge packages if installed
  local pkgs=(ubuntu-advantage-tools ubuntu-pro-client ubuntu-pro-client-l10n)
  local to_purge=()
  for p in "${pkgs[@]}"; do
    if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx "$p"; then
      to_purge+=("$p")
    fi
  done
  if ((${#to_purge[@]} > 0)); then
    run "APT purge UA tools: ${to_purge[*]}" apt-get purge -y "${to_purge[@]}"
    run "APT autoremove (after UA purge)" apt-get autoremove -y
  fi

  # Pin to prevent re-installation
  run "Write APT pin: no-ubuntu-advantage-tools" bash -c 'cat >/etc/apt/preferences.d/no-ubuntu-advantage-tools <<EOF
Package: ubuntu-advantage-tools ubuntu-pro-client ubuntu-pro-client-l10n
Pin: release *
Pin-Priority: -10
EOF'

  for p in "${pkgs[@]}"; do
    run "apt-mark hold $p (best-effort)" apt-mark hold "$p"
  done
}

# ---- Firefox: Mozilla official APT repo (packages.mozilla.org) ----
configure_mozilla_official_repo() {
  ensure_tools
  run "Create /etc/apt/keyrings" install -d -m 0755 /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/packages.mozilla.org.asc ]]; then
    run "Fetch Mozilla APT signing key" bash -c \
      'wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | tee /etc/apt/keyrings/packages.mozilla.org.asc >/dev/null'
  fi

  if (( USE_DEB822 )); then
    run "Write deb822 source: mozilla.sources" bash -c 'cat >/etc/apt/sources.list.d/mozilla.sources <<EOF
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF'
    run "Remove legacy mozilla.list (best-effort)" rm -f /etc/apt/sources.list.d/mozilla.list
  else
    run "Write list source: mozilla.list" bash -c \
      'echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" >/etc/apt/sources.list.d/mozilla.list'
    run "Remove deb822 mozilla.sources (best-effort)" rm -f /etc/apt/sources.list.d/mozilla.sources
  fi

  # Keep a global pin for packages.mozilla.org so it wins by default
  run "Write global pin: packages.mozilla.org" bash -c 'cat >/etc/apt/preferences.d/mozilla-global <<EOF
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000
EOF'
}

# ---- Explicit mozillateam PPA detection (no duplicates) ----
mozillateam_ppa_present() {
  # Returns 0 if present, 1 otherwise.
  # We look for either the Launchpad PPA URL or the typical LP-PPA origin string.
  grep -R --line-number -E 'mozillateam/ppa|LP-PPA-mozillateam-ppa' \
    /etc/apt/sources.list /etc/apt/sources.list.d/* 2>/dev/null >/dev/null
}

# ---- Thunderbird: Mozilla Team PPA (ppa:mozillateam/ppa) ----
configure_mozillateam_ppa() {
  ensure_tools
  if mozillateam_ppa_present; then
    log "mozillateam PPA appears to already be present; skipping add-apt-repository."
    return 0
  fi
  run "Add Mozilla Team PPA (ppa:mozillateam/ppa)" add-apt-repository -y ppa:mozillateam/ppa
}

# ---- APT pinning for Firefox vs Thunderbird ----
configure_apt_priorities_firefox_thunderbird() {
  run "Write APT pin: Firefox from packages.mozilla.org; Thunderbird from mozillateam PPA" bash -c 'cat >/etc/apt/preferences.d/99-firefox-thunderbird-sourcing <<EOF
# Prefer Mozilla official repo for Firefox
Package: firefox firefox-* xul-ext-*
Pin: origin packages.mozilla.org
Pin-Priority: 1001

# Strongly de-prioritize Firefox from Ubuntu archive to avoid snap-stub transitions
Package: firefox firefox-*
Pin: release o=Ubuntu
Pin-Priority: -1

# Prevent Firefox from being selected from mozillateam PPA (even if present there)
Package: firefox firefox-*
Pin: release o=LP-PPA-mozillateam-ppa
Pin-Priority: -1

# Prefer mozillateam PPA for Thunderbird (real deb)
Package: thunderbird thunderbird-*
Pin: release o=LP-PPA-mozillateam-ppa
Pin-Priority: 1001

# Strongly de-prioritize Ubuntu archive Thunderbird (often a snap transition stub)
Package: thunderbird thunderbird-*
Pin: release o=Ubuntu
Pin-Priority: -1
EOF'
}

install_firefox_mozilla_deb() {
  # Only purge if it's installed; avoids noisy apt errors on repeat runs
  if dpkg -l 2>/dev/null | awk "{print \$2}" | grep -qx firefox; then
    run "APT purge existing firefox (best-effort)" apt-get purge -y firefox
  fi
  apt_update
  run "Install Firefox (should come from packages.mozilla.org)" apt-get install -y firefox
}

install_thunderbird_from_ppa() {
  if dpkg -l 2>/dev/null | awk "{print \$2}" | grep -qx thunderbird; then
    run "APT purge existing thunderbird (best-effort)" apt-get purge -y thunderbird
  fi
  apt_update
  run "Install Thunderbird (should come from mozillateam PPA)" apt-get install -y thunderbird
}

# ---- Reinforcement hooks (post-upgrade/install; optionally post-update) ----
install_reinforcement_hooks() {
  ensure_tools

  # Reinforcement script: safe to re-run and safe to call repeatedly
  run "Install reinforcement script /usr/local/sbin/unsnap-hardening-reinforce" bash -c 'cat >/usr/local/sbin/unsnap-hardening-reinforce <<'"'"'EOF'"'"'
#!/usr/bin/env bash
set -u -o pipefail

LOG="/var/log/unsnap-hardening-reinforce.log"
log(){ echo "[$(date -Is)] $*" | tee -a "$LOG" >&2; }

have(){ command -v "$1" >/dev/null 2>&1; }

log "Reinforce start"

# Re-apply key pins/holds if present (no harm)
if [[ -f /etc/apt/preferences.d/no-snapd ]]; then log "Pin present: no-snapd"; fi
if [[ -f /etc/apt/preferences.d/no-ubuntu-snap-store ]]; then log "Pin present: no-ubuntu-snap-store"; fi
if [[ -f /etc/apt/preferences.d/no-ubuntu-advantage-tools ]]; then log "Pin present: no-ubuntu-advantage-tools"; fi
if [[ -f /etc/apt/preferences.d/99-firefox-thunderbird-sourcing ]]; then log "Pin present: firefox/thunderbird"; fi
if [[ -f /etc/apt/preferences.d/mozilla-global ]]; then log "Pin present: mozilla-global"; fi

# Re-hold (idempotent)
apt-mark hold snapd snap-store ubuntu-app-center app-center gnome-software-plugin-snap ubuntu-advantage-tools ubuntu-pro-client ubuntu-pro-client-l10n >/dev/null 2>&1 || true

# If snapd somehow came back, purge it again
if dpkg -l 2>/dev/null | awk "{print \$2}" | grep -qx snapd; then
  log "snapd detected; purging again"
  apt-get purge -y snapd || true
  apt-get autoremove -y || true
  rm -rf /snap /var/snap /var/lib/snapd /var/cache/snapd || true
fi

# If ubuntu-advantage-tools came back, purge it again
if dpkg -l 2>/dev/null | awk "{print \$2}" | grep -qx ubuntu-advantage-tools; then
  log "ubuntu-advantage-tools detected; purging again"
  apt-get purge -y ubuntu-advantage-tools ubuntu-pro-client ubuntu-pro-client-l10n || true
  apt-get autoremove -y || true
fi

# Re-disable telemetry bits (idempotent)
if [[ -f /etc/default/apport ]]; then
  sed -ri 's/^enabled=.*/enabled=0/' /etc/default/apport || true
  grep -q '^enabled=0' /etc/default/apport || echo 'enabled=0' >> /etc/default/apport
else
  echo 'enabled=0' >/etc/default/apport
fi

if [[ -f /etc/default/motd-news ]]; then
  sed -ri 's/^ENABLED=.*/ENABLED=0/' /etc/default/motd-news || true
  grep -q '^ENABLED=0' /etc/default/motd-news || echo 'ENABLED=0' >> /etc/default/motd-news
else
  echo 'ENABLED=0' >/etc/default/motd-news
fi

for f in /etc/update-motd.d/50-motd-news /etc/update-motd.d/80-livepatch; do
  [[ -e "$f" ]] && chmod -x "$f" || true
done

# Mask common services if they reappear
for unit in whoopsie.service apport.service ua-timer.timer ua-timer.service ubuntu-advantage.service ubuntu-advantage.timer; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^${unit}"; then
    systemctl stop "$unit" 2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
    systemctl mask "$unit" 2>/dev/null || true
  fi
done

log "Reinforce complete"
EOF'
  chmod 0755 /usr/local/sbin/unsnap-hardening-reinforce

  # APT hook file: always install DPkg::Post-Invoke hook; Update hook optional
  run "Install APT hook file /etc/apt/apt.conf.d/99unsnap-hardening-reinforce" bash -c "cat >/etc/apt/apt.conf.d/99unsnap-hardening-reinforce <<EOF
// Unsnap hardening reinforcement hooks
DPkg::Post-Invoke { \"/usr/local/sbin/unsnap-hardening-reinforce || true\"; };
EOF"

  if (( ENABLE_POST_UPDATE_HOOK == 1 )); then
    run "Enable APT::Update::Post-Invoke hook (/etc/apt/apt.conf.d/99unsnap-hardening-post-update)" bash -c "cat >/etc/apt/apt.conf.d/99unsnap-hardening-post-update <<EOF
// Optional: run reinforcement after apt update
APT::Update::Post-Invoke { \"/usr/local/sbin/unsnap-hardening-reinforce || true\"; };
EOF"
  else
    # Remove optional hook file if present (keeps behavior explicit and avoids duplicates)
    run "Ensure APT::Update::Post-Invoke hook is disabled (remove file if present)" rm -f /etc/apt/apt.conf.d/99unsnap-hardening-post-update
  fi
}

final_verification() {
  log "Final verification..."

  if have snap; then
    record_error "snap command still present at $(command -v snap)"
  else
    log "snap command not found (good)."
  fi

  if dpkg -l 2>/dev/null | awk '{print $2}' | grep -qx snapd; then
    record_error "snapd package still installed"
  else
    log "snapd not installed (good)."
  fi

  run "Firefox path/version" bash -c 'command -v firefox >/dev/null && firefox --version 2>/dev/null || true'
  run "Thunderbird path/version" bash -c 'command -v thunderbird >/dev/null && thunderbird --version 2>/dev/null || true'

  # Show apt policy for visibility (quietly appended to main log if user wants)
  run "APT policy (firefox, thunderbird)" bash -c 'apt-cache policy firefox thunderbird | tee -a "'"$LOG_FILE"'" || true'

  # Check UA tools absent (best-effort)
  run "Check UA tools installed? (best-effort)" bash -c 'dpkg -l ubuntu-advantage-tools ubuntu-pro-client 2>/dev/null || true'

  # Hook files presence
  run "Check installed hook files" bash -c '
    ls -l /etc/apt/apt.conf.d/99unsnap-hardening-reinforce 2>/dev/null || true
    ls -l /etc/apt/apt.conf.d/99unsnap-hardening-post-update 2>/dev/null || true
  '
}

print_error_summary() {
  log "==================== SUMMARY ===================="
  if ((${#ERRORS[@]} == 0)); then
    log "No errors recorded."
  else
    log "Errors recorded: ${#ERRORS[@]}"
    local i=1
    for e in "${ERRORS[@]}"; do
      log "  $i) $e"
      i=$((i+1))
    done
    log ""
    log "NOTE: If Thunderbird pins did not work, check:"
    log "  apt-cache policy firefox thunderbird"
    log "If the mozillateam PPA origin differs from LP-PPA-mozillateam-ppa, update pins accordingly."
  fi
  log "Log file: $LOG_FILE"
  log "================================================="
}

main() {
  require_root
  parse_args "$@"
  source_os_release
  detect_release_tuning

  if [[ "$UB_ID" != "ubuntu" ]]; then
    record_error "This script is tuned for Ubuntu; detected ID=$UB_ID (continuing best-effort)"
  fi

  step "Ensure tools" ensure_tools

  step "Remove snaps" remove_all_snaps
  step "Stop/disable snapd" stop_and_disable_snapd
  step "Purge snapd + residues" purge_snapd_and_residue
  step "Prevent snapd reinstall" prevent_snapd_reinstall

  step "Block store transition packages" block_store_transition_packages
  step "Remove store desktop leftovers" remove_store_desktop_entries_leftovers

  step "Install APT/Flatpak-first workflow" install_apt_flatpak_gnome_software

  step "Disable Canonical/Ubuntu telemetry & reporting" disable_ubuntu_telemetry_reporting
  step "Purge + block ubuntu-advantage-tools" purge_and_block_ubuntu_advantage_tools

  step "Configure Mozilla official repo (Firefox)" configure_mozilla_official_repo
  step "Configure Mozilla Team PPA (Thunderbird)" configure_mozillateam_ppa
  step "Configure APT priorities (Firefox vs Thunderbird)" configure_apt_priorities_firefox_thunderbird

  step "Install Firefox" install_firefox_mozilla_deb
  step "Install Thunderbird" install_thunderbird_from_ppa

  step "Install reinforcement hooks (post-upgrade; optional post-update)" install_reinforcement_hooks

  step "Final verification" final_verification

  print_error_summary
}

main "$@"
