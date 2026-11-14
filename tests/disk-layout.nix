{ pkgs, inputs }:
let
  system = inputs.nixpkgs.lib.nixosSystem {
    specialArgs = { inherit inputs; };
    modules = [
      ../modules/storage.nix
      {
        nixpkgs.hostPlatform = pkgs.stdenv.hostPlatform.system;
        boot.loader.systemd-boot.enable = true;
        boot.initrd.systemd.enable = true;
        system.stateVersion = "23.11";
      }
    ];
  };
in
# Creates the layout on an empty disk, installs a system with only the storage
# module and boots it.
inputs.disko.lib.testLib.makeDiskoTest {
  inherit pkgs;
  name = "apollo";
  inherit (system) extendModules;
  disko-config = builtins.removeAttrs system.config [ "_module" ];
  # Once exported, the pool asks for its passphrase.
  postUnmountPreMount = ''
    machine.succeed(
        "zpool import -N -R /mnt rpool",
        "zfs load-key -L file:///tmp/secret.key rpool",
    )
  '';
  # Overrides the test library’s setting.
  extraSystemConfig.boot.zfs.devNodes = pkgs.lib.mkForce "/dev/disk/by-partuuid";
  bootCommands = ''
    machine.wait_for_console_text("Starting password query on")
    machine.send_console("secretsecret\n")
  '';
  extraTestScript = ''
    machine.succeed(
        "findmnt -no SOURCE / | grep -Fx rpool/local/root",
        "findmnt -no SOURCE /nix | grep -Fx rpool/local/nix",
        "findmnt -no SOURCE /persist | grep -Fx rpool/safe/persist",
        "findmnt -no SOURCE /var/log | grep -Fx rpool/safe/log",
        "findmnt -no FSTYPE /boot | grep -Fx vfat",
        "blkid -p -s VERSION -o value /dev/disk/by-partlabel/ESP | grep -Fx FAT32",
        "zfs get -Ho value keylocation rpool | grep -Fx prompt",
    )
    # The installer wrote this file to the root dataset after the snapshot.
    machine.fail("test -e /home/testfile")
  '';
}
