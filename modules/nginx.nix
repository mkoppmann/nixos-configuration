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

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

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

    virtualHosts."www.mkoppmann.at" = {
      enableACME = true;
      forceSSL = true;
      root = "/srv/www/mkoppmann.at/";

      extraConfig = default-headers;

      locations."~ /\.git".extraConfig = ''
        deny all;
      '';
    };
  };
}
