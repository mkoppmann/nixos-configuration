{ config, pkgs, ... }:

{
  programs.fish = {
    enable = true;
    interactiveShellInit = ''
      set fish_greeting # Disable greeting
    '';
    plugins = [
      { name = "done"; src = pkgs.fishPlugins.done; }
      { name = "forgit"; src = pkgs.fishPlugins.forgit; }
      { name = "sponge"; src = pkgs.fishPlugins.sponge; }
    ];
  };

  programs.git = {
    enable = true;
    userName = "mkoppmann";
    userEmail = "dev@mkoppmann.at";
  };

  home.stateVersion = "23.11";
}

