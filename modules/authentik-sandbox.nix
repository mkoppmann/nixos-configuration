# Sandboxes Authentik’s server and worker; `ak` runs with the server’s
# settings. Separate from authentik.nix so its test can use it.
{ config, lib, ... }:
let
  # DynamicUser already makes the system read-only and /tmp private, and rules
  # out new privileges.
  sandbox = {
    ProtectHome = true;
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
    LockPersonality = true;
    CapabilityBoundingSet = "";
    SystemCallArchitectures = "native";
    # Gunicorn sets its socket’s owner, even to itself.
    SystemCallFilter = [
      "@system-service"
      "~@privileged"
      "@chown"
    ];
  };
in
{
  config = lib.mkIf config.services.authentik.enable {
    systemd.services = {
      authentik.serviceConfig = sandbox;
      authentik-worker.serviceConfig = sandbox;
    };
  };
}
