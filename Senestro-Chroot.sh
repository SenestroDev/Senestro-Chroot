#!/data/data/com.termux/files/usr/bin/bash
#######################################################
#  🐧 SENESTRO CHROOT — Real Linux Installer v1.1
#
#  Sets up a true chroot Ubuntu environment on a
#  rooted Android device (Magisk/su required).
#  No proot overhead — real kernel-level chroot.
#
#  ─────────────────────────────────────────────────
#  WHAT GETS INSTALLED
#  ─────────────────────────────────────────────────
#  Termux side:
#    wget, tar, bzip2, xz-utils (rootfs download tools)
#
#  Ubuntu chroot side (per step selection):
#    Step 1 — Download & extract Ubuntu 22.04 ARM64 rootfs
#    Step 2 — Mount /proc /dev /sys /dev/pts /tmp
#    Step 3 — Fix DNS (resolv.conf)
#    Step 4 — Fix PATH + TERM inside chroot
#    Step 5 — Run apt update && apt upgrade
#    Step 6 — Install essentials (vim, nano, curl, wget, git, sudo)
#    Step 7 — Set locale & timezone
#    Step 8 — Create optional non-root user with passwordless sudo
#
#  ─────────────────────────────────────────────────
#  LAUNCHER SCRIPTS (generated in BASE_DIR)
#  ─────────────────────────────────────────────────
#    start-chroot.sh  — mount filesystems and enter chroot
#    stop-chroot.sh   — unmount all filesystems cleanly
#
#  ─────────────────────────────────────────────────
#  VERSION HISTORY  [CHANGELOG_START]
#  ─────────────────────────────────────────────────
#  v1.0 — Initial release: 8 optional steps, banner,
#          progress bar, spinner, logging, pre-flight
#          checks, launcher scripts, uninstall flag,
#          status flag, --help, --version, --changelog
#  v1.1 — start-chroot.sh: use /bin/bash -l (login shell)
#          to silence "cannot set terminal process group",
#          "no job control", and "groups: command not found"
#          warnings on chroot entry
#  v1.2 — Full uninstall rewrite: 4-phase cleanup (unmount,
#          rootfs, tarball, BASE_DIR), disk-usage summary,
#          smart mount detection (normal then lazy fallback),
#          per-phase spinners, post-delete verification,
#          error counter, and final status banner
#  v1.3 — Fix step headers: PURPLE → WHITE (visible on dark
#          terminals); create_launchers now adds bin symlinks
#          start-senestro-chroot.sh and stop-senestro-chroot.sh
#          in Termux $PREFIX/bin; uninstall expanded to 5 phases
#          to remove symlinks before BASE_DIR wipe; --status
#          shows symlink state; completion banner shows aliases
#  v1.4 — Color-scheme-neutral output: WHITE remapped to bold
#          (adapts to dark and light terminals), GRAY remapped
#          to plain, CYAN retired from all informational text
#          (now BOLD); only semantic colors kept (RED=error,
#          GREEN=ok, YELLOW=warn); ask_step prompt now plain
#          text so it's readable on any background
#  [CHANGELOG_END]
#
#  Author: Senestro
#######################################################


# =============================================================================
# CONFIGURATION
# =============================================================================
TOTAL_STEPS=8
CURRENT_STEP=0
BASE_DIR="$HOME/Senestro-Chroot"
ROOTFS_DIR="$BASE_DIR/rootfs"
LOG_DIR="$BASE_DIR/logs"
LOG_FILE="$LOG_DIR/senestro-chroot.log"
ROOTFS_URL="https://cdimage.ubuntu.com/ubuntu-base/releases/22.04/release/ubuntu-base-22.04-base-arm64.tar.gz"
ROOTFS_TAR="$BASE_DIR/ubuntu-base-22.04-arm64.tar.gz"
SCRIPT_VERSION="1.4"
SCRIPT_UPDATE_URL="https://raw.githubusercontent.com/SenestroDev/Senestro-Chroot/refs/heads/main/Senestro-Chroot.sh"


# =============================================================================
# ANSI COLOR CODES
# =============================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'        # bold, inherits terminal fg — visible on any bg
CYAN='\033[0;36m'     # kept for decorative dots/spinner only
WHITE='\033[1m'       # remapped to plain bold (adapts to dark AND light)
GRAY='\033[0m'        # remapped to NC — no dim color that vanishes on light bg
PURPLE='\033[0m'      # retired — mapped to NC so any leftover refs are safe
NC='\033[0m'


# =============================================================================
# LOGGING
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true
}


# =============================================================================
# PROGRESS BAR
# =============================================================================
update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    PERCENT=$((CURRENT_STEP * 100 / TOTAL_STEPS))
    FILLED=$((PERCENT / 5))
    EMPTY=$((20 - FILLED))

    BAR="${GREEN}"
    for ((i=0; i<FILLED; i++)); do BAR+="█"; done
    BAR+="${GRAY}"
    for ((i=0; i<EMPTY; i++)); do BAR+="░"; done
    BAR+="${NC}"

    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${BOLD}Step ${CURRENT_STEP}/${TOTAL_STEPS}${NC} ${BAR} ${BOLD}${PERCENT}%${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}


# =============================================================================
# SPINNER
# =============================================================================
spinner() {
    local pid=$1
    local message=$2

    printf "  ${YELLOW}⏳${NC} %s" "$message"

    while kill -0 "$pid" 2>/dev/null; do
        printf "${CYAN}.${NC}"
        sleep 1
    done

    wait "$pid"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
    else
        printf " ${RED}✗${NC} ${RED}(failed — see $LOG_FILE)${NC}\n"
    fi

    return $exit_code
}


# =============================================================================
# INTERNET CHECK
# =============================================================================
check_internet() {
    printf "  ${YELLOW}⏳${NC} Checking internet connectivity..."

    local _OK=0

    if command -v curl > /dev/null 2>&1; then
        if curl -fsS --head --connect-timeout 8 \
               "https://packages.termux.dev" > /dev/null 2>&1 || \
           curl -fsS --head --connect-timeout 8 \
               "https://google.com" > /dev/null 2>&1; then
            _OK=1
        fi
    fi

    if [ $_OK -eq 0 ] && command -v ping > /dev/null 2>&1; then
        if ping -c 1 -W 5 8.8.8.8 > /dev/null 2>&1; then
            _OK=1
        fi
    fi

    if [ $_OK -eq 1 ]; then
        printf " ${GREEN}✓${NC}\n"
        log "OK    internet connectivity check passed"
        return 0
    else
        printf " ${RED}✗${NC}\n"
        echo ""
        echo -e "  ${RED}✗  No internet connection detected.${NC}"
        echo -e "  ${YELLOW}Make sure Wi-Fi or mobile data is enabled, then try again.${NC}"
        echo ""
        log "FAIL  internet connectivity check failed — aborting"
        exit 1
    fi
}


