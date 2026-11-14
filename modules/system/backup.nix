{
  config,
  lib,
  pkgs,
  ...
}:
let
  # Archive path → dataset. Both are snapshotted in one atomic command.
  datasets = {
    persist = "rpool/safe/persist";
    "var/log" = "rpool/safe/log";
  };
  snapshots = lib.mapAttrsToList (_: dataset: "${dataset}@borg") datasets;
  root = "/run/borgbackup-sidechest";
  zfs = config.boot.zfs.package;
  dumps = map (db: "postgresqlBackup-${db}.service") config.services.postgresqlBackup.databases ++ [
    "postgresql-globals-backup.service"
  ];
  ping = suffix: ''
    ${pkgs.curl}/bin/curl -fsS -m 10 --retry 5 -o /dev/null \
      "$(cat ${config.sops.secrets.healthchecks_backup_url.path})${suffix}"
  '';
in
{
  sops.secrets = {
    borg_passphrase = { };
    borg_ssh_key = { };
    healthchecks_backup_url = { };
  };

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

  services.borgbackup.jobs.sidechest = {
    repo = "ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg";
    encryption = {
      mode = "repokey-blake2";
      passCommand = "cat ${config.sops.secrets.borg_passphrase.path}";
    };
    environment.BORG_RSH = "ssh -i ${config.sops.secrets.borg_ssh_key.path}";
    doInit = false;
    compression = "auto,zstd";
    failOnWarnings = true;
    startAt = "*-*-* 03:00:00 Europe/Vienna";
    persistentTimer = true;

    # Relative to the snapshot mounts below, so archives contain `persist/…`
    # and `var/log/…`.
    paths = lib.attrNames datasets;
    exclude = [
      "persist/var/lib/postgresql"
      "persist/root/.cache/borg"
      "persist/var/lib/systemd/random-seed"
      "var/log/nginx/access.log"
    ];

    # PostgreSQL is backed up through the dumps, which land in the snapshot.
    preHook = ''
      systemctl start ${lib.escapeShellArgs dumps}
      for snapshot in ${lib.escapeShellArgs snapshots}; do
        ${zfs}/bin/zfs destroy "$snapshot" 2>/dev/null || true
      done
      ${zfs}/bin/zfs snapshot ${lib.escapeShellArgs snapshots}
      ${lib.concatStrings (
        lib.mapAttrsToList (path: dataset: ''
          mkdir -p ${root}/${path}
          ${zfs}/bin/mount.zfs -o ro ${dataset}@borg ${root}/${path}
        '') datasets
      )}
      cd ${root}
    '';
    postHook = ''
      cd /
      ${lib.concatMapStrings (path: "${pkgs.util-linux}/bin/umount ${root}/${path} || true\n") (
        lib.attrNames datasets
      )}
      for snapshot in ${lib.escapeShellArgs snapshots}; do
        ${zfs}/bin/zfs destroy "$snapshot" || true
      done
    '';

    prune.keep = {
      daily = 7;
      weekly = 4;
      monthly = 6;
    };
  };

  systemd.services.borgbackup-job-sidechest.serviceConfig = {
    # ExecStartPost then runs only after a successful run.
    Type = "oneshot";
    # The snapshot mounts live in the unit's private mount namespace.
    RuntimeDirectory = "borgbackup-sidechest";
    ExecStartPre = [ "-${pkgs.writeShellScript "ping-start" (ping "/start")}" ];
    ExecStartPost = [ "-${pkgs.writeShellScript "ping-success" (ping "")}" ];
  };

  systemd.services.borgbackup-check-sidechest = {
    description = "Verify the sidechest Borg repository and its latest archive";
    startAt = "*-*-01 05:00:00 Europe/Vienna";
    path = [
      config.services.borgbackup.package
      pkgs.openssh
    ];
    environment = {
      inherit (config.systemd.services.borgbackup-job-sidechest.environment)
        BORG_REPO
        BORG_PASSCOMMAND
        BORG_RSH
        ;
    };
    script = "borg check --lock-wait 3600 --verify-data --last 1";
    serviceConfig = {
      Type = "oneshot";
      CPUSchedulingPolicy = "idle";
      IOSchedulingClass = "idle";
    };
  };

  services.sanoid = {
    enable = true;
    datasets.${datasets.persist} = {
      autosnap = true;
      autoprune = true;
      hourly = 24;
      daily = 7;
      monthly = 0;
      yearly = 0;
    };
  };
}
