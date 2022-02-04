{ system ? builtins.currentSystem
, iosSdkVersion ? "13.2"
# , reflex-platform-func ? import ./dep/reflex-platform
, profiling ? false
, config ? {}
, routeHost ? "force-bridge.dev.obsidian.systems"
}:
let
  terms.security.acme.acceptTerms = false;

  reflex-platform-func = import (sources.obelisk + "/dep/reflex-platform");

  nix-thunk = import ./dep/nix-thunk {};
  sources = nix-thunk.mapSubdirectories nix-thunk.thunkSource ./dep;

  reflex-platform = getReflexPlatform { inherit system; };
  inherit (reflex-platform) hackGet nixpkgs pinBuildInputs;
  pkgs = nixpkgs;

  getReflexPlatform = { system, enableLibraryProfiling ? profiling }: reflex-platform-func {
    inherit iosSdkVersion config system enableLibraryProfiling;

    nixpkgsOverlays = [
      (import (sources.obelisk + "/nixpkgs-overlays"))
    ];

    haskellOverlays = [
      (import (sources.obelisk + "/haskell-overlays/misc-deps.nix") { inherit hackGet; })
      pkgs.obeliskExecutableConfig.haskellOverlay
      (import (sources.obelisk + "/haskell-overlays/obelisk.nix"))
      # TODO(skylar) Do we need this? Why does it make things not work
      # (import (sources.obelisk + "/haskell-overlays/tighten-ob-exes.nix"))
      (import ./haskell-overlays/force-push.nix)
    ];
  };

  ghcForcePush = reflex-platform.ghc;
  ghcForcePushEnvs = pkgs.lib.mapAttrs (n: v: reflex-platform.workOn ghcForcePush v) ghcForcePush;

  serverModules = {
    mkBaseEc2 = { nixosPkgs, ... }: {...}: {
      imports = [
        (nixosPkgs.path + /nixos/modules/virtualisation/amazon-image.nix)
      ];
      ec2.hvm = true;
    };

    mkForceBridgeUi = {...}: {
      services.nginx = {
        enable = true;
        recommendedProxySettings = true;
        httpConfig = ''
          server {
            listen 80;
            listen [::]:80;

            server_name force-bridge;

            root /var/lib/backend;
            index index.html;
          }
        '';
      };
    };

    mkDefaultNetworking = { adminEmail ? "soraskymizu@gmail.com", enableHttps ? false, ... }: {...}: {
      networking = {
        hostName = "force-bridge-dev";
        firewall.allowedTCPPorts = if enableHttps then [ 80 443 ] else [ 80 ];
      };

      # `amazon-image.nix` already sets these but if the user provides their own module then
      # forgetting these can cause them to lose access to the server!
      # https://github.com/NixOS/nixpkgs/blob/fab05f17d15e4e125def4fd4e708d205b41d8d74/nixos/modules/virtualisation/amazon-image.nix#L133-L136
      services.openssh.enable = true;
      services.openssh.permitRootLogin = "prohibit-password";

      security.acme.certs = if enableHttps then {
        "${routeHost}".email = adminEmail;
      } else {};

      security.acme.${if enableHttps && (terms.security.acme.acceptTerms or false) then "acceptTerms" else null} = true;
    };
  };

  serverFunc = { adminEmail ? "soraskymizu@gmail.com", routeHost, module ? serverModules.mkBaseEc2 }@args:
    let
      nixos = import (pkgs.path + /nixos);
    in nixos {
      system = "x86_64-linux";
      configuration = {
        imports = [
          (module { nixosPkgs = pkgs; })
          (serverModules.mkDefaultNetworking args)
          (serverModules.mkForceBridgeUi { inherit args; })
          # (serverModules.mkObeliskApp args)
          ./acme.nix  # Backport of ACME upgrades from 20.03
        ];

        # Backport of ACME upgrades from 20.03
        disabledModules = [
          (pkgs.path + /nixos/modules/security/acme.nix)
        ];
      };
    };

in rec
{
  force-push = ghcForcePush;
  command = ghcForcePush.force-push;
  dev-shell = force-push-envs.force-push;
  force-push-envs = pkgs.lib.filterAttrs (k: _: pkgs.lib.strings.hasPrefix "force-" k) ghcForcePushEnvs; #TODO: use thunkSet https://github.com/reflex-frp/reflex-platform/pull/671

  # Full nixos-system runnable on AWS
  server = serverFunc { inherit routeHost; };

  # Ui component
  force-bridge-ui = import sources.force-bridge-ui {};
}