# =============================================================================
# DISK SPACE CHECK
# =============================================================================
check_disk_space() {
    printf "  ${YELLOW}⏳${NC} Checking available disk space..."

    local _AVAIL_KB
    _AVAIL_KB=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')

    if [ -z "$_AVAIL_KB" ] || ! [[ "$_AVAIL_KB" =~ ^[0-9]+$ ]]; then
        printf " ${YELLOW}⚠ (unable to check)${NC}\n"
        log "WARN  disk space check skipped — df output unparseable"
        return 0
    fi

    local _AVAIL_MB=$(( _AVAIL_KB / 1024 ))
    local _AVAIL_GB_INT=$(( _AVAIL_MB / 1024 ))
    local _AVAIL_GB_DEC=$(( (_AVAIL_MB % 1024) * 10 / 1024 ))

    printf " ${WHITE}${_AVAIL_GB_INT}.${_AVAIL_GB_DEC} GB free${NC}"

    if [ $_AVAIL_MB -lt 500 ]; then
        printf " ${RED}✗${NC}\n"
        echo ""
        echo -e "  ${RED}✗  Critically low disk space (${_AVAIL_GB_INT}.${_AVAIL_GB_DEC} GB free).${NC}"
        echo -e "  ${YELLOW}At least 500 MB is required. Free up space and try again.${NC}"
        echo ""
        log "FAIL  disk space check: only ${_AVAIL_MB} MB free — aborting"
        exit 1
    elif [ $_AVAIL_MB -lt 2048 ]; then
        printf " ${YELLOW}⚠${NC}\n"
        echo ""
        echo -e "  ${YELLOW}⚠  Low disk space (${_AVAIL_GB_INT}.${_AVAIL_GB_DEC} GB free).${NC}"
        echo -e "  ${YELLOW}   2 GB or more is recommended. The install may run out of space.${NC}"
        echo ""
        log "WARN  disk space check: ${_AVAIL_MB} MB free (below 2 GB recommended)"
    else
        printf " ${GREEN}✓${NC}\n"
        log "OK    disk space check: ${_AVAIL_MB} MB free"
    fi
}


# =============================================================================
# SU / ROOT CHECK
# Verifies that the device is rooted and su is functional before proceeding.
# =============================================================================
check_root() {
    printf "  ${YELLOW}⏳${NC} Checking root access (su)..."

    local _WHOAMI
    _WHOAMI=$(su -c "whoami" 2>/dev/null)

    if [ "$_WHOAMI" = "root" ]; then
        printf " ${GREEN}✓${NC}\n"
        log "OK    root access check passed (su whoami=root)"
        return 0
    else
        printf " ${RED}✗${NC}\n"
        echo ""
        echo -e "  ${RED}✗  Root access not available.${NC}"
        echo -e "  ${YELLOW}This script requires a rooted device with Magisk or equivalent.${NC}"
        echo -e "  ${YELLOW}Make sure su is granted in your root manager, then try again.${NC}"
        echo ""
        log "FAIL  root access check failed — su whoami returned: $_WHOAMI"
        exit 1
    fi
}


# =============================================================================
# TERMUX PACKAGE HELPERS
# =============================================================================
pkg_update_safe() {
    local label=${1:-"Refreshing package lists"}
    log "pkg update (${label})"

    (timeout 90 bash -c \
        'DEBIAN_FRONTEND=noninteractive yes | pkg update -y' \
        >> "$LOG_FILE" 2>&1) &
    spinner $! "${label}..."

    local rc=$?
    [ $rc -eq 124 ] && log "WARN  pkg update timed out after 90s (${label})"
    return $rc
}

is_pkg_installed() {
    dpkg -s "$1" > /dev/null 2>&1
}

install_pkg() {
    local pkg=$1
    local name=${2:-$pkg}

    if is_pkg_installed "$pkg"; then
        printf "  ${GREEN}✓${NC} %s — already installed, skipping\n" "$name"
        log "SKIP  $pkg ($name) — already installed"
        return 0
    fi

    log "START $pkg ($name)"
    (DEBIAN_FRONTEND=noninteractive pkg install -y "$pkg" >> "$LOG_FILE" 2>&1) &
    spinner $! "Installing ${name}..."
    local rc=$?

    if [ $rc -eq 0 ]; then
        log "OK    $pkg ($name)"
    else
        log "FAIL  $pkg ($name) — exit $rc"
    fi
    return $rc
}


# =============================================================================
# RUN A COMMAND INSIDE THE CHROOT (via su + chroot)
# =============================================================================
run_in_chroot() {
    su -c "chroot '$ROOTFS_DIR' /bin/bash -c $(printf '%q' "$1")" >> "$LOG_FILE" 2>&1
}

run_in_chroot_spin() {
    local cmd=$1
    local label=$2
    (su -c "chroot '$ROOTFS_DIR' /bin/bash -c $(printf '%q' "$cmd")" >> "$LOG_FILE" 2>&1) &
    spinner $! "$label"
    return $?
}


# =============================================================================
# ASK STEP — prompts the user whether to run a given step
# Returns 0 (yes/default) or 1 (skip)
# =============================================================================
ask_step() {
    local step_num=$1
    local step_name=$2

    echo ""
    echo -e "  ${BOLD}▶ Step ${step_num}: ${step_name}${NC}"
    printf "  Run this step? [Y/n]: "
    read -r _STEP_CHOICE
    echo ""

    if [[ -z "$_STEP_CHOICE" ]] || [[ "$_STEP_CHOICE" =~ ^[Yy]$ ]]; then
        return 0   # yes
    else
        printf "  Skipping Step ${step_num} — ${step_name}\n"
        log "SKIP  Step ${step_num}: ${step_name} — skipped by user"
        return 1   # no
    fi
}


# =============================================================================
# SHOW BANNER
# =============================================================================
show_banner() {
    clear
    echo -e "${BOLD}"
    cat << 'BANNEREOF'
    ╔══════════════════════════════════════════════╗
    ║   🐧  SENESTRO CHROOT v1.4  🐧               ║
    ║   Real Linux on Android via chroot + su      ║
    ╚══════════════════════════════════════════════╝
BANNEREOF
    echo -e "${NC}"
    echo -e "  ${GRAY}Log: $LOG_FILE${NC}"
    echo ""
}


