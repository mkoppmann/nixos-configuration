{
  config,
  lib,
  pkgs,
  ...
}:
let
  hsts = ''
    # Add HSTS header with preloading to HTTPS requests.
    add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload";
  '';

  csp = ''
    # Enable CSP for your services.
    add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; upgrade-insecure-requests;" always;
  '';

  referrer-policy = ''
    # Minimize information leaked to other domains
    add_header 'Referrer-Policy' 'no-referrer';
  '';

  x-frame-options = ''
    # Disable embedding as a frame
    add_header X-Frame-Options DENY;
  '';

  x-content-type-options = ''
    # Prevent injection of code in other mime types (XSS Attacks)
    add_header X-Content-Type-Options nosniff;
  '';

  default-headers = hsts + csp + referrer-policy + x-frame-options + x-content-type-options;

  synapse-client-config."m.homeserver".base_url = "https://matrix.ncrypt.at";

  synapse-server-config."m.server" = "matrix.ncrypt.at:443";

  synapse-mk-well-known = data: ''
    default_type application/json;
    add_header Access-Control-Allow-Origin *;
    return 200 '${builtins.toJSON data}';
  '';

in
{
  services.nginx = {
    enable = true;

    package = pkgs.nginxMainline.override { withSlice = true; };

    recommendedGzipSettings = true;
    recommendedZstdSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    proxyCachePath."pleroma" = {
      enable = true;
      useTempPath = false;
      maxSize = "10g";
      levels = "1:2";
      keysZoneSize = "10m";
      keysZoneName = "pleroma_media_cache";
      inactive = "720m";
    };

    upstreams."phoenix" = {
      servers = {
        "127.0.0.1:4000" = {
          max_fails = 5;
          fail_timeout = "60s";
        };
      };
    };

    virtualHosts."cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts;

      globalRedirect = "www.cypherpunk.observer";
    };

    virtualHosts."communicating.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = ''
        etag on;

        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;

        client_max_body_size 100m;
      '';

      locations."/" = {
        recommendedProxySettings = false;
        proxyPass = "http://phoenix";
      };

      locations."/media" = {
        return = "301 https://media.communicating.cypherpunk.observer$request_uri";
      };

      locations."/proxy" = {
        return = "404";
      };
    };

    virtualHosts."media.communicating.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = ''
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      '';

      locations."/" = {
        return = "404";
      };

      locations."~ ^/(media|proxy)" = {
        recommendedProxySettings = false;
        proxyPass = "http://phoenix";

        extraConfig = ''
          proxy_cache        pleroma_media_cache;
          slice              1m;
          proxy_cache_key    $host$uri$is_args$args$slice_range;
          proxy_set_header   Range $slice_range;
          proxy_cache_valid  200 206 301 304 1h;
          proxy_cache_lock   on;
          proxy_ignore_client_abort on;
          proxy_buffering    on;
          chunked_transfer_encoding on;
        '';
      };
    };

    virtualHosts."mta-sts.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/mta-sts.cypherpunk.observer/";

      extraConfig = default-headers;
    };

    virtualHosts."www.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/cypherpunk.observer/";

      extraConfig = default-headers;

      locations."~ /\.git".extraConfig = ''
        deny all;
      '';
    };

    virtualHosts."mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts;

      globalRedirect = "www.mkoppmann.at";
    };

    virtualHosts."mta-sts.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/mta-sts.mkoppmann.at/";

      extraConfig = default-headers;
    };

    virtualHosts."wtcvss.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/wtcvss/";

      extraConfig =
        hsts
        + referrer-policy
        + x-frame-options
        + x-content-type-options
        + ''
          add_header Content-Security-Policy "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; font-src 'self'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; upgrade-insecure-requests;" always;
        '';
    };

    virtualHosts."www.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/mkoppmann.at/";

      extraConfig = default-headers;

      locations."~ /\.git".extraConfig = ''
        deny all;
      '';
    };

    virtualHosts."ncrypt.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts;

      locations."= /.well-known/matrix/server".extraConfig = synapse-mk-well-known synapse-server-config;

      locations."= /.well-known/matrix/client".extraConfig = synapse-mk-well-known synapse-client-config;

      locations."/".return = "301 https://www.ncrypt.at$request_uri";
    };

    virtualHosts."chat.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig =
        hsts
        + referrer-policy
        + x-content-type-options
        + ''
          add_header X-Frame-Options SAMEORIGIN always;
          add_header Content-Security-Policy "frame-ancestors 'self';" always;
        '';

      root = pkgs.element-web.override {
        conf = {
          default_server_config."m.homeserver" = {
            base_url = "https://matrix.ncrypt.at";
            server_name = "ncrypt.at";
          };
          disable_guests = true;
          disable_3pid_login = true;
          default_country_code = "AT";
          show_labs_settings = true;
          features = {
            feature_latex_maths = "labs";
            feature_pinning = "labs";
          };
          rooms_directory.servers = [
            "ncrypt.at"
            "matrix.org"
          ];
        };
      };
    };

    virtualHosts."cloud.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
    };

    virtualHosts."idp.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "https://localhost:9443";
      };
    };

    virtualHosts."matrix.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;

      locations."/".return = "404";

      locations."/_matrix" = {
        extraConfig = ''
          client_max_body_size 0;
        '';
        proxyPass = "http://127.0.0.1:8008";
      };

      locations."/_synapse/client" = {
        extraConfig = ''
          client_max_body_size 0;
        '';
        proxyPass = "http://127.0.0.1:8008";
      };
    };

    virtualHosts."office.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
    };

    virtualHosts."pw.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
      };
    };

    virtualHosts."www.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/".return = "200";
    };
  };
}
