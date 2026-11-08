{ pkgs, ... }:
let
  checkout = "/etc/nixos";
in
{
  # The deployment checkout belongs to a user without login, so Git never runs
  # as root, and changing what root builds still takes sudo. Root only reads
  # the checkout through Nix, whose libgit2 rejects repositories owned by
  # another user unless they are marked safe.
  users.users.deploy = {
    isSystemUser = true;
    group = "deploy";
    # Nix keeps its fetcher cache here.
    home = "/var/lib/deploy";
    createHome = true;
  };
  users.groups.deploy = { };
  # It runs `nix flake update` in the upgrade service.
  nix.settings.allowed-users = [ "deploy" ];

  environment.persistence."/persist".directories = [
    {
      directory = checkout;
      user = "deploy";
      group = "deploy";
      mode = "0755";
    }
  ];
  programs.git.config.safe.directory = checkout;

  system.autoUpgrade = {
    enable = true;
    flake = "${checkout}#apollo";
    upgrade = false; # Update inputs explicitly below.
    dates = "*-*-* 00/6:00:00 Europe/Vienna";
    randomizedDelaySec = "30min";
    allowReboot = false;
    flags = [
      "--print-build-logs"
      # The lock file is updated by mcp in preStart.
      "--no-write-lock-file"
    ];
  };

  # Audit trail: `nix flake update` logs every changed input revision, and
  # postStart logs the resulting package changes to the journal.
  systemd.services.nixos-upgrade = {
    serviceConfig.RuntimeDirectory = "nixos-upgrade";
    preStart = ''
      readlink -f /run/current-system > "$RUNTIME_DIRECTORY/previous-system"
      ${pkgs.util-linux}/bin/runuser -u deploy -- nix flake update --flake ${checkout}
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
