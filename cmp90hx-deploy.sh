#!/usr/bin/env bash
###############################################################################
# CMP 90HX Full Deploy Script
# Automation: Driver management + PCIe unlock + accelerated llama.cpp build
#
# Usage:
#   sudo ./cmp90hx-deploy.sh --all          # Full deploy (driver + unlock + build)
#   sudo ./cmp90hx-deploy.sh --driver       # Install compatible driver only
#   sudo ./cmp90hx-deploy.sh --unlock       # PCIe + Compute unlock only
#   sudo ./cmp90hx-deploy.sh --verify       # Verify unlock status only
#   sudo ./cmp90hx-deploy.sh --build-llama  # Build llama.cpp with DP2A patch
#   sudo ./cmp90hx-deploy.sh --benchmark    # Run benchmark after build
#   sudo ./cmp90hx-deploy.sh --status       # Show current GPU status
#   sudo ./cmp90hx-deploy.sh --deps         # Install dependencies only
#   sudo ./cmp90hx-deploy.sh --help         # Show this help
#
# Sources:
#   PCIe unlock:    https://github.com/pearlfortune/cmpunlocker
#   Research/eFuse: https://github.com/WildFlash1st/cmp90hx-unlock
#   DP2A patch:     https://github.com/ggml-org/llama.cpp/issues/24616
###############################################################################

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# CONSTANTS
# ─────────────────────────────────────────────────────────────────────────────
CMPUNLOCKER_VERSION="v0.1.28"
CMPUNLOCKER_URL="https://github.com/pearlfortune/cmpunlocker/releases/download/${CMPUNLOCKER_VERSION}/cmpunlocker-v0.1.28-linux-x64-cli.tar.gz"
CMPUNLOCKER_SHA_URL="https://github.com/pearlfortune/cmpunlocker/releases/download/${CMPUNLOCKER_VERSION}/SHA256SUMS"
LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_DIR="${HOME}/llama.cpp-cmp90hx"
CMPUNLOCKER_WORKDIR="/var/tmp/cmpunlocker-deploy"
DRIVER_WORKDIR="/var/tmp/cmp90hx-driver"
CUDA_ARCH="86"

# Supported driver versions for cmpunlocker
SUPPORTED_DRIVERS=("580.159.03" "610.43.03")
RECOMMENDED_DRIVER="610.43.03"

# NVIDIA driver download base URL
NVIDIA_DL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS
# ─────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING
# ─────────────────────────────────────────────────────────────────────────────
log_info()    { printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"; }
log_success() { printf '%s[ OK ]%s %s\n' "$GREEN" "$NC" "$*"; }
log_warn()    { printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"; }
log_error()   { printf '%s[ERR ]%s %s\n' "$RED" "$NC" "$*"; }

log_step() {
    printf '\n%s' "$CYAN"
    printf '=%.0s' {1..62}
    printf '%s\n' "$NC"
    printf '%s  %s%s\n' "$CYAN" "$*" "$NC"
    printf '%s' "$CYAN"
    printf '=%.0s' {1..62}
    printf '%s\n\n' "$NC"
}

die() { log_error "$*"; exit 1; }

# ─────────────────────────────────────────────────────────────────────────────
# SYSTEM CHECKS
# ─────────────────────────────────────────────────────────────────────────────
check_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script requires root privileges. Run: sudo $0 $*"
    fi
}

check_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        die "This script only supports Linux x86_64."
    fi
    if [[ "$(uname -m)" != "x86_64" ]]; then
        die "This script only supports x86_64 architecture."
    fi
}

check_cmp90hx_present() {
    log_info "Checking for CMP 90HX in system..."
    if lspci -nn 2>/dev/null | grep -qi "10de:220d\|10de:1555"; then
        log_success "CMP 90HX detected."
        lspci -nn | grep -i "10de:220d\|10de:1555"
    else
        die "CMP 90HX (10de:220d / 10de:1555) not found. Ensure the card is seated in a PCIe slot."
    fi
}

