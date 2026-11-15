{ pkgs, inputs }:
let
  host = import ../host.nix;
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  # nixpkgs’ public test key, in place of the one on /persist. A store path
  # of its own, so the boot disk’s build has it.
  hostKeyFile = pkgs.path + "/nixos/tests/initrd-network-ssh/ssh_host_ed25519_key";
  hostKey = builtins.path {
    path = hostKeyFile;
    name = "initrd-host-key";
  };
  hostPublicKey = pkgs.lib.trim (builtins.readFile (hostKeyFile + ".pub"));
  # The disko test library’s passphrase.
  passphrase = "secretsecret";
  prompt = "Enter key for rpool:";
  ssh = "ssh -p 2222 -i /root/unlock -o StrictHostKeyChecking=yes -o ConnectTimeout=10";
  target = "root@${host.ipv4.address}";

  # ssh runs in a terminal of its own, as it does for the operator.
  unlock = pkgs.writeText "unlock.exp" ''
    set timeout 300
    spawn ${ssh} -t ${target}
    expect {
      "${prompt}" {}
      timeout { exit 1 }
      eof { exit 1 }
    }
    send "${passphrase}\r"
    # The connection ends when the initrd hands over to the booted system.
    set timeout 60
    expect eof
  '';
  noShell = pkgs.writeText "no-shell.exp" ''
    set timeout 300
    spawn ${ssh} -t ${target} echo shell-access
    expect {
      "shell-access" { exit 1 }
      "${prompt}" { exit 0 }
      timeout { exit 2 }
      eof { exit 3 }
    }
  '';
in
# Apollo’s initrd in front of its encrypted pool: a client unlocks the pool
# over SSH, and the server boots from it.
pkgs.testers.runNixOSTest {
  name = "remote-unlock";

  node.specialArgs = { inherit inputs; };

  nodes.server =
    { lib, ... }:
    {
      imports = [
        ../modules/system/boot.nix
        ../modules/system/ssh.nix
        ../modules/system/storage.nix
      ];

      virtualisation = {
        useBootLoader = true;
        useEFIBoot = true;
        mountHostNixStore = true;
        memorySize = 2048;
        # The pool’s disk; the VM boots from its own.
        emptyDiskImages = [ 4096 ];
      };
      disko.enableConfig = false;
      disko.devices.disk.main.device = lib.mkForce "/dev/vdb";

      users.users.mcp = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      };

      boot.initrd = {
        secrets = lib.mkForce { "/persist/credentials/initrd_host_ed25519_key" = hostKey; };
        # The test network’s interface, with Apollo’s address.
        systemd.network.networks."10-${host.interface}".matchConfig.Name = lib.mkForce "eth1";
      };

      # The first boot creates the pool, the second one boots from it.
      specialisation.encrypted.configuration.virtualisation.fileSystems."/" = lib.mkForce {
        device = "rpool/local/root";
        fsType = "zfs";
      };
    };

  nodes.client =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.expect ];
      programs.ssh.knownHosts.apollo = {
        hostNames = [ "[${host.ipv4.address}]:2222" ];
        publicKey = hostPublicKey;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      start_all()

      with subtest("The pool is created with Apollo’s layout"):
          server.wait_for_unit("multi-user.target")
          # Without a pool, the rollback failed.
          server.succeed("systemctl is-failed zfs-rollback-check.service")
          server.succeed(
              "echo -n '${passphrase}' > /tmp/secret.key",
              "${pkgs.lib.getExe nodes.server.system.build.format}",
              "zfs get -Ho value keylocation rpool | grep -Fx prompt",
              "zpool export rpool",
              "bootctl set-default nixos-generation-1-specialisation-encrypted.conf",
              "sync",
          )
          server.shutdown()

      # The client takes the place of Apollo’s gateway.
      client.wait_for_unit("network.target")
      client.succeed(
          "ip addr add ${host.ipv4.gateway}/${toString host.ipv4.prefixLength} dev eth1",
          "install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/unlock",
      )

      server.start()
      client.wait_until_succeeds("nc -z -w 1 ${host.ipv4.address} 2222")

      with subtest("Classical key exchange is refused"):
          client.succeed(
              "(${ssh} -o KexAlgorithms=curve25519-sha256 ${target} true 2>&1 || true)"
              " | grep -F 'no matching key exchange method found'"
          )

      with subtest("The unlock key gets the prompt instead of its command"):
          client.succeed("expect -f ${noShell}")

      with subtest("The passphrase over SSH boots the server"):
          client.succeed("expect -f ${unlock}")
          server.wait_for_unit("multi-user.target")
          server.succeed(
              "findmnt -no SOURCE / | grep -Fx rpool/local/root",
              "zfs get -Ho value keystatus rpool | grep -Fx available",
              "systemctl is-active zfs-rollback-check.service",
          )
    '';
}
