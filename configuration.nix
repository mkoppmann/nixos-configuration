{ config, lib, pkgs, impermanence, ... }:

{
  imports = [ impermanence.nixosModule ./hardware-configuration.nix ];

  nix = {
    gc = {
      automatic = true;
      dates = "weekly";
      options = "--delete-older-than 30d";
    };
    optimise.automatic = true;
    settings = {
      allowed-users = [ "@wheel" ];
      experimental-features = [ "nix-command" "flakes" ];
    };
  };

  boot = {
    loader.systemd-boot.enable = true;
    loader.efi.canTouchEfiVariables = true;
    kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
    kernelParams = [ "ip=152.53.35.165::152.53.32.1:255.255.252.0::ens3:none" ];
    supportedFilesystems = [ "zfs" ];
    initrd = {
      kernelModules = [ "virtio_pci" ];
      network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ /persist/credentials/initrd_host_ed25519_key ];
          authorizedKeys = config.users.users.mcp.openssh.authorizedKeys.keys;
        };
        postCommands = lib.mkAfter ''
                    echo "zfs load-key -a; killall zfs" >> /root/.profile
          	'';
      };
      postDeviceCommands = lib.mkAfter ''
        zfs rollback -r "rpool/local/root@blank"
      '';
    };
    zfs = {
      devNodes = "/dev/disk/by-partuuid";
      requestEncryptionCredentials = true;
    };
  };

  fileSystems = {
    "/".options = [ "noatime" ];
    "/boot".options = [ "umask=0077" ];
    "/var/log".options = [ "noatime" ];
    "/var/log".neededForBoot = true;
    "/nix".options = [ "noatime" ];
    "/persist".options = [ "noatime" ];
    "/persist".neededForBoot = true;
  };

  zramSwap.enable = true;

  environment = {
    etc = {
      "machine-id".source = "/persist/etc/machine-id";
      "ssh/ssh_host_ed25519_key".source =
        "/persist/etc/ssh/ssh_host_ed25519_key";
      "ssh/ssh_host_ed25519_key.pub".source =
        "/persist/etc/ssh/ssh_host_ed25519_key.pub";
      "ssh/ssh_host_rsa_key".source = "/persist/etc/ssh/ssh_host_rsa_key";
      "ssh/ssh_host_rsa_key.pub".source =
        "/persist/etc/ssh/ssh_host_rsa_key.pub";
    };

    persistence = {
      "/persist" = {
        hideMounts = true;
        directories = [ "/etc/nixos" ];
        files = [
          "/root/.ssh/known_hosts"
          "/home/mcp/.config/share/fish/fish_history"
        ];
      };
    };

    variables = { EDITOR = "nvim"; };
  };

  networking = {
    hostId = "e538f1c9";
    hostName = "apollo";
    networkmanager.enable = false;
    useDHCP = false;

    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 2222 ];
      allowedUDPPorts = [ ];
    };

    nameservers =
      [ "2606:4700:4700::1111" "2606:4700:4700::1001" "1.1.1.1" "1.0.0.1" ];

    interfaces.ens3 = {
      useDHCP = false;

      ipv4.addresses = [{
        address = "152.53.35.165";
        prefixLength = 22;
      }];

      ipv6.addresses = [{
        address = "2a0a:4cc0:100:23::bad:c0de";
        prefixLength = 64;
      }];
    };

    defaultGateway = "152.53.32.1";
  };

  time.timeZone = "Europe/Vienna";

  environment.systemPackages = with pkgs; [
    fzf
    git
    neovim
    tmux
  ];

  users = {
    mutableUsers = false;
    users = {
      mcp = {
        extraGroups = [ "wheel" ];
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID2aEPKcElIy1hJbiBjAa2wil6AYqWydtORxl0ErfBOT"
        ];
        hashedPasswordFile = "/persist/credentials/user_mcp";
        shell = pkgs.fish;
      };

      root = { initialHashedPassword = "!"; };
    };
  };

  programs.fish.enable = true;

  services = {
    borgbackup.jobs = {
      "sidechest" = {
        paths = [ "/persist" "/var/log" ];
        repo =
          "ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg";
        encryption = {
          mode = "repokey-blake2";
          passCommand = "cat /persist/credentials/borg_sidechest_passphrase";
        };
        environment.BORG_RSH = "ssh -i /persist/credentials/borg_sidechest_ssh";
        compression = "auto,zstd";
        startAt = "daily";
      };
    };

    openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
      };
      allowSFTP = true;
      extraConfig = ''
        AllowTcpForwarding yes
        X11Forwarding no
        AllowAgentForwarding no
        AllowStreamLocalForwarding no
        AuthenticationMethods publickey
      '';
    };

    zfs = {
      autoScrub.enable = true;
      autoSnapshot.enable = true;
      trim.enable = true;
    };
  };

  security = {
    auditd.enable = true;
    audit.enable = true;
    sudo.execWheelOnly = true;
    sudo.extraConfig = ''
      # rollback results in sudo lectures after each reboot
      Defaults lecture = never
    '';
  };

  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "23.11"; # Did you read the comment?

}

