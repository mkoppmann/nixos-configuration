{ ... }:
let
  host = import ../../host.nix;
in
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

    interfaces.${host.interface} = {
      useDHCP = false;

      ipv4.addresses = [
        { inherit (host.ipv4) address prefixLength; }
      ];

      ipv6.addresses = [
        { inherit (host.ipv6) address prefixLength; }
      ];
    };

    defaultGateway = host.ipv4.gateway;
    defaultGateway6 = {
      address = host.ipv6.gateway;
      inherit (host) interface;
    };
  };
}
