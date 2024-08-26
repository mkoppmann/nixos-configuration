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

    virtualHosts."idp.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyWebsockets = true;
        proxyPass = "https://localhost:9443";
      };
    };

    virtualHosts."pw.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:${toString config.services.vaultwarden.config.ROCKET_PORT}";
      };
    };
  };
}
