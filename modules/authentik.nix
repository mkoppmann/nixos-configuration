{
  config,
  pkgs,
  ...
}:
let
  # Upstream Authentik takes the first X-Forwarded-For entry.
  proxyHeaders = (import ../lib/nginx-proxy.nix).clientAddressHeaders;

  # Real copies: Authentik rejects blueprints that resolve to a path outside
  # this directory, which rules out symlinks into other store paths.
  blueprints = pkgs.runCommand "authentik-blueprints" { } ''
    cp -rL --no-preserve=mode ${config.services.authentik.authentikComponents.staticWorkdirDeps}/blueprints $out
    install -D -m 0444 ${./authentik-applications.yaml} $out/apollo/applications.yaml
  '';
in
{
  imports = [ ./authentik-sandbox.nix ];

  sops = {
    secrets = {
      authentik_secret_key = { };
      authentik_smtp_password = { };
      immich_openid_client_secret = { };
      matrix_openid_client_secret = { };
    };
    templates."authentik.env" = {
      # The client secrets are read by the applications blueprint.
      content = ''
        AUTHENTIK_SECRET_KEY=${config.sops.placeholder.authentik_secret_key}
        AUTHENTIK_EMAIL__PASSWORD=${config.sops.placeholder.authentik_smtp_password}
        ACTUAL_CLIENT_SECRET=${config.sops.placeholder.actual_openid_client_secret}
        IMMICH_CLIENT_SECRET=${config.sops.placeholder.immich_openid_client_secret}
        MATRIX_CLIENT_SECRET=${config.sops.placeholder.matrix_openid_client_secret}
        NEXTCLOUD_CLIENT_SECRET=${config.sops.placeholder.nextcloud_openid_client_secret}
      '';
      restartUnits = [
        "authentik.service"
        "authentik-worker.service"
      ];
    };
  };

  services.authentik = {
    enable = true;
    environmentFile = config.sops.templates."authentik.env".path;
    createDatabase = false;
    nginx.enable = false;
    settings = {
      avatars = "initials";
      blueprints_dir = blueprints;
      disable_startup_analytics = true;
      disable_update_check = true;
      email = {
        host = "smtp.webspace.bz";
        port = 465;
        username = "idp@ncrypt.at";
        use_tls = false;
        use_ssl = true;
        from = "Authentik ncrypt.at <idp@ncrypt.at>";
      };
      error_reporting.enabled = false;
      # Only Nginx on this host may set forwarding headers.
      listen.trusted_proxy_cidrs = [
        "127.0.0.0/8"
        "::1/128"
      ];
      postgresql = {
        user = "authentik";
        name = "authentik";
        host = "/run/postgresql";
        sslmode = "disable";
      };
    };
  };

  services.authentik-ldap.enable = false;

  services.authentik-radius.enable = false;

  systemd.services = {
    authentik-migrate = {
      requires = [ "postgresql.service" ];
      after = [ "postgresql.service" ];
    };
  };

  environment.persistence."/persist".directories = [
    "/var/lib/private/authentik"
  ];

  services.postgresql = {
    ensureDatabases = [ "authentik" ];
    ensureUsers = [
      {
        name = "authentik";
        ensureDBOwnership = true;
      }
    ];
  };

  services.nginx = {
    virtualHosts."idp.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "https://localhost:9443";
        recommendedProxySettings = false;
        extraConfig = proxyHeaders;
      };
      locations."/api/v3/flows/executor/" = {
        proxyPass = "https://localhost:9443";
        recommendedProxySettings = false;
        extraConfig = proxyHeaders + "limit_req zone=login burst=20 nodelay;";
      };
      # Authentik sends each file’s date as Last-Modified, and every file in the
      # Nix store dates from 1970: browsers would keep files for years and be
      # told that changed ones are unchanged. Only chunks and assets carry
      # content hashes in their names.
      locations."/static/" = {
        proxyPass = "https://localhost:9443";
        recommendedProxySettings = false;
        extraConfig = proxyHeaders + "proxy_hide_header Last-Modified;";
      };
      locations."~ ^/static/dist/(.+/)?(chunks|assets)/" = {
        proxyPass = "https://localhost:9443";
        recommendedProxySettings = false;
        extraConfig = proxyHeaders + ''
          proxy_hide_header Last-Modified;
          proxy_hide_header Cache-Control;
          add_header Cache-Control "public, max-age=31536000, immutable";
        '';
      };
    };
  };
}
