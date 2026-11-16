{
  config,
  pkgs,
  inputs,
  ...
}:
let
  inherit (import ../../lib/nginx-headers.nix) hsts referrer-policy x-content-type-options;

  # A location with add_header must repeat its complete response-header policy.
  actual-headers =
    hsts
    + referrer-policy
    + x-content-type-options
    + ''
      add_header Cross-Origin-Embedder-Policy "require-corp" always;
      add_header Cross-Origin-Opener-Policy "same-origin" always;
      add_header Origin-Agent-Cluster "?1" always;
    '';

  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  services.actual = {
    enable = true;
    package = pkgs-unstable.actual-server;

    settings = {
      hostname = "127.0.0.1";
      port = 5006;
      # Nginx on this host sets the forwarding headers. The default list
      # leaves it out, so every client would have Nginx’s address.
      trustedProxies = [ "127.0.0.1/32" ];

      openId = {
        discoveryURL = "https://idp.ncrypt.at/application/o/actual-budget/";
        client_id = "6Q2OZAPVXR23GFP2Nun4ThngMEyDXx8ViBPNQe2p";
        client_secret._secret = "/run/credentials/actual.service/openid_client_secret";
        server_hostname = "https://budget.ncrypt.at";
        authMethod = "openid";
      };
    };
  };

  sops.secrets.actual_openid_client_secret.restartUnits = [ "actual.service" ];
  # The config generator runs as the dynamic user and cannot read /run/secrets.
  systemd.services.actual.serviceConfig.LoadCredential =
    "openid_client_secret:${config.sops.secrets.actual_openid_client_secret.path}";

  environment.persistence."/persist".directories = [
    "/var/lib/private/actual"
  ];

  services.nginx = {
    virtualHosts."budget.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = hsts + referrer-policy + x-content-type-options;

      locations."/" = {
        proxyPass = "http://127.0.0.1:5006";

        extraConfig = actual-headers + ''
          # Nginx owns these headers. The application’s CSP and framing pass.
          proxy_hide_header Strict-Transport-Security;
          proxy_hide_header Referrer-Policy;
          proxy_hide_header X-Content-Type-Options;
          proxy_hide_header Cross-Origin-Embedder-Policy;
          proxy_hide_header Cross-Origin-Opener-Policy;
          proxy_hide_header Origin-Agent-Cluster;
        '';
      };
    };
  };
}
