{
  config,
  lib,
  pkgs,
  ...
}:
let
  backup = config.services.postgresqlBackup;
  declaredDatabases = lib.unique config.services.postgresql.ensureDatabases;
  missingDatabases = lib.subtractLists backup.databases declaredDatabases;
  globalsDirectory = "${backup.location}/globals";
in
{
  assertions = [
    {
      assertion = backup.enable;
      message = "Apollo PostgreSQL backup: services.postgresqlBackup.enable must remain true.";
    }
    {
      assertion = !backup.backupAll;
      message = "Apollo PostgreSQL backup: services.postgresqlBackup.backupAll must remain false to retain custom-format per-database dumps.";
    }
    {
      assertion = missingDatabases == [ ];
      message = "Apollo PostgreSQL backup: missing declared databases: ${lib.concatStringsSep ", " missingDatabases}.";
    }
  ];

  # Databases and roles are declared by the modules of their services.
  environment.persistence."/persist".directories = [
    "/var/backup"
    "/var/lib/postgresql"
  ];

  services.postgresql = {
    enable = true;
    package = pkgs.postgresql_16_jit;
    enableJIT = true;
    enableTCPIP = false;

    authentication = pkgs.lib.mkForce ''
      #type database  DBuser   auth-method
      local sameuser  all      peer
      local all       postgres peer
    '';
  };

  services.postgresqlBackup = {
    enable = true;
    backupAll = false;
    startAt = [ ];
    location = "/var/backup/postgresql";
    compression = "none";
    pgdumpOptions = "--format=custom";

    # Include declarations contributed by service modules.
    databases = declaredDatabases;
  };

  systemd.tmpfiles.rules = [
    "d '${globalsDirectory}' 0700 postgres postgres - -"
  ];

  systemd.services.postgresql-globals-backup = {
    description = "Backup of PostgreSQL globals";
    requires = [ "postgresql.target" ];
    after = [ "postgresql.target" ];
    unitConfig.RequiresMountsFor = [ globalsDirectory ];
    inherit (backup) startAt;

    path = [
      pkgs.coreutils
      config.services.postgresql.package
    ];
    environment = {
      PGHOST = "/run/postgresql";
      PGPORT = toString config.services.postgresql.settings.port;
      PGUSER = "postgres";
      PG_BACKUP_DIR = globalsDirectory;
    };
    script = builtins.readFile ../scripts/postgresql-globals-backup.sh;

    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      Group = "postgres";
      UMask = "0077";
    };
  };
}