# =============================================================================
# STEP 1 — DOWNLOAD & EXTRACT UBUNTU ROOTFS
# =============================================================================
step_download_rootfs() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Download & Extract Ubuntu 22.04 ARM64 rootfs${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: Download & extract Ubuntu rootfs ==="

    # Create directories
    su -c "mkdir -p '$ROOTFS_DIR'" >> "$LOG_FILE" 2>&1
    mkdir -p "$BASE_DIR"

    # Check if rootfs already extracted
    if su -c "[ -d '$ROOTFS_DIR/bin' ] && [ -d '$ROOTFS_DIR/etc' ]" 2>/dev/null; then
        printf "  ${GREEN}✓${NC} Ubuntu rootfs already extracted — skipping download\n"
        log "SKIP  rootfs already present at $ROOTFS_DIR"
        return 0
    fi

    # Download if tarball not already present
    if [ ! -f "$ROOTFS_TAR" ]; then
        printf "  ${YELLOW}⏳${NC} Downloading Ubuntu 22.04 base (ARM64)..."
        log "START downloading rootfs from $ROOTFS_URL"
        (wget -q "$ROOTFS_URL" -O "$ROOTFS_TAR" >> "$LOG_FILE" 2>&1) &
        local _dl_pid=$!
        while kill -0 "$_dl_pid" 2>/dev/null; do
            printf "${CYAN}.${NC}"
            sleep 2
        done
        wait "$_dl_pid"
        local _dl_rc=$?

        if [ $_dl_rc -ne 0 ]; then
            printf " ${RED}✗${NC}\n"
            echo ""
            echo -e "  ${RED}✗  Download failed (exit $_dl_rc).${NC}"
            echo -e "  ${YELLOW}Check your internet connection and try again.${NC}"
            echo -e "  ${GRAY}  Log: $LOG_FILE${NC}"
            rm -f "$ROOTFS_TAR"
            log "FAIL  rootfs download — exit $_dl_rc"
            exit 1
        fi
        printf " ${GREEN}✓${NC}\n"
        log "OK    rootfs downloaded to $ROOTFS_TAR"
    else
        printf "  ${GREEN}✓${NC} Tarball already present — skipping download\n"
        log "SKIP  tarball already present at $ROOTFS_TAR"
    fi

    # Extract
    printf "  ${YELLOW}⏳${NC} Extracting rootfs (this may take a minute)..."
    log "START extracting rootfs"
    (su -c "tar -xzf '$ROOTFS_TAR' -C '$ROOTFS_DIR'" >> "$LOG_FILE" 2>&1) &
    local _ex_pid=$!
    while kill -0 "$_ex_pid" 2>/dev/null; do
        printf "${CYAN}.${NC}"
        sleep 2
    done
    wait "$_ex_pid"
    local _ex_rc=$?

    if [ $_ex_rc -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
        printf "  ${GREEN}✓${NC} Ubuntu rootfs extracted to: ${GRAY}${ROOTFS_DIR}${NC}\n"
        log "OK    rootfs extracted to $ROOTFS_DIR"
        # Keep the tarball — user can delete manually if space is needed
        printf "  ${GRAY}Tarball kept at $ROOTFS_TAR (delete manually if space is needed)${NC}\n"
    else
        printf " ${RED}✗${NC}\n"
        echo ""
        echo -e "  ${RED}✗  Extraction failed (exit $_ex_rc).${NC}"
        echo -e "  ${YELLOW}The tarball may be incomplete — delete it and try again:${NC}"
        echo -e "    ${GREEN}rm '$ROOTFS_TAR'${NC}"
        log "FAIL  rootfs extraction — exit $_ex_rc"
        exit 1
    fi
}


# =============================================================================
# STEP 2 — MOUNT ESSENTIAL FILESYSTEMS
# =============================================================================
step_mount() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Mount /proc /dev /sys /dev/pts /tmp${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: Mount filesystems ==="

    _mount_one() {
        local type=$1   # "bind" or fs type
        local src=$2
        local dst="${ROOTFS_DIR}${3}"
        local label=$4

        # Skip if already mounted
        if su -c "mountpoint -q '$dst'" 2>/dev/null; then
            printf "  ${GREEN}✓${NC} %s — already mounted, skipping\n" "$label"
            log "SKIP  $dst already mounted"
            return 0
        fi

        su -c "mkdir -p '$dst'" >> "$LOG_FILE" 2>&1

        if [ "$type" = "bind" ]; then
            su -c "mount --bind '$src' '$dst'" >> "$LOG_FILE" 2>&1
        else
            su -c "mount -t '$type' '$type' '$dst'" >> "$LOG_FILE" 2>&1
        fi

        local rc=$?
        if [ $rc -eq 0 ]; then
            printf "  ${GREEN}✓${NC} Mounted %s\n" "$label"
            log "OK    mounted $dst"
        else
            printf "  ${RED}✗${NC} Failed to mount %s ${RED}(check $LOG_FILE)${NC}\n" "$label"
            log "FAIL  mount $dst — exit $rc"
        fi
        return $rc
    }

    _mount_one bind /dev      /dev      "/dev (device nodes)"
    _mount_one bind /dev/pts  /dev/pts  "/dev/pts (pseudo-terminals)"
    _mount_one proc proc      /proc     "/proc (process info)"
    _mount_one sysfs sysfs    /sys      "/sys (kernel/device info)"
    _mount_one tmpfs tmpfs    /tmp      "/tmp (temporary files)"
}


# =============================================================================
# STEP 3 — FIX DNS
# =============================================================================
step_dns() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Fix DNS (resolv.conf)${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: DNS fix ==="

    printf "  ${YELLOW}⏳${NC} Writing DNS nameservers..."
    su -c "cat > '${ROOTFS_DIR}/etc/resolv.conf' << 'DNSEOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
nameserver 1.1.1.1
DNSEOF" >> "$LOG_FILE" 2>&1

    local rc=$?
    if [ $rc -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
        printf "  ${GREEN}✓${NC} DNS set: 8.8.8.8, 8.8.4.4, 1.1.1.1\n"
        log "OK    DNS resolv.conf written"
    else
        printf " ${RED}✗${NC}\n"
        log "FAIL  DNS resolv.conf — exit $rc"
    fi
}


# =============================================================================
# STEP 4 — FIX PATH & TERM
# =============================================================================
step_env() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Fix PATH and TERM inside chroot${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: PATH + TERM fix ==="

    printf "  ${YELLOW}⏳${NC} Writing /etc/bash.bashrc additions..."
    su -c "cat >> '${ROOTFS_DIR}/etc/bash.bashrc' << 'BASHRCEOF'

# Senestro-Chroot: PATH and TERM fix
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export TERM=xterm-256color
export LANG=C.UTF-8
BASHRCEOF" >> "$LOG_FILE" 2>&1

    local rc=$?
    if [ $rc -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
        printf "  ${GREEN}✓${NC} PATH + TERM + LANG written to /etc/bash.bashrc\n"
        log "OK    /etc/bash.bashrc updated"
    else
        printf " ${RED}✗${NC}\n"
        log "FAIL  /etc/bash.bashrc update — exit $rc"
    fi

    # Also write /etc/environment for non-interactive sessions
    printf "  ${YELLOW}⏳${NC} Writing /etc/environment..."
    su -c "cat > '${ROOTFS_DIR}/etc/environment' << 'ENVEOF'
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
TERM=xterm-256color
LANG=C.UTF-8
ENVEOF" >> "$LOG_FILE" 2>&1

    local rc2=$?
    if [ $rc2 -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
        printf "  ${GREEN}✓${NC} /etc/environment written\n"
        log "OK    /etc/environment written"
    else
        printf " ${RED}✗${NC}\n"
        log "FAIL  /etc/environment — exit $rc2"
    fi
}


# =============================================================================
# STEP 5 — APT UPDATE & UPGRADE
# =============================================================================
step_apt_update() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] apt update && apt upgrade [Ubuntu]${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: apt update + upgrade ==="

    run_in_chroot_spin \
        "export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && apt-get update -y" \
        "apt update [Ubuntu]..."

    run_in_chroot_spin \
        "export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && apt-get upgrade -y --no-install-recommends" \
        "apt upgrade [Ubuntu]..."
}


# =============================================================================
# STEP 6 — INSTALL ESSENTIAL PACKAGES
# =============================================================================
step_essentials() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Install essential packages [Ubuntu]${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: Essential packages ==="

    _install_apt() {
        local pkg=$1
        local name=${2:-$pkg}

        # Check if already installed
        local _status
        _status=$(su -c "chroot '$ROOTFS_DIR' /bin/bash -c \
            \"export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && \
              dpkg-query -W -f='\${Status}' '$pkg' 2>/dev/null || echo 'not-installed'\"" 2>/dev/null || echo "not-installed")

        if echo "$_status" | grep -q "install ok installed"; then
            printf "  ${GREEN}✓${NC} %s — already installed, skipping\n" "$name"
            log "SKIP  $pkg ($name) — already installed"
            return 0
        fi

        run_in_chroot_spin \
            "export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && apt-get install -y --no-install-recommends $pkg" \
            "Installing ${name} [Ubuntu]..."
        local rc=$?
        if [ $rc -eq 0 ]; then
            log "OK    $pkg ($name) installed"
        else
            log "FAIL  $pkg ($name) — exit $rc"
        fi
        return $rc
    }

    _install_apt "vim"        "Vim Editor"
    _install_apt "nano"       "Nano Editor"
    _install_apt "curl"       "cURL"
    _install_apt "wget"       "Wget"
    _install_apt "git"        "Git"
    _install_apt "sudo"       "Sudo"
    _install_apt "iproute2"   "Network Tools (ip)"
    _install_apt "iputils-ping" "Ping"
}


# =============================================================================
# STEP 7 — LOCALE & TIMEZONE
# =============================================================================
step_locale() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Set locale and timezone [Ubuntu]${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: Locale + timezone ==="

    # Locale
    run_in_chroot_spin \
        "export DEBIAN_FRONTEND=noninteractive PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && \
         apt-get install -y --no-install-recommends locales && \
         locale-gen en_US.UTF-8 && \
         update-locale LANG=en_US.UTF-8" \
        "Setting locale (en_US.UTF-8) [Ubuntu]..."

    # Timezone picker
    echo ""
    echo -e "  ${BOLD}Choose a timezone for the chroot:${NC}"
    echo ""
    echo -e "    ${GREEN}[1]${NC} Africa/Lagos"
    echo -e "    ${BOLD}[2]${NC} UTC"
    echo -e "    ${BOLD}[3]${NC} America/New_York"
    echo -e "    ${BOLD}[4]${NC} America/Los_Angeles"
    echo -e "    ${BOLD}[5]${NC} Europe/London"
    echo -e "    ${BOLD}[6]${NC} Asia/Kolkata"
    echo -e "    ${BOLD}[7]${NC} Custom (type your own)"
    echo ""
    printf "  Choose [default: 1 — Africa/Lagos]: "
    read -r _TZ_CHOICE

    case "${_TZ_CHOICE:-1}" in
        1) _TZ="Africa/Lagos" ;;
        2) _TZ="UTC" ;;
        3) _TZ="America/New_York" ;;
        4) _TZ="America/Los_Angeles" ;;
        5) _TZ="Europe/London" ;;
        6) _TZ="Asia/Kolkata" ;;
        7)
            printf "  Enter timezone (e.g. Asia/Tokyo): "
            read -r _TZ
            [ -z "$_TZ" ] && _TZ="UTC"
            ;;
        *) _TZ="Africa/Lagos" ;;
    esac

    run_in_chroot_spin \
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && \
         ln -sf /usr/share/zoneinfo/${_TZ} /etc/localtime && \
         echo '${_TZ}' > /etc/timezone" \
        "Setting timezone (${_TZ}) [Ubuntu]..."

    printf "  ${GREEN}✓${NC} Timezone set to: ${WHITE}${_TZ}${NC}\n"
    log "OK    timezone set to $_TZ"
    unset _TZ _TZ_CHOICE
}


