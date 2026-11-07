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
    # Logging must never fail an upgrade. The record is missing when a switch
    # changes this unit mid-run, because systemd then runs the new postStart.
    postStart = ''
      record="$RUNTIME_DIRECTORY/previous-system"
      if [ -e "$record" ]; then
        previous=$(cat "$record")
        echo "Package changes since $previous:"
        nix store diff-closures "$previous" /run/current-system || echo "Package diff unavailable."
      else
        echo "No previous system recorded; skipping package diff."
      fi
    '';
  };
}
