{ fetchFromGitHub
, stdenv
, fuse3
, pkg-config
, squashfuse
, zstd
, zlib
, xz
, lz4
, lzo
, lib
}:

let
  src = fetchFromGitHub {
    owner = "AppImage";
    repo = "type2-runtime";
    rev = "2df896eb93b2c63664605cd531c19d09a4266894";
    sha256 = "0rg2alfb8fwld86gdhhdlm1jdmyw8scbjsyp00himwiz47vv3r5g";
  };
  fuse3' = fuse3.overrideAttrs (old: {
    patches = (old.patches or []) ++ [];
  });
  squashfuse' = (squashfuse.override (
    lib.optionalAttrs (squashfuse ? override && squashfuse.override ? __functionArgs && squashfuse.override.__functionArgs ? fuse3) {
      fuse3 = fuse3';
    } // lib.optionalAttrs (squashfuse ? override && squashfuse.override ? __functionArgs && squashfuse.override.__functionArgs ? fuse) {
      fuse = fuse3';
    }
  )).overrideAttrs (old: {
    postInstall = (old.postInstall or "") + ''
      cp *.h -t $out/include/squashfuse/
    '';
  });
in
stdenv.mkDerivation {
  pname = "appimage-type2-runtime";
  version = "unstable-2024-08-17";
  inherit src;
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [
    fuse3'
    squashfuse'
    zstd
    zlib
    xz
    lz4
    lzo
  ];
  configurePhase = ''
    $PKG_CONFIG --cflags fuse3 > cflags
  '';
  buildPhase = ''
    # Rinominiamo la funzione main originale direttamente nel codice sorgente per evitare la trappola delle macro globali
    sed -i 's/int main(int/int original_main(int/g' src/runtime/runtime.c

    # Appendiamo l'iniettore AnyLinux che implementa il vero punto di ingresso "main" finale
    cat << 'EOF' >> src/runtime/runtime.c

    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <unistd.h>
    #include <sys/stat.h>
    #include <sys/types.h>

    int original_main(int argc, char* argv[]);

    static int check_fuse_and_fusermount() {
        if (access("/dev/fuse", F_OK) != 0) return 0;
        char *path = getenv("PATH");
        if (!path) return 0;
        char *path_copy = strdup(path);
        char *token = strtok(path_copy, ":");
        int found = 0;
        while (token) {
            char buf[512];
            snprintf(buf, sizeof(buf), "%s/fusermount", token);
            if (access(buf, X_OK) == 0) { found = 1; break; }
            snprintf(buf, sizeof(buf), "%s/fusermount3", token);
            if (access(buf, X_OK) == 0) { found = 1; break; }
            token = strtok(NULL, ":");
        }
        free(path_copy);
        return found;
    }

    int main(int argc, char **argv) {
        // Dirottiamo l'estrazione trasparente dentro ~/.cache per non sporcare la radice della HOME
        if (!getenv("TMPDIR")) {
            char *home = getenv("HOME");
            if (home) {
                char cache_path[512];
                snprintf(cache_path, sizeof(cache_path), "%s/.cache", home);
                mkdir(cache_path, 0755); // Crea la cartella se assente, non fa nulla se esiste
                setenv("TMPDIR", cache_path, 1);
            }
        }

        int has_appimage_arg = 0;
        for (int i = 1; i < argc; i++) {
            if (strncmp(argv[i], "--appimage-", 11) == 0) {
                has_appimage_arg = 1;
                break;
            }
        }

        // Se FUSE o fusermount non sono presenti, iniettiamo l'estrazione trasparente AnyLinux automatica
        if (!has_appimage_arg) {
            if (!check_fuse_and_fusermount()) {
                char **new_argv = malloc((argc + 2) * sizeof(char*));
                if (new_argv) {
                    new_argv[0] = argv[0];
                    new_argv[1] = "--appimage-extract-and-run";
                    for (int i = 1; i < argc; i++) {
                        new_argv[i+1] = argv[i];
                    }
                    new_argv[argc+1] = NULL;
                    return original_main(argc + 1, new_argv);
                }
            }
        }

        return original_main(argc, argv);
    }
    EOF

    $CC src/runtime/runtime.c -o $out \
      -D_FILE_OFFSET_BITS=64 -DGIT_COMMIT='"0000000"' \
      $(cat cflags) \
      -std=gnu99 -Os -ffunction-sections -fdata-sections -Wl,--gc-sections -static -w \
      -lsquashfuse -lsquashfuse_ll -lfuse3 -lzstd -lz -llzma -llz4 -llzo2 \
      -T src/runtime/data_sections.ld

    printf %b '\x41\x49\x02' > magic_bytes
    dd if=magic_bytes of=$out bs=1 count=3 seek=8 conv=notrunc status=none
  '';
  dontFixup = true;
}
