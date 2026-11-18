{
  config,
  lib,
  pkgs,
  ...
}:
let
  host = import ../../host.nix;

  # RFC 9116 wants an expiry date within a year. It is a year after the date
  # of the nixpkgs revision, which is part of the system’s version, so every
  # automatic update moves it on.
  expires =
    let
      date = builtins.match ".*\\.([0-9]{4})([0-9]{2})([0-9]{2})\\..*" config.system.nixos.version;
      year = toString (lib.toInt (lib.head date) + 1);
      # A leap day has no counterpart in the next year.
      monthAndDay =
        if
          lib.tail date == [
            "02"
            "29"
          ]
        then
          "02-28"
        else
          lib.concatStringsSep "-" (lib.tail date);
    in
    # Builds without a dated version, such as the VM tests, get a fixed date.
    if date == null then "2000-01-01T00:00:00Z" else "${year}-${monthAndDay}T00:00:00Z";

  securityTxt = pkgs.writeText "security.txt" ''
    Contact: mailto:security@ncrypt.at
    Expires: ${expires}
    Preferred-Languages: en, de
  '';
in
{
  # These settings apply to every virtual host, whichever module declares it.
  options.services.nginx.virtualHosts = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          config = {
            # No service needs HTTP/2 or HTTP/3, so clients reach only the
            # HTTP/1.1 parser. Nginx serves HTTP/3 only on a QUIC listener.
            http2 = false;
            quic = false;

            locations."= /.well-known/security.txt" = lib.mkIf (name != "_") {
              alias = securityTxt;
              extraConfig = "charset utf-8;";
            };
          };
        }
      )
    );
  };

  config = {
    environment.persistence."/persist".directories = [
      "/var/lib/acme"
    ];

    security.acme = {
      acceptTerms = true;
      defaults.email = "acme@ncrypt.at";
    };

    # WireGuard clients reach the websites through the tunnel, and photos.nix
    # proxies to the photo server in it.
    systemd.services.nginx.serviceConfig.IPAddressAllow = host.wireguard.network;

    services.nginx = {
      enable = true;

      recommendedGzipSettings = true;
      recommendedOptimisation = true;
      recommendedProxySettings = true;
      recommendedTlsSettings = true;

      # Service modules apply `limit_req zone=login` to their login endpoints.
      # Only POST requests count, so page loads and reads stay unlimited.
      appendHttpConfig = ''
        # Requests are not logged. A host that wants a log declares its own.
        access_log off;

        # IPv6 clients count by their /64: a client chooses its addresses
        # within that network freely.
        map $remote_addr $login_limit_client {
          default $binary_remote_addr;
          "~^(?<login_limit_network>([0-9a-f]*:){4})" $login_limit_network;
        }
        map $request_method $login_limit_key {
          POST $login_limit_client;
          default "";
        }
        limit_req_zone $login_limit_key zone=login:10m rate=10r/m;
        limit_req_status 429;
      '';

      # Requests for unknown host names get no response and no certificate.
      virtualHosts."_" = {
        default = true;
        rejectSSL = true;
        locations."/".return = "444";
      };
    };
  };
}
