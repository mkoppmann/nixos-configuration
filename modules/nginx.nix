{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../lib/nginx-headers.nix)
    hsts
    referrer-policy
    x-frame-options
    x-content-type-options
    default-headers
    default-headers-without-csp
    ;

  synapse-client-config."m.homeserver".base_url = "https://matrix.ncrypt.at";

  synapse-server-config."m.server" = "matrix.ncrypt.at:443";

  synapse-mk-well-known =
    data:
    hsts
    + ''
      default_type application/json;
      add_header Access-Control-Allow-Origin *;
      return 200 '${builtins.toJSON data}';
    '';

in
{
  environment.persistence."/persist".directories = [
    "/srv/www"
    "/var/lib/acme"
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "acme@ncrypt.at";
  };

  services.nginx = {
    enable = true;

    package = pkgs.nginxMainline.override { withSlice = true; };

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    virtualHosts."cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts;

      globalRedirect = "www.cypherpunk.observer";
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

    virtualHosts."photos.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig =
        hsts
        + referrer-policy
        + x-frame-options
        + x-content-type-options
        + ''
          client_max_body_size 50000M;
        '';

      locations."/" = {
        proxyPass = "http://10.100.0.2:2283";
        proxyWebsockets = true;

        extraConfig = ''
          proxy_read_timeout 600s;
          proxy_send_timeout 600s;
          send_timeout 600s;
          proxy_redirect off;
        '';
      };

      locations."= /.well-known/immich" = {
        proxyPass = "http://10.100.0.2:2283";
      };
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
      root = "/srv/www/mkoppmann.at/dist/";

      extraConfig =
        hsts
        + referrer-policy
        + x-frame-options
        + x-content-type-options
        + ''
          etag on;
        '';

      locations."= /".extraConfig = default-headers-without-csp + ''
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
      '';

      locations."~* \\.html$".extraConfig = default-headers-without-csp + ''
        add_header Cache-Control "no-cache, no-store, must-revalidate" always;
      '';

      locations."~* ^/_astro/".extraConfig = default-headers-without-csp + ''
        expires 1y;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
      '';

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

    virtualHosts."www.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;
      locations."/".return = "200";
    };
  };
}
