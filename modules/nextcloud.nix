{
  config,
  pkgs,
  ...
}:
{
  imports = [ ./nextcloud-sandbox.nix ];

  sops = {
    secrets = {
      nextcloud_admin_password = { };
      nextcloud_openid_client_secret.restartUnits = [ "nextcloud-oidc.service" ];
      nextcloud_instanceid = { };
      nextcloud_passwordsalt = { };
      nextcloud_secret = { };
      nextcloud_smtp_password = { };
    };
    templates."nextcloud-secrets.json".content = builtins.toJSON {
      instanceid = config.sops.placeholder.nextcloud_instanceid;
      passwordsalt = config.sops.placeholder.nextcloud_passwordsalt;
      secret = config.sops.placeholder.nextcloud_secret;
      mail_smtppassword = config.sops.placeholder.nextcloud_smtp_password;
    };
  };

  services.nextcloud = {
    enable = true;
    hostName = "cloud.ncrypt.at";
    package = pkgs.nextcloud35;

    configureRedis = true;
    database.createLocally = false;
    notify_push.enable = true;
    secretFile = config.sops.templates."nextcloud-secrets.json".path;

    phpOptions = {
      "opcache.interned_strings_buffer" = "16";
      "session.upload_progress.enabled" = "0";
    };

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
        tasks
        user_oidc
        ;
    };

    config = {
      adminuser = "ncroot";
      adminpassFile = config.sops.secrets.nextcloud_admin_password.path;

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
      mail_smtpport = 465;
      mail_from_address = "cloud";
      mail_domain = "ncrypt.at";
      mail_smtpauthtype = "LOGIN";
      mail_smtpauth = true;
      mail_smtpname = "cloud@ncrypt.at";

      overwriteprotocol = "https";
      "overwrite.cli.url" = "https://${config.services.nextcloud.hostName}";
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

  # Login through Authentik; the matching provider is in the Authentik
  # applications blueprint.
  systemd.services.nextcloud-oidc = {
    description = "Configure Nextcloud’s Authentik login";
    requires = [ "nextcloud-setup.service" ];
    after = [ "nextcloud-setup.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Keeps the unit active, so a deploy that changes it runs it again.
      RemainAfterExit = true;
      User = "nextcloud";
      LoadCredential = config.systemd.services.nextcloud-setup.serviceConfig.LoadCredential ++ [
        "oidc_client_secret:${config.sops.secrets.nextcloud_openid_client_secret.path}"
      ];
    };
    script = ''
      occ=${config.services.nextcloud.occ}/bin/nextcloud-occ
      $occ user_oidc:provider Authentik \
        --clientid=s20Aqu1UTDPWkhJqNhWcVtmFLXFiyGtWBmIG6Nf8 \
        --clientsecret-file="$CREDENTIALS_DIRECTORY/oidc_client_secret" \
        --discoveryuri=https://idp.ncrypt.at/application/o/nextcloud/.well-known/openid-configuration \
        --scope="openid email offline_access profile" \
        --mapping-uid=user_id \
        --mapping-quota=quota \
        --unique-uid=0 \
        --check-bearer=0 \
        --bearer-provisioning=0 \
        --group-provisioning=0
      $occ config:app:set user_oidc allow_multiple_user_backends --value=0
    '';
  };

  environment.persistence."/persist".directories = [
    "/var/lib/nextcloud"
  ];

  services.postgresql = {
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [
      {
        name = "nextcloud";
        ensureDBOwnership = true;
      }
    ];
  };

  services.nginx = {
    virtualHosts."cloud.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      # Same routing as the module's `location /`.
      locations."= /login".extraConfig = ''
        limit_req zone=login burst=20 nodelay;
        try_files $uri $uri/ /index.php$request_uri;
      '';
    };
  };
}
