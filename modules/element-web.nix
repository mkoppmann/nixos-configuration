{ pkgs, ... }:
let
  inherit (import ../lib/nginx-headers.nix) hsts referrer-policy x-content-type-options;
in
{
  services.nginx = {
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
  };
}
