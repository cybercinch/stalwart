#!/bin/bash
set -euo pipefail

# Stalwart Fast Cross-Compilation Build Script
# This script cross-compiles the stalwart binary outside of Docker for faster builds

# Configuration
TARGET_ARCH="${TARGET_ARCH:-x86_64-unknown-linux-gnu}"
BUILD_TYPE="${BUILD_TYPE:-release}"
# Note: cross-compiling 'rocks' requires the newer libclang provided by the
# ':main'-tagged cross images (see Cross.toml) - the default cross images
# ship libclang 3.8.x, too old for librocksdb-sys's bindgen.
FEATURES="${FEATURES:-sqlite postgres mysql rocks s3 redis azure nats enterprise}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [[ ! -f "Cargo.toml" ]] || [[ ! -d "crates/main" ]]; then
    log_error "Must be run from the Stalwart project root directory"
    exit 1
fi

log_info "Starting Stalwart cross-compilation build"
log_info "Target: $TARGET_ARCH"
log_info "Build type: $BUILD_TYPE"
log_info "Features: $FEATURES"

# Set up environment for proper libclang detection
export LIBCLANG_PATH="/usr/lib64"
export LD_LIBRARY_PATH="/usr/lib64:${LD_LIBRARY_PATH:-}"
export CLANG_PATH="/usr/bin/clang"
log_info "Using libclang from: $LIBCLANG_PATH"

# Check if cross is available for more reliable cross-compilation
if command -v cross &> /dev/null && docker info &> /dev/null 2>&1; then
    log_info "Using 'cross' for reliable cross-compilation"

    log_info "Building stalwart binary with cross..."
    if [[ "$BUILD_TYPE" == "release" ]]; then
        cross build --target "$TARGET_ARCH" --release -p stalwart --no-default-features --features "$FEATURES"
    else
        cross build --target "$TARGET_ARCH" -p stalwart --no-default-features --features "$FEATURES"
    fi
else
    log_info "Using native cargo (install 'cross' for better cross-compilation)"

    # Ensure target is installed
    log_info "Installing Rust target $TARGET_ARCH"
    rustup target add "$TARGET_ARCH"

    # Install cross-compilation tools if needed
    case "$TARGET_ARCH" in
        x86_64-unknown-linux-gnu)
            # Native build, no additional tools needed
            ;;
        aarch64-unknown-linux-gnu)
            log_info "Installing ARM64 cross-compilation tools"
            if command -v apt-get >/dev/null 2>&1; then
                sudo apt-get update && sudo apt-get install -y gcc-aarch64-linux-gnu
            elif command -v dnf >/dev/null 2>&1; then
                sudo dnf install -y gcc-aarch64-linux-gnu
            else
                log_warn "Unknown package manager, you may need to install cross-compilation tools manually"
            fi
            export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=aarch64-linux-gnu-gcc
            ;;
        *)
            log_warn "Unsupported target $TARGET_ARCH, trying anyway..."
            ;;
    esac

    log_info "Building stalwart binary..."
    if [[ "$BUILD_TYPE" == "release" ]]; then
        cargo build --target "$TARGET_ARCH" --release -p stalwart --no-default-features --features "$FEATURES"
    else
        cargo build --target "$TARGET_ARCH" -p stalwart --no-default-features --features "$FEATURES"
    fi
fi

# Set build directory
BUILD_DIR="target/$TARGET_ARCH/$BUILD_TYPE"

# Verify binary exists
if [[ ! -f "$BUILD_DIR/stalwart" ]]; then
    log_error "stalwart binary not found at $BUILD_DIR/stalwart"
    exit 1
fi

STALWART_SIZE=$(du -h "$BUILD_DIR/stalwart" | cut -f1)

log_info "Build completed successfully!"
log_info "Binary location: $BUILD_DIR/stalwart ($STALWART_SIZE)"

# Install cross if not available
if ! command -v cross &> /dev/null; then
    log_info ""
    log_info "For faster and more reliable cross-compilation, install 'cross':"
    log_info "cargo install cross"
    if ! docker info &> /dev/null 2>&1; then
        log_info "And ensure Docker is running"
    fi
fi
