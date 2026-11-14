{ ... }:
{
  networking = {
    hostName = "apollo";
    networkmanager.enable = false;
    useDHCP = false;

    nftables.enable = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [ 51820 ];
    };

    interfaces.ens3 = {
      useDHCP = false;

      ipv4.addresses = [
        {
          address = "152.53.35.165";
          prefixLength = 22;
        }
      ];

      ipv6.addresses = [
        {
          address = "2a0a:4cc0:100:23::bad:c0de";
          prefixLength = 64;
        }
      ];
    };

    defaultGateway = "152.53.32.1";
    defaultGateway6 = {
      address = "fe80::1";
      interface = "ens3";
    };
  };
}
