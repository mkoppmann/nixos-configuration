# Sandboxes the units that run Nextcloud’s code: web requests, background jobs
# and the push daemon. Separate from nextcloud.nix so its test can use it.
{ config, lib, ... }:
let
  cfg = config.services.nextcloud;
  sandbox = {
    ProtectSystem = "strict";
    ProtectHome = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectProc = "invisible";
    ProtectHostname = true;
    ProtectClock = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    RestrictAddressFamilies = [
      "AF_UNIX"
      "AF_INET"
      "AF_INET6"
    ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    MemoryDenyWriteExecute = true;
    NoNewPrivileges = true;
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
    ];
  };
in
{
  config = lib.mkIf cfg.enable {
    # PCRE’s JIT needs memory that is writable and executable at once.
    services.nextcloud.phpOptions."pcre.jit" = "0";

    systemd.services = {
      # The main process runs as root: it clears the credentials it copies for
      # the workers, hands the socket to nginx, and starts and stops the
      # workers as nextcloud.
      phpfpm-nextcloud.serviceConfig = sandbox // {
        ProtectSystem = lib.mkForce "strict";
        RestrictAddressFamilies = lib.mkForce sandbox.RestrictAddressFamilies;
        ReadWritePaths = [ cfg.datadir ];
        CapabilityBoundingSet = [
          "CAP_CHOWN"
          "CAP_DAC_OVERRIDE"
          "CAP_KILL"
          "CAP_SETGID"
          "CAP_SETUID"
        ];
        SystemCallFilter = sandbox.SystemCallFilter ++ [
          "@chown"
          "@setuid"
        ];
      };

      nextcloud-cron.serviceConfig = sandbox // {
        ReadWritePaths = [ cfg.datadir ];
      };

      nextcloud-notify_push.serviceConfig = lib.mkIf cfg.notify_push.enable (
        sandbox // { ProcSubset = "pid"; }
      );
    };
  };
}
