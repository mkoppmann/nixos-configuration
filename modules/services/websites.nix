{
  inputs,
  lib,
  pkgs,
  ...
}:
let
  inherit (import ../../lib/nginx-headers.nix)
    hsts
    referrer-policy
    x-frame-options
    x-content-type-options
    revalidate
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

  site = name: inputs.${name}.packages.${pkgs.stdenv.hostPlatform.system}.default;

  # Nginx’s error log names the client of every failed request, such as a
  # missing page. The personal sites only log what breaks Nginx itself.
  no-client-errors = ''
    error_log stderr crit;
  '';

  visitsLog = "/var/log/nginx/visits.log";

  # Page views per day, and the pages and referring sites with the most views.
  visits = pkgs.writeShellScriptBin "visits" ''
    views() {
      ${pkgs.gzip}/bin/zcat -f ${visitsLog}* |
        ${pkgs.gawk}/bin/awk '$2 == 200 && $3 == "human" && $5 ~ /(\/|\.html)$/'
    }
    top() {
      sort | uniq -c | sort -rn | head -n 15
    }
    echo "Views per day:"
    views | cut -c 1-10 | sort | uniq -c | tail -n 30
    echo "Pages:"
    views | cut -d " " -f 5- | top
    echo "Referring sites:"
    views | ${pkgs.gawk}/bin/awk '$4 != "-" && $4 != "www.mkoppmann.at" { print $4 }' | top
  '';

  # Also the MX records of these domains.
  mailbox-org = lib.importJSON ../../dns/mailbox-org.json;
in
{
  environment.systemPackages = [ visits ];

  services.nginx = {
    # The page views of www.mkoppmann.at, with nothing that identifies a
    # visitor: the hour, the status, whether the client calls itself a
    # program, the referring site and the page. No address and no user agent.
    # Nginx wants a log format defined before the hosts that use it.
    commonHttpConfig = ''
      map $time_iso8601 $visit_hour {
        "~^(?<hour>[^:]+)" $hour;
      }
      map $http_user_agent $visit_client {
        default human;
        "" bot;
        "~*(bot|crawl|spider|slurp|curl|wget|python|http|feed|monitor|scan)" bot;
      }
      map $http_referer $visit_referrer {
        default -;
        "~^https?://(?<site>[^/:]+)" $site;
      }
      log_format visits '$visit_hour $status $visit_client $visit_referrer $uri';
    '';

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

      extraConfig = default-headers;

      locations."/".extraConfig = ''
        default_type text/html;
        return 200 "";
      '';
    };

    virtualHosts."mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts + no-client-errors;

      globalRedirect = "www.mkoppmann.at";
    };

    virtualHosts."mta-sts.mkoppmann.at" = mta-sts-host mailbox-org;

    virtualHosts."wtcvss.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = site "wtcvss";

      extraConfig =
        hsts
        + referrer-policy
        + x-frame-options
        + x-content-type-options
        + revalidate
        + no-client-errors
        + ''
          add_header Content-Security-Policy "default-src 'none'; style-src 'self' 'unsafe-inline'; img-src 'self'; font-src 'self'; script-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; upgrade-insecure-requests;" always;
        '';
    };

    virtualHosts."www.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = site "website";

      extraConfig =
        hsts
        + referrer-policy
        + x-frame-options
        + x-content-type-options
        + revalidate
        + no-client-errors
        + ''
          access_log ${visitsLog} visits;
        '';

      locations."~* ^/_astro/".extraConfig = default-headers-without-csp + ''
        access_log off;
        add_header Cache-Control "public, max-age=31536000, immutable" always;
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
      extraConfig = hsts;
      locations."/".return = "200";
    };
  };
}
