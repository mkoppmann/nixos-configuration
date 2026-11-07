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
  };
}
