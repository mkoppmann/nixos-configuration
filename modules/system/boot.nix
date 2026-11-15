{
  config,
  lib,
  ...
}:
let
  host = import ../../host.nix;
in
{
  boot = {
    loader.systemd-boot = {
      enable = true;
      # The 512 MiB boot partition holds the kernel and initrd of each entry.
      # Rollbacks with nixos-rebuild use the system profile, which keeps more.
      configurationLimit = 10;
    };
    loader.efi.canTouchEfiVariables = true;
    initrd = {
      availableKernelModules = [
        "virtio_pci"
        "virtio_net"
      ];
      kernelModules = [
        "virtio_pci"
        "virtio_net"
      ];
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ "/persist/credentials/initrd_host_ed25519_key" ];
          # The keys only answer the passphrase prompt: no shell, no forwarding.
          authorizedKeys = map (
            key: ''command="systemd-tty-ask-password-agent --watch",restrict,pty ${key}''
          ) config.users.users.mcp.openssh.authorizedKeys.keys;
          extraConfig = "KexAlgorithms ${lib.concatStringsSep "," config.services.openssh.settings.KexAlgorithms}";
        };
      };
      systemd = {
        enable = true;
        network = {
          enable = true;

          networks."10-${host.interface}" = {
            matchConfig.Name = host.interface;

            address = [
              "${host.ipv4.address}/${toString host.ipv4.prefixLength}"
            ];

            routes = [
              {
                Gateway = host.ipv4.gateway;
              }
            ];

            networkConfig.IPv6AcceptRA = false;

            linkConfig.RequiredForOnline = "routable";
          };

          wait-online.enable = true;
        };
        services = {
          sshd = {
            wants = [ "network-online.target" ];
            after = [
              "network-online.target"
              "initrd-nixos-copy-secrets.service"
            ];
          };
          # sshd doesn’t start without its privilege separation directory.
          sshd-privsep-directory = {
            description = "Create sshd’s privilege separation directory";
            wantedBy = [ "initrd.target" ];
            before = [ "sshd.service" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot";
            script = "mkdir -p /var/empty";
          };
        };
      };
    };
  };

  zramSwap.enable = true;
}
