{
  description = "Apollo’s NixOS Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    authentik-nix = {
      url = "github:nix-community/authentik-nix";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      # Both are only used by impermanence's own tests.
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "";
    };
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    disko = {
      url = "github:nix-community/disko";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The sites build with their own locked nixpkgs, so Apollo's updates
    # cannot break them.
    website.url = "github:mkoppmann/website";
    wtcvss.url = "github:mkoppmann/wtcvss";
  };

  outputs =
    {
      self,
      nixpkgs,
      ...
    }@inputs:
    let
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      nixosConfigurations.apollo = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./configuration.nix

          # `nixos-version --json` reports the deployed commit.
          { system.configurationRevision = self.rev or self.dirtyRev or "dirty"; }
        ];
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShellNoCC {
          packages = with pkgs; [
            age
            nixfmt
            sops
          ];
        };
      });

      checks =
        nixpkgs.lib.recursiveUpdate
          (forAllSystems (pkgs: {
            formatting = pkgs.runCommand "formatting" { nativeBuildInputs = [ pkgs.nixfmt ]; } ''
              find ${self} -name '*.nix' -exec nixfmt --check {} +
              touch $out
            '';
            deadnix = pkgs.runCommand "deadnix" { nativeBuildInputs = [ pkgs.deadnix ]; } ''
              deadnix --fail ${self}
              touch $out
            '';
            statix = pkgs.runCommand "statix" { nativeBuildInputs = [ pkgs.statix ]; } ''
              statix check --config ${self}/statix.toml ${self}
              touch $out
            '';
            secrets-encrypted = pkgs.runCommand "secrets-encrypted" { nativeBuildInputs = [ pkgs.sops ]; } ''
              for file in ${self}/secrets/*; do
                sops filestatus "$file" | grep -q '"encrypted":true' || { echo "$file is not encrypted"; exit 1; }
              done
              touch $out
            '';
          }))
          {
            x86_64-linux = {
              toplevel = self.nixosConfigurations.apollo.config.system.build.toplevel;
              hardening = import ./tests/hardening.nix {
                pkgs = nixpkgs.legacyPackages.x86_64-linux;
                inherit inputs;
              };
              backup = import ./tests/backup.nix {
                pkgs = nixpkgs.legacyPackages.x86_64-linux;
                inherit inputs;
              };
              disk-layout = import ./tests/disk-layout.nix {
                pkgs = nixpkgs.legacyPackages.x86_64-linux;
                inherit inputs;
              };
              secrets = import ./tests/secrets.nix {
                pkgs = nixpkgs.legacyPackages.x86_64-linux;
                inherit inputs;
              };
              nextcloud = import ./tests/nextcloud.nix {
                pkgs = nixpkgs.legacyPackages.x86_64-linux;
                inherit (self.nixosConfigurations.apollo.config.services.nextcloud) package;
              };
            };
          };
    };
}
