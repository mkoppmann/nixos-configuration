{ inputs, ... }:
{
  imports = [
    inputs.authentik-nix.nixosModules.default
    inputs.impermanence.nixosModules.impermanence
    ./hardware-configuration.nix
    ./modules/actual.nix
    ./modules/alerts.nix
    ./modules/authentik.nix
    ./modules/auto-upgrade.nix
    ./modules/backup-orchestration.nix
    ./modules/boot.nix
    ./modules/element-web.nix
    ./modules/impermanence.nix
    ./modules/mas.nix
    ./modules/matrix-synapse.nix
    ./modules/networking.nix
    ./modules/nextcloud.nix
    ./modules/nginx.nix
    ./modules/nix.nix
    ./modules/pleroma.nix
    ./modules/postgresql.nix
    ./modules/users.nix
    ./modules/vaultwarden.nix
    ./modules/wireguard.nix
    ./nixos-modules/matrix-authentication-service.nix
  ];

  time.timeZone = "Europe/Vienna";

  environment.persistence."/persist".directories = [
    {
      directory = "/root/.config/borg";
      mode = "0700";
    }
    {
      directory = "/root/.cache/borg";
      mode = "0700";
    }
  ];

  # Matches the fingerprint Hetzner publishes for Storage Boxes:
  # SHA256:XqONwb1S0zuj5A1CDxpOSuD2hnAArV1A3wKY7Z3sdgM
  programs.ssh.knownHosts.storage-box = {
    hostNames = [ "[u237324-sub2.your-storagebox.de]:23" ];
    publicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIICf9svRenC/PLKIL9nk6K/pxQgoiFC41wTNvoIncOxs";
  };

  services.borgbackup.jobs = {
    "sidechest" = {
      paths = [
        "/persist"
        "/var/log"
      ];
      exclude = [
        "/persist/var/lib/postgresql"
        "/persist/root/.cache/borg"
        "/persist/var/lib/systemd/random-seed"
        "/var/log/audit/audit.log"
        "/var/log/journal/e538f1c97e5f472581a47d4a0acd816c/system.journal"
        "/var/log/nginx/access.log"
      ];
      repo = "ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg";
      encryption = {
        mode = "repokey-blake2";
        passCommand = "cat /persist/credentials/borg_sidechest_passphrase";
      };
      environment.BORG_RSH = "ssh -i /persist/credentials/borg_sidechest_ssh";
      compression = "auto,zstd";
      startAt = "daily";
      prune.keep = {
        daily = 7;
        weekly = 4;
        monthly = 6;
      };
    };
  };

  security = {
    auditd.enable = true;
    audit.enable = true;
  };

  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?
}
