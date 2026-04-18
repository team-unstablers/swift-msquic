#!/usr/bin/env bash
#
# build-msquic-linux.sh
#
# Fetches and builds msquic as a static library for Linux, then packages
# it into SwiftPM-compatible .artifactbundle directories (SE-0482).
#
# Usage:
#   ./scripts/build-msquic-linux.sh [--release] [--debug] [--clean]
#
# If neither --release nor --debug is specified, both are built.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ────────────────────────────────────────────────────────────
MSQUIC_REPO="https://github.com/team-unstablers/msquic.git"
MSQUIC_TAG="v2.5.6-tuvariant+260410"
MSQUIC_VERSION="2.5.6"

WORK_DIR="$PROJECT_ROOT/.build/msquic-build"
CLONE_DIR="$WORK_DIR/msquic"

# Detect host triple
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  TRIPLE="x86_64-unknown-linux-gnu" ;;
    aarch64) TRIPLE="aarch64-unknown-linux-gnu" ;;
    *)       echo "error: unsupported architecture: $ARCH" >&2; exit 1 ;;
esac

# ── Parse arguments ──────────────────────────────────────────────────────────
BUILD_RELEASE=false
BUILD_DEBUG=false
CLEAN=false

for arg in "$@"; do
    case "$arg" in
        --release) BUILD_RELEASE=true ;;
        --debug)   BUILD_DEBUG=true ;;
        --clean)   CLEAN=true ;;
        --help|-h)
            echo "Usage: $0 [--release] [--debug] [--clean]"
            exit 0
            ;;
        *) echo "error: unknown argument: $arg" >&2; exit 1 ;;
    esac
done

# Default: build both
if ! $BUILD_RELEASE && ! $BUILD_DEBUG; then
    BUILD_RELEASE=true
    BUILD_DEBUG=true
fi

if $CLEAN; then
    echo "==> Cleaning build directory..."
    rm -rf "$WORK_DIR"
    rm -rf "$PROJECT_ROOT/MsQuic.artifactbundle"
    rm -rf "$PROJECT_ROOT/MsQuicDebug.artifactbundle"
fi

# ── Clone ────────────────────────────────────────────────────────────────────
if [ ! -d "$CLONE_DIR/.git" ]; then
    echo "==> Cloning msquic ($MSQUIC_TAG)..."
    mkdir -p "$WORK_DIR"
    git clone --recursive --depth 1 --branch "$MSQUIC_TAG" "$MSQUIC_REPO" "$CLONE_DIR"
else
    echo "==> msquic source already present, skipping clone."
fi

HEADER_SRC="$CLONE_DIR/src/inc"

# ── Build function ───────────────────────────────────────────────────────────
build_msquic() {
    local BUILD_TYPE="$1"        # Release or Debug
    local BUNDLE_NAME="$2"       # MsQuic or MsQuicDebug
    local BUILD_DIR="$WORK_DIR/build-$(echo "$BUILD_TYPE" | tr '[:upper:]' '[:lower:]')"
    local BUNDLE_DIR="$PROJECT_ROOT/$BUNDLE_NAME.artifactbundle"

    echo "==> Building msquic ($BUILD_TYPE)..."
    cmake -S "$CLONE_DIR" -B "$BUILD_DIR" \
        -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
        -DQUIC_BUILD_SHARED=OFF \
        -DQUIC_BUILD_TOOLS=OFF \
        -DQUIC_BUILD_TEST=OFF \
        -DQUIC_BUILD_PERF=OFF

    cmake --build "$BUILD_DIR" --target msquic_lib -- -j"$(nproc)"

    # Locate the monolithic static library
    local LIB_FILE
    LIB_FILE="$(find "$BUILD_DIR" -name 'libmsquic.a' -print -quit)"
    if [ -z "$LIB_FILE" ]; then
        echo "error: libmsquic.a not found in $BUILD_DIR" >&2
        exit 1
    fi

    echo "==> Packaging $BUNDLE_NAME.artifactbundle..."
    rm -rf "$BUNDLE_DIR"
    mkdir -p "$BUNDLE_DIR/include"

    # Copy the static library
    cp "$LIB_FILE" "$BUNDLE_DIR/libmsquic.a"

    # Copy public headers
    local HEADERS=(
        msquic.h msquic.hpp msquic_fuzz.h msquic_posix.h msquichelper.h msquicp.h
        quic_cert.h quic_crypt.h quic_datapath.h quic_driver_helpers.h
        quic_hashtable.h quic_pcp.h quic_platform.h quic_platform_posix.h
        quic_sal_stub.h quic_storage.h quic_tls.h quic_toeplitz.h
        quic_trace.h quic_trace_manifested_etw.h quic_var_int.h quic_versions.h
    )
    for h in "${HEADERS[@]}"; do
        if [ -f "$HEADER_SRC/$h" ]; then
            cp "$HEADER_SRC/$h" "$BUNDLE_DIR/include/$h"
        fi
    done

    # Create module.modulemap
    cat > "$BUNDLE_DIR/include/module.modulemap" <<'EOF'
module MsQuic [system] {
  header "msquic.h"
  export *
}
EOF

    # Create info.json (SE-0482 format)
    cat > "$BUNDLE_DIR/info.json" <<INFOJSON
{
    "schemaVersion": "1.0",
    "artifacts": {
        "$BUNDLE_NAME": {
            "version": "$MSQUIC_VERSION",
            "type": "staticLibrary",
            "variants": [
                {
                    "path": "libmsquic.a",
                    "supportedTriples": ["$TRIPLE"],
                    "staticLibraryMetadata": {
                        "headerPaths": ["include"],
                        "moduleMapPath": "include/module.modulemap"
                    }
                }
            ]
        }
    }
}
INFOJSON

    echo "==> $BUNDLE_DIR created successfully."
}

# ── Execute builds ───────────────────────────────────────────────────────────
if $BUILD_RELEASE; then
    build_msquic Release MsQuic
fi

if $BUILD_DEBUG; then
    build_msquic Debug MsQuicDebug
fi

echo ""
echo "Done. Artifact bundles are ready at the project root."
echo "Run 'swift build' to use them."
