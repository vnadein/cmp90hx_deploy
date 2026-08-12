#!/usr/bin/env bash
###############################################################################
# CMP 90HX Full Deploy Script v0.4
# Automation: Driver management + PCIe unlock + accelerated llama.cpp build
#
# Handles custom kernels by building candidate module from stockflow package.
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
CMPUNLOCKER_CLI_URL="https://github.com/pearlfortune/cmpunlocker/releases/download/${CMPUNLOCKER_VERSION}/cmpunlocker-v0.1.28-linux-x64-cli.tar.gz"
CMPUNLOCKER_90HX_STOCKFLOW_URL="https://github.com/pearlfortune/cmpunlocker/releases/download/${CMPUNLOCKER_VERSION}/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow.tar.gz"
CMPUNLOCKER_SHA_URL="https://github.com/pearlfortune/cmpunlocker/releases/download/${CMPUNLOCKER_VERSION}/SHA256SUMS"
NVIDIA_SOURCE_URL="https://download.nvidia.com/XFree86/NVIDIA-kernel-module-source/NVIDIA-kernel-module-source-610.43.03.tar.xz"
NVIDIA_DL_BASE="https://download.nvidia.com/XFree86/Linux-x86_64"

LLAMA_REPO="https://github.com/ggml-org/llama.cpp.git"
LLAMA_DIR="${HOME}/llama.cpp-cmp90hx"
WORKDIR="/var/tmp/cmp90hx-deploy"
CUDA_ARCH="86"

SUPPORTED_DRIVERS=("580.159.03" "610.43.03")
RECOMMENDED_DRIVER="610.43.03"
HIVEOS_KERNEL="6.10.0-hiveos"

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
    [[ "$(uname -s)" == "Linux" ]] || die "Only Linux x86_64 supported."
    [[ "$(uname -m)" == "x86_64" ]] || die "Only x86_64 architecture supported."
}

check_cmp90hx_present() {
    log_info "Checking for CMP 90HX..."
    if lspci -nn 2>/dev/null | grep -qi "10de:220d\|10de:1555"; then
        log_success "CMP 90HX detected."
    else
        die "CMP 90HX (10de:220d / 10de:1555) not found."
    fi
}

get_current_driver_version() {
    modinfo -F version nvidia 2>/dev/null || echo ""
}

get_current_kernel() {
    uname -r
}

is_driver_supported() {
    local ver="$1"
    for s in "${SUPPORTED_DRIVERS[@]}"; do
        [[ "$ver" == "$s" ]] && return 0
    done
    return 1
}

