{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.nextcloud = {
    enable = true;
    hostName = "cloud.ncrypt.at";
    package = pkgs.nextcloud29;

    configureRedis = true;
    database.createLocally = false;
    notify_push.enable = true;
    secretFile = "/var/lib/nextcloud/secrets.json";

    phpOptions."opcache.interned_strings_buffer" = "16";
    maxUploadSize = "16G";
    https = true;

    autoUpdateApps.enable = false;
    extraAppsEnable = true;
    extraApps = with config.services.nextcloud.package.packages.apps; {
      # Packaged apps:
      # https://github.com/NixOS/nixpkgs/blob/master/pkgs/servers/nextcloud/packages/nextcloud-apps.json
      inherit
        calendar
        contacts
        notes
        notify_push
        onlyoffice
        tasks
        user_oidc
        ;
    };

    config = {
      adminuser = "ncroot";
      adminpassFile = "/var/lib/nextcloud/adminpass";

      dbtype = "pgsql";
      dbhost = "/run/postgresql";
      dbuser = "nextcloud";
      dbname = "nextcloud";
    };

    settings = {
      default_phone_region = "AT";
      enable_preview = true;
      htaccess.RewriteBase = "/";

      mail_smtpmode = "smtp";
      mail_sendmailmode = "smtp";
      mail_smtpsecure = "ssl";
      mail_smtphost = "smtp.webspace.bz";
      mail_smtpport = "465";
      mail_from_address = "cloud";
      mail_domain = "ncrypt.at";
      mail_smtpauthtype = "LOGIN";
      mail_smtpauth = true;
      mail_smtpname = "cloud@ncrypt.at";

      overwriteprotocol = "https";
      trusted_proxies = [
        "127.0.0.1"
        "152.53.35.165"
        "2a0a:4cc0:100:23::bad:c0de"
      ];
    };
  };

  systemd.services."nextcloud-setup" = {
    requires = [ "postgresql.service" ];
    after = [ "postgresql.service" ];
  };
}
