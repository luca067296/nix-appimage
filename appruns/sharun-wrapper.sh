#!/bin/sh
# Risolve dinamicamente la posizione dell'AppDir temporaneo
SELF=$(readlink -f "$0")
APPDIR=$(dirname "$SELF")

# Configurazione principale di sharun
export SHARUN_DIR="$APPDIR"

# --- VIRTUALIZZAZIONE DI NIX ---
export SHARUN_BIND="$APPDIR/nix:/nix"
export SHARUN_PROOT_ARGS="-b $APPDIR/nix:/nix -b /dev:/dev -b /proc:/proc -b /sys:/sys -b /tmp:/tmp"
export PROOT_NO_SECCOMP=1

# Configura il nome dell'interprete secondo gli standard di sharun
export SHARUN_LDNAME="ld.so"

# Legge il target del symlink entrypoint
TARGET_LINK=$(readlink "$APPDIR/entrypoint")
REAL_ENTRYPOINT="$APPDIR$TARGET_LINK"

# Traduzione POSIX pura di lib.path
if [ -f "$APPDIR/lib.path" ]; then
    COLON_PATHS=""
    while read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        stripped="${line#/}"
        if [ -z "$COLON_PATHS" ]; then
            COLON_PATHS="$APPDIR/$stripped"
        else
            COLON_PATHS="$COLON_PATHS:$APPDIR/$stripped"
        fi
    done < "$APPDIR/lib.path"
    export SHARUN_EXTRA_LIBRARY_PATH="$COLON_PATHS"
fi

# Diagnostica avanzata in caso di debug attivo
if [ "$DEBUG" = "1" ] || [ "$VERBOSE" = "1" ]; then
    echo "--- WRAPPER DIAGNOSTICS ---"
    echo "APPDIR: $APPDIR"
    echo "REAL_ENTRYPOINT: $REAL_ENTRYPOINT"
    echo "SHARUN_LDNAME: $SHARUN_LDNAME"
    echo "SHARUN_BIND: $SHARUN_BIND"
    echo "SHARUN_EXTRA_LIBRARY_PATH: $SHARUN_EXTRA_LIBRARY_PATH"
    echo "---------------------------"
    export SHARUN_PRINTENV=1
fi

# Eseguiamo il motore di virtualizzazione statico sharun
exec "$APPDIR/bin/sharun" "$REAL_ENTRYPOINT" "$@"
