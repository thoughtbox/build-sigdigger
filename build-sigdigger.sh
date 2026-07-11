#!/usr/bin/env bash
#
# this is for https://github.com/BatchDrake/SigDigger
#
# Build and install SigDigger and its dependencies:
#   sigutils -> suscan -> SuWidgets -> SigDigger
#
# SPDX-License-Identifier: MIT
#
set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM_NAME="${0##*/}"
readonly VERSION="3.0"

PREFIX="${HOME}/.local/sigdigger"
WORKDIR="${PWD}/sigdigger-build"
JOBS=""
BUILD_TYPE="Release"
UPDATE=0
CLEAN=0
ASSUME_YES=0
NO_LAUNCHER=0
VERBOSE=0

CURRENT_STEP="initialisation"
START_SECONDS=${SECONDS}

usage() {
    cat <<EOF
${PROGRAM_NAME} ${VERSION}
Build and install SigDigger and its dependencies.

USAGE
  ${PROGRAM_NAME} [OPTIONS] [INSTALL_PREFIX]

ARGUMENTS
  INSTALL_PREFIX          Installation directory. This is equivalent to
                          --prefix. The default is:

                              ${HOME}/.local/sigdigger

OPTIONS
  -p, --prefix PATH       Installation prefix.
  -w, --workdir PATH      Directory used for source checkouts and builds.
                          Default: ${PWD}/sigdigger-build
  -j, --jobs NUMBER       Number of parallel build jobs.
                          Default: number of available CPU cores.
      --build-type TYPE   CMake build type: Release, Debug, RelWithDebInfo,
                          or MinSizeRel. Default: Release.
  -u, --update            Fast-forward existing Git checkouts and update
                          their submodules before building.
  -c, --clean             Delete existing per-project build directories
                          before configuring.
  -y, --yes               Do not ask for confirmation.
      --no-launcher       Do not create the lowercase 'sigdigger' launcher.
  -v, --verbose           Enable verbose CMake and make output.
      --version           Print the script version and exit.
  -h, --help              Print this help and exit.

EXAMPLES
  Install for the current user:

      ./${PROGRAM_NAME}

  Install into a chosen directory:

      ./${PROGRAM_NAME} --prefix "\$HOME/apps/sigdigger"

  Update all repositories and perform a clean rebuild:

      ./${PROGRAM_NAME} --update --clean

  Build with eight parallel jobs without prompting:

      ./${PROGRAM_NAME} --jobs 8 --yes

  Install system-wide:

      sudo ./${PROGRAM_NAME} --prefix /opt/sigdigger --yes

NOTES
  * A user-owned prefix does not require sudo.
  * The script does not install operating-system packages. It checks for the
    required build tools and reports any that are missing.
  * Existing source checkouts are reused. They are changed only when --update
    is supplied.
  * Add PREFIX/bin to PATH after installation, or run the printed command.
EOF
}

colour_enabled() {
    [[ -t 1 && -z ${NO_COLOR:-} ]]
}

colour() {
    local code=$1
    shift
    if colour_enabled; then
        printf '\033[%sm%s\033[0m' "${code}" "$*"
    else
        printf '%s' "$*"
    fi
}

info()    { printf '%s %s\n' "$(colour '1;34' '[INFO]')" "$*"; }
success() { printf '%s %s\n' "$(colour '1;32' '[ OK ]')" "$*"; }
warn()    { printf '%s %s\n' "$(colour '1;33' '[WARN]')" "$*" >&2; }
fatal()   { printf '%s %s\n' "$(colour '1;31' '[FAIL]')" "$*" >&2; exit 1; }

print_debian_install_help() {
    cat >&2 <<'EOF'

On Debian/Ubuntu, install the required build dependencies with:

  sudo apt update
  sudo apt install build-essential git cmake pkg-config qmake6 qmake6-bin qt6-base-dev qt6-l10n-tools libsndfile1-dev libfftw3-dev libsoapysdr-dev libxml2-dev libvolk-dev libcpu-features-dev libasound2-dev

If ALSA development files are unavailable on your system, install PortAudio instead:

  sudo apt install portaudio19-dev
EOF
}

on_error() {
    local status=$?
    printf '\n%s Step failed: %s\n' \
        "$(colour '1;31' '[FAIL]')" "${CURRENT_STEP}" >&2
    printf '       Command: %s\n' "${BASH_COMMAND}" >&2
    printf '       Line: %s, exit status: %s\n' \
        "${BASH_LINENO[0]:-unknown}" "${status}" >&2
    exit "${status}"
}
trap on_error ERR
trap 'printf "\nInterrupted.\n" >&2; exit 130' INT TERM

