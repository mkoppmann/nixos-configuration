{
  config,
  lib,
  pkgs,
  ...
}:
let
  # authentik-nix names Authentik’s release in its lock file, which this
  # flake’s lock file repeats for the pinned revision.
  pinnedRelease = (lib.importJSON ../../../flake.lock).nodes.authentik-src.original.ref;

  host = import ../../../host.nix;
  inherit (import ../../../lib/nginx-headers.nix) hsts proxy-hsts;

  # Upstream Authentik takes the first X-Forwarded-For entry.
  proxyHeaders = (import ../../../lib/nginx-proxy.nix).clientAddressHeaders;

  # Real copies: Authentik rejects blueprints that resolve to a path outside
  # this directory, which rules out symlinks into other store paths.
  blueprints = pkgs.runCommand "authentik-blueprints" { } ''
    cp -rL --no-preserve=mode ${config.services.authentik.authentikComponents.staticWorkdirDeps}/blueprints $out
    install -D -m 0444 ${./applications.yaml} $out/apollo/applications.yaml
  '';
in
{
  imports = [ ./sandbox.nix ];

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
      listen = {
        # Only Nginx reaches Authentik. The default is every interface.
        http = [
          "127.0.0.1:9000"
          "[::1]:9000"
        ];
        https = [
          "127.0.0.1:9443"
          "[::1]:9443"
        ];
        metrics = [
          "127.0.0.1:9300"
          "[::1]:9300"
        ];
        # Only Nginx on this host may set forwarding headers.
        trusted_proxy_cidrs = [
          "127.0.0.0/8"
          "::1/128"
        ];
      };
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

  # The automatic upgrades leave authentik-nix at its pinned revision. This
  # unit fails, and so mails, while authentik-nix offers another Authentik
  # release than the pinned one.
  systemd.services.authentik-update-check = {
    description = "Fail when authentik-nix offers a newer Authentik";
    startAt = "daily";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    path = [
      pkgs.curl
      pkgs.jq
    ];
    script = ''
      offered=$(
        curl -fsS -m 30 --retry 3 \
          https://raw.githubusercontent.com/nix-community/authentik-nix/main/flake.lock |
          jq -er '.nodes."authentik-src".original.ref'
      )
      echo "Pinned: ${pinnedRelease}, offered: $offered"
      [ "$offered" = ${lib.escapeShellArg pinnedRelease} ]
    '';
    serviceConfig = {
      Type = "oneshot";
      DynamicUser = true;
      CapabilityBoundingSet = "";
      PrivateDevices = true;
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectControlGroups = true;
      RestrictAddressFamilies = [
        "AF_INET"
        "AF_INET6"
      ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged"
      ];
    };
  };

  systemd.services = {
    authentik-migrate = {
      requires = [ "postgresql.target" ];
      after = [ "postgresql.target" ];
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
    # API tokens and app passwords skip the login flow and with it the admin
    # gate of the applications blueprint, so the API accepts them only from
    # WireGuard. Browsers use the session cookie, and the applications’ OAuth2
    # endpoints are outside /api/.
    commonHttpConfig = ''
      geo $authentik_outside_wireguard {
        default 1;
        ${host.wireguard.network} 0;
      }
      map $http_authorization $authentik_has_authorization {
        default 1;
        "" 0;
      }
      map $authentik_outside_wireguard$authentik_has_authorization$uri $authentik_token_outside_wireguard {
        default 0;
        ~^11/api/ 1;
      }
      map $uri $authentik_static_cache_control {
        default no-cache;
        "~^/static/dist/(.+/)?chunks/[^/]+$" "public, max-age=31536000, immutable";
      }
    '';

    virtualHosts."idp.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      extraConfig = proxy-hsts + ''
        if ($authentik_token_outside_wireguard) {
          return 403;
        }
      '';
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
      # Authentik’s own server derives a file’s Last-Modified and ETag from its
      # date and length, and every file in the Nix store dates from 1970: a
      # rebuilt file of the same length would pass for unchanged. Nginx sends
      # store files with an ETag made of their store path. Only chunks carry a
      # content hash in every name. Assets also hold files with fixed names.
      # The header is left off errors, so that no missing chunk is kept.
      locations."/static/" = {
        alias = "${config.services.authentik.authentikComponents.frontend}/";
        extraConfig = hsts + ''
          add_header Cache-Control $authentik_static_cache_control;
        '';
      };
    };
  };
}
