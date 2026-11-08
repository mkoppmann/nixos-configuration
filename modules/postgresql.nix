{
  config,
  lib,
  pkgs,
  ...
}:
let
  globalsDirectory = "/var/backup/postgresql/globals";
in
{
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

  # The Borg job starts the dumps; see backup.nix.
  services.postgresqlBackup = {
    enable = true;
    startAt = [ ];
    location = "/var/backup/postgresql";
    compression = "none";
    pgdumpOptions = "--format=custom";
    # Databases are declared by the modules of their services.
    databases = lib.unique config.services.postgresql.ensureDatabases;
  };

  systemd.tmpfiles.rules = [ "d ${globalsDirectory} 0700 postgres postgres - -" ];

  # Roles, their password hashes and memberships are not part of the dumps.
  systemd.services.postgresql-globals-backup = {
    description = "Backup of PostgreSQL globals";
    requires = [ "postgresql.target" ];
    after = [ "postgresql.target" ];
    path = [ config.services.postgresql.package ];
    script = ''
      pg_dumpall --globals-only > ${globalsDirectory}/globals.in-progress.sql
      mv ${globalsDirectory}/globals.in-progress.sql ${globalsDirectory}/globals.sql
    '';
    serviceConfig = {
      Type = "oneshot";
      User = "postgres";
      UMask = "0077";
    };
  };
}
