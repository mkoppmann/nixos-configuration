# Evaluate on a machine with Nix; no build, secrets or server access required.
let
  flake = builtins.getFlake ("path:" + toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  config = flake.nixosConfigurations.apollo.config;
  services = config.systemd.services;
  timers = config.systemd.timers;
  covered = [
    "actual" "authentik" "authentik-worker" "matrix-synapse"
    "matrix-authentication-service" "phpfpm-nextcloud" "nextcloud-notify_push"
    "pleroma" "vaultwarden" "nextcloud-cron" "synapse-auto-compressor"
    "authentik-migrate" "pleroma-migrations" "nextcloud-setup"
    "nextcloud-update-db" "nextcloud-notify_push_setup"
  ];
  legacyTimers = [ "borgbackup-job-sidechest" "postgresql-globals-backup" ]
    ++ map (db: "postgresqlBackup-${db}") config.services.postgresqlBackup.databases;
in
assert builtins.seq config.system.build.toplevel.drvPath true;
assert config.services.postgresqlBackup.startAt == [ ];
assert config.services.borgbackup.jobs.sidechest.startAt == [ ];
assert lib.all (name: !(builtins.hasAttr name timers)) legacyTimers;
assert timers.apollo-backup.timerConfig.OnCalendar == "*-*-* 03:00:00 Europe/Vienna";
assert !timers.apollo-backup.timerConfig.Persistent;
assert timers.apollo-backup.timerConfig.RandomizedDelaySec == 0;
assert !timers.apollo-backup-upload.timerConfig.Persistent;
assert services.apollo-backup.unitConfig.ConditionPathExists == "!/persist/var/lib/apollo-backup/deployment-hold";
assert services.apollo-backup-upload.unitConfig.ConditionPathExists == "!/persist/var/lib/apollo-backup/deployment-hold";
assert timers.apollo-backup-watchdog.timerConfig.OnUnitActiveSec == "1s";
assert lib.all (name: services.${name}.unitConfig.ConditionPathExists == "!/run/apollo-backup/quiescing") covered;
assert lib.all (name: !(builtins.hasAttr "ConditionPathExists" services.${name}.unitConfig)) [
  "onlyoffice-docservice" "onlyoffice-converter" "rabbitmq"
];
assert services.apollo-backup.serviceConfig.KillMode == "control-group";
assert services.apollo-backup.serviceConfig.TimeoutStopSec == "5s";
assert lib.hasInfix "start --no-block apollo-backup-recover.service" services.apollo-backup.serviceConfig.ExecStopPost;
assert services.apollo-backup.unitConfig.OnSuccess == [ "apollo-backup-upload.service" ];
assert builtins.elem "apollo-backup.service" services.apollo-backup-recover.after;
assert builtins.elem "multi-user.target" services.apollo-backup-boot-recovery.wantedBy;
assert lib.hasInfix "apollo-backup-upload.service" services.borgbackup-job-sidechest.serviceConfig.ExecStart;
assert lib.all (db: lib.hasInfix "operation.lock" services."postgresqlBackup-${db}".script)
  config.services.postgresqlBackup.databases;
assert lib.hasInfix "operation.lock" services.postgresql-globals-backup.script;
assert lib.hasInfix "apollo_backup_maintenance" config.services.nginx.virtualHosts."cloud.ncrypt.at".extraConfig;
assert !(lib.hasInfix "apollo_backup_maintenance" config.services.nginx.virtualHosts."office.ncrypt.at".extraConfig);
assert lib.hasInfix "open_file_cache off" config.services.nginx.virtualHosts."cloud.ncrypt.at".extraConfig;
assert config.system.stateVersion == "23.11";
assert config.home-manager.users.mcp.home.stateVersion == "23.11";
{
  schedule = timers.apollo-backup.timerConfig;
  captureUnits = covered;
  consistencyExcluded = [ "OnlyOffice" "RabbitMQ" "live host state and logs" ];
  checks = "passed";
}
