{
  lib,
  pkgs,
  utils,
  ...
}:
let
  randomSeedPersistenceUnit = "persist-${utils.escapeSystemdPath "/persist/var/lib/systemd/random-seed"}.service";
in
{
  environment.etc = {
    "machine-id".source = "/persist/etc/machine-id";
    "ssh/ssh_host_ed25519_key".source = "/persist/etc/ssh/ssh_host_ed25519_key";
    "ssh/ssh_host_ed25519_key.pub".source = "/persist/etc/ssh/ssh_host_ed25519_key.pub";
    "ssh/ssh_host_rsa_key".source = "/persist/etc/ssh/ssh_host_rsa_key";
    "ssh/ssh_host_rsa_key.pub".source = "/persist/etc/ssh/ssh_host_rsa_key.pub";
  };

  # Host-level state; services declare their own directories.
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/etc/nixos"
      "/root/.ssh"
      {
        directory = "/var/lib/logrotate";
        mode = "0700";
      }
      "/var/lib/nixos"
      {
        directory = "/var/lib/systemd/timers";
        mode = "0755";
      }
      {
        directory = "/var/lib/systemd/timesync";
        user = "systemd-timesync";
        group = "systemd-timesync";
        mode = "0755";
      }
    ];
    files = [ "/var/lib/systemd/random-seed" ];
    users.mcp = {
      directories = [ ".local/share/fish" ];
    };
  };

  # Protect the backing tree too: DynamicUser's host-side private directory
  # must not become traversable through /persist. Do not chown its children.
  system.activationScripts.apollo-private-state-permissions = {
    deps = [ "createPersistentStorageDirs" ];
    text = ''
      ${pkgs.coreutils}/bin/install -d -o root -g root -m 0700 \
        /persist/var/lib/private /var/lib/private
    '';
  };

  systemd.services = {
    # Impermanence represents file persistence with a service, not a .mount
    # unit. RequiresMountsFor on random-seed alone cannot order that service.
    systemd-random-seed = {
      requires = [ randomSeedPersistenceUnit ];
      after = [ randomSeedPersistenceUnit ];
    };
    "${lib.removeSuffix ".service" randomSeedPersistenceUnit}".unitConfig.RequiresMountsFor = [
      "/persist/var/lib/systemd"
    ];
  };

  # Logrotate atomically replaces its state file; persist its directory.
  services.logrotate.extraArgs = [
    "--state"
    "/var/lib/logrotate/status"
  ];
}
