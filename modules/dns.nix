{ ... }:
let
  wireguardNet = "10.100.0.0/24";
in
{
  # Resolver for WireGuard clients. It sends Authentik's host name to the
  # tunnel address, so admins reach it from inside WireGuard (see the admin
  # gate in the Authentik applications blueprint).
  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings = {
      server = {
        interface = [ "10.100.0.1" ];
        access-control = [ "${wireguardNet} allow" ];
        access-control-view = [ "${wireguardNet} wireguard" ];
      };
      view = [
        {
          name = "wireguard";
          view-first = true;
          # Static: no IPv6 answer, which would bypass the tunnel.
          local-zone = [ ''"idp.ncrypt.at." static'' ];
          local-data = [ ''"idp.ncrypt.at. A 10.100.0.1"'' ];
        }
      ];
      forward-zone = [
        {
          name = ".";
          forward-tls-upstream = true;
          forward-addr = [
            "146.255.56.98@853#dot1.applied-privacy.net"
            "2a02:1b8:10:234::2@853#dot1.applied-privacy.net"
          ];
        }
      ];
    };
  };

  networking.firewall.interfaces.wg0 = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };
}
