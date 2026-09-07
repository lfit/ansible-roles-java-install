#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 The Linux Foundation
##############################################################################
# Pre-install the JVM toolchain via SDKMAN! at image-build time.
#
#   java  : two latest LTS Temurin + latest GA Temurin + latest EA OpenJDK
#   maven : latest 3.x + latest 4.x
#   mvnd  : latest 1.0.x + latest 2.0.x
#
# Versions are resolved from the SDKMAN broker API when the image is built,
# so the image is not tied to what the distro packages.
#
#   ./install-jvm-toolchain.sh              # resolve + install
#   ./install-jvm-toolchain.sh --dry-run    # resolve + print only
#   ./install-jvm-toolchain.sh --self-check # run assertions, install nothing
##############################################################################
set -euo pipefail

SDKMAN_DIR="${SDKMAN_DIR:-/opt/sdkman}"
API="https://api.sdkman.io/2/candidates"
PLATFORM="${PLATFORM:-linuxx64}"

# Early-access builds are spelled '+ea.' upstream today and were spelled
# '.ea.' / '-ea' before that. Match every form: when the spelling changed,
# the EA lookup stopped matching and silently emptied the whole Java list.
EA_RE='(\.ea\.|-ea|\+ea\.)'

api_all() { curl -fsSL "$API/$1/$PLATFORM/versions/all" | tr ',' '\n' | grep .; }

# mvnd is platform-agnostic: /versions/all is empty, the table endpoint is not.
api_table() {
    curl -fsSL "$API/$1/$PLATFORM/versions/list?installed=" |
        sed -n '/^ *[0-9]/p' | tr -s ' ' '\n' | grep .
}

# Latest in a stream, preferring GA over pre-releases (4.0.0 beats 4.0.0-rc-5).
pick() {
    local prefix="$1" all="$2" stream ga
    stream="$(printf '%s\n' "$all" | grep -E "^${prefix}" || true)"
    ga="$(printf '%s\n' "$stream" | grep -vEi -- '-(rc|alpha|beta|m|ea)' || true)"
    [ -n "$ga" ] && stream="$ga"
    printf '%s\n' "$stream" | sort -V | tail -1
}

# LTS majors: 8, 11, 17, then every 4th release from 21 (21, 25, 29, ...).
select_java() {
    local all="$1" tem major out=()
    tem="$(printf '%s\n' "$all" | grep -E -- '-tem$' | grep -Ev -- "$EA_RE" || true)"

    for major in $(printf '%s\n' "$tem" | cut -d. -f1 | sort -un |
        awk '$1==8 || $1==11 || $1==17 || ($1>=21 && ($1-21)%4==0)' | tail -2); do
        out+=("$(printf '%s\n' "$tem" | grep -E "^${major}\." | sort -V | tail -1 || true)")
    done

    # Every lookup below is best-effort: an unmatched grep must not abort the
    # run via set -e/pipefail. resolve() checks the final list instead.
    out+=("$(printf '%s\n' "$tem" | sort -V | tail -1 || true)")
    out+=("$(printf '%s\n' "$all" | grep -E -- "${EA_RE}.*-open$" | sort -V | tail -1 || true)")

    printf '%s\n' "${out[@]}" | grep . | sort -uV || true
}

resolve() {
    local java_all maven_all mvnd_all
    java_all="$(api_all java)"
    maven_all="$(api_all maven)"
    mvnd_all="$(api_table mvnd)"

    JAVA_VERSIONS=()
    mapfile -t JAVA_VERSIONS < <(select_java "$java_all")
    # install_all defaults to JAVA_VERSIONS[1], so fewer than two entries is
    # unusable. Fail here with a diagnosable message rather than dying later
    # on an unbound array index.
    if [ "${#JAVA_VERSIONS[@]}" -lt 2 ]; then
        echo "ERROR: resolved ${#JAVA_VERSIONS[@]} Java version(s), expected at least 2." >&2
        echo "ERROR: the upstream version format has probably changed; compare" >&2
        echo "ERROR: select_java() against $API/java/$PLATFORM/versions/all" >&2
        exit 1
    fi
    MAVEN_VERSIONS=("$(pick '3\.' "$maven_all")" "$(pick '4\.' "$maven_all")")
    MVND_VERSIONS=("$(pick '1\.0\.' "$mvnd_all")" "$(pick '2\.0\.' "$mvnd_all")")
}

install_sdkman() {
    if [ ! -d "$SDKMAN_DIR" ]; then
        curl -fsSL "https://get.sdkman.io?rcupdate=false" | bash
    fi
    # Non-interactive, and never self-update inside a baked image.
    sed -i 's/^sdkman_auto_answer=.*/sdkman_auto_answer=true/;
            s/^sdkman_selfupdate=.*/sdkman_selfupdate=false/' "$SDKMAN_DIR/etc/config"
}

