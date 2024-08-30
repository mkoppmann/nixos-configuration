{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib.modules)
    mkOverride
    ;

  host = "idp.ncrypt.at";
in
{
  services.authentik = {
    enable = true;
    environmentFile = "/persist/var/lib/authentik/authentik-env";
    createDatabase = false;
    nginx.enable = false;
    settings = {
      avatars = "initials";
      cert_discovery_dir = "env://CREDENTIALS_DIRECTORY";
      disable_startup_analytics = true;
      disable_update_check = true;
      email = {
        host = "smtp.webspace.bz";
        port = 465;
        username = "idp@ncrypt.at";
        use_tls = true;
        use_ssl = false;
        from = "Authentik ncrypt.at";
      };
      error_reporting.enabled = false;
      postgresql = {
        user = "authentik";
        name = "authentik";
        host = "";
      };
    };
  };

  services.authentik-ldap.enable = false;

  services.authentik-radius.enable = false;

  systemd.services = {
    authentik-migrate = {
      requires = [ "postgresql.service" ];
      after = [
        "network-online.target"
        "postgresql.service"
      ];
    };

    authentik-worker = {
      serviceConfig.LoadCredential = [
        "${host}.pem:${config.security.acme.certs.${host}.directory}/fullchain.pem"
        "${host}.key:${config.security.acme.certs.${host}.directory}/key.pem"
      ];
    };

    authentik = {
      after = [
        "network-online.target"
        "redis-authentik.service"
        "postgresql.service"
      ];
    };
  };

  services.postgresql.package = mkOverride 998 pkgs.postgresql_16_jit;
}