is_hiveos_kernel() {
    [[ "$(get_current_kernel)" == "$HIVEOS_KERNEL" ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# DEPENDENCIES
# ─────────────────────────────────────────────────────────────────────────────
install_deps() {
    log_step "INSTALLING DEPENDENCIES"

    local deps=(wget tar gzip git cmake build-essential python3 kmod coreutils
                binutils make gcc patch xz-utils)

    # Kernel headers check
    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        log_warn "Kernel headers not found for $(uname -r). Installing..."
        if command -v apt-get &>/dev/null; then
            apt-get update -qq
            apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || {
                log_warn "Trying linux-headers-generic..."
                apt-get install -y linux-headers-generic 2>/dev/null || true
            }
        fi
    fi

    if [[ ! -d "/lib/modules/$(uname -r)/build" ]]; then
        die "Kernel headers still not found. Install manually: sudo apt install linux-headers-$(uname -r)"
    fi
    log_success "Kernel headers found: /lib/modules/$(uname -r)/build"

    if command -v apt-get &>/dev/null; then
        log_info "Installing packages via apt..."
        apt-get update -qq 2>/dev/null
        apt-get install -y "${deps[@]}" 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
        dnf install -y "${deps[@]}" 2>/dev/null || true
    elif command -v pacman &>/dev/null; then
        pacman -Sy --noconfirm "${deps[@]}" 2>/dev/null || true
    fi

    log_success "Dependencies installed."
}

# ─────────────────────────────────────────────────────────────────────────────
# DRIVER MANAGEMENT
# ─────────────────────────────────────────────────────────────────────────────
install_driver() {
    log_step "NVIDIA DRIVER MANAGEMENT"

    check_root
    check_cmp90hx_present

    local current_version
    current_version=$(get_current_driver_version)

    if [[ -n "$current_version" ]] && is_driver_supported "$current_version"; then
        log_success "Driver ${current_version} is already supported."
        return 0
    fi

    if [[ -n "$current_version" ]]; then
        log_warn "Current driver: ${current_version} (NOT SUPPORTED)"
    else
        log_warn "No NVIDIA driver detected."
    fi

    printf '\n'
    printf '  Supported drivers for CMP 90HX unlock:\n\n'
    printf '    %s1)%s NVIDIA Open %s610.43.03%s (recommended)\n' "$GREEN" "$NC" "$BOLD" "$NC"
    printf '    %s2)%s NVIDIA Open %s580.159.03%s (stable, older)\n' "$GREEN" "$NC" "$BOLD" "$NC"
    printf '    %s3)%s Skip driver installation\n' "$YELLOW" "$NC"
    printf '\n'
    printf '  Select [1/2/3]: '
    read -r choice

    local target=""
    case "$choice" in
        1) target="610.43.03" ;;
        2) target="580.159.03" ;;
        3) log_warn "Skipping."; return 1 ;;
        *) target="$RECOMMENDED_DRIVER" ;;
    esac

    printf '\n'
    printf '  Install NVIDIA Open %s? (y/N): ' "$target"
    read -r confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || { log_info "Cancelled."; return 1; }

    mkdir -p "$WORKDIR/driver"
    cd "$WORKDIR/driver"

    local FILE="NVIDIA-Linux-x86_64-${target}.run"
    local URL="${NVIDIA_DL_BASE}/${target}/${FILE}"

    if [[ ! -f "$FILE" ]]; then
        log_info "Downloading ${FILE}..."
        wget -q --show-progress -c "$URL" || die "Download failed."
    fi
    chmod +x "$FILE"

    log_info "Stopping GPU processes and unloading modules..."
    systemctl stop nvidia-persistenced 2>/dev/null || true
    fuser -k /dev/nvidia* 2>/dev/null || true
    sleep 1
    rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia 2>/dev/null || true
    sleep 2

    if lsmod | grep -q "^nvidia "; then
        die "Cannot unload nvidia module. Close GPU apps or reboot first."
    fi

    log_info "Installing NVIDIA Open ${target} (this takes several minutes)..."
    if "./${FILE}" --silent --kernel-module-type=open --no-questions \
        --disable-nouveau --no-cc-version-check --install-libglvnd; then
        log_success "Driver installed!"
    else
        die "Driver install failed. Check /var/log/nvidia-installer.log"
    fi

    modprobe nvidia 2>/dev/null || {
        log_warn "Reboot required to load new driver."
        printf '  Run: sudo reboot && sudo %s --all\n' "$0"
        return 0
    }
    sleep 3

    local new_ver
    new_ver=$(get_current_driver_version)
    log_success "Driver loaded: ${new_ver}"
}

ensure_compatible_driver() {
    local ver
    ver=$(get_current_driver_version)
    if [[ -n "$ver" ]] && is_driver_supported "$ver"; then
        log_success "Driver ${ver} compatible."
        return 0
    fi
    install_driver
}

