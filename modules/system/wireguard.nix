{ config, lib, ... }:
let
  host = import ../../host.nix;

  # Named after the last octet of their address.
  peers = {
    peer2 = "+IFbnbONQDMU/o2+WElWUhrTBmxr1oU4cibRMZTLnlg=";
    peer3 = "lxpp4+QWuxyx2eS/tjMQSecmK6Nydy5Mr9CP0hksdAY=";
    peer4 = "4B4eX/YtE2QtTs1ykQ/pPcg1get4L0mGcBFe/GDmK1c=";
    peer5 = "GXKLE+7Rz/LAgmig/XAvthAs5vBJh/czJ9pywODMoAI=";
    peer6 = "GoSqFQkA5b0rx7a3OXPVPrxttF0s99Q5DW72dXPUTFI=";
  };
in
{
  sops.secrets = {
    wireguard_private_key.restartUnits = [ "wireguard-wg0.service" ];
  }
  // lib.mapAttrs' (
    name: _:
    lib.nameValuePair "wireguard_psk_${name}" {
      restartUnits = [ "wireguard-wg0-peer-${name}.service" ];
    }
  ) peers;

  # Peers reach Apollo and, through NAT, the internet. Everything else that
  # would pass through Apollo is dropped: packets between peers, and packets
  # from the internet to a peer.
  networking.firewall.filterForward = true;
  networking.nat = {
    enable = true;
    externalInterface = host.interface;
    internalInterfaces = [ "wg0" ];
  };

  # Services exchange packets with the tunnel network only where their own
  # IPAddressAllow permits it.
  systemd.slices.system = {
    overrideStrategy = "asDropin";
    sliceConfig.IPAddressDeny = host.wireguard.network;
  };

  networking.wireguard = {
    enable = true;
    interfaces.wg0 = {
      ips = [ "${host.wireguard.address}/${toString host.wireguard.prefixLength}" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key.path;

      # The preshared keys protect recorded traffic against a future quantum
      # computer, which could break the key exchange alone.
      peers = lib.mapAttrsToList (name: publicKey: {
        inherit name publicKey;
        presharedKeyFile = config.sops.secrets."wireguard_psk_${name}".path;
        allowedIPs = [ "${host.wireguard.peer (lib.removePrefix "peer" name)}/32" ];
      }) peers;
    };
  };
}
