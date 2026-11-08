{ ... }:
{
  # Reachable only through WireGuard. The initrd's unlock SSH on port 2222 has
  # no firewall and stays public.
  networking.firewall.interfaces.wg0.allowedTCPPorts = [ 22 ];

  services.openssh = {
    enable = true;
    openFirewall = false;
    authorizedKeysInHomedir = false;

    hostKeys = [
      {
        path = "/persist/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    settings = {
      AllowUsers = [ "mcp@10.100.0.0/24" ];
      PermitRootLogin = "no";
      AuthenticationMethods = "publickey";
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;

      # Post-quantum hybrid key exchange only.
      KexAlgorithms = [
        "mlkem768x25519-sha256"
        "sntrup761x25519-sha512"
        "sntrup761x25519-sha512@openssh.com"
      ];

      AllowTcpForwarding = false;
      AllowAgentForwarding = false;
      AllowStreamLocalForwarding = false;
      X11Forwarding = false;

      # Logs the key fingerprint of every login.
      LogLevel = "VERBOSE";
    };
  };
}
