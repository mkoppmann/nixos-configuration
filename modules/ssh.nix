{ ... }:
{
  services.openssh = {
    enable = true;
    authorizedKeysInHomedir = false;

    hostKeys = [
      {
        path = "/persist/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    settings = {
      AllowUsers = [ "mcp" ];
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
