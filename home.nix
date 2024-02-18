{ config, pkgs, ... }:

{
  programs.git = {
    enable = true;
    userName = "mkoppmann";
    userEmail = "dev@mkoppmann.at";
  };

  home.stateVersion = "23.11";
}

