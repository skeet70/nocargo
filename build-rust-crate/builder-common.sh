declare -a buildFlagsArray
buildFlagsArray+=(
    --color=always
    -C codegen-units=$NIX_BUILD_CORES
)

if [[ -n "${optLevel:-}" ]]; then
    buildFlagsArray+=(-C opt-level="$optLevel")
fi
if [[ -n "${debug:-}" ]]; then
    buildFlagsArray+=(-C debuginfo="$debug")
fi
if [[ -n "${debugAssertions:-}" ]]; then
    buildFlagsArray+=(-C debug-assertions=yes)
else
    buildFlagsArray+=(-C debug-assertions=no)
fi

# Collect all transitive dependencies (symlinks).
collectTransDeps() {
    local collectDir="$1" line name binName depOut depDev
    mkdir -p "$collectDir"
    shift
    for line in "$@"; do
        IFS=: read -r name binName depOut depDev <<<"$line"
        # May be empty.
        cp --no-dereference --no-clobber -t $collectDir $depDev/rust-support/deps-closure/* 2>/dev/null || true
    done
}

addExternFlags() {
    local var="$1" kind="$2" line name binName depOut depDev path
    shift 2
    for line in "$@"; do
        IFS=: read -r name binName depOut depDev <<<"$line"

        if [[ -e "$depOut/lib/$binName$sharedLibraryExt" ]]; then
            path="$depOut/lib/$binName$sharedLibraryExt"
        elif [[ "$kind" == meta ]]; then
            path="$depDev/lib/$binName.rmeta"
        elif [[ -e "$depOut/lib/$binName.rlib" ]]; then
            path="$depOut/lib/$binName.rlib"
        elif [[ -e "$depOut/lib/$binName$sharedLibraryExt" ]]; then
            path="$depOut/lib/$binName$sharedLibraryExt"
        fi

        if [[ ! -e "$path" ]]; then
            echo "No linkable file found for $line"
            exit 1
        fi
        eval "$var"'+=(--extern "$name=$path")'
    done
}

addFeatures() {
    local var="$1" feat
    shift
    for feat in "$@"; do
        eval "$var"'+=(--cfg "feature=\"$feat\"")'
    done
}

importBuildOut() {
    local var="$1" drv="$2" crateType="$3" flags
    [[ ! -e "$drv/rust-support/build-stdout" ]] && return

    echo export OUT_DIR="$drv/rust-support/out-dir"
    export OUT_DIR="$drv/rust-support/out-dir"

    cat "$drv/rust-support/rustc-envs"
    source "$drv/rust-support/rustc-envs"

    mapfile -t flags <"$drv/rust-support/rustc-flags"
    eval "$var"'+=("${flags[@]}")'

    if [[ "$crateType" == cdylib ]]; then
        mapfile -t flags <"$drv/rust-support/cdylib-flags"
        eval "$var"'+=("${flags[@]}")'
    fi

    if [[ -n "${dev:-}" ]]; then
        mkdir -p "$dev/rust-support"
        cp -t "$dev/rust-support" "$drv/rust-support/dependent-meta"
    fi
}

runRustc() {
    local msg="$1"
    shift
    echo "$msg: RUSTC ${*@Q}"
    $RUSTC "$@"
}

convertCargoToml() {
    local cargoToml="${1:-"$(pwd)/Cargo.toml"}"
    cargoTomlJson="$(mktemp "$(dirname "$cargoToml")/Cargo.json.XXX")"
    toml2json <"$cargoToml" >"$cargoTomlJson"
}

# https://doc.rust-lang.org/cargo/reference/environment-variables.html#environment-variables-cargo-sets-for-crates
setCargoCommonBuildEnv() {
    # export CARGO=
    CARGO_MANIFEST_DIR="$(dirname "$cargoTomlJson")"
    export CARGO_MANIFEST_DIR
    export CARGO_CRATE_NAME="$crateName"
    export CARGO_PKG_VERSION="$version"

    CARGO_PKG_NAME="$(jq '.package.name // ""' "$cargoTomlJson")"
    CARGO_PKG_AUTHORS="$(jq '.package.authors // [] | join(":")' "$cargoTomlJson")"
    CARGO_PKG_DESCRIPTION="$(jq '.package.description // ""' "$cargoTomlJson")"
    CARGO_PKG_HOMEPAGE="$(jq '.package.homepage // ""' "$cargoTomlJson")"
    CARGO_PKG_LICENSE="$(jq '.package.license // ""' "$cargoTomlJson")"
    CARGO_PKG_LICENSE_FILE="$(jq '.package."license-file" // ""' "$cargoTomlJson")"
    export CARGO_PKG_NAME CARGO_PKG_AUTHORS CARGO_PKG_DESCRIPTION \
        CARGO_PKG_HOMEPAGE CARGO_PKG_LICENSE CARGO_PKG_LICENSE_FILE

    if [[ "$version" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)(-([A-Za-z0-9.-]+))?(\+.*)?$ ]]; then
        export CARGO_PKG_VERSION_MAJOR="${BASH_REMATCH[0]}"
        export CARGO_PKG_VERSION_MINOR="${BASH_REMATCH[1]}"
        export CARGO_PKG_VERSION_PATCH="${BASH_REMATCH[2]}"
        export CARGO_PKG_VERSION_PRE="${BASH_REMATCH[4]}"
    else
        echo "Invalid version: $version"
    fi
}
