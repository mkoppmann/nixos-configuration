{
  config,
  ...
}:
{
  services.vaultwarden = {
    enable = true;
    dbBackend = "postgresql";
    environmentFile = "/var/lib/bitwarden_rs/.env";

    config = {
      DATABASE_URL = "postgresql:///vaultwarden";
      SIGNUPS_ALLOWED = false;
      SIGNUPS_VERIFY = true;
      SHOW_PASSWORD_HINT = false;
      DOMAIN = "https://pw.ncrypt.at";
      _ENABLE_YUBICO = false;
      _ENABLE_DUO = false;

      ROCKET_ADDRESS = "127.0.0.1";
      ROCKET_PORT = 8222;
      ROCKET_LOG = "critical";

      SMTP_HOST = "smtp.webspace.bz";
      SMTP_FROM = "pw@ncrypt.at";
      SMTP_FROM_NAME = "Vaultwarden ncrypt.at";
      SMTP_USERNAME = "pw@ncrypt.at";
      SMTP_AUTH_MECHANISM = "\"Login\"";
    };
  };

  environment.persistence."/persist".directories = [
    "/var/lib/bitwarden_rs"
  ];

  services.postgresql = {
    ensureDatabases = [ "vaultwarden" ];
    ensureUsers = [
      {
        name = "vaultwarden";
        ensureDBOwnership = true;
      }
    ];
  };

  services.nginx = {
    virtualHosts."pw.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
        proxyWebsockets = true;
      };
      locations."= /identity/connect/token" = {
        proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
        extraConfig = "limit_req zone=login burst=20 nodelay;";
      };
    };
  };
}
