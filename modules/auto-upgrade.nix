{ ... }:
{
  system.autoUpgrade = {
    enable = true;
    flake = "/etc/nixos#apollo";
    upgrade = false; # Update inputs explicitly below.
    dates = "*-*-* 00/6:00:00 Europe/Vienna";
    randomizedDelaySec = "30min";
    allowReboot = false;
    flags = [ "--print-build-logs" ];
  };

  # Audit trail: `nix flake update` logs every changed input revision, and
  # postStart logs the resulting package changes to the journal.
  systemd.services.nixos-upgrade = {
    serviceConfig.RuntimeDirectory = "nixos-upgrade";
    preStart = ''
      readlink -f /run/current-system > "$RUNTIME_DIRECTORY/previous-system"
      cd /etc/nixos
      nix flake update
    '';
    postStart = ''
      previous=$(cat "$RUNTIME_DIRECTORY/previous-system")
      echo "Package changes since $previous:"
      nix store diff-closures "$previous" /run/current-system
    '';
  };
}