# =============================================================================
# STEP 8 — OPTIONAL USER CREATION
# =============================================================================
step_user() {
    update_progress
    echo -e "${BOLD}[Step ${CURRENT_STEP}/${TOTAL_STEPS}] Optional: Create non-root user [Ubuntu]${NC}"
    echo ""
    log "=== STEP $CURRENT_STEP: Optional user creation ==="

    echo -e "  ${BOLD}Would you like to create a non-root user inside the chroot?${NC}"
    printf "  [y/N]: "
    read -r _CREATE_USER
    echo ""

    if ! [[ "$_CREATE_USER" =~ ^[Yy]$ ]]; then
        echo -e "  ${GRAY}Skipping — you can add users later with: useradd -m -s /bin/bash <name>${NC}"
        log "INFO  user creation skipped"
        return 0
    fi

    # Username validation
    local _NEW_USER=""
    while true; do
        echo -e "  ${GRAY}ℹ  Must be lowercase letters, digits, hyphen or underscore (e.g. senestro)${NC}"
        printf "  Enter username: "
        read -r _NEW_USER

        if [ -z "$_NEW_USER" ]; then
            printf "  ${RED}✗${NC} Username cannot be empty. Try again.\n\n"
            continue
        elif ! echo "$_NEW_USER" | grep -qE '^[a-z][a-z0-9_-]*$'; then
            printf "  ${RED}✗${NC} Invalid — use lowercase only, no spaces or uppercase.\n\n"
            continue
        fi

        # Check if user exists inside chroot
        local _USER_EXISTS
        _USER_EXISTS=$(su -c "chroot '$ROOTFS_DIR' /bin/bash -c \
            \"export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && \
              getent passwd '${_NEW_USER}' > /dev/null 2>&1 && echo yes || echo no\"" 2>/dev/null || echo "no")

        if [[ "$_USER_EXISTS" == *"yes"* ]]; then
            echo ""
            printf "  ${YELLOW}⚠${NC}  User ${WHITE}${_NEW_USER}${NC} already exists inside the chroot.\n"
            echo ""
            echo -e "    ${GREEN}[1]${NC} Continue without creating a new user"
            echo -e "    ${BOLD}[2]${NC} Enter a different username"
            echo ""
            printf "  Choose [1/2]: "
            read -r _EXIST_CHOICE
            echo ""

            if [[ "$_EXIST_CHOICE" == "1" ]]; then
                printf "  ${GRAY}Skipping — user ${_NEW_USER} already exists.${NC}\n"
                log "INFO  user '$_NEW_USER' already exists — skipped"
                unset _NEW_USER _USER_EXISTS _EXIST_CHOICE
                return 0
            else
                unset _NEW_USER _USER_EXISTS _EXIST_CHOICE
                continue
            fi
        fi
        unset _USER_EXISTS
        break
    done

    echo ""

    # Password input
    local _NEW_PASS=""
    local _NEW_PASS2=""
    while true; do
        printf "  Password for ${WHITE}${_NEW_USER}${NC}: "
        read -rs _NEW_PASS
        echo ""
        printf "  Confirm password    : "
        read -rs _NEW_PASS2
        echo ""

        if [ -z "$_NEW_PASS" ]; then
            printf "  ${RED}✗${NC} Password cannot be empty. Try again.\n\n"
        elif [ "$_NEW_PASS" != "$_NEW_PASS2" ]; then
            printf "  ${RED}✗${NC} Passwords do not match. Try again.\n\n"
        else
            break
        fi
    done

    run_in_chroot_spin \
        "export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin && \
         useradd -m -s /bin/bash '${_NEW_USER}' && \
         echo '${_NEW_USER}:${_NEW_PASS}' | chpasswd && \
         usermod -aG sudo '${_NEW_USER}' && \
         mkdir -p /etc/sudoers.d && \
         echo '${_NEW_USER} ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/${_NEW_USER} && \
         chmod 440 /etc/sudoers.d/${_NEW_USER}" \
        "Creating user ${_NEW_USER} [Ubuntu]..."

    printf "  ${GREEN}✓${NC} User ${WHITE}${_NEW_USER}${NC} created with /bin/bash shell\n"
    printf "  ${GREEN}✓${NC} Added to sudo group with NOPASSWD\n"
    log "OK    user '$_NEW_USER' created with passwordless sudo"

    unset _NEW_PASS _NEW_PASS2 _NEW_USER _CREATE_USER
}


