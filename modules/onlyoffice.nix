{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.onlyoffice = {
    enable = true;
    hostname = "office.ncrypt.at";
    jwtSecretFile = "/var/lib/onlyoffice/onlyoffice-jwt";
  };
}
