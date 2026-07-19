#!/bin/sh
#-------------------------------------------------------#
## GOALS:
# - Universal AppRun for all NixAppImages (CLI/GUI/Everything)
# - Handle ARGV0, Symlinks, CMDLINE ARGS accurately
# - Host-Blending Architecture shadowed by private /run tmpfs
# - Native nixGL Emulation: Map internal Nix Mesa drivers to variables
# - Bundled-First Bwrap execution to eliminate cross-distro Musl/Glibc conflicts
# - Full Hardware 3D Acceleration (Intel/AMD) without Glibc Mismatches
#-------------------------------------------------------#

if [ "${DEBUG}" = "1" ]; then
    set -x
fi

## Check PATH
if [ -z "${PATH}" ] || [ "${PATH}" = "" ]; then
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
else
    case "${PATH}" in
        */*:* | *:*/*)
            if ! which basename du cut dirname getent printf realpath readlink >/dev/null 2>&1; then
                PATH="${PATH}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            fi
            ;;
        *)
            PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
            ;;
    esac
fi

if ! which basename du cut dirname getent printf realpath readlink >/dev/null 2>&1; then
   echo "ERROR: Coreutils (Busybox) commands not found anywhere in \$PATH (${PATH})"
   exit 1
fi

## HELP Menu
if [ "${SHOW_HELP}" = "1" ] || [ "${SHOW_HELP}" = "ON" ]; then
  printf "\n" ; echo "AppRun Helper Format: NixAppImage (https://l.ajam.dev/nixappimage)"
  echo "Set ENV (\$VARIABLE=1 | \$VARIABLE=ON) or Run With: \$VARIABLE=1 \"/path/to/\$APP.NixAppImage\""
  echo "VARIABLES:"
  echo "SHOW_HELP --> Toggle Help Message"
  echo "VERBOSE --> Toggle Verbose Mode"
  echo "DEBUG --> Toggle Debug Mode"
  printf "\n" ; exit 0
fi

## Get/Set ENV Vars (From Pkg)
SELF_PATH="$(dirname "$(realpath "$0")")" ; export SELF_PATH
SELF_NAME="${ARGV0:-${0##*/}}" ; export SELF_NAME
PATH="${SELF_PATH}/usr/bin:${PATH}"
export PATH

## Rilevamento di Bubblewrap (Bundled-First per consistenza assoluta glibc/musl)
case "${BWRAP_MODE}" in
  "LATEST")   BWRAP_BIN="${SELF_PATH}/bwrap-bin" ;;
  "PATCHED")  BWRAP_BIN="${SELF_PATH}/bwrap-patched" ;;
  "SYSTEM")
    if which bwrap >/dev/null 2>&1; then
        BWRAP_BIN="$(which bwrap)"
    else
        BWRAP_BIN="${SELF_PATH}/bwrap"
    fi
    ;;
  *)
    if [ -e "${SELF_PATH}/bwrap" ]; then
        BWRAP_BIN="${SELF_PATH}/bwrap"
    elif [ -e "${SELF_PATH}/bwrap-bin" ]; then
        BWRAP_BIN="${SELF_PATH}/bwrap-bin"
    elif which bwrap >/dev/null 2>&1; then
        BWRAP_BIN="$(which bwrap)"
    fi
    ;;
esac
export BWRAP_BIN

if [ ! -e "${BWRAP_BIN}" ]; then
   echo "ERROR: Bubblewrap binary not found" ; exit 1
fi
chmod +x "${BWRAP_BIN}" 2>/dev/null

if [ ! -d "${SELF_PATH}/nix/store" ]; then
   echo "ERROR: /nix/store NOT FOUND at \$APPDIR/nix/store" ; exit 1
fi

## Get/Set ENVS (from Host)
if [ -z "${USER}" ]; then USER="$(whoami)" ; export USER ; fi
if [ -z "${HOME}" ]; then HOME="$(getent passwd "${USER}" | cut -d: -f6)" ; export HOME ; fi

## XDG Inheritance
if [ -d "${HOME}" ]; then
    if [ -z "${XDG_CACHE_HOME}" ];   then export XDG_CACHE_HOME="${HOME}/.cache" ; fi
    if [ -z "${XDG_CONFIG_HOME}" ];  then export XDG_CONFIG_HOME="${HOME}/.config" ; fi
    if [ -z "${XDG_DATA_HOME}" ];    then export XDG_DATA_HOME="${HOME}/.local/share" ; fi
    if [ -z "${XDG_RUNTIME_DIR}" ]; then export XDG_RUNTIME_DIR="/run/user/$(id -u)" ; fi
    if [ -z "${XDG_STATE_HOME}" ];   then export XDG_STATE_HOME="${HOME}/.local/state" ; fi
    XDG_INHERITS="--setenv XDG_CACHE_HOME '${XDG_CACHE_HOME}' --setenv XDG_CONFIG_HOME '${XDG_CONFIG_HOME}' --setenv XDG_DATA_HOME '${XDG_DATA_HOME}' --setenv XDG_RUNTIME_DIR '${XDG_RUNTIME_DIR}' --setenv XDG_STATE_HOME '${XDG_STATE_HOME}'"
fi

## DISPLAY & WAYLAND Sockets
if [ -n "${WAYLAND_DISPLAY}" ]; then
    DISPLAY_SHARES="--setenv WAYLAND_DISPLAY '${WAYLAND_DISPLAY}'"
fi
if [ -n "${DISPLAY}" ]; then
    XDISPLAY_SHARES="--setenv DISPLAY '${DISPLAY}'"
