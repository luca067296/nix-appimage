{ pkgs ? import <nixpkgs> {}
, mkappimage-runtime
, ...
}:

program:
let
  # Incorpora l'intera closure grafica Mesa di Nix all'interno dell'AppImage
  closureInfo = pkgs.closureInfo { rootPaths = [ program pkgs.mesa ]; };
  arch = if pkgs.stdenv.hostPlatform.system == "aarch64-linux" then "aarch64" else "x86_64";
  bwrap-sha256 = if arch == "aarch64"
    then "aaf6282c278a23f8492a57e8b484867ca609220f949d89686ab90713c3dfead5"
    else "64ce8bae20ba27fdbf832eb830e06394a0eb77bc15b588e9b66a40a17b23affb";
  bwrap-static = pkgs.fetchurl {
    url = "https://github.com/pkgforge/nix-appimage/releases/download/bwrap/bwrap-${arch}";
    sha256 = bwrap-sha256;
  };
in
pkgs.stdenv.mkDerivation {
  name = "${program.name or "app"}.AppImage";
  nativeBuildInputs = with pkgs; [ squashfsTools ];
  dontUnpack = true;
  buildPhase = ''
    export AppDir=$(mktemp -d)
    mkdir -p $AppDir/nix/store
    echo "=== Copia della closure di Nix ==="
    while read -r path; do
      if [ -e "$path" ]; then
        cp -a "$path" "$AppDir/nix/store/"
      fi
    done < ${closureInfo}/store-paths
    find $AppDir/nix/store -type d -exec chmod +w {} +
    echo "=== Integrazione di Bubblewrap statico ==="
    cp ${bwrap-static} $AppDir/bwrap
    cp ${bwrap-static} $AppDir/bwrap-bin
    chmod +x $AppDir/bwrap $AppDir/bwrap-bin
    echo "=== Creazione dell'entrypoint (Symlink Diretto) ==="
    if [ -d "${program}/bin" ]; then
      EXE_FILE=$(find "${program}/bin" -maxdepth 1 -type f -executable ! -name ".*" | head -n 1)
    else
      EXE_FILE="${program}"
    fi
    if [ -z "$EXE_FILE" ] || [ ! -x "$EXE_FILE" ]; then
      echo "ERRORE: Impossibile trovare l'eseguibile per $program"
      exit 1
    fi
    ln -s "$EXE_FILE" $AppDir/entrypoint
    echo "Entrypoint configurato come symlink a: $EXE_FILE"
    echo "=== Installazione del fido AppRun (Bwrap-native) ==="
    cp ${./appruns/bwrap/AppRun.sh} $AppDir/AppRun
    chmod +x $AppDir/AppRun
    echo "=== Generazione del file system SquashFS ==="
    mksquashfs $AppDir AppDir.squashfs -comp gzip -noappend -processors 2
    echo "=== Assemblaggio finale dell'AppImage ==="
    cat ${mkappimage-runtime} AppDir.squashfs > $out
    chmod +x $out
  '';
  installPhase = "true";
}

