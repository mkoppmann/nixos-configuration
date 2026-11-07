{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
let
  pkgs-unstable = inputs.nixpkgs-unstable.legacyPackages.${pkgs.stdenv.hostPlatform.system};
in
{
  services.actual = {
    enable = true;
    package = pkgs-unstable.actual-server;

    settings = {
      hostname = "127.0.0.1";
      port = 5006;

      openId = {
        discoveryURL = "https://idp.ncrypt.at/application/o/actual-budget/";
        client_id = "6Q2OZAPVXR23GFP2Nun4ThngMEyDXx8ViBPNQe2p";
        client_secret._secret = "/var/lib/actual/openid_client_secret";
        server_hostname = "https://budget.ncrypt.at";
        authMethod = "openid";
      };
    };
  };
}
