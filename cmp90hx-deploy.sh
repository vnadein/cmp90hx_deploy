#!/usr/bin/env bash
###############################################################################
# CMP 90HX Full Deploy Script
# Automation: PCIe unlock + accelerated llama.cpp build (DP2A patch)
#
# Usage:
#   sudo ./cmp90hx-deploy.sh --all          # Full deploy (unlock + build)
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
CUDA_ARCH="86"

# ─────────────────────────────────────────────────────────────────────────────
# COLORS (using $'...' ANSI-C quoting for reliable interpretation)
# ─────────────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
NC=$'\033[0m'

# ─────────────────────────────────────────────────────────────────────────────
# LOGGING UTILITIES
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

check_nvidia_driver() {
    log_info "Checking NVIDIA driver..."
    if ! command -v nvidia-smi &>/dev/null; then
        die "nvidia-smi not found. Install NVIDIA Open Driver (580.159.03 or 610.43.03)."
    fi
    local driver_version
    driver_version=$(modinfo -F version nvidia 2>/dev/null || nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    log_success "NVIDIA driver version: ${driver_version}"

    if [[ "$driver_version" != "580.159.03" && "$driver_version" != "610.43.03" ]]; then
        log_warn "Driver ${driver_version} is not in the tested list (580.159.03 / 610.43.03)."
        log_warn "Unlock may not work. Proceeding at your own risk."
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
            apt-get install -y "linux-headers-$(uname -r)" 2>/dev/null || log_warn "Could not install kernel headers automatically."
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
# FUNCTION: Unlock PCIe + Compute
# ─────────────────────────────────────────────────────────────────────────────
unlock_pcie() {
    log_step "UNLOCKING PCIe + COMPUTE (cmpunlocker ${CMPUNLOCKER_VERSION})"

    check_root
    check_cmp90hx_present
    check_nvidia_driver

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
    log_info "Driver version:"
    modinfo -F version nvidia 2>/dev/null || echo "Unable to determine"

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
    printf '  Stage 2: Unlock PCIe + Compute\n'
    printf '  Stage 3: Verify unlock\n'
    printf '  Stage 4: Build llama.cpp with DP2A patch\n'
    printf '\n'
    printf 'Continue? (y/N): '
    read -r confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Cancelled."
        exit 0
    fi

    install_deps
    unlock_pcie
    build_llama

    log_step "DEPLOYMENT COMPLETE!"
    printf '\n'
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
    printf '  %s--all%s           Full deployment (unlock + build llama.cpp)\n' "$GREEN" "$NC"
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
        --unlock)       unlock_pcie ;;
        --verify)       verify_unlock ;;
        --build-llama)  install_deps; build_llama ;;
        --benchmark)    run_benchmark ;;
        --status)       show_status ;;
        --deps)         install_deps ;;
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