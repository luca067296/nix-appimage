{
  description = "AnyLinux AppImage Bundler using Nix and Local Sharun";
  inputs = {
    # Ramo stabile garantito del 2026
    nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";
  };
  outputs = { self, nixpkgs }@inputs:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      lib = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          mkAppImage = pkgs.callPackage ./mkAppImage.nix {
            sharun = ./bin/sharun;
            mkappimage-runtime = pkgs.pkgsStatic.callPackage ./runtimes/appimage-type2-runtime/default.nix {};
          };
        }
      );
      bundlers = forAllSystems (system: {
        default = self.lib.${system}.mkAppImage;
      });
    };
}
