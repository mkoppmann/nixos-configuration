# Apollo’s addresses, as its provider assigned them, and the WireGuard network.
let
  wireguardPrefix = "10.100.0";
in
{
  interface = "ens3";

  ipv4 = {
    address = "152.53.35.165";
    prefixLength = 22;
    gateway = "152.53.32.1";
  };

  ipv6 = {
    address = "2a0a:4cc0:100:23::bad:c0de";
    prefixLength = 64;
    gateway = "fe80::1";
  };

  wireguard = {
    network = "${wireguardPrefix}.0/24";
    prefixLength = 24;
    address = "${wireguardPrefix}.1";
    # The address of the peer with this last octet.
    peer = octet: "${wireguardPrefix}.${toString octet}";
  };
}
