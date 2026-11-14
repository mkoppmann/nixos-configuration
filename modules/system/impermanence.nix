{ pkgs, ... }:
{
  environment.etc = {
    "machine-id".source = "/persist/etc/machine-id";
  };

  # Host-level state; services declare their own directories.
  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
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

  # Logrotate atomically replaces its state file; persist its directory.
  services.logrotate.extraArgs = [
    "--state"
    "/var/lib/logrotate/status"
  ];
}
