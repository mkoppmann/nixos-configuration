{
  config,
  lib,
  pkgs,
  ...
}:
{
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

    ensureDatabases = [
      "pleroma"
      "vaultwarden"
    ];

    ensureUsers = [
      {
        name = "pleroma";
        ensureDBOwnership = true;
      }
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
      }
    ];
  };

  services.postgresqlBackup = {
    enable = true;
    startAt = "*-*-* 23:05:00";
    location = "/var/backup/postgresql";
    compression = "none";
    pgdumpOptions = "--format=custom";

    databases = [
      "pleroma"
      "vaultwarden"
    ];
  };
}
