{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.actual = {
    enable = true;

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
