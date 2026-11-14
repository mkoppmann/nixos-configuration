{
  config,
  pkgs,
  ...
}:
{
  sops.secrets.mcp_password_hash.neededForUsers = true;

  environment = {
    enableAllTerminfo = true;

    systemPackages = with pkgs; [
      fishPlugins.done
      fishPlugins.forgit
      fishPlugins.sponge
      fzf
      tmux
      wireguard-tools
    ];

    shellAliases.vimdiff = "nvim -d";
  };

  users = {
    mutableUsers = false;
    users = {
      mcp = {
        extraGroups = [ "wheel" ];
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAID2aEPKcElIy1hJbiBjAa2wil6AYqWydtORxl0ErfBOT"
        ];
        hashedPasswordFile = config.sops.secrets.mcp_password_hash.path;
        shell = pkgs.fish;
      };

      root = {
        initialHashedPassword = "!";
      };
    };
  };

  programs = {
    fish = {
      enable = true;
      interactiveShellInit = "set fish_greeting";
    };

    git = {
      enable = true;
      config.user = {
        name = "mkoppmann";
        email = "dev@mkoppmann.at";
      };
    };

    neovim = {
      enable = true;
      defaultEditor = true;
      viAlias = true;
      vimAlias = true;
      withRuby = false;
      withPython3 = false;
      configure.customRC = ''
        set relativenumber
        set number
      '';
    };
  };

  security.sudo = {
    execWheelOnly = true;
    extraConfig = ''
      # rollback results in sudo lectures after each reboot
      Defaults lecture = never
    '';
  };
}