get_current_driver_version() {
    modinfo -F version nvidia 2>/dev/null || echo ""
}

is_driver_supported() {
    local ver="$1"
    for supported in "${SUPPORTED_DRIVERS[@]}"; do
        if [[ "$ver" == "$supported" ]]; then
            return 0
        fi
    done
    return 1
}

check_nvidia_driver() {
    log_info "Checking NVIDIA driver..."
    if ! command -v nvidia-smi &>/dev/null; then
        log_warn "nvidia-smi not found. NVIDIA driver may not be installed."
        return 1
    fi

    local driver_version
    driver_version=$(get_current_driver_version)

    if [[ -z "$driver_version" ]]; then
        log_warn "Could not determine NVIDIA driver version."
        return 1
    fi

    log_success "NVIDIA driver version: ${driver_version}"

    if is_driver_supported "$driver_version"; then
        log_success "Driver ${driver_version} is supported by cmpunlocker."
        return 0
    else
        log_warn "Driver ${driver_version} is NOT supported."
        log_warn "Supported versions: ${SUPPORTED_DRIVERS[*]}"
        return 1
    fi
}

check_cuda_toolkit() {
    log_info "Checking CUDA Toolkit..."
    if command -v nvcc &>/dev/null; then
        local cuda_ver
        cuda_ver=$(nvcc --version 2>/dev/null | grep "release" | sed 's/.*release //' | sed 's/,.*//')
        log_success "CUDA Toolkit: ${cuda_ver}"
    else
        log_warn "nvcc not found in PATH. Checking standard locations..."
        if [[ -f /usr/local/cuda/bin/nvcc ]]; then
            export PATH="/usr/local/cuda/bin:$PATH"
            export LD_LIBRARY_PATH="/usr/local/cuda/lib64:${LD_LIBRARY_PATH:-}"
            log_success "CUDA found at /usr/local/cuda"
        else
            die "CUDA Toolkit not found. Install: sudo apt install nvidia-cuda-toolkit"
        fi
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Install dependencies
# ─────────────────────────────────────────────────────────────────────────────
install_deps() {
    log_step "INSTALLING DEPENDENCIES"

    local deps=(wget tar gzip git cmake build-essential python3 kmod coreutils binutils)

    # Check kernel headers
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        log_warn "Kernel headers not found. Attempting installation..."
        if command -v apt-get &>/dev/null; then
            apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || {
                log_warn "Could not install kernel headers for $(uname -r)."
                log_warn "Trying generic headers..."
                apt-get install -y linux-headers-generic 2>/dev/null || true
            }
        fi
    fi

    if command -v apt-get &>/dev/null; then
        log_info "Installing dependencies via apt..."
        apt-get update -qq 2>/dev/null
        apt-get install -y "${deps[@]}" 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        log_info "Installing dependencies via dnf..."
        dnf install -y wget tar gzip git cmake gcc gcc-c++ make python3 kmod coreutils binutils 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
        log_info "Installing dependencies via pacman..."
        pacman -Sy --noconfirm wget tar gzip git cmake base-devel python kmod coreutils binutils 2>/dev/null || true
    else
        log_warn "Unknown package manager. Ensure installed: ${deps[*]}"
    fi

    log_success "Dependencies checked/installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Install compatible NVIDIA driver
# ─────────────────────────────────────────────────────────────────────────────
install_driver() {
    log_step "NVIDIA DRIVER MANAGEMENT"

    check_root
    check_cmp90hx_present

    local current_version
    current_version=$(get_current_driver_version)

    # Check if current driver is already supported
    if [[ -n "$current_version" ]] && is_driver_supported "$current_version"; then
        log_success "Current driver ${current_version} is already supported. No action needed."
        return 0
    fi

    # Show current state
    if [[ -n "$current_version" ]]; then
        log_warn "Current driver: ${current_version} (NOT SUPPORTED)"
    else
        log_warn "No NVIDIA driver detected or version unknown."
    fi

    printf '\n'
    printf '  Supported driver versions for CMP 90HX unlock:\n'
    printf '\n'
    printf '    %s1)%s NVIDIA Open %s610.43.03%s (recommended, latest)\n' "$GREEN" "$NC" "$BOLD" "$NC"
    printf '    %s2)%s NVIDIA Open %s580.159.03%s (stable, older)\n' "$GREEN" "$NC" "$BOLD" "$NC"
    printf '    %s3)%s Skip driver installation (proceed at your own risk)\n' "$YELLOW" "$NC"
    printf '\n'
    printf '  Note: This will install NVIDIA Open Kernel Modules.\n'
    printf '  Your current driver will be replaced.\n'
    printf '\n'
    printf '  Select option [1/2/3]: '
    read -r driver_choice

    local target_version=""
    case "$driver_choice" in
        1) target_version="610.43.03" ;;
        2) target_version="580.159.03" ;;
        3)
            log_warn "Skipping driver installation. Unlock may fail."
            return 1
            ;;
        *)
            log_warn "Invalid choice. Using recommended: ${RECOMMENDED_DRIVER}"
            target_version="$RECOMMENDED_DRIVER"
            ;;
    esac

    printf '\n'
    log_info "Selected driver: NVIDIA Open ${target_version}"
    printf '\n'
    printf '  WARNING: This will:\n'
    printf '    1. Stop all GPU processes\n'
    printf '    2. Unload current NVIDIA driver\n'
    printf '    3. Download and install NVIDIA Open %s\n' "$target_version"
    printf '    4. Reboot may be required\n'
    printf '\n'
    printf '  Continue with driver installation? (y/N): '
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Driver installation cancelled."
        return 1
    fi

    # Create work directory
    mkdir -p "$DRIVER_WORKDIR"
    cd "$DRIVER_WORKDIR"

    local DRIVER_FILE="NVIDIA-Linux-x86_64-${target_version}.run"
    local DRIVER_URL="${NVIDIA_DL_BASE}/${target_version}/${DRIVER_FILE}"

    # Download driver
    if [[ ! -f "$DRIVER_FILE" ]]; then
        log_info "Downloading NVIDIA driver ${target_version}..."
        log_info "URL: ${DRIVER_URL}"
        wget -q --show-progress -c "$DRIVER_URL" || die "Failed to download driver from ${DRIVER_URL}"
    else
        log_info "Driver file already exists: ${DRIVER_FILE}"
    fi

    # Verify file exists and is not empty
    if [[ ! -s "$DRIVER_FILE" ]]; then
        die "Downloaded driver file is empty. Remove ${DRIVER_WORKDIR}/${DRIVER_FILE} and retry."
    fi

    local file_size
    file_size=$(stat -f%z "$DRIVER_FILE" 2>/dev/null || stat -c%s "$DRIVER_FILE" 2>/dev/null)
    log_info "Driver file size: $(( file_size / 1024 / 1024 )) MB"

    if (( file_size < 100000000 )); then
        die "Driver file too small (<100MB). Download may be corrupted."
    fi

    chmod +x "$DRIVER_FILE"

    # Stop GPU processes
    log_info "Stopping GPU processes..."
    if command -v systemctl &>/dev/null; then
        # Stop common GPU services
        systemctl stop nvidia-persistenced 2>/dev/null || true
        systemctl stop nvidia-fabricmanager 2>/dev/null || true
    fi

    # Kill any processes using NVIDIA devices
    if command -v fuser &>/dev/null; then
        fuser -v /dev/nvidia* 2>/dev/null && {
            log_info "Killing processes using NVIDIA devices..."
            fuser -k /dev/nvidia* 2>/dev/null || true
            sleep 2
        }
    fi

    # Unload NVIDIA kernel modules
    log_info "Unloading NVIDIA kernel modules..."
    rmmod nvidia_uvm 2>/dev/null || true
    rmmod nvidia_drm 2>/dev/null || true
    rmmod nvidia_modeset 2>/dev/null || true
    rmmod nvidia 2>/dev/null || true
    sleep 2

    # Check if modules are unloaded
    if lsmod | grep -q "^nvidia "; then
        log_warn "nvidia module still loaded. Attempting force unload..."
        rmmod -f nvidia 2>/dev/null || {
            die "Cannot unload nvidia module. Close all GPU applications and retry, or reboot."
        }
    fi

    # Install driver with Open Kernel Modules
    log_info "Installing NVIDIA Open Kernel Modules ${target_version}..."
    log_info "This may take several minutes..."
    printf '\n'

    # Run installer
    # --silent: no interactive prompts
    # --kernel-module-type=open: use open-source kernel module
    # --no-questions: skip questions
    # --disable-nouveau: blacklist nouveau
    # --no-cc-version-check: skip compiler version check (for newer kernels)
    # --kernel-source-path: specify kernel headers if needed
    local install_flags=(
        --silent
        --kernel-module-type=open
        --no-questions
        --disable-nouveau
        --no-cc-version-check
        --install-libglvnd
    )

    # Add kernel source path if available
    if [[ -d "/lib/modules/$(uname -r)/build" ]]; then
        install_flags+=(--kernel-source-path="/lib/modules/$(uname -r)/build")
    fi

    if "./${DRIVER_FILE}" "${install_flags[@]}"; then
        log_success "Driver installation completed!"
    else
        local exit_code=$?
        log_error "Driver installation failed with exit code: ${exit_code}"
        log_error "Check /var/log/nvidia-installer.log for details."
        printf '\n'
        log_info "Common fixes:"
        log_info "  1. Ensure kernel headers are installed: sudo apt install linux-headers-$(uname -r)"
        log_info "  2. Ensure gcc is installed: sudo apt install gcc"
        log_info "  3. Disable Secure Boot in BIOS"
        log_info "  4. Try manual install: sudo ./${DRIVER_FILE} --kernel-module-type=open"
        return 1
    fi

    # Load the new driver
    log_info "Loading new NVIDIA driver..."
    modprobe nvidia 2>/dev/null || {
        log_warn "Could not load nvidia module. A reboot is required."
        printf '\n'
        printf '  %sPlease reboot your system and re-run this script:%s\n' "$BOLD" "$NC"
        printf '    sudo reboot\n'
        printf '    sudo %s --all\n' "$0"
        printf '\n'
        return 0
    }

    sleep 3

    # Verify new driver
    local new_version
    new_version=$(get_current_driver_version)
    if [[ "$new_version" == "$target_version" ]]; then
        log_success "Driver ${new_version} installed and loaded successfully!"
    else
        log_warn "Driver version after install: ${new_version}"
        log_warn "Expected: ${target_version}"
        log_warn "A reboot may be required."
    fi

    # Show nvidia-smi
    printf '\n'
    nvidia-smi 2>/dev/null || log_warn "nvidia-smi not available until reboot."

    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Ensure compatible driver (auto-fix)
