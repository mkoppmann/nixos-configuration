{ config, lib, pkgs, ... }:
let
  backup = config.services.postgresqlBackup;
  borg = config.services.borgbackup.jobs.sidechest;
  state = "/persist/var/lib/apollo-backup";
  runtime = "/run/apollo-backup";
  applications = [
    "actual" "authentik" "authentik-worker" "matrix-synapse"
    "matrix-authentication-service" "phpfpm-nextcloud" "nextcloud-notify_push"
    "pleroma" "vaultwarden"
  ];
  jobs = [ "nextcloud-cron" "synapse-auto-compressor" ];
  migrations = [
    "authentik-migrate" "pleroma-migrations" "nextcloud-setup"
    "nextcloud-update-db" "nextcloud-notify_push_setup"
  ] ++ lib.optional config.services.nextcloud.autoUpdateApps.enable "nextcloud-update-plugins";
  timers = jobs ++ lib.optional config.services.nextcloud.autoUpdateApps.enable "nextcloud-update-plugins";
  hosts = [
    "budget.ncrypt.at" "idp.ncrypt.at" "matrix.ncrypt.at" "auth.matrix.ncrypt.at"
    "cloud.ncrypt.at" "pw.ncrypt.at" "communicating.cypherpunk.observer"
    "media.communicating.cypherpunk.observer"
  ];
  settings = pkgs.writeText "apollo-backup.json" (builtins.toJSON {
    inherit state runtime;
    applications = map (n: "${n}.service") applications;
    jobs = map (n: "${n}.service") jobs;
    migrations = map (n: "${n}.service") migrations;
    timers = map (n: "${n}.timer") timers;
    databases = lib.unique backup.databases;
    dumpDirectory = backup.location;
    pgPort = toString config.services.postgresql.settings.port;
    datasets = { persist = "rpool/safe/persist"; "var/log" = "rpool/safe/log"; };
    captureSeconds = 480;
    resumeSeconds = 120;
    minimumFreePercent = 10;
    listeners = {
      "actual.service" = { host = "127.0.0.1"; port = 5006; };
      "authentik.service" = { host = "localhost"; port = 9443; };
      "matrix-synapse.service" = { host = "127.0.0.1"; port = 8008; };
      "matrix-authentication-service.service" = { host = "127.0.0.1"; port = 8091; };
      "pleroma.service" = { host = "127.0.0.1"; port = 4000; };
      "vaultwarden.service" = { host = "127.0.0.1"; port = config.services.vaultwarden.config.ROCKET_PORT; };
      "phpfpm-nextcloud.service" = { socket = config.services.phpfpm.pools.nextcloud.socket; };
      "nextcloud-notify_push.service" = { socket = config.services.nextcloud.notify_push.socketPath; };
    };
    borg = {
      inherit (borg) repo compression;
      prefix = borg.archiveBaseName;
      keep = borg.prune.keep;
      # Preserve the reviewed absolute exclusions as the configuration interface.
      # The uploader uses relative paths beneath its read-only staging root.
      exclude = map (p: "pp:${lib.removePrefix "/" p}") borg.exclude ++ [
        "pp:persist/var/lib/apollo-backup"
        "sh:**/.zfs" "sh:persist/var/backup/postgresql/.capture-*"
        "sh:persist/var/backup/postgresql/.publish-*" "sh:**/*.in-progress.sql"
      ];
    };
  });
  python = pkgs.python3;
  program = pkgs.writeShellScriptBin "apollo-backup" ''
    export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
    export PATH=${lib.makeBinPath [
      pkgs.coreutils pkgs.util-linux config.systemd.package pkgs.zfs
      config.services.postgresql.package config.services.borgbackup.package pkgs.openssh
    ]}:$PATH
    exec ${python}/bin/python3 ${../scripts/backup-orchestration.py} ${settings} "$@"
  '';
  command = "${program}/bin/apollo-backup";
  verification = pkgs.writeShellScriptBin "apollo-backup-verify" ''
    export PYTHONTZPATH=${pkgs.tzdata}/share/zoneinfo
    export PATH=${lib.makeBinPath [
      pkgs.coreutils pkgs.util-linux config.systemd.package pkgs.zfs
      config.services.postgresql.package config.services.borgbackup.package pkgs.openssh
    ]}:$PATH
    exec ${python}/bin/python3 ${../scripts/backup-verification.py} ${settings} ${../scripts/backup-orchestration.py} "$@"
  '';
  testScenarios = [ "dump" "snapshot" "timeout" "kill" "retain" "upload" "low-space" "concurrency" ];
  testUnits = map (name: "apollo-backup-test@${name}.service") testScenarios;
  common = {
    unitConfig.RequiresMountsFor = [ "/persist" "/var/log" backup.location ];
    environment = borg.environment // {
      BORG_REPO = borg.repo;
      BORG_PASSCOMMAND = borg.encryption.passCommand;
      BORG_BASE_DIR = "/root";
      BORG_CACHE_DIR = "/root/.cache/borg";
      BORG_CONFIG_DIR = "/root/.config/borg";
      BORG_SECURITY_DIR = "/root/.config/borg/security";
      PYTHONUNBUFFERED = "1";
    };
    restartIfChanged = false;
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      TimeoutStartSec = "infinity";
      TimeoutStopSec = "5s";
      KillMode = "control-group";
      # Snapshot bind mounts must be visible to the recovery unit too.
      PrivateMounts = false;
    };
  };
  manualLock = ''
    exec 9<>${runtime}/operation.lock
    ${pkgs.util-linux}/bin/flock --exclusive --nonblock 9 || exit 75
  '';