# =============================================================================
# CREATE LAUNCHER SCRIPTS
# =============================================================================
create_launchers() {
    echo ""
    echo -e "${BOLD}[✦] Creating launcher scripts...${NC}"
    echo ""
    log "=== Creating launcher scripts ==="

    mkdir -p "$BASE_DIR"

    # ── start-chroot.sh ───────────────────────────────────────────────────────
    cat > "$BASE_DIR/start-chroot.sh" << STARTEOF
#!/data/data/com.termux/files/usr/bin/bash
# Senestro-Chroot — Start Script
# Mounts filesystems and enters the Ubuntu chroot.
# Requires root (su/Magisk).

ROOTFS="${ROOTFS_DIR}"

echo ""
echo "Starting Senestro Chroot (Ubuntu 22.04)..."
echo ""

# Mount essential filesystems (skip if already mounted)
_mount() {
    local type=\$1 src=\$2 dst="\${ROOTFS}\$3" label=\$4
    su -c "mountpoint -q '\$dst'" 2>/dev/null && { echo "  ✓ \$label — already mounted"; return 0; }
    su -c "mkdir -p '\$dst'" 2>/dev/null
    if [ "\$type" = "bind" ]; then
        su -c "mount --bind '\$src' '\$dst'" 2>/dev/null
    else
        su -c "mount -t '\$type' '\$type' '\$dst'" 2>/dev/null
    fi
    local rc=\$?
    [ \$rc -eq 0 ] && echo "  ✓ Mounted \$label" || echo "  ✗ Failed to mount \$label"
    return \$rc
}

_mount bind /dev      /dev      "/dev"
_mount bind /dev/pts  /dev/pts  "/dev/pts"
_mount proc proc      /proc     "/proc"
_mount sysfs sysfs    /sys      "/sys"
_mount tmpfs tmpfs    /tmp      "/tmp"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Entering Ubuntu chroot shell..."
echo "  Type 'exit' to leave and auto-unmount"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Enter the chroot as a login shell (-l) to:
#   - suppress "cannot set terminal process group" (no real TTY in chroot)
#   - suppress "no job control in this shell"
#   - suppress "groups: command not found" (bash login init message)
#   - source /etc/profile and ~/.bash_profile for a proper environment
su -c "chroot '\$ROOTFS' /bin/bash -l"

# Unmount in reverse order on exit
echo ""
echo "Cleaning up mounts..."
su -c "umount '\${ROOTFS}/tmp'"     2>/dev/null && echo "  ✓ Unmounted /tmp"
su -c "umount '\${ROOTFS}/sys'"     2>/dev/null && echo "  ✓ Unmounted /sys"
su -c "umount '\${ROOTFS}/proc'"    2>/dev/null && echo "  ✓ Unmounted /proc"
su -c "umount '\${ROOTFS}/dev/pts'" 2>/dev/null && echo "  ✓ Unmounted /dev/pts"
su -c "umount '\${ROOTFS}/dev'"     2>/dev/null && echo "  ✓ Unmounted /dev"
echo ""
echo "Chroot exited cleanly."
echo ""
STARTEOF
    chmod +x "$BASE_DIR/start-chroot.sh"
    printf "  ${GREEN}✓${NC} Created $BASE_DIR/start-chroot.sh\n"
    log "OK    start-chroot.sh written"

    # ── stop-chroot.sh ────────────────────────────────────────────────────────
    cat > "$BASE_DIR/stop-chroot.sh" << STOPEOF
#!/data/data/com.termux/files/usr/bin/bash
# Senestro-Chroot — Stop Script
# Force-unmounts all chroot filesystems (use if start-chroot.sh crashed).

ROOTFS="${ROOTFS_DIR}"

echo ""
echo "Force-unmounting chroot filesystems..."
echo ""

su -c "umount -l '\${ROOTFS}/tmp'"     2>/dev/null && echo "  ✓ /tmp"
su -c "umount -l '\${ROOTFS}/sys'"     2>/dev/null && echo "  ✓ /sys"
su -c "umount -l '\${ROOTFS}/proc'"    2>/dev/null && echo "  ✓ /proc"
su -c "umount -l '\${ROOTFS}/dev/pts'" 2>/dev/null && echo "  ✓ /dev/pts"
su -c "umount -l '\${ROOTFS}/dev'"     2>/dev/null && echo "  ✓ /dev"

echo ""
echo "All mounts released."
echo ""
STOPEOF
    chmod +x "$BASE_DIR/stop-chroot.sh"
    printf "  ${GREEN}✓${NC} Created $BASE_DIR/stop-chroot.sh\n"
    log "OK    stop-chroot.sh written"

    # ── Symlinks in Termux $PREFIX/bin (callable from anywhere) ──────────────
    local _BIN_DIR="/data/data/com.termux/files/usr/bin"

    ln -sf "$BASE_DIR/start-chroot.sh" "${_BIN_DIR}/start-senestro-chroot.sh" 2>/dev/null
    if [ $? -eq 0 ]; then
        printf "  ${GREEN}✓${NC} Symlink: ${_BIN_DIR}/start-senestro-chroot.sh\n"
        log "OK    symlink start-senestro-chroot.sh -> $BASE_DIR/start-chroot.sh"
    else
        printf "  ${YELLOW}⚠${NC} Could not create symlink for start-senestro-chroot.sh\n"
        log "WARN  symlink start-senestro-chroot.sh failed"
    fi

    ln -sf "$BASE_DIR/stop-chroot.sh" "${_BIN_DIR}/stop-senestro-chroot.sh" 2>/dev/null
    if [ $? -eq 0 ]; then
        printf "  ${GREEN}✓${NC} Symlink: ${_BIN_DIR}/stop-senestro-chroot.sh\n"
        log "OK    symlink stop-senestro-chroot.sh -> $BASE_DIR/stop-chroot.sh"
    else
        printf "  ${YELLOW}⚠${NC} Could not create symlink for stop-senestro-chroot.sh\n"
        log "WARN  symlink stop-senestro-chroot.sh failed"
    fi
}


