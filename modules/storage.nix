{ inputs, ... }:
let
  legacy = mountpoint: {
    type = "zfs_fs";
    inherit mountpoint;
    options.mountpoint = "legacy";
    mountOptions = [ "noatime" ];
  };
in
{
  imports = [ inputs.disko.nixosModules.disko ];

  disko.devices = {
    disk.main = {
      type = "disk";
      device = "/dev/vda";
      content = {
        type = "gpt";
        partitions = {
          ESP = {
            # /boot is mounted by this label, which Apollo’s partition has.
            label = "ESP";
            type = "EF00";
            size = "512M";
            content = {
              type = "filesystem";
              format = "vfat";
              extraArgs = [
                "-F"
                "32"
              ];
              mountpoint = "/boot";
              mountOptions = [ "umask=0077" ];
            };
          };
          zfs = {
            size = "100%";
            content = {
              type = "zfs";
              pool = "rpool";
            };
          };
        };
      };
    };

    zpool.rpool = {
      type = "zpool";
      options = {
        ashift = "12";
        autotrim = "on";
      };
      rootFsOptions = {
        acltype = "posixacl";
        atime = "off";
        canmount = "off";
        compression = "zstd";
        dnodesize = "auto";
        normalization = "formD";
        xattr = "sa";
        mountpoint = "none";
        encryption = "aes-256-gcm";
        keyformat = "passphrase";
        # The installer reads the passphrase from this file; booting asks for it.
        keylocation = "file:///tmp/zfs.key";
      };
      postCreateHook = "zfs set keylocation=prompt rpool";

      datasets = {
        local = {
          type = "zfs_fs";
          options.mountpoint = "none";
        };
        safe = {
          type = "zfs_fs";
          options.mountpoint = "none";
        };
        "local/nix" = legacy "/nix";
        "local/root" = legacy "/" // {
          mountOptions = [
            "noatime"
            "x-systemd.device-timeout=infinity"
          ];
          postCreateHook = ''
            zfs list rpool/local/root@blank >/dev/null 2>&1 ||
              zfs snapshot rpool/local/root@blank
          '';
        };
        "safe/log" = legacy "/var/log";
        "safe/persist" = legacy "/persist";
      };
    };
  };

  fileSystems = {
    "/persist".neededForBoot = true;
    "/var/log".neededForBoot = true;
  };
}
