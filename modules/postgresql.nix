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
  };

  services.postgresqlBackup = {
    enable = true;
    startAt = "*-*-* 23:05:00";
    location = "/var/backup/postgresql";
    backupAll = true;
    compression = "zstd";
  };
}