# =============================================================================
# SHOW COMPLETION BANNER
# =============================================================================
show_completion() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║   ✅  Senestro Chroot — Ready!               ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${WHITE}Ubuntu 22.04 ARM64 chroot is set up.${NC}"
    echo ""
    echo -e "  ${GREEN}Start chroot:${NC}"
    echo -e "    ${WHITE}bash $BASE_DIR/start-chroot.sh${NC}"
    echo -e "    ${GRAY}or: start-senestro-chroot.sh${NC}"
    echo ""
    echo -e "  ${GREEN}Force-unmount (if hung):${NC}"
    echo -e "    ${WHITE}bash $BASE_DIR/stop-chroot.sh${NC}"
    echo -e "    ${GRAY}or: stop-senestro-chroot.sh${NC}"
    echo ""
    echo -e "  ${GRAY}Rootfs location : $ROOTFS_DIR${NC}"
    echo -e "  ${GRAY}Log file        : $LOG_FILE${NC}"
    echo ""
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}


# =============================================================================
# UNINSTALL — Full cleanup of BASE_DIR and all associated files
# =============================================================================
uninstall_chroot() {
    # Bootstrap logging before LOG_DIR might exist
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    : > "$LOG_FILE" 2>/dev/null || true
    log "=== --uninstall run at $(date) ==="

    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  🗑  Senestro Chroot — Full Uninstall        ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    # ── Disk usage summary ────────────────────────────────────────────────────
    if [ -d "$BASE_DIR" ]; then
        local _USED
        _USED=$(du -sh "$BASE_DIR" 2>/dev/null | awk '{print $1}')
        echo -e "  ${WHITE}Installation found:${NC}"
        echo -e "    ${GRAY}Location : ${WHITE}${BASE_DIR}${NC}"
        echo -e "    ${GRAY}Disk used: ${WHITE}${_USED:-unknown}${NC}"
    else
        echo -e "  ${YELLOW}⚠  $BASE_DIR does not exist — nothing to remove.${NC}"
        echo ""
        log "INFO  BASE_DIR not found — nothing to remove"
        exit 0
    fi

    echo ""
    echo -e "  ${RED}The following will be permanently deleted:${NC}"
    echo -e "    ${WHITE}•${NC} Ubuntu rootfs       ${GRAY}${ROOTFS_DIR}${NC}"
    echo -e "    ${WHITE}•${NC} Launcher scripts    ${GRAY}${BASE_DIR}/start-chroot.sh${NC}"
    echo -e "                         ${GRAY}${BASE_DIR}/stop-chroot.sh${NC}"
    echo -e "    ${WHITE}•${NC} Downloaded tarball  ${GRAY}${ROOTFS_TAR}${NC}"
    echo -e "    ${WHITE}•${NC} Bin symlinks        ${GRAY}/data/data/com.termux/files/usr/bin/start-senestro-chroot.sh${NC}"
    echo -e "                         ${GRAY}/data/data/com.termux/files/usr/bin/stop-senestro-chroot.sh${NC}"
    echo -e "    ${WHITE}•${NC} Log files           ${GRAY}${LOG_DIR}${NC}"
    echo -e "    ${WHITE}•${NC} Entire base dir     ${GRAY}${BASE_DIR}${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  This action cannot be undone.${NC}"
    echo ""
    printf "  ${YELLOW}Type ${WHITE}yes${YELLOW} to confirm full removal, or press Enter to cancel: ${NC}"
    read -r _CONFIRM
    echo ""

    if [ "$_CONFIRM" != "yes" ]; then
        echo -e "  ${GREEN}Uninstall cancelled — nothing was changed.${NC}"
        echo ""
        log "INFO  --uninstall cancelled by user"
        exit 0
    fi

    local _UNINSTALL_ERRORS=0

    # ── Step 1: Force-unmount all chroot filesystems ──────────────────────────
    echo -e "${BOLD}[1/5] Unmounting chroot filesystems...${NC}"
    echo ""

    _unmount_one() {
        local label=$1
        local target=$2
        # Try regular umount first, then lazy (-l) as fallback
        if su -c "mountpoint -q '$target'" 2>/dev/null; then
            if su -c "umount '$target'" 2>/dev/null; then
                printf "  ${GREEN}✓${NC} %-20s unmounted\n" "$label"
                log "OK    umount $target"
            elif su -c "umount -l '$target'" 2>/dev/null; then
                printf "  ${YELLOW}⚠${NC} %-20s lazy-unmounted (was busy)\n" "$label"
                log "WARN  umount -l $target (lazy)"
            else
                printf "  ${RED}✗${NC} %-20s failed to unmount\n" "$label"
                log "FAIL  umount $target — both normal and lazy failed"
                _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
            fi
        else
            printf "  ${GRAY}–${NC} %-20s not mounted, skipping\n" "$label"
            log "SKIP  $target not mounted"
        fi
    }

    # Unmount in reverse mount order to avoid busy-device errors
    _unmount_one "/tmp"     "${ROOTFS_DIR}/tmp"
    _unmount_one "/sys"     "${ROOTFS_DIR}/sys"
    _unmount_one "/proc"    "${ROOTFS_DIR}/proc"
    _unmount_one "/dev/pts" "${ROOTFS_DIR}/dev/pts"
    _unmount_one "/dev"     "${ROOTFS_DIR}/dev"

    if [ $_UNINSTALL_ERRORS -gt 0 ]; then
        echo ""
        echo -e "  ${RED}⚠  $_UNINSTALL_ERRORS filesystem(s) could not be unmounted.${NC}"
        echo -e "  ${YELLOW}   Deletion may fail for paths still in use.${NC}"
        log "WARN  $_UNINSTALL_ERRORS unmount failures before deletion"
    fi

    # ── Step 2: Remove rootfs (largest, separate step with spinner) ───────────
    echo ""
    echo -e "${BOLD}[2/5] Removing Ubuntu rootfs...${NC}"
    echo ""

    if su -c "[ -d '$ROOTFS_DIR' ]" 2>/dev/null; then
        printf "  ${YELLOW}⏳${NC} Deleting rootfs (this may take a while)..."
        log "START rm -rf $ROOTFS_DIR"
        (su -c "rm -rf '$ROOTFS_DIR'" >> "$LOG_FILE" 2>&1) &
        local _rm_rootfs_pid=$!
        while kill -0 "$_rm_rootfs_pid" 2>/dev/null; do
            printf "${CYAN}.${NC}"
            sleep 1
        done
        wait "$_rm_rootfs_pid"
        local _rm_rootfs_rc=$?

        if [ $_rm_rootfs_rc -eq 0 ]; then
            printf " ${GREEN}✓${NC}\n"
            log "OK    $ROOTFS_DIR removed"
        else
            printf " ${RED}✗ (check $LOG_FILE)${NC}\n"
            log "FAIL  rm $ROOTFS_DIR — exit $_rm_rootfs_rc"
            _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
        fi
    else
        printf "  ${GRAY}–${NC} Rootfs directory not found, skipping\n"
        log "SKIP  $ROOTFS_DIR not present"
    fi

    # ── Step 3: Remove downloaded tarball ────────────────────────────────────
    echo ""
    echo -e "${BOLD}[3/5] Removing downloaded tarball...${NC}"
    echo ""

    if [ -f "$ROOTFS_TAR" ]; then
        printf "  ${YELLOW}⏳${NC} Deleting tarball..."
        log "START rm $ROOTFS_TAR"
        (su -c "rm -f '$ROOTFS_TAR'" >> "$LOG_FILE" 2>&1) &
        local _rm_tar_pid=$!
        while kill -0 "$_rm_tar_pid" 2>/dev/null; do
            printf "${CYAN}.${NC}"
            sleep 1
        done
        wait "$_rm_tar_pid"
        local _rm_tar_rc=$?

        if [ $_rm_tar_rc -eq 0 ]; then
            printf " ${GREEN}✓${NC}\n"
            log "OK    tarball $ROOTFS_TAR removed"
        else
            printf " ${RED}✗ (check $LOG_FILE)${NC}\n"
            log "FAIL  rm $ROOTFS_TAR — exit $_rm_tar_rc"
            _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
        fi
    else
        printf "  ${GRAY}–${NC} Tarball not found, skipping\n"
        log "SKIP  $ROOTFS_TAR not present"
    fi

    # ── Step 4: Remove symlinks from Termux bin ───────────────────────────────
    echo ""
    echo -e "${BOLD}[4/5] Removing bin symlinks...${NC}"
    echo ""

    local _BIN_DIR="/data/data/com.termux/files/usr/bin"
    local _SYMLINKS=("start-senestro-chroot.sh" "stop-senestro-chroot.sh")

    for _sym in "${_SYMLINKS[@]}"; do
        local _sym_path="${_BIN_DIR}/${_sym}"
        if [ -L "$_sym_path" ]; then
            rm -f "$_sym_path" 2>/dev/null
            if [ $? -eq 0 ]; then
                printf "  ${GREEN}✓${NC} Removed symlink: ${_sym_path}\n"
                log "OK    removed symlink $_sym_path"
            else
                printf "  ${RED}✗${NC} Failed to remove: ${_sym_path}\n"
                log "FAIL  rm symlink $_sym_path"
                _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
            fi
        elif [ -e "$_sym_path" ]; then
            printf "  ${YELLOW}⚠${NC} ${_sym} exists but is not a symlink — skipping\n"
            log "WARN  $_sym_path exists but is not a symlink — skipped"
        else
            printf "  ${GRAY}–${NC} ${_sym} not found, skipping\n"
            log "SKIP  $_sym_path not present"
        fi
    done

    # ── Step 5: Remove entire BASE_DIR (launchers, logs, any remaining files) ─
    echo ""
    echo -e "${BOLD}[5/5] Removing base directory...${NC}"
    echo ""

    printf "  ${YELLOW}⏳${NC} Deleting $BASE_DIR..."
    log "START rm -rf $BASE_DIR"
    (su -c "rm -rf '$BASE_DIR'" >> "$LOG_FILE" 2>&1) &
    local _rm_base_pid=$!
    while kill -0 "$_rm_base_pid" 2>/dev/null; do
        printf "${CYAN}.${NC}"
        sleep 1
    done
    wait "$_rm_base_pid"
    local _rm_base_rc=$?

    if [ $_rm_base_rc -eq 0 ]; then
        printf " ${GREEN}✓${NC}\n"
        log "OK    $BASE_DIR removed"
    else
        printf " ${RED}✗ (check $LOG_FILE)${NC}\n"
        log "FAIL  rm $BASE_DIR — exit $_rm_base_rc"
        _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
    fi

    # ── Verification ──────────────────────────────────────────────────────────
    echo ""
    if su -c "[ -e '$BASE_DIR' ]" 2>/dev/null || [ -e "$BASE_DIR" ]; then
        echo -e "  ${RED}✗  $BASE_DIR still exists — partial removal.${NC}"
        echo -e "  ${YELLOW}   Some files may be locked by active processes.${NC}"
        echo -e "  ${YELLOW}   Try running stop-chroot.sh first, then re-run --uninstall.${NC}"
        log "WARN  $BASE_DIR still present after removal attempt"
        _UNINSTALL_ERRORS=$((_UNINSTALL_ERRORS + 1))
    else
        echo -e "  ${GREEN}✓${NC} Verified: $BASE_DIR is gone"
        log "OK    $BASE_DIR verified absent"
    fi

    # ── Final summary ─────────────────────────────────────────────────────────
    echo ""
    if [ $_UNINSTALL_ERRORS -eq 0 ]; then
        echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║   ✅  Senestro Chroot fully removed          ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${GREEN}All files have been deleted successfully.${NC}"
        log "=== --uninstall completed successfully ==="
    else
        echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
        echo -e "${BOLD}║   ⚠  Uninstall completed with errors         ║${NC}"
        echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
        echo ""
        echo -e "  ${YELLOW}$_UNINSTALL_ERRORS issue(s) occurred during removal.${NC}"
        echo -e "  ${GRAY}Review the log for details: ${WHITE}${LOG_FILE}${NC}"
        log "=== --uninstall completed with $_UNINSTALL_ERRORS error(s) ==="
    fi
    echo ""
}


