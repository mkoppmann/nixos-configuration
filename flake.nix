{
  description = "Apollo’s NixOS Flake";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05-small";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable-small";
    authentik-nix = {
      url = "github:nix-community/authentik-nix";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    impermanence = {
      url = "github:nix-community/impermanence";
      # Both are only used by impermanence's own tests.
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.home-manager.follows = "";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      home-manager,
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

          home-manager.nixosModules.home-manager
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.users.mcp = import ./home.nix;
          }
        ];
      };

      formatter = forAllSystems (pkgs: pkgs.nixfmt);

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
          }))
          {
            # VM tests are added here as they are written.
            x86_64-linux.toplevel = self.nixosConfigurations.apollo.config.system.build.toplevel;
          };
    };
}
