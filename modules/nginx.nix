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

  services.nginx = {
    enable = true;

    recommendedGzipSettings = true;
    recommendedOptimisation = true;
    recommendedProxySettings = true;
    recommendedTlsSettings = true;

    # Service modules apply `limit_req zone=login` to their login endpoints.
    # Only POST requests count, so page loads and reads stay unlimited.
    appendHttpConfig = ''
      map $request_method $login_limit_key {
        POST $binary_remote_addr;
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