# =============================================================================
# SHOW STATUS
# =============================================================================
show_status() {
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  📋  Senestro Chroot — Status                ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    _check() {
        local label=$1
        local path=$2
        if su -c "[ -e '$path' ]" 2>/dev/null || [ -e "$path" ]; then
            printf "  ${GREEN}✓${NC} %-30s ${GRAY}%s${NC}\n" "$label" "$path"
        else
            printf "  ${RED}✗${NC} %-30s ${GRAY}%s${NC}\n" "$label" "$path"
        fi
    }

    echo -e "  ${WHITE}Rootfs${NC}"
    _check "Ubuntu rootfs /bin"    "${ROOTFS_DIR}/bin"
    _check "Ubuntu rootfs /etc"    "${ROOTFS_DIR}/etc"
    _check "Ubuntu rootfs /usr"    "${ROOTFS_DIR}/usr"
    echo ""

    echo -e "  ${WHITE}Mounts${NC}"
    for _mp in dev proc sys tmp; do
        local _dst="${ROOTFS_DIR}/${_mp}"
        if su -c "mountpoint -q '$_dst'" 2>/dev/null; then
            printf "  ${GREEN}✓${NC} %-30s ${GRAY}mounted${NC}\n" "/${_mp}"
        else
            printf "  ${GRAY}–${NC} %-30s ${GRAY}not mounted${NC}\n" "/${_mp}"
        fi
    done
    echo ""

    echo -e "  ${WHITE}Launchers${NC}"
    _check "start-chroot.sh"       "${BASE_DIR}/start-chroot.sh"
    _check "stop-chroot.sh"        "${BASE_DIR}/stop-chroot.sh"
    echo ""

    echo -e "  ${WHITE}Symlinks${NC}"
    _check "start-senestro-chroot.sh" "/data/data/com.termux/files/usr/bin/start-senestro-chroot.sh"
    _check "stop-senestro-chroot.sh"  "/data/data/com.termux/files/usr/bin/stop-senestro-chroot.sh"
    echo ""

    echo -e "  ${WHITE}Log${NC}"
    _check "Log file"              "$LOG_FILE"
    echo ""
}