in
{
  assertions = [
    {
      assertion = borg.paths == [ "/persist" "/var/log" ]
        && borg.user == "root" && borg.encryption.passCommand != null
        && borg.archiveBaseName != null && borg.prune.prefix == borg.archiveBaseName;
      message = "Apollo backup: source layout, root user, passCommand and archive/prune prefix must match the snapshot uploader.";
    }
    {
      assertion = lib.all (p: lib.hasPrefix "/" p) borg.exclude;
      message = "Apollo backup: exclusions must be absolute paths for staging translation.";
    }
    {
      assertion = borg.patterns == [ ] && borg.dumpCommand == null && borg.createCommand == "create"
        && lib.all (name: borg.${name} == "") [
          "extraArgs" "extraCreateArgs" "extraPruneArgs" "extraCompactArgs"
          "preHook" "postHook" "postCreate" "postPrune"
        ];
      message = "Apollo backup: review uploader support before adding Borg hooks, patterns or extra command arguments.";
    }
    {
      assertion = backup.startAt == [ ] && borg.startAt == [ ];
      message = "Apollo backup: independent dump and Borg schedules must remain disabled.";
    }
    {
      assertion = backup.location == "/var/backup/postgresql"
        && backup.compression == "none" && backup.pgdumpOptions == "--format=custom"
        && lib.all (db: builtins.match "[a-zA-Z0-9_-]+" db != null) backup.databases;
      message = "Apollo backup: capture requires the reviewed PostgreSQL dump path and custom format.";
    }
    {
      assertion = config.fileSystems."/persist".device == "rpool/safe/persist"
        && config.fileSystems."/var/log".device == "rpool/safe/log";
      message = "Apollo backup: review snapshot coverage when changing datasets.";
    }
  ];

  services.borgbackup.jobs.sidechest.startAt = lib.mkForce [ ];
  services.borgbackup.jobs.sidechest.doInit = false;
  services.borgbackup.jobs.sidechest.failOnWarnings = true;
  systemd.tmpfiles.rules = [
    "d ${state} 0700 root root - -"
    "d ${runtime} 0755 root root - -"
    "d ${runtime}/private 0700 root root - -"
    "f ${runtime}/operation.lock 0660 root postgres - -"
    "f ${runtime}/recovery.lock 0600 root root - -"
  ];
  environment.systemPackages = [ program verification ] ++ map
    (name: pkgs.writeShellScriptBin "apollo-backup-${name}" ''
      exec ${command} ${name} "$@"
    '') [ "status" "preflight" ];

  systemd.services = lib.mkMerge [
    (lib.genAttrs (applications ++ jobs ++ migrations) (_: {
      # Existing processes drain/stop explicitly; new starts are held back.
      unitConfig.ConditionPathExists = "!${runtime}/quiescing";
    }))
    (lib.genAttrs (map (db: "postgresqlBackup-${db}") backup.databases ++ [ "postgresql-globals-backup" ]) (_: {
      script = lib.mkBefore manualLock;
    }))
    {
      apollo-backup = lib.recursiveUpdate common {
        description = "Apollo consistent nightly capture and application resumption";
        requires = [ "postgresql.target" ];
        after = [ "postgresql.target" "apollo-backup-boot-recovery.service" ];
        wants = [ "apollo-backup-watchdog.timer" ];
        unitConfig.ConditionPathExists = "!${state}/deployment-hold";
        unitConfig.OnSuccess = [ "apollo-backup-upload.service" ];
        serviceConfig.ExecStart = "${command} capture";
        # Do not put recovery under this unit's five-second stop/kill budget.
        serviceConfig.ExecStopPost = "${config.systemd.package}/bin/systemctl start --no-block apollo-backup-recover.service";
      };
      apollo-backup-upload = lib.recursiveUpdate common {
        description = "Upload Apollo's retained ZFS capture through Borg";
        after = [ "network-online.target" "apollo-backup-boot-recovery.service" "apollo-backup-recover.service" ];
        wants = [ "network-online.target" ];
        unitConfig.ConditionPathExists = "!${state}/deployment-hold";
        serviceConfig.ExecStart = "${command} upload";
        serviceConfig.ExecStopPost = "${command} unmount";
      };
      apollo-backup-recover = lib.recursiveUpdate common {
        description = "Resume applications after interrupted Apollo backup maintenance";
        after = [ "apollo-backup.service" ] ++ testUnits;
        serviceConfig.ExecStart = "${command} recover";
      };
      apollo-backup-boot-recovery = lib.recursiveUpdate common {
        description = "Reconcile Apollo backup state after reboot";
        wantedBy = [ "multi-user.target" ];
        before = [ "apollo-backup.service" "apollo-backup-upload.service" ];
        serviceConfig.ExecStart = "${command} boot-recover";
      };
      apollo-backup-watchdog = lib.recursiveUpdate common {
        description = "Independent Apollo backup maintenance deadline and storage guard";
        after = [ "apollo-backup-boot-recovery.service" ];
        unitConfig.StartLimitIntervalSec = 0;
        serviceConfig.ExecStart = "${command} watchdog";
      };
      "apollo-backup-test@" = lib.recursiveUpdate common {
        description = "Supervised Apollo backup verification (%i)";
        after = [ "postgresql.target" "apollo-backup-boot-recovery.service" ];
        wants = [ "apollo-backup-watchdog.timer" ];
        serviceConfig.ExecStart = "${verification}/bin/apollo-backup-verify worker %i";
        serviceConfig.ExecStopPost = "${config.systemd.package}/bin/systemctl start --no-block apollo-backup-recover.service";
      };
      # Keep the old operator entrypoint, but never execute the generated live-source script.
      borgbackup-job-sidechest = lib.mkForce {
        description = "Request an upload of Apollo's retained capture";
        restartIfChanged = false;
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.systemd.package}/bin/systemctl start apollo-backup-upload.service";
        };
      };
    }
  ];
  systemd.timers = {
    apollo-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 03:00:00 Europe/Vienna";
        Persistent = false;
        AccuracySec = "1s";
        RandomizedDelaySec = 0;
      };
    };
    apollo-backup-upload = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* *:00:00 Europe/Vienna";
        Persistent = false;
        AccuracySec = "1s";
      };
    };
    apollo-backup-watchdog = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10s";
        OnUnitActiveSec = "1s";
        AccuracySec = "1s";
      };
    };
  };

  # File flag checks need no reload. Keep HTTP ACME challenges reachable.
  services.nginx.virtualHosts = lib.genAttrs hosts (_: {
    extraConfig = lib.mkBefore ''
      # Do not cache existence/nonexistence of the maintenance marker.
      open_file_cache off;
      set $apollo_backup_maintenance 0;
      if (-f ${runtime}/maintenance) { set $apollo_backup_maintenance 1; }
      if ($uri ~ "^/\\.well-known/acme-challenge/") { set $apollo_backup_maintenance 0; }
      if ($apollo_backup_maintenance = 1) { return 503; }
    '';
  });
}
