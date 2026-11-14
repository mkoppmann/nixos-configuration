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
    # Must stay explicit: with stateVersion 23.11, authentik-nix would select
    # PostgreSQL 14 otherwise.
    package = pkgs.postgresql_16;
    enableTCPIP = false;

    # Memory budget for 15 GiB of RAM: 4 GiB for the ZFS cache (see storage.nix),
    # 2 GiB of shared buffers here, the rest for the applications.
    settings = {
      # Without TCP, PostgreSQL still listens on localhost. Clients use the
      # socket, so the unit has no network at all (PrivateNetwork below).
      listen_addresses = lib.mkForce "";
      shared_buffers = "2GB";
      effective_cache_size = "6GB";
      work_mem = "16MB";
      maintenance_work_mem = "512MB";
      # Storage is SSD-backed.
      random_page_cost = 1.1;
      max_wal_size = "4GB";
      # The default 20 % leaves tables with millions of rows unvacuumed for
      # months.
      autovacuum_vacuum_scale_factor = 0.05;
      autovacuum_analyze_scale_factor = 0.02;
      shared_preload_libraries = "pg_stat_statements";
    };

    authentication = pkgs.lib.mkForce ''
      #type database  DBuser   auth-method
      local sameuser  all      peer
      local all       postgres peer
    '';
  };

  systemd.services.postgresql.serviceConfig.PrivateNetwork = true;

  systemd.services.postgresql-setup.script = lib.mkAfter ''
    psql -d postgres -c 'CREATE EXTENSION IF NOT EXISTS pg_stat_statements'
  '';

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
