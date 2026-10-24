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

  systemd.services.nixos-upgrade.preStart = ''
    cd /etc/nixos
    nix flake update
  '';
}