# ─────────────────────────────────────────────────────────────────────────────
# BUILD CANDIDATE MODULE FOR CUSTOM KERNEL
# All logging goes to stderr; only the final path goes to stdout.
# ─────────────────────────────────────────────────────────────────────────────
build_candidate() {
    local kernel
    kernel=$(get_current_kernel)

    # All log output to stderr so $(build_candidate) captures only the path
    log_step "BUILDING CANDIDATE MODULE FOR KERNEL ${kernel}" >&2

    local STOCKFLOW_DIR="${WORKDIR}/stockflow"
    local SF_PKG_DIR="${STOCKFLOW_DIR}/cmpunlocker-v0.1.28-linux-x64-90hx-stockflow"
    local SF_BUILD_DIR="${SF_PKG_DIR}/stockflow/610.43.03"
    local ARTIFACT_DIR="${SF_BUILD_DIR}/artifacts/610.43.03-${kernel}-rejoin15-serialized-start"

    # ── Check if already built ────────────────────────────────────────────────
    if [[ -f "${ARTIFACT_DIR}/nvidia.ko" ]]; then
        log_success "Candidate already built." >&2
        printf '%s' "$ARTIFACT_DIR"
        return 0
    fi

    mkdir -p "$STOCKFLOW_DIR"
    cd "$STOCKFLOW_DIR"

    # ── Download stockflow package ────────────────────────────────────────────
    if [[ ! -f "cmpunlocker-v0.1.28-linux-x64-90hx-stockflow.tar.gz" ]]; then
        log_info "Downloading 90HX stockflow package (~60MB)..." >&2
        wget -q --show-progress -c "$CMPUNLOCKER_90HX_STOCKFLOW_URL" >&2 || {
            log_error "Failed to download stockflow package." >&2
            return 1
        }
    fi

    # ── Download SHA256SUMS ───────────────────────────────────────────────────
    if [[ ! -f "SHA256SUMS" ]]; then
        wget -q -c "$CMPUNLOCKER_SHA_URL" >&2 || true
    fi

    # ── Extract ───────────────────────────────────────────────────────────────
    if [[ ! -d "$SF_PKG_DIR" ]]; then
        log_info "Extracting stockflow package..." >&2
        tar xzf cmpunlocker-v0.1.28-linux-x64-90hx-stockflow.tar.gz >&2
    fi

    cd "$SF_BUILD_DIR"

    # ── Download NVIDIA kernel module source ──────────────────────────────────
    local NVIDIA_SRC="${STOCKFLOW_DIR}/NVIDIA-kernel-module-source-610.43.03.tar.xz"
    if [[ ! -f "$NVIDIA_SRC" ]]; then
        log_info "Downloading NVIDIA kernel source 610.43.03 (~50MB)..." >&2
        wget -q --show-progress -c "$NVIDIA_SOURCE_URL" -O "$NVIDIA_SRC" >&2 || {
            log_error "Failed to download NVIDIA source." >&2
            return 1
        }
    fi

    # ── Build candidate ───────────────────────────────────────────────────────
    log_info "Compiling candidate for kernel ${kernel}..." >&2
    log_info "This may take 5-15 minutes..." >&2

    local BUILD_LOG="${STOCKFLOW_DIR}/build-candidate.log"

    if JOBS="$(nproc)" CMP90_STOCKFLOW_VARIANT=rejoin15 \
        CMP90_STOCKFLOW_LOW_MEM_G_BINDATA=1 \
        ./build-candidate.sh --source-tarball "$NVIDIA_SRC" >"$BUILD_LOG" 2>&1; then
        log_success "Candidate build completed." >&2
    else
        log_error "Candidate build FAILED." >&2
        log_error "Last 40 lines of build log:" >&2
        tail -40 "$BUILD_LOG" >&2
        printf '\n' >&2
        log_info "Full log: ${BUILD_LOG}" >&2
        printf '\n' >&2
        log_info "Possible fixes:" >&2
        log_info "  1. Install kernel headers: sudo apt install linux-headers-$(uname -r)" >&2
        log_info "  2. Install gcc/make: sudo apt install build-essential" >&2
        log_info "  3. Try a different kernel (6.10.x recommended)" >&2
        return 1
    fi

    # ── Locate artifact ───────────────────────────────────────────────────────
    # Try exact match first
    if [[ -f "${ARTIFACT_DIR}/nvidia.ko" ]]; then
        log_success "Artifact: ${ARTIFACT_DIR}/nvidia.ko" >&2
        printf '%s' "$ARTIFACT_DIR"
        return 0
    fi

    # Fallback: search for any artifact matching this kernel
    local FOUND
    FOUND=$(find "${SF_BUILD_DIR}/artifacts" -maxdepth 1 -type d -name "*${kernel}*" 2>/dev/null | head -1)
    if [[ -n "$FOUND" && -f "${FOUND}/nvidia.ko" ]]; then
        log_success "Artifact (fallback): ${FOUND}/nvidia.ko" >&2
        printf '%s' "$FOUND"
        return 0
    fi

    # Last resort: any artifact directory
    FOUND=$(find "${SF_BUILD_DIR}/artifacts" -maxdepth 1 -type d -name "610*" 2>/dev/null | head -1)
    if [[ -n "$FOUND" && -f "${FOUND}/nvidia.ko" ]]; then
        log_warn "Using fallback artifact: ${FOUND}" >&2
        printf '%s' "$FOUND"
        return 0
    fi

    log_error "No valid artifact found after build." >&2
    log_error "Contents of artifacts/:" >&2
    ls -la "${SF_BUILD_DIR}/artifacts/" 2>/dev/null >&2 || true
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# UNLOCK PCIe + COMPUTE
# ─────────────────────────────────────────────────────────────────────────────
unlock_pcie() {
    log_step "UNLOCKING PCIe + COMPUTE"

    check_root
    check_cmp90hx_present

    # Check driver
    local drv
    drv=$(get_current_driver_version)
    if ! is_driver_supported "${drv:-}"; then
        log_warn "Driver '${drv:-none}' not supported. Attempting fix..."
        ensure_compatible_driver || die "Cannot proceed without compatible driver."
        drv=$(get_current_driver_version)
    fi
    log_success "Using driver: ${drv}"

    # Prepare cmpunlocker-rs binary
    mkdir -p "$WORKDIR/cli"
    cd "$WORKDIR/cli"

    if [[ ! -f "cmpunlocker-rs" ]]; then
        if [[ ! -f "cmpunlocker-v0.1.28-linux-x64-cli.tar.gz" ]]; then
            log_info "Downloading cmpunlocker CLI..."
            wget -q --show-progress -c "$CMPUNLOCKER_CLI_URL" || die "Download failed."
            wget -q -c "$CMPUNLOCKER_SHA_URL" || true
        fi
        tar xzf cmpunlocker-v0.1.28-linux-x64-cli.tar.gz 2>/dev/null
        if [[ -d "cmpunlocker-v0.1.28-linux-x64-cli" ]]; then
            cp "cmpunlocker-v0.1.28-linux-x64-cli/cmpunlocker-rs" .
        fi
    fi

    if [[ ! -f "cmpunlocker-rs" ]]; then
        die "cmpunlocker-rs binary not found after extraction."
    fi

    # Determine unlock strategy based on kernel
    local kernel
    kernel=$(get_current_kernel)
    local CANDIDATE_FLAG=""

    if [[ "$kernel" == "$HIVEOS_KERNEL" ]]; then
        log_info "Kernel ${kernel} — using embedded candidate."
    else
        log_info "Kernel ${kernel} — building custom candidate..."
        printf '\n'

        local CANDIDATE_DIR
        # Capture only stdout (the path); all logs go to stderr
        CANDIDATE_DIR=$(build_candidate)
        local BUILD_RC=$?

        if [[ $BUILD_RC -ne 0 || -z "$CANDIDATE_DIR" ]]; then
            die "Failed to build candidate for kernel ${kernel}."
        fi

        # Verify nvidia.ko exists
        if [[ ! -f "${CANDIDATE_DIR}/nvidia.ko" ]]; then
            log_error "nvidia.ko not found in: ${CANDIDATE_DIR}"
            ls -la "${CANDIDATE_DIR}/" 2>/dev/null || true
            die "Candidate build produced no usable module."
        fi

        CANDIDATE_FLAG="--candidate ${CANDIDATE_DIR}/nvidia.ko"
        log_info "Candidate: ${CANDIDATE_DIR}/nvidia.ko"

        # Show module info
        modinfo -F vermagic "${CANDIDATE_DIR}/nvidia.ko" 2>/dev/null && true
    fi

    # Run unlock
    printf '\n'
    log_info "Running CMP 90HX unlock..."
    log_warn "Ensure miners and CUDA tasks are stopped."

    local UNLOCK_CMD="./cmpunlocker-rs compute90hx-v67 run --all-cmp90hx --acknowledge I-ACCEPT-90HX-V67-COMPUTE-UNLOCK"
    if [[ -n "$CANDIDATE_FLAG" ]]; then
        UNLOCK_CMD="${UNLOCK_CMD} ${CANDIDATE_FLAG}"
    fi

    log_info "Command: ${UNLOCK_CMD}"
    printf '\n'

    if eval "$UNLOCK_CMD"; then
        log_success "Unlock command completed!"
    else
        die "Unlock failed. Check /var/lib/cmpunlocker-rs/transactions/"
    fi

    sleep 3
    verify_unlock
}

# ─────────────────────────────────────────────────────────────────────────────
# VERIFY UNLOCK
# ─────────────────────────────────────────────────────────────────────────────
verify_unlock() {
    log_step "VERIFYING UNLOCK"

    local BIN="${WORKDIR}/cli/cmpunlocker-rs"
    [[ -f "$BIN" ]] || BIN="cmpunlocker-rs"

    if "$BIN" compute90hx-v67 verify --all-cmp90hx --expect full; then
        log_success "UNLOCK CONFIRMED: PASS_CMP90HX_ALL_TARGETS_FULL_SPEED"
    else
        log_error "Unlock NOT confirmed."
        return 1
    fi

    printf '\n'
    nvidia-smi 2>/dev/null || true
    printf '\n'
    log_info "PCIe link:"
    nvidia-smi --query-gpu=pcie.link.gen.current,pcie.link.width.current --format=csv 2>/dev/null || true
}

# ─────────────────────────────────────────────────────────────────────────────
# BUILD llama.cpp
# ─────────────────────────────────────────────────────────────────────────────
build_llama() {
    log_step "BUILDING llama.cpp WITH DP2A PATCH"

    command -v cmake &>/dev/null || die "cmake not found."
    command -v git &>/dev/null || die "git not found."

    # CUDA check
    if ! command -v nvcc &>/dev/null; then
        if [[ -f /usr/local/cuda/bin/nvcc ]]; then
            export PATH="/usr/local/cuda/bin:$PATH"
        else
            die "CUDA Toolkit not found. Install: sudo apt install nvidia-cuda-toolkit"
        fi
    fi

    if [[ -d "$LLAMA_DIR/.git" ]]; then
        log_info "Updating existing llama.cpp..."
        cd "$LLAMA_DIR"
        git stash 2>/dev/null || true
        git checkout main 2>/dev/null || git checkout master 2>/dev/null || true
        git pull --ff-only 2>/dev/null || true
        git checkout -- ggml/src/ggml-cuda/common.cuh 2>/dev/null || true
    else
        log_info "Cloning llama.cpp..."
        git clone --depth=1 "$LLAMA_REPO" "$LLAMA_DIR"
        cd "$LLAMA_DIR"
    fi

    cd "$LLAMA_DIR"

    # Apply DP2A patch
    local CUDA_FILE="ggml/src/ggml-cuda/common.cuh"
    [[ -f "$CUDA_FILE" ]] || CUDA_FILE=$(find . -name "common.cuh" -path "*/ggml-cuda/*" | head -1)
    [[ -f "$CUDA_FILE" ]] || die "common.cuh not found."

    if grep -q "DISABLE_DP4A" "$CUDA_FILE" 2>/dev/null; then
        log_warn "DP2A patch already applied."
    else
        python3 - "$CUDA_FILE" << 'PYEOF'
import sys
fp = sys.argv[1]
with open(fp) as f: c = f.read()
old = '#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)\n    return __dp4a(a, b, c);'
old2 = '#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)\n        return __dp4a(a, b, c);'
new = '''#if __CUDA_ARCH__ >= GGML_CUDA_CC_DP4A || defined(GGML_USE_MUSA)
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
    #endif'''
if old in c:
    c = c.replace(old, new)
elif old2 in c:
    c = c.replace(old2, new)
else:
    print("NOT_FOUND"); sys.exit(1)
with open(fp, 'w') as f: f.write(c)
print("OK")
PYEOF
        [[ $? -eq 0 ]] && log_success "DP2A patch applied." || die "Patch failed."
    fi

    # Compile
    log_info "Compiling (sm_${CUDA_ARCH}, DISABLE_DP4A)..."
    rm -rf build
    cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH" \
          -DCMAKE_CUDA_FLAGS="-DDISABLE_DP4A" -DCMAKE_BUILD_TYPE=Release
    cmake --build build --config Release -j "$(nproc)"

    [[ -f "build/bin/llama-cli" ]] && log_success "Build complete!" || die "Build failed."
    printf '\n'
    log_info "Binaries: ${LLAMA_DIR}/build/bin/"
}

# ─────────────────────────────────────────────────────────────────────────────
# BENCHMARK
# ─────────────────────────────────────────────────────────────────────────────
run_benchmark() {
    log_step "BENCHMARK"
    local B="${LLAMA_DIR}/build/bin/llama-bench"
    [[ -f "$B" ]] || die "llama-bench not found. Run --build-llama first."
    "$B" -hf TheBloke/Llama-2-7B-GGUF:Q4_0 -p 512 -n 128 -ngl 99 -r 3
}

# ─────────────────────────────────────────────────────────────────────────────
# STATUS
# ─────────────────────────────────────────────────────────────────────────────
show_status() {
    log_step "CMP 90HX STATUS"
    lspci -nn | grep -i nvidia || true
    printf '\n'
    nvidia-smi 2>/dev/null || log_warn "nvidia-smi not available."
    printf '\n'
    nvidia-smi --query-gpu=pcie.link.gen.max,pcie.link.gen.current,pcie.link.width.max,pcie.link.width.current --format=csv 2>/dev/null || true
    printf '\n'
    local drv; drv=$(get_current_driver_version)
    log_info "Driver: ${drv:-unknown}"
    log_info "Kernel: $(get_current_kernel)"
    if [[ -n "$drv" ]]; then
        is_driver_supported "$drv" && log_success "Driver SUPPORTED." || log_warn "Driver NOT supported. Run: sudo $0 --driver"
    fi
    is_hiveos_kernel && log_info "Kernel is HiveOS (embedded candidate available)." \
                     || log_info "Custom kernel (candidate build required for unlock)."
}

# ─────────────────────────────────────────────────────────────────────────────
# FULL DEPLOY
# ─────────────────────────────────────────────────────────────────────────────
deploy_all() {
    log_step "FULL CMP 90HX DEPLOYMENT"
    printf '  1. Install dependencies\n'
    printf '  2. Ensure compatible driver\n'
    printf '  3. Build candidate (if custom kernel)\n'
    printf '  4. Unlock PCIe + Compute\n'
    printf '  5. Build llama.cpp with DP2A patch\n\n'
    printf 'Continue? (y/N): '
    read -r c; [[ "$c" =~ ^[Yy]$ ]] || exit 0

    install_deps
    ensure_compatible_driver
    unlock_pcie
    build_llama

    log_step "DEPLOYMENT COMPLETE!"
    printf '  Binaries: %s/build/bin/\n' "$LLAMA_DIR"
    printf '  After reboot: sudo %s --unlock\n\n' "$0"
}

# ─────────────────────────────────────────────────────────────────────────────
# HELP
# ─────────────────────────────────────────────────────────────────────────────
show_help() {
    printf '%s%sCMP 90HX Full Deploy Script v2%s\n\n' "$BOLD" "$CYAN" "$NC"
    printf 'Usage: sudo %s [OPTION]\n\n' "$0"
    printf '  %s--all%s           Full deployment\n' "$GREEN" "$NC"
    printf '  %s--driver%s        Install compatible driver\n' "$GREEN" "$NC"
    printf '  %s--unlock%s        Unlock PCIe + Compute\n' "$GREEN" "$NC"
    printf '  %s--verify%s        Verify unlock\n' "$GREEN" "$NC"
    printf '  %s--build-llama%s   Build llama.cpp + DP2A patch\n' "$GREEN" "$NC"
    printf '  %s--benchmark%s     Run benchmark\n' "$GREEN" "$NC"
    printf '  %s--status%s        GPU status\n' "$GREEN" "$NC"
    printf '  %s--deps%s          Install dependencies\n' "$GREEN" "$NC"
    printf '  %s--help%s          This help\n' "$GREEN" "$NC"
    printf '\nSupported drivers: 610.43.03, 580.159.03\n'
    printf 'Custom kernels: candidate auto-built from stockflow source.\n\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# MAIN
# ─────────────────────────────────────────────────────────────────────────────
main() {
    [[ $# -eq 0 ]] && { show_help; exit 0; }
    check_linux
    case "${1}" in
        --all)          deploy_all ;;
        --driver)       check_root; install_driver ;;
        --unlock)       unlock_pcie ;;
        --verify)       check_root; verify_unlock ;;
        --build-llama)  check_root; install_deps; build_llama ;;
        --benchmark)    run_benchmark ;;
        --status)       show_status ;;
        --deps)         check_root; install_deps ;;
        --help|-h)      show_help ;;
        *)              log_error "Unknown: $1"; show_help; exit 1 ;;
    esac
}

main "$@"
