{ config, lib, ... }:
let
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

  # Peers reach Apollo and, through NAT, the internet, but not each other.
  # The iptables firewall has no forward filtering of its own.
  networking.firewall = {
    extraCommands = ''
      iptables -w -D FORWARD -i wg0 -o wg0 -j DROP 2>/dev/null || true
      iptables -w -I FORWARD -i wg0 -o wg0 -j DROP
    '';
    extraStopCommands = ''
      iptables -w -D FORWARD -i wg0 -o wg0 -j DROP 2>/dev/null || true
    '';
  };

  networking.wireguard = {
    enable = true;
    interfaces.wg0 = {
      ips = [ "10.100.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard_private_key.path;

      # The preshared keys protect recorded traffic against a future quantum
      # computer, which could break the key exchange alone.
      peers = lib.mapAttrsToList (name: publicKey: {
        inherit name publicKey;
        presharedKeyFile = config.sops.secrets."wireguard_psk_${name}".path;
        allowedIPs = [ "10.100.0.${lib.removePrefix "peer" name}/32" ];
        persistentKeepalive = 25;
      }) peers;
    };
  };
}
