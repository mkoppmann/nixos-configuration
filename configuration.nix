{ inputs, ... }:
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    inputs.impermanence.nixosModules.impermanence
    ./hardware-configuration.nix
    ./modules/actual.nix
    ./modules/authentik.nix
    ./modules/auto-upgrade.nix
    ./modules/backup.nix
    ./modules/boot.nix
    ./modules/dns.nix
    ./modules/element-web.nix
    ./modules/impermanence.nix
    ./modules/kernel.nix
    ./modules/mas.nix
    ./modules/matrix-synapse.nix
    ./modules/monitoring.nix
    ./modules/networking.nix
    ./modules/nextcloud.nix
    ./modules/nginx.nix
    ./modules/nix.nix
    ./modules/photos.nix
    ./modules/pleroma.nix
    ./modules/postgresql.nix
    ./modules/secrets.nix
    ./modules/ssh.nix
    ./modules/users.nix
    ./modules/vaultwarden.nix
    ./modules/websites.nix
    ./modules/wireguard.nix
    ./nixos-modules/matrix-authentication-service.nix
  ];

  time.timeZone = "Europe/Vienna";

  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?
}
