# Evaluation only: no builds, PostgreSQL processes, or production secrets.
# Use a path flake so new files in the working tree are included before staging.
let
  flake = builtins.getFlake ("path:" + toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  system = flake.nixosConfigurations.apollo;
  config = system.config;
  backup = config.services.postgresqlBackup;
  schedule = lib.toList backup.startAt;
  globals = config.systemd.services.postgresql-globals-backup;
  declared = lib.unique config.services.postgresql.ensureDatabases;
  expected = [
    "authentik"
    "matrix-authentication-service"
    "matrix-synapse"
    "nextcloud"
    "onlyoffice"
    "pleroma"
    "vaultwarden"
  ];

  extend = module: (system.extendModules { modules = [ module ]; }).config;
  evaluates = cfg: builtins.seq cfg.system.build.toplevel.drvPath true;
  rejects =
    message: cfg:
    let
      failures = lib.filter (a: !a.assertion) cfg.assertions;
    in
    assert lib.any (a: lib.hasInfix message a.message) failures;
    assert !(builtins.tryEval cfg.system.build.toplevel.drvPath).success;
    true;

  added = extend {
    services.postgresql.ensureDatabases = [
      "t02-coverage-check"
      "t02-coverage-check"
    ];
  };
  additionalBackup = extend {
    services.postgresqlBackup.databases = [ "t02-manual-check" ];
  };
  missing = extend {
    services.postgresqlBackup.databases = lib.mkForce (
      lib.filter (db: db != "onlyoffice") backup.databases
    );
  };
  disabled = extend {
    services.postgresqlBackup.enable = lib.mkForce false;
  };
  allDatabases = extend {
    services.postgresqlBackup = {
      backupAll = lib.mkForce true;
      databases = lib.mkForce [ ];
    };
  };
in
assert evaluates config;
assert lib.all (db: builtins.elem db declared) expected;
assert lib.sort builtins.lessThan backup.databases == lib.sort builtins.lessThan declared;
assert backup.enable && !backup.backupAll;
assert backup.compression == "none" && backup.pgdumpOptions == "--format=custom";
assert lib.all (
  db:
  let
    unit = config.systemd.services."postgresqlBackup-${db}";
  in
  unit.enable
  && lib.hasInfix "pg_dump --format=custom ${db}" unit.script
  && unit.startAt == schedule
  && !(builtins.hasAttr "postgresqlBackup-${db}" config.systemd.timers)
) declared;
assert globals.enable;
assert globals.startAt == schedule;
assert globals.serviceConfig.User == "postgres" && globals.serviceConfig.Group == "postgres";
assert globals.serviceConfig.UMask == "0077";
assert builtins.elem "postgresql.target" globals.requires;
assert builtins.elem "postgresql.target" globals.after;
assert globals.unitConfig.RequiresMountsFor == [ "${backup.location}/globals" ];
assert globals.environment.PG_BACKUP_DIR == "${backup.location}/globals";
assert globals.environment.PGHOST == "/run/postgresql";
assert globals.environment.PGPORT == toString config.services.postgresql.settings.port;
assert globals.environment.PGUSER == "postgres";
assert builtins.elem (toString config.services.postgresql.package) (map toString globals.path);
assert builtins.elem "d '${backup.location}/globals' 0700 postgres postgres - -" config.systemd.tmpfiles.rules;
assert schedule == [ ];
assert !(builtins.hasAttr "postgresql-globals-backup" config.systemd.timers);
{
  declaredDatabases = lib.sort builtins.lessThan declared;
  backupDatabases = lib.sort builtins.lessThan backup.databases;
  automaticDumpSchedule = schedule;
  scenarios = {
    baseline = true;
    addedDatabase =
      assert evaluates added;
      assert builtins.elem "t02-coverage-check" added.services.postgresqlBackup.databases;
      assert builtins.length (
        lib.filter (db: db == "t02-coverage-check") added.services.postgresqlBackup.databases
      ) == 1;
      assert added.systemd.services.postgresqlBackup-t02-coverage-check.enable;
      assert !(builtins.hasAttr "postgresqlBackup-t02-coverage-check" added.systemd.timers);
      true;
    additionalBackupAllowed =
      assert evaluates additionalBackup;
      assert builtins.elem "t02-manual-check" additionalBackup.services.postgresqlBackup.databases;
      assert additionalBackup.systemd.services.postgresqlBackup-t02-manual-check.enable;
      true;
    missingDatabaseRejected = rejects "missing declared databases: onlyoffice." missing;
    disabledBackupsRejected = rejects "services.postgresqlBackup.enable must remain true." disabled;
    dumpAllRejected = rejects "services.postgresqlBackup.backupAll must remain false" allDatabases;
  };
}
