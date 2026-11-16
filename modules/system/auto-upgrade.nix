{ lib, pkgs, ... }:
let
  checkout = "/etc/nixos";

  # Only inputs that can’t change how Apollo is configured: nixpkgs’ release
  # branches and the websites, which are packages built in the sandbox. The
  # other inputs provide NixOS modules, which run as root. They stay at the
  # revisions of Git’s lock file until a reviewed commit changes them. CI
  # reads the same list for its scheduled runs.
  updatedInputs = lib.importJSON ./updated-inputs.json;

  lock = lib.importJSON ../../flake.lock;
  pinnedInputs = lib.mapAttrs (_: node: lock.nodes.${node}.locked) (
    removeAttrs lock.nodes.root.inputs updatedInputs
  );
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
    upgrade = false; # preStart updates the inputs.
    dates = "*-*-* 00/6:00:00 Europe/Vienna";
    randomizedDelaySec = "30min";
    allowReboot = false;
    flags = [
      "--print-build-logs"
      # preStart updates the lock file as deploy.
      "--no-write-lock-file"
    ];
  };

  # Audit trail: `nix flake update` logs every changed input revision, and
  # postStart logs the resulting package changes to the journal.
  systemd.services.nixos-upgrade = {
    serviceConfig.RuntimeDirectory = "nixos-upgrade";
    preStart = ''
      readlink -f /run/current-system > "$RUNTIME_DIRECTORY/previous-system"
      ${pkgs.util-linux}/bin/runuser -u deploy -- \
        nix flake update ${lib.escapeShellArgs updatedInputs} --flake ${checkout}
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

  # The pinned inputs get no updates by themselves. Once a week this unit
  # fails, and so mails, when their branches have commits that the lock file
  # lacks, and lists the newest of them.
  systemd.services.pinned-inputs-check = {
    description = "Fail when pinned flake inputs are behind their branches";
    startAt = "Mon 07:00 Europe/Vienna";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.jq
    ];
    script = ''
      behind=0
      check() {
        comparison=$(curl -fsS -m 30 --retry 3 "https://api.github.com/repos/$2/$3/compare/$4...HEAD")
        count=$(jq -er .ahead_by <<< "$comparison")
        if [ "$count" -gt 0 ]; then
          echo "$1: $count new commits, the newest:"
          jq -r '.commits[-5:][] | "  " + (.commit.message | split("\n")[0])' <<< "$comparison"
          behind=1
        fi
      }
      ${lib.concatStrings (
        lib.mapAttrsToList (
          name: locked:
          assert locked.type == "github";
          "check ${
            lib.escapeShellArgs [
              name
              locked.owner
              locked.repo
              locked.rev
            ]
          }\n"
        ) pinnedInputs
      )}
      [ "$behind" = 0 ]
    '';
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      CapabilityBoundingSet = "";
      PrivateDevices = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
    };
  };
}