require_value() {
    (($# >= 2)) || fatal "$1 requires a value"
}

parse_arguments() {
    local positional_prefix_set=0

    while (($#)); do
        case "$1" in
            -p|--prefix)
                require_value "$@"
                PREFIX=$2
                positional_prefix_set=1
                shift 2
                ;;
            -w|--workdir)
                require_value "$@"
                WORKDIR=$2
                shift 2
                ;;
            -j|--jobs)
                require_value "$@"
                JOBS=$2
                shift 2
                ;;
            --build-type)
                require_value "$@"
                BUILD_TYPE=$2
                shift 2
                ;;
            -u|--update)
                UPDATE=1
                shift
                ;;
            -c|--clean)
                CLEAN=1
                shift
                ;;
            -y|--yes)
                ASSUME_YES=1
                shift
                ;;
            --no-launcher)
                NO_LAUNCHER=1
                shift
                ;;
            -v|--verbose)
                VERBOSE=1
                shift
                ;;
            --version)
                printf '%s %s\n' "${PROGRAM_NAME}" "${VERSION}"
                exit 0
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            --)
                shift
                break
                ;;
            -*)
                fatal "unknown option: $1 (try --help)"
                ;;
            *)
                ((positional_prefix_set == 0)) ||
                    fatal "only one installation prefix may be supplied"
                PREFIX=$1
                positional_prefix_set=1
                shift
                ;;
        esac
    done

    (($# == 0)) || fatal "unexpected argument: $1"
}

detect_jobs() {
    [[ -n ${JOBS} ]] && return

    if command -v nproc >/dev/null 2>&1; then
        JOBS=$(nproc)
    elif command -v getconf >/dev/null 2>&1; then
        JOBS=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1')
    elif command -v sysctl >/dev/null 2>&1; then
        JOBS=$(sysctl -n hw.ncpu 2>/dev/null || printf '1')
    else
        JOBS=1
    fi
}

validate_options() {
    [[ ${JOBS} =~ ^[1-9][0-9]*$ ]] ||
        fatal "--jobs must be a positive integer"

    case "${BUILD_TYPE}" in
        Release|Debug|RelWithDebInfo|MinSizeRel) ;;
        *) fatal "unsupported build type: ${BUILD_TYPE}" ;;
    esac
}

