{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.matrix-authentication-service;

  settingsFormat = pkgs.formats.yaml { };

  configFile = settingsFormat.generate "mas-config.yaml" cfg.settings;
in
{
  options.services.matrix-authentication-service = {
    enable = lib.mkEnableOption "Matrix Authentication Service (MAS)";

    package = lib.mkPackageOption pkgs "matrix-authentication-service" { };

    extraConfigFiles = lib.mkOption {
      type = lib.types.listOf lib.types.path;
      default = [ ];
      description = ''
        Additional YAML configuration files to pass to MAS.
        These are merged with the main configuration and can contain secrets
        (e.g. encryption key, signing keys, homeserver shared secret)
        that should not be in the Nix store.
      '';
    };

    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = settingsFormat.type;
      };
      default = { };
      description = ''
        MAS configuration as a Nix attribute set.
        See <https://element-hq.github.io/matrix-authentication-service/reference/configuration.html>
        for the full reference.

        **Do not place secrets here** — they end up world-readable in the Nix store.
        Use {option}`extraConfigFiles` instead.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.services.matrix-authentication-service = {
      description = "Matrix Authentication Service";
      wants = [ "network-online.target" ];
      after = [
        "network-online.target"
        "postgresql.service"
      ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];

      environment = {
        MAS_CONFIG = lib.concatStringsSep ":" (
          [ "${configFile}" ] ++ cfg.extraConfigFiles
        );
      };

      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} server";
        Restart = "on-failure";
        RestartSec = "5s";

        # Hardening
        DynamicUser = true;
        StateDirectory = "matrix-authentication-service";
        RuntimeDirectory = "matrix-authentication-service";
        UMask = "0077";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = false; # WASM policy engine needs W^X
        SystemCallFilter = [
          "@system-service"
          "~@privileged"
        ];
        SystemCallArchitectures = "native";
        CapabilityBoundingSet = "";
      };
    };
  };
}