# ─────────────────────────────────────────────────────────────────────────────
ensure_compatible_driver() {
    local current_version
    current_version=$(get_current_driver_version)

    if [[ -z "$current_version" ]]; then
        log_warn "No NVIDIA driver detected."
        install_driver
        return $?
    fi

    if is_driver_supported "$current_version"; then
        log_success "Driver ${current_version} is compatible."
        return 0
    fi

    log_warn "Driver ${current_version} is NOT compatible with cmpunlocker."
    log_warn "Supported: ${SUPPORTED_DRIVERS[*]}"
    printf '\n'

    install_driver
    return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Unlock PCIe + Compute
# ─────────────────────────────────────────────────────────────────────────────
unlock_pcie() {
    log_step "UNLOCKING PCIe + COMPUTE (cmpunlocker ${CMPUNLOCKER_VERSION})"

    check_root
    check_cmp90hx_present

    # Ensure driver is compatible before attempting unlock
    if ! check_nvidia_driver; then
        printf '\n'
        log_warn "Incompatible driver detected. Attempting auto-fix..."
        if ! ensure_compatible_driver; then
            die "Cannot proceed with incompatible driver."
        fi
        # Re-check after driver install
        if ! check_nvidia_driver; then
            die "Driver still incompatible after installation attempt. Reboot and retry."
        fi
    fi

    mkdir -p "$CMPUNLOCKER_WORKDIR"
    cd "$CMPUNLOCKER_WORKDIR"

    # Download binary if not present
    if [[ ! -f "cmpunlocker-v0.1.28-linux-x64-cli.tar.gz" ]]; then
        log_info "Downloading cmpunlocker ${CMPUNLOCKER_VERSION}..."
        wget -q --show-progress -c "$CMPUNLOCKER_URL" || die "Failed to download cmpunlocker."
        wget -q --show-progress -c "$CMPUNLOCKER_SHA_URL" || die "Failed to download SHA256SUMS."
    fi

    # Verify checksum
    log_info "Verifying checksum..."
    if sha256sum -c SHA256SUMS --ignore-missing 2>/dev/null | grep -q "OK"; then
        log_success "Checksum verified."
    else
        die "Checksum MISMATCH! File corrupted. Remove ${CMPUNLOCKER_WORKDIR} and retry."
    fi

    # Extract
    if [[ ! -d "cmpunlocker-v0.1.28-linux-x64-cli" ]]; then
        log_info "Extracting archive..."
        tar vxzf cmpunlocker-v0.1.28-linux-x64-cli.tar.gz
    fi

    cd cmpunlocker-v0.1.28-linux-x64-cli

    # Run unlock
    log_info "Running CMP 90HX unlock..."
    log_warn "This will temporarily modify GPU state. Ensure miners and CUDA tasks are stopped."

    if ./cmpunlocker-rs compute90hx-v67 run \
        --all-cmp90hx \
        --acknowledge I-ACCEPT-90HX-V67-COMPUTE-UNLOCK; then
        log_success "Unlock command executed successfully!"
    else
        die "Unlock failed. Check /var/lib/cmpunlocker-rs/transactions/ for details."
    fi

    sleep 3
    verify_unlock
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Verify unlock
# ─────────────────────────────────────────────────────────────────────────────
verify_unlock() {
    log_step "VERIFYING UNLOCK STATUS"

    check_root

    local BIN=""
    if [[ -f "${CMPUNLOCKER_WORKDIR}/cmpunlocker-v0.1.28-linux-x64-cli/cmpunlocker-rs" ]]; then
        BIN="${CMPUNLOCKER_WORKDIR}/cmpunlocker-v0.1.28-linux-x64-cli/cmpunlocker-rs"
    elif command -v cmpunlocker-rs &>/dev/null; then
        BIN="cmpunlocker-rs"
    else
        log_warn "cmpunlocker-rs not found. Downloading for verification..."
        mkdir -p "$CMPUNLOCKER_WORKDIR"
        cd "$CMPUNLOCKER_WORKDIR"
        if [[ ! -f "cmpunlocker-v0.1.28-linux-x64-cli.tar.gz" ]]; then
            wget -q -c "$CMPUNLOCKER_URL"
            wget -q -c "$CMPUNLOCKER_SHA_URL"
        fi
        tar xzf cmpunlocker-v0.1.28-linux-x64-cli.tar.gz 2>/dev/null
        BIN="${CMPUNLOCKER_WORKDIR}/cmpunlocker-v0.1.28-linux-x64-cli/cmpunlocker-rs"
    fi

    log_info "Running verification..."
    if "$BIN" compute90hx-v67 verify --all-cmp90hx --expect full; then
        log_success "UNLOCK CONFIRMED: PASS_CMP90HX_ALL_TARGETS_FULL_SPEED"
    else
        log_error "Unlock NOT confirmed. Try rebooting and re-running."
        return 1
    fi

    printf '\n'
    log_info "Current GPU state (nvidia-smi):"
    nvidia-smi 2>/dev/null || true

    printf '\n'
    log_info "PCIe link status:"
    nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Show GPU status
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    log_step "CMP 90HX STATUS"

    printf '\n'
    log_info "NVIDIA PCI devices:"
    lspci -nn | grep -i nvidia || true

    printf '\n'
    if command -v nvidia-smi &>/dev/null; then
        log_info "nvidia-smi output:"
        nvidia-smi
        printf '\n'
        log_info "PCIe link info:"
        nvidia-smi --query-gpu=pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.max,pcie.link.width.current --format=csv 2>/dev/null || true
    else
        log_warn "nvidia-smi not found."
    fi

    printf '\n'
    local drv
    drv=$(get_current_driver_version)
    if [[ -n "$drv" ]]; then
        log_info "Driver version: ${drv}"
        if is_driver_supported "$drv"; then
            log_success "Driver is SUPPORTED by cmpunlocker."
        else
            log_warn "Driver is NOT supported. Supported: ${SUPPORTED_DRIVERS[*]}"
            log_warn "Run: sudo $0 --driver"
        fi
    else
        log_warn "Could not determine driver version."
    fi

    printf '\n'
    log_info "Kernel: $(uname -r)"
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Build llama.cpp with DP2A patch
# ─────────────────────────────────────────────────────────────────────────────
build_llama() {
    log_step "BUILDING llama.cpp WITH DP2A PATCH FOR CMP 90HX"

    check_cuda_toolkit

    if ! command -v cmake &>/dev/null; then
        die "cmake not found. Install: sudo apt install cmake"
    fi
    if ! command -v git &>/dev/null; then
        die "git not found. Install: sudo apt install git"
    fi

    # Clone or update repository
    if [[ -d "$LLAMA_DIR/.git" ]]; then
        log_info "llama.cpp repo exists. Updating..."
        cd "$LLAMA_DIR"
        git stash 2>/dev/null || true
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
        git pull --ff-only 2>/dev/null || log_warn "Could not update. Using current version."
        git checkout -- ggml/src/ggml-cuda/common.cuh 2>/dev/null || true
    else
        log_info "Cloning llama.cpp into ${LLAMA_DIR}..."
        git clone --depth=1 "$LLAMA_REPO" "$LLAMA_DIR"
        cd "$LLAMA_DIR"
    fi

    cd "$LLAMA_DIR"
    log_info "Working directory: $(pwd)"

    # ─── APPLY DP2A PATCH ────────────────────────────────────────────────────
    log_info "Applying DP2A patch (replacing throttled DP4A with DP2A)..."

    local CUDA_COMMON_FILE="ggml/src/ggml-cuda/common.cuh"

    if [[ ! -f "$CUDA_COMMON_FILE" ]]; then
        CUDA_COMMON_FILE=$(find . -name "common.cuh" -path "*/ggml-cuda/*" 2>/dev/null | head -1)
        if [[ -z "$CUDA_COMMON_FILE" ]]; then
            die "common.cuh not found in llama.cpp structure. Project layout has changed."
        fi
        log_info "Found alternative path: $CUDA_COMMON_FILE"
    fi

    if grep -q "DISABLE_DP4A" "$CUDA_COMMON_FILE" 2>/dev/null; then
        log_warn "DP2A patch already applied. Skipping."
    else
        cat << 'PYTHON_PATCH_EOF' > /tmp/patch_cmp90hx_dp2a.py
import sys
filepath = sys.argv[1]
with open(filepath, 'r') as f:
    content = f.read()

old_code = """#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)
    return __dp4a(a, b, c);"""

old_code_alt = """#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)
        return __dp4a(a, b, c);"""

new_code = """#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)
    #if defined(DISABLE_DP4A)
        int a_lo, a_hi;
        asm("prmt.b32 %0, %1, 0, 0x9180;" : "=r"(a_lo) : "r"(a));
        asm("prmt.b32 %0, %1, 0, 0xB3A2;" : "=r"(a_hi) : "r"(a));
        int r = c;
        asm("dp2a.lo.s32.s32 %0, %1, %2, %0;" : "+r"(r) : "r"(a_lo), "r"(b));
        asm("dp2a.hi.s32.s32 %0, %1, %2, %0;" : "+r"(r) : "r"(a_hi), "r"(b));
        return r;
    #else
        return __dp4a(a, b, c);
    #endif"""

if old_code in content:
    content = content.replace(old_code, new_code)
    with open(filepath, 'w') as f:
        f.write(content)
    print("PATCH_OK")
elif old_code_alt in content:
    content = content.replace(old_code_alt, new_code)
    with open(filepath, 'w') as f:
        f.write(content)
    print("PATCH_OK")
else:
    print("PATCH_NOT_FOUND")
PYTHON_PATCH_EOF

        local patch_result
        patch_result=$(python3 /tmp/patch_cmp90hx_dp2a.py "$CUDA_COMMON_FILE")
        rm -f /tmp/patch_cmp90hx_dp2a.py

        if [[ "$patch_result" == "PATCH_OK" ]]; then
            log_success "DP2A patch applied successfully!"
        else
            die "Failed to apply patch. File structure has changed. Apply manually or update script."
        fi
    fi

    # ─── COMPILE ─────────────────────────────────────────────────────────────
    log_info "Compiling llama.cpp with flags:"
    log_info "  -DGGML_CUDA=ON"
    log_info "  -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}"
    log_info "  -DCMAKE_CUDA_FLAGS=\"-DDISABLE_DP4A\""

    rm -rf build

    cmake -B build \
        -DGGML_CUDA=ON \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCH}" \
        -DCMAKE_CUDA_FLAGS="-DDISABLE_DP4A" \
        -DCMAKE_BUILD_TYPE=Release

    cmake --build build --config Release -j "$(nproc)"

    if [[ -f "build/bin/llama-cli" ]]; then
        log_success "Build completed successfully!"
        printf '\n'
        log_info "Binaries:"
        log_info "  llama-cli:    ${LLAMA_DIR}/build/bin/llama-cli"
        log_info "  llama-server: ${LLAMA_DIR}/build/bin/llama-server"
        log_info "  llama-bench:  ${LLAMA_DIR}/build/bin/llama-bench"
        printf '\n'
        log_info "Benchmark example:"
        log_info "  ${LLAMA_DIR}/build/bin/llama-bench -hf TheBloke/Llama-2-7B-GGUF:Q4_0 -p 512 -n 128 -ngl 99 -r 3"
        printf '\n'
        log_info "Chat example:"
        log_info "  ${LLAMA_DIR}/build/bin/llama-cli -m /path/to/model.gguf -ngl 99 -t 8"
    else
        die "Build did not produce llama-cli. Check compilation errors above."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Run benchmark
# ─────────────────────────────────────────────────────────────────────────────
run_benchmark() {
    log_step "BENCHMARKING llama.cpp ON CMP 90HX"

    local BENCH_BIN="${LLAMA_DIR}/build/bin/llama-bench"

    if [[ ! -f "$BENCH_BIN" ]]; then
        die "llama-bench not found. Run first: $0 --build-llama"
    fi

    log_info "Running benchmark (Llama-2-7B Q4_0, pp512 + tg128)..."
    log_info "Expected results for CMP 90HX with DP2A patch:"
    log_info "  pp512: ~370-400 t/s (prompt processing)"
    log_info "  tg128: ~100-120 t/s (token generation) <- ACCELERATED by patch!"
    printf '\n'

    "$BENCH_BIN" -hf TheBloke/Llama-2-7B-GGUF:Q4_0 -p 512 -n 128 -ngl 99 -r 3
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Full deployment
# ─────────────────────────────────────────────────────────────────────────────
deploy_all() {
    log_step "FULL CMP 90HX DEPLOYMENT"

    printf '  Stage 1: Install dependencies\n'
    printf '  Stage 2: Ensure compatible NVIDIA driver\n'
    printf '  Stage 3: Unlock PCIe + Compute\n'
    printf '  Stage 4: Verify unlock\n'
    printf '  Stage 5: Build llama.cpp with DP2A patch\n'
    printf '\n'
    printf 'Continue? (y/N): '
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi

    install_deps
    ensure_compatible_driver
    unlock_pcie
    build_llama

    log_step "DEPLOYMENT COMPLETE!"
    printf '\n'
    printf '  [OK] Compatible driver installed\n'
    printf '  [OK] PCIe unlocked (Gen3 x16)\n'
    printf '  [OK] llama.cpp built with DP2A patch\n'
    printf '\n'
    printf '  Binaries: %s/build/bin/\n' "$LLAMA_DIR"
    printf '\n'
    printf '  Quick test:\n'
    printf '    %s/build/bin/llama-bench -hf TheBloke/Llama-2-7B-GGUF:Q4_0 -p 512 -n 128 -ngl 99\n' "$LLAMA_DIR"
    printf '\n'
    printf '  NOTE: Unlock is temporary. After reboot run:\n'
    printf '    sudo %s --unlock\n' "$0"
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# FUNCTION: Help
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    printf '%s%sCMP 90HX Full Deploy Script%s\n\n' "$BOLD" "$CYAN" "$NC"
    printf 'Usage: sudo %s [OPTION]\n\n' "$0"
    printf 'Options:\n'
    printf '  %s--all%s           Full deployment (driver + unlock + build llama.cpp)\n' "$GREEN" "$NC"
    printf '  %s--driver%s        Install compatible NVIDIA driver only\n' "$GREEN" "$NC"
    printf '  %s--unlock%s        Unlock PCIe + Compute only\n' "$GREEN" "$NC"
    printf '  %s--verify%s        Verify unlock status only\n' "$GREEN" "$NC"
    printf '  %s--build-llama%s   Build llama.cpp with DP2A patch only\n' "$GREEN" "$NC"
    printf '  %s--benchmark%s     Run benchmark after build\n' "$GREEN" "$NC"
    printf '  %s--status%s        Show current GPU status\n' "$GREEN" "$NC"
    printf '  %s--deps%s          Install dependencies only\n' "$GREEN" "$NC"
    printf '  %s--help%s          Show this help message\n' "$GREEN" "$NC"
    printf '\n'
    printf 'Examples:\n'
    printf '  sudo %s --all            # First-time deployment\n' "$0"
    printf '  sudo %s --driver         # Fix incompatible driver\n' "$0"
    printf '  sudo %s --unlock         # After reboot (unlock is temporary)\n' "$0"
    printf '  sudo %s --build-llama    # Rebuild llama.cpp after update\n' "$0"
    printf '\n'
    printf 'Requirements:\n'
    printf '  - Linux x86_64\n'
    printf '  - NVIDIA CMP 90HX (10de:220d)\n'
    printf '  - NVIDIA Open Driver 580.159.03 or 610.43.03\n'
    printf '  - CUDA Toolkit\n'
    printf '  - Secure Boot disabled\n'
    printf '\n'
    printf 'Supported drivers:\n'
    printf '  - 610.43.03 (recommended)\n'
    printf '  - 580.159.03 (stable)\n'
    printf '\n'
    printf 'Source repositories:\n'
    printf '  PCIe unlock:    https://github.com/pearlfortune/cmpunlocker\n'
    printf '  HW research:    https://github.com/WildFlash1st/cmp90hx-unlock\n'
    printf '  DP2A patch:     https://github.com/ggml-org/llama.cpp/issues/24616\n'
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    if [[ $# -eq 0 ]]; then
        show_help
        exit 0
    fi

    check_linux

    case "${1}" in
        --all)          deploy_all ;;
        --driver)       check_root; install_driver ;;
        --unlock)       unlock_pcie ;;
        --verify)       verify_unlock ;;
        --build-llama)  install_deps; build_llama ;;
        --benchmark)    run_benchmark ;;
        --status)       show_status ;;
        --deps)         check_root; install_deps ;;
        --help|-h)      show_help ;;
        *)
            log_error "Unknown option: $1"
            printf '\n'
            show_help
            exit 1
            ;;
    esac
}

main "$@"
