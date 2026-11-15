{
  ...
}:
{
  environment.persistence."/persist".directories = [
    "/var/lib/acme"
  ];

  security.acme = {
    acceptTerms = true;
    defaults.email = "acme@ncrypt.at";
  };

  # WireGuard clients reach the websites through the tunnel, and photos.nix
  # proxies to the photo server in it.
  systemd.services.nginx.serviceConfig.IPAddressAllow = "10.100.0.0/24";

  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # Service modules apply `limit_req zone=login` to their login endpoints.
    # Only POST requests count, so page loads and reads stay unlimited.
    appendHttpConfig = ''
      # Requests are not logged; a host that wants a log declares its own.
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
}
