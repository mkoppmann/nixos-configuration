{ lib, pkgs, ... }:
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

  # RFC 8461 policy for receiving mail servers.
  mta-sts-host = mxs: {
    enableACME = true;
    forceSSL = true;
    extraConfig = default-headers;
    locations."/".return = "404";
    locations."= /.well-known/mta-sts.txt".alias = pkgs.writeText "mta-sts.txt" ''
      version: STSv1
      mode: enforce
      ${lib.concatMapStrings (mx: "mx: ${mx}\n") mxs}max_age: 2505600
    '';
  };

  mailbox-org = [
    "mxext1.mailbox.org"
    "mxext2.mailbox.org"
    "mxext3.mailbox.org"
  ];
in
{
  environment.persistence."/persist".directories = [ "/srv/www" ];

  services.nginx = {
    virtualHosts."cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts;

      globalRedirect = "www.cypherpunk.observer";
    };

    virtualHosts."mta-sts.cypherpunk.observer" = mta-sts-host mailbox-org;

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

    virtualHosts."mta-sts.mkoppmann.at" = mta-sts-host mailbox-org;

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