verify_installed() {
    local candidate="$1" version
    shift
    for version in "$@"; do
        if [ ! -d "$SDKMAN_DIR/candidates/$candidate/$version" ]; then
            echo "ERROR: $candidate $version was not installed" >&2
            exit 1
        fi
    done
}

install_all() {
    local version

    # SDKMAN!'s shell functions are not `set -u` clean, so relax it while they
    # run and verify the installed candidates explicitly afterwards instead.
    set +u
    # shellcheck disable=SC1091
    source "$SDKMAN_DIR/bin/sdkman-init.sh"

    for version in "${JAVA_VERSIONS[@]}"; do sdk install java "$version"; done
    for version in "${MAVEN_VERSIONS[@]}"; do sdk install maven "$version"; done
    for version in "${MVND_VERSIONS[@]}"; do sdk install mvnd "$version"; done

    # Conservative defaults: newest LTS Java, Maven 3.x, mvnd 1.0.x.
    sdk default java "${JAVA_VERSIONS[1]}"
    sdk default maven "${MAVEN_VERSIONS[0]}"
    sdk default mvnd "${MVND_VERSIONS[0]}"
    set -u

    verify_installed java "${JAVA_VERSIONS[@]}"
    verify_installed maven "${MAVEN_VERSIONS[@]}"
    verify_installed mvnd "${MVND_VERSIONS[@]}"

    # ponytail: world-readable shared install; per-user SDKMAN_DIR only if
    # jobs ever need to `sdk install` at runtime.
    chmod -R a+rX "$SDKMAN_DIR"
    # shellcheck disable=SC2016  # $SDKMAN_DIR must stay literal in the profile
    printf 'export SDKMAN_DIR=%s\n[ -s "$SDKMAN_DIR/bin/sdkman-init.sh" ] && . "$SDKMAN_DIR/bin/sdkman-init.sh"\n' \
        "$SDKMAN_DIR" >/etc/profile.d/sdkman.sh
}

self_check() {
    local all java
    all='8.0.492-tem
11.0.32-tem
17.0.20-tem
21.0.11-tem
21.0.12-tem
21.0.2-open
25.0.2-open
25.0.3-tem
26.0.1-open
26.0.1-tem
26.ea.35-open
27.ea.24-open
27.ea.31-open'
    java="$(select_java "$all")"
    [ "$java" = '21.0.12-tem
25.0.3-tem
26.0.1-tem
27.ea.31-open' ] || { echo "FAIL java: $java" >&2; exit 1; }

    # Current upstream spelling: '+ea.' pre-releases and '+N' build suffixes
    # on Temurin. This exact shape used to resolve to an empty list.
    all='8.0.504+1-tem
11.0.32+1.1-tem
17.0.20-tem
21.0.12+1.1-tem
21.0.2-open
25.0.2-open
25.0.4-tem
26.0.2+1.1-open
26.0.2+1.1-tem
27.0.0+ea.34-open
27.0.0+ea.35-open
28.0.0+ea.14-open'
    java="$(select_java "$all")"
    [ "$java" = '21.0.12+1.1-tem
25.0.4-tem
26.0.2+1.1-tem
28.0.0+ea.14-open' ] || { echo "FAIL java ea-plus: $java" >&2; exit 1; }

    # No EA build published at all: the LTS/GA set must still resolve.
    java="$(select_java '17.0.20-tem
21.0.12+1.1-tem
25.0.4-tem')"
    [ "$java" = '21.0.12+1.1-tem
25.0.4-tem' ] || { echo "FAIL java no-ea: $java" >&2; exit 1; }

    # GA wins over a pre-release in the same stream.
    [ "$(pick '4\.' '4.0.0-rc-4
4.0.0-rc-5')" = '4.0.0-rc-5' ] || { echo 'FAIL rc-only' >&2; exit 1; }
    [ "$(pick '4\.' '4.0.0-rc-5
4.0.0')" = '4.0.0' ] || { echo 'FAIL ga-preferred' >&2; exit 1; }
    [ "$(pick '3\.' '3.9.9
3.9.11
4.0.0')" = '3.9.11' ] || { echo 'FAIL maven3' >&2; exit 1; }

    echo 'self-check OK'
}

main() {
    case "${1:-}" in
        --self-check) self_check; return ;;
    esac

    resolve
    printf 'java:  %s\n' "${JAVA_VERSIONS[@]}"
    printf 'maven: %s\n' "${MAVEN_VERSIONS[@]}"
    printf 'mvnd:  %s\n' "${MVND_VERSIONS[@]}"

    if [ "${1:-}" = '--dry-run' ]; then return; fi
    install_sdkman
    install_all
}

main "$@"
