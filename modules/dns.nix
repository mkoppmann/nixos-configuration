{ ... }:
let
  wireguardNet = "10.100.0.0/24";
in
{
  # Resolver for Apollo and its WireGuard clients, encrypted to Applied
  # Privacy. For WireGuard clients it sends Authentik's host name to the tunnel
  # address, so admins reach it from inside WireGuard (see the admin gate in
  # the Authentik applications blueprint).
  services.unbound = {
    enable = true;
    resolveLocalQueries = true;
    settings = {
      server = {
        interface = [
          "127.0.0.1"
          "::1"
          "10.100.0.1"
        ];
        access-control = [
          "127.0.0.0/8 allow"
          "::1/128 allow"
          "${wireguardNet} allow"
        ];
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
          # If Applied Privacy fails, resolve directly from the authoritative
          # servers rather than from a second provider. Unbound would spread
          # queries across several providers instead of using one as fallback.
          forward-first = true;
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
