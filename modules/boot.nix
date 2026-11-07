{
  config,
  pkgs,
  ...
}:
{
  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    supportedFilesystems = [ "zfs" ];
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
          hostKeys = [ /persist/credentials/initrd_host_ed25519_key ];
          authorizedKeys = config.users.users.mcp.openssh.authorizedKeys.keys;
        };
      };
      systemd = {
        enable = true;
        network = {
          enable = true;

          networks."10-ens3" = {
            matchConfig.Name = "ens3";

            address = [
              "152.53.35.165/22"
            ];

            routes = [
              {
                Gateway = "152.53.32.1";
              }
            ];

            networkConfig = {
              DNS = [
                "1.1.1.1"
                "1.0.0.1"
              ];
              IPv6AcceptRA = false;
            };

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
          zfs-unlock-profile = {
            description = "Prepare root profile for ZFS remote unlock";
            wantedBy = [ "initrd.target" ];
            before = [ "initrd-root-fs.target" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot";
            script = ''
              mkdir -p /var/empty
              echo "systemd-tty-ask-password-agent --watch" > /var/empty/.profile
            '';
          };

          zfs-rollback = {
            description = "Rollback root ZFS dataset to blank snapshot";
            wantedBy = [ "initrd.target" ];
            after = [ "zfs-import-rpool.service" ];
            before = [ "sysroot.mount" ];
            unitConfig.DefaultDependencies = false;
            serviceConfig.Type = "oneshot";
            path = [ pkgs.zfs ];
            script = ''
              zfs rollback -r "rpool/local/root@blank"
            '';
          };
        };
      };
    };

    zfs = {
      devNodes = "/dev/disk/by-partuuid";
      forceImportRoot = false;
      requestEncryptionCredentials = true;
    };
  };

  fileSystems = {
    "/".options = [
      "noatime"
      "x-systemd.device-timeout=infinity"
    ];
    "/boot".options = [ "umask=0077" ];
    "/var/log".options = [ "noatime" ];
    "/var/log".neededForBoot = true;
    "/nix".options = [ "noatime" ];
    "/persist".options = [ "noatime" ];
    "/persist".neededForBoot = true;
  };

  zramSwap.enable = true;

  services.zfs = {
    autoScrub.enable = true;
    trim.enable = true;
  };
}
