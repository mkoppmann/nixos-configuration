{ ... }:
{
  networking = {
    hostId = "e538f1c9";
    hostName = "apollo";
    networkmanager.enable = false;
    useDHCP = false;

    firewall = {
      enable = true;
      allowedTCPPorts = [
        80
        443
      ];
      allowedUDPPorts = [ 51820 ];
    };

    nameservers = [
      "2606:4700:4700::1111"
      "2606:4700:4700::1001"
      "1.1.1.1"
      "1.0.0.1"
    ];

    nat = {
      enable = true;
      externalInterface = "ens3";
      internalInterfaces = [ "wg0" ];
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
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
    };
    allowSFTP = true;
    extraConfig = ''
      AllowTcpForwarding yes
      X11Forwarding no
      AllowAgentForwarding no
      AllowStreamLocalForwarding no
      AuthenticationMethods publickey
    '';
  };
}