fi

## Pre-Exec Checks (Risoluzione sicura del link Nix)
if [ -L "${SELF_PATH}/entrypoint" ] || [ -f "${SELF_PATH}/entrypoint" ]; then
    TARGET_VAL="$(readlink "${SELF_PATH}/entrypoint" || echo "")"
    if [ -n "$TARGET_VAL" ]; then
        DEFAULT_CMD="$TARGET_VAL"
    else
        DEFAULT_CMD="${SELF_PATH}/entrypoint"
    fi
    export DEFAULT_CMD
else
    for exec_bin in "${SELF_PATH}/usr/bin/"*; do
        if [ -x "${exec_bin}" ] && [ -f "${exec_bin}" ]; then
            DEFAULT_CMD="$(realpath "${exec_bin}")" ; export DEFAULT_CMD
            break
        fi
    done
fi

if [ -z "${DEFAULT_CMD}" ]; then
    echo "ERROR: No executable entrypoint found!" ; exit 1
fi

## BWRAP Capability & Sandbox Options
if [ "${ENABLE_ADMIN}" = "1" ] || [ "${ENABLE_ADMIN}" = "ON" ]; then ADMIN_STATUS="--cap-add cap_sys_admin" ; fi
if [ "${ENABLE_DEV}" = "0" ] || [ "${ENABLE_DEV}" = "OFF" ]; then DEV_STATUS="" ; else DEV_STATUS="--dev-bind-try /dev /dev" ; fi
if [ "${ENABLE_NET}" = "0" ] || [ "${ENABLE_NET}" = "OFF" ]; then NET_STATUS="--unshare-net" ; fi

bwrap_run(){
  [ "${VERBOSE}" = "1" ] && echo "INFO: BubbleWrap Version --> $("${BWRAP_BIN}" --version)"

  CURRENT_UID=$(id -u)

  # === EMULAZIONE REGISTRO NIXGL ===
  # Scansione per rintracciare la cartella contenente i driver grafici Mesa interni di Nix
  NIX_GL_FLAGS=""
  for store_dir in "${SELF_PATH}"/nix/store/*; do
      if [ -d "$store_dir/lib/dri" ]; then
          NIX_GL_FLAGS="$NIX_GL_FLAGS --setenv LIBGL_DRIVERS_PATH '$store_dir/lib/dri'"

          # Generazione dell'indice dei profili EGL Vendor interni
          EGL_FILES=""
          if [ -d "$store_dir/share/glvnd/egl_vendor.d" ]; then
              for json in "$store_dir"/share/glvnd/egl_vendor.d/*.json; do
                  if [ -f "$json" ]; then
                      if [ -z "$EGL_FILES" ]; then EGL_FILES="$json"; else EGL_FILES="$EGL_FILES:$json"; fi
                  fi
              done
          fi
          if [ -n "$EGL_FILES" ]; then
              NIX_GL_FLAGS="$NIX_GL_FLAGS --setenv __EGL_VENDOR_LIBRARY_FILENAMES '$EGL_FILES'"
          fi

          # Generazione dell'indice dei profili Vulkan ICD interni
          VK_FILES=""
          if [ -d "$store_dir/share/vulkan/icd.d" ]; then
              for json in "$store_dir"/share/vulkan/icd.d/*.json; do
                  if [ -f "$json" ]; then
                      if [ -z "$VK_FILES" ]; then VK_FILES="$json"; else VK_FILES="$VK_FILES:$json"; fi
                  fi
              done
          fi
          if [ -n "$VK_FILES" ]; then
              NIX_GL_FLAGS="$NIX_GL_FLAGS --setenv VK_DRIVER_FILES '$VK_FILES'"
          fi
          break
      fi
  done

  eval "\"${BWRAP_BIN}\" \
    --bind / / \
    --tmpfs /run \
    --dir /run/user \
    --bind-try \"/run/user/${CURRENT_UID}\" \"/run/user/${CURRENT_UID}\" \
    --bind-try /run/dbus /run/dbus \
    --bind-try /run/systemd /run/systemd \
    --bind-try /run/NetworkManager /run/NetworkManager \
    --dir /run/opengl-driver \
    --ro-bind \"${SELF_PATH}/nix\" '/nix' \
    --setenv 'DEFAULT_CMD' \"${DEFAULT_CMD}\" \
    --setenv 'PATH' \"${PATH}\" \
    --setenv 'SELF_PATH' \"${SELF_PATH}\" \
    --setenv 'XDG_RUNTIME_DIR' \"${XDG_RUNTIME_DIR}\" \
    ${XDG_INHERITS} \
    ${ADMIN_STATUS} \
    ${DEV_STATUS} \
    ${NET_STATUS} \
    ${DISPLAY_SHARES} \
    ${XDISPLAY_SHARES} \
    ${NIX_GL_FLAGS} \
    ${BWRAP_EXTRA_ARGS} \
    \"${DEFAULT_CMD}\" \
    \"\$@\""
}

if [ $# -eq 0 ]; then
     bwrap_run
else
     if [ -x "${SELF_PATH}/usr/bin/$1" ] && [ -f "${SELF_PATH}/usr/bin/$1" ]; then
         SELF_CMD="$1" ; export SELF_CMD
         shift
         DEFAULT_CMD="$(readlink -f "${SELF_PATH}/usr/bin/${SELF_CMD}")" ; export DEFAULT_CMD
         bwrap_run "$@"
     else
         bwrap_run "$@"
     fi
fi

if [ "${DEBUG}" = "1" ]; then set +x ; fi