# =============================================================================
# SHOW VERSION
# =============================================================================
show_version() {
    echo ""
    echo -e "${BOLD}  🐧 Senestro Chroot${NC}"
    echo -e "     Version : ${WHITE}${SCRIPT_VERSION}${NC}"
    echo -e "     File    : ${WHITE}${BASH_SOURCE[0]}${NC}"
    echo ""
}


# =============================================================================
# SHOW CHANGELOG
# =============================================================================
show_changelog() {
    clear
    echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}║  📜  Senestro Chroot — Changelog             ║${NC}"
    echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
    echo ""

    local _IN=0
    while IFS= read -r _LINE; do
        if echo "$_LINE" | grep -q "CHANGELOG_START"; then
            _IN=1
            continue
        fi
        if echo "$_LINE" | grep -q "CHANGELOG_END"; then
            break
        fi
        if [ $_IN -eq 1 ]; then
            echo -e "  ${GRAY}${_LINE}${NC}"
        fi
    done < "${BASH_SOURCE[0]}"

    echo ""
}


# =============================================================================
# SHOW HELP
# =============================================================================
show_help() {
    clear
    echo -e "${BOLD}"
    cat << 'HELPBANNER'
    ╔══════════════════════════════════════════════╗
    ║   🐧  SENESTRO CHROOT v1.4  🐧               ║
    ╚══════════════════════════════════════════════╝
HELPBANNER
    echo -e "${NC}"

    echo -e "${WHITE}  USAGE${NC}"
    echo -e "    ${GREEN}bash Senestro-Chroot.sh${NC} ${GRAY}[flag]${NC}"
    echo ""
    echo -e "${WHITE}  FLAGS${NC}"
    echo ""
    echo -e "    ${GREEN}(no flag)${NC}          Run the interactive installer"
    echo -e "                       Each step is optional — you choose"
    echo ""
    echo -e "    ${GREEN}--uninstall${NC}        Full cleanup: unmount filesystems, delete rootfs,"
    echo -e "                       tarball, launchers, logs, and entire BASE_DIR"
    echo -e "                       Shows disk usage before deletion and verifies removal"
    echo ""
    echo -e "    ${GREEN}--status${NC}           Show which components are installed/mounted"
    echo ""
    echo -e "    ${GREEN}--changelog${NC}        Display version history (offline)"
    echo ""
    echo -e "    ${GREEN}--version${NC}          Print current version and exit"
    echo ""
    echo -e "    ${GREEN}--help${NC}  ${GREEN}-h${NC}         Show this help and exit"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "${WHITE}  STEPS (each is optional — prompted at runtime)${NC}"
    echo ""
    echo -e "   Step 1  Download & extract Ubuntu 22.04 ARM64 rootfs"
    echo -e "   Step 2  Mount /proc /dev /sys /dev/pts /tmp"
    echo -e "   Step 3  Fix DNS (resolv.conf with Google + Cloudflare)"
    echo -e "   Step 4  Fix PATH + TERM + LANG inside chroot"
    echo -e "   Step 5  apt update && apt upgrade"
    echo -e "   Step 6  Install essentials (vim, nano, curl, wget, git, sudo)"
    echo -e "   Step 7  Set locale (en_US.UTF-8) and timezone"
    echo -e "   Step 8  Create optional non-root user with passwordless sudo"
    echo ""
    echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${WHITE}After install, enter the chroot with:${NC}"
    echo -e "    ${GREEN}bash $BASE_DIR/start-chroot.sh${NC}"
    echo ""
    echo -e "  Log: ${GRAY}$LOG_FILE${NC}"
    echo ""
}


# =============================================================================
# MAIN — Interactive install with per-step opt-in
# =============================================================================
main() {
    # Ensure log dir exists and reset log
    mkdir -p "$LOG_DIR"
    : > "$LOG_FILE"
    {
        echo "========================================"
        echo " Senestro Chroot Installer v${SCRIPT_VERSION} — $(date)"
        echo "========================================"
    } >> "$LOG_FILE"

    show_banner

    # ── Pre-flight ─────────────────────────────────────────────────────────────
    echo -e "  ${WHITE}Running pre-flight checks...${NC}"
    echo ""
    check_root
    check_internet
    check_disk_space
    echo ""

    # ── Termux tools ───────────────────────────────────────────────────────────
    echo -e "  ${WHITE}Installing required Termux tools...${NC}"
    echo ""
    pkg_update_safe "Refreshing Termux packages"
    install_pkg "wget"      "Wget"
    install_pkg "tar"       "Tar"
    install_pkg "bzip2"     "Bzip2"
    install_pkg "xz-utils"  "XZ Utils"
    echo ""

    # ── Pre-install info ───────────────────────────────────────────────────────
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  ${WHITE}Senestro Chroot Installer${NC}"
    echo ""
    echo -e "  ${GRAY}Ubuntu 22.04 ARM64 rootfs (real chroot, not proot)${NC}"
    echo -e "  ${GRAY}Rootfs destination : $ROOTFS_DIR${NC}"
    echo -e "  ${GRAY}Launchers          : $BASE_DIR${NC}"
    echo -e "  ${GRAY}Log file           : $LOG_FILE${NC}"
    echo ""
    echo -e "  ${BOLD}Each step will ask before running.${NC}"
    echo -e "  ${BOLD}Press Enter to accept the default (Yes) or type 'n' to skip.${NC}"
    echo ""
    echo -e "  ${YELLOW}⚠  Make sure su is granted in Magisk for all mount operations.${NC}"
    echo -e "  ${YELLOW}Press Enter to begin, or Ctrl+C to cancel...${NC}"
    read -r
    echo -e "${WHITE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # ── Steps (each is optional) ───────────────────────────────────────────────
    ask_step 1 "Download & Extract Ubuntu 22.04 ARM64 rootfs" && step_download_rootfs
    ask_step 2 "Mount /proc /dev /sys /dev/pts /tmp"          && step_mount
    ask_step 3 "Fix DNS (resolv.conf)"                        && step_dns
    ask_step 4 "Fix PATH + TERM + LANG"                       && step_env
    ask_step 5 "apt update && apt upgrade [Ubuntu]"           && step_apt_update
    ask_step 6 "Install essentials (vim, nano, curl, git...)" && step_essentials
    ask_step 7 "Set locale & timezone [Ubuntu]"               && step_locale
    ask_step 8 "Create optional non-root user [Ubuntu]"       && step_user

    # ── Always create launcher scripts ────────────────────────────────────────
    create_launchers

    log "=== Installation finished ==="
    show_completion
}


# =============================================================================
# ENTRY POINT
# =============================================================================
case "${1:-}" in
    --uninstall)   uninstall_chroot ;;
    --status)      show_status ;;
    --changelog)   show_changelog ;;
    --version)     show_version ;;
    --help|-h)     show_help ;;
    *)             main "$@" ;;
esac