check_commands() {
    CURRENT_STEP="checking build tools"
    local missing=()
    local command_name

    for command_name in git cmake make pkg-config qmake6; do
        command -v "${command_name}" >/dev/null 2>&1 ||
            missing+=("${command_name}")
    done

    if ((${#missing[@]})); then
        printf '%s Missing required build commands:\n' \
            "$(colour '1;31' '[FAIL]')" >&2
        printf '         - %s\n' "${missing[@]}" >&2
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            print_debian_install_help
        else
            printf '\nInstall the corresponding development packages, then rerun this script.\n' >&2
        fi
        exit 1
    fi
}

check_pkg_config_modules() {
    CURRENT_STEP="checking development libraries"
    local missing=()
    local module_name

    for module_name in sndfile fftw3f SoapySDR libxml-2.0 volk; do
        pkg-config --exists "${module_name}" || missing+=("${module_name}")
    done

    if ! pkg-config --exists alsa && ! pkg-config --exists portaudio-2.0; then
        missing+=("alsa or portaudio-2.0")
    fi

    if ((${#missing[@]})); then
        printf '%s Missing required pkg-config modules:\n' \
            "$(colour '1;31' '[FAIL]')" >&2
        printf '         - %s\n' "${missing[@]}" >&2
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            print_debian_install_help
        else
            printf '\nInstall the corresponding development packages, then rerun this script.\n' >&2
        fi
        exit 1
    fi
}

check_qt_modules() {
    CURRENT_STEP="checking Qt development files"
    local missing=()
    local module_name

    for module_name in Qt6Core Qt6Gui Qt6Widgets Qt6OpenGL Qt6OpenGLWidgets; do
        pkg-config --exists "${module_name}" || missing+=("${module_name}")
    done

    if ((${#missing[@]})); then
        printf '%s Missing required Qt 6 pkg-config modules:\n' \
            "$(colour '1;31' '[FAIL]')" >&2
        printf '         - %s\n' "${missing[@]}" >&2
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            print_debian_install_help
        else
            printf '\nInstall the corresponding Qt 6 development packages, then rerun this script.\n' >&2
        fi
        exit 1
    fi
}

check_qt_tools() {
    CURRENT_STEP="checking Qt build tools"

    if [[ ! -x /usr/lib/qt6/bin/lrelease ]] && ! command -v lrelease >/dev/null 2>&1; then
        printf '%s Missing required Qt translation tool: lrelease\n' \
            "$(colour '1;31' '[FAIL]')" >&2
        if command -v apt-get >/dev/null 2>&1 || command -v apt >/dev/null 2>&1; then
            print_debian_install_help
        else
            printf '\nInstall the package that provides lrelease, then rerun this script.\n' >&2
        fi
        exit 1
    fi
}

canonicalise_directories() {
    CURRENT_STEP="preparing directories"

    mkdir -p "${PREFIX}" "${WORKDIR}"
    PREFIX=$(cd "${PREFIX}" && pwd -P)
    WORKDIR=$(cd "${WORKDIR}" && pwd -P)

    local test_file="${PREFIX}/.sigdigger-write-test.$$"
    if ! : >"${test_file}" 2>/dev/null; then
        fatal "installation prefix is not writable: ${PREFIX}"
    fi
    rm -f "${test_file}"
}

print_configuration() {
    cat <<EOF

Configuration
-------------
Install prefix : ${PREFIX}
Working tree   : ${WORKDIR}
Build type     : ${BUILD_TYPE}
Parallel jobs  : ${JOBS}
Update sources : $( ((UPDATE)) && printf 'yes' || printf 'no' )
Clean builds   : $( ((CLEAN)) && printf 'yes' || printf 'no' )
Create launcher: $( ((NO_LAUNCHER)) && printf 'no' || printf 'yes' )
Verbose output : $( ((VERBOSE)) && printf 'yes' || printf 'no' )

Projects
--------
  1. sigutils
  2. suscan
  3. SuWidgets
  4. SigDigger

EOF
}

confirm() {
    ((ASSUME_YES)) && return

    local answer
    read -r -p "Continue? [Y/n] " answer
    case "${answer}" in
        ""|y|Y|yes|YES|Yes) ;;
        *) printf 'Cancelled.\n'; exit 0 ;;
    esac
}

configure_environment() {
    export PATH="${PREFIX}/bin:${PATH}"
    export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PREFIX}/lib64/pkgconfig:${PREFIX}/share/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
    export CMAKE_PREFIX_PATH="${PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
    export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
}

clone_or_update() {
    local name=$1
    local url=$2
    local recursive=${3:-0}
    local directory="${WORKDIR}/${name}"

    CURRENT_STEP="obtaining ${name}"

    if [[ -d "${directory}/.git" ]]; then
        if ((UPDATE)); then
            info "Updating ${name}"
            git -C "${directory}" pull --ff-only
            if ((recursive)); then
                git -C "${directory}" submodule sync --recursive
                git -C "${directory}" submodule update --init --recursive
            fi
        else
            info "Reusing ${directory}"
        fi
        return
    fi

    [[ ! -e ${directory} ]] ||
        fatal "${directory} exists but is not a Git checkout"

    info "Cloning ${name}"
    if ((recursive)); then
        git clone --recursive "${url}" "${directory}"
    else
        git clone "${url}" "${directory}"
    fi
}

cmake_cache_matches_source() {
    local build_dir=$1
    local source_dir=$2
    local cache_file="${build_dir}/CMakeCache.txt"
    local recorded_source=""

    [[ -f ${cache_file} ]] || return 0

    while IFS= read -r line; do
        if [[ ${line} == CMAKE_HOME_DIRECTORY:INTERNAL=* ]]; then
            recorded_source=${line#CMAKE_HOME_DIRECTORY:INTERNAL=}
            break
        fi
    done < "${cache_file}"

    [[ -z ${recorded_source} || ${recorded_source} == "${source_dir}" ]]
}

build_cmake_project() {
    local name=$1
    local source_dir="${WORKDIR}/${name}"
    local build_dir="${source_dir}/build-v3"
    local build_args=(--parallel "${JOBS}")

    CURRENT_STEP="configuring ${name}"
    ((CLEAN)) && rm -rf "${build_dir}"

    if ! cmake_cache_matches_source "${build_dir}" "${source_dir}"; then
        warn "Removing stale build directory for ${name}: ${build_dir}"
        rm -rf "${build_dir}"
    fi

    info "Configuring ${name}"
    cmake -S "${source_dir}" -B "${build_dir}" \
        -DCMAKE_BUILD_TYPE="${BUILD_TYPE}" \
        -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
        -DCMAKE_INSTALL_RPATH="${PREFIX}/lib;${PREFIX}/lib64" \
        -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=TRUE

    ((VERBOSE)) && build_args+=(--verbose)

    CURRENT_STEP="building ${name}"
    info "Building ${name}"
    cmake --build "${build_dir}" "${build_args[@]}"

    CURRENT_STEP="installing ${name}"
    info "Installing ${name}"
    cmake --install "${build_dir}"

    success "${name} installed"
}

build_qmake_project() {
    local name=$1
    local project_file=$2
    shift 2

    local source_dir="${WORKDIR}/${name}"
    local build_dir="${source_dir}/build-v3"
    local make_args=(-j "${JOBS}")

    CURRENT_STEP="configuring ${name}"
    ((CLEAN)) && rm -rf "${build_dir}"
    mkdir -p "${build_dir}"

    info "Configuring ${name}"
    (
        cd "${build_dir}"
        qmake6 "${source_dir}/${project_file}" \
            PREFIX="${PREFIX}" \
            QMAKE_RPATHDIR+="${PREFIX}/lib" \
            QMAKE_RPATHDIR+="${PREFIX}/lib64" \
            "$@"
    )

    ((VERBOSE)) && make_args+=(VERBOSE=1)

    CURRENT_STEP="building ${name}"
    info "Building ${name}"
    make -C "${build_dir}" "${make_args[@]}"

    CURRENT_STEP="installing ${name}"
    info "Installing ${name}"
    make -C "${build_dir}" install

    success "${name} installed"
}

create_launcher() {
    ((NO_LAUNCHER)) && return

    CURRENT_STEP="creating launcher"
    mkdir -p "${PREFIX}/bin"

    local executable=""
    local candidate
    for candidate in \
        "${PREFIX}/bin/SigDigger" \
        "${PREFIX}/bin/sigdigger-bin"; do
        if [[ -x ${candidate} ]]; then
            executable=${candidate}
            break
        fi
    done

    if [[ -z ${executable} ]]; then
        warn "Could not identify the installed SigDigger executable; launcher not created."
        return
    fi

    # Do not replace the real executable if upstream installs it in lowercase.
    if [[ ${executable} == "${PREFIX}/bin/sigdigger" ]]; then
        return
    fi

    cat >"${PREFIX}/bin/sigdigger" <<EOF
#!/usr/bin/env sh
PREFIX='${PREFIX}'
export LD_LIBRARY_PATH="\${PREFIX}/lib:\${PREFIX}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
exec '${executable}' "\$@"
EOF
    chmod 0755 "${PREFIX}/bin/sigdigger"
    success "Created ${PREFIX}/bin/sigdigger"
}

build_all() {
    clone_or_update sigutils  "https://github.com/BatchDrake/sigutils.git" 1
    clone_or_update suscan    "https://github.com/BatchDrake/suscan.git" 1
    clone_or_update SuWidgets "https://github.com/BatchDrake/SuWidgets.git"
    clone_or_update SigDigger "https://github.com/BatchDrake/SigDigger.git"

    build_cmake_project sigutils
    build_cmake_project suscan
    build_qmake_project SuWidgets SuWidgetsLib.pro
    build_qmake_project SigDigger SigDigger.pro \
        SUWIDGETS_PREFIX="${PREFIX}"

    create_launcher
}

print_completion() {
    local elapsed=$((SECONDS - START_SECONDS))
    local executable="${PREFIX}/bin/sigdigger"

    [[ -x ${executable} ]] ||
        executable="${PREFIX}/bin/SigDigger"

    printf '\n'
    success "Installation completed in $((elapsed / 60))m $((elapsed % 60))s"
    printf '\nInstalled under:\n  %s\n' "${PREFIX}"

    if [[ -x ${executable} ]]; then
        printf '\nRun SigDigger:\n  %q\n' "${executable}"
    fi

    cat <<EOF

To make the installed commands available in future shells, add this line to
your shell profile:

  export PATH="${PREFIX}/bin:\$PATH"

The launcher sets the required library path automatically. Other programs
using these installed libraries may also need:

  export LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib64\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}"
EOF
}

main() {
    parse_arguments "$@"
    detect_jobs
    validate_options
    check_commands
    check_pkg_config_modules
    check_qt_modules
    check_qt_tools
    canonicalise_directories
    print_configuration
    confirm
    configure_environment
    build_all
    print_completion
}

main "$@"
