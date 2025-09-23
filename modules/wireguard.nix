{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.wireguard = {
    enable = true;
    interfaces.wg0 = {
      ips = [ "10.100.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = "/var/lib/wireguard/private_key";

      postSetup = ''
        ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING -s 10.100.0.0/24 -o ens3 -j MASQUERADE
      '';

      postShutdown = ''
        "${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING -s 10.100.0.0/24 -o ens3 -j MASQUERADE 2>/dev/null || true"
      '';

      peers = [
        {
          publicKey = "+IFbnbONQDMU/o2+WElWUhrTBmxr1oU4cibRMZTLnlg=";
          allowedIPs = [ "10.100.0.2/32" ];
          persistentKeepalive = 25;
        }
        {
          publicKey = "lxpp4+QWuxyx2eS/tjMQSecmK6Nydy5Mr9CP0hksdAY=";
          allowedIPs = [ "10.100.0.3/32" ];
          persistentKeepalive = 25;
        }
        {
          publicKey = "4B4eX/YtE2QtTs1ykQ/pPcg1get4L0mGcBFe/GDmK1c=";
          allowedIPs = [ "10.100.0.4/32" ];
          persistentKeepalive = 25;
        }
        {
          publicKey = "GXKLE+7Rz/LAgmig/XAvthAs5vBJh/czJ9pywODMoAI=";
          allowedIPs = [ "10.100.0.5/32" ];
          persistentKeepalive = 25;
        }
        {
          publicKey = "GoSqFQkA5b0rx7a3OXPVPrxttF0s99Q5DW72dXPUTFI=";
          allowedIPs = [ "10.100.0.6/32" ];
          persistentKeepalive = 25;
        }
      ];
    };
  };
}
