self: super:

let
  pkgs = self.callPackage ({ pkgs }: pkgs) {};
  inherit (pkgs) obeliskCleanSource;
  haskellLib = pkgs.haskell.lib;
  onLinux = pkg: f: if pkgs.stdenv.isLinux then f pkg else pkg;
in

{
    force-push = haskellLib.overrideCabal (self.callCabal2nix "force-push" (obeliskCleanSource ../lib/push) {}) {
      librarySystemDepends = [
        pkgs.nix
        pkgs.openssh
        pkgs.rsync
        pkgs.which
      ];
    };
}
