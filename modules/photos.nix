{ ... }:
let
  inherit (import ../lib/nginx-headers.nix)
    hsts
    referrer-policy
    x-frame-options
    x-content-type-options
    ;
in
{
  # Immich runs on a WireGuard peer.
  services.nginx = {
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
  };
}
