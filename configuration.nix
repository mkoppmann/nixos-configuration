{ inputs, ... }:
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    inputs.impermanence.nixosModules.impermanence
    ./hardware-configuration.nix
    ./modules/system/auto-upgrade.nix
    ./modules/system/backup.nix
    ./modules/system/boot.nix
    ./modules/system/dns.nix
    ./modules/system/impermanence.nix
    ./modules/system/kernel.nix
    ./modules/system/monitoring.nix
    ./modules/system/networking.nix
    ./modules/system/nix.nix
    ./modules/system/secrets.nix
    ./modules/system/ssh.nix
    ./modules/system/storage.nix
    ./modules/system/users.nix
    ./modules/system/wireguard.nix
    ./modules/services/actual.nix
    ./modules/services/authentik
    ./modules/services/matrix/element-web.nix
    ./modules/services/matrix/mas.nix
    ./modules/services/matrix/synapse.nix
    ./modules/services/nextcloud
    ./modules/services/nginx.nix
    ./modules/services/photos.nix
    ./modules/services/pleroma.nix
    ./modules/services/postgresql.nix
    ./modules/services/vaultwarden.nix
    ./modules/services/websites.nix
    ./nixos-modules/matrix-authentication-service.nix
  ];

  time.timeZone = "Europe/Vienna";

  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?
}
