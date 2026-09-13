# Evaluation only: no runtime credentials, mail, activation or lockfile changes.
let
  flake = builtins.getFlake ("path:" + toString ../.);
  config = flake.nixosConfigurations.apollo.config;
  lib = flake.inputs.nixpkgs.lib;
  services = config.systemd.services;
in
assert builtins.seq config.system.build.toplevel.drvPath true;
assert services.apollo-alert-send.serviceConfig.LoadCredential == [
  "smtp-password:/persist/credentials/reporting_smtp_password"
];
assert services.apollo-alert-send.serviceConfig.TimeoutStartSec == "90s";
assert services.apollo-alert-verify-failure.serviceConfig.PrivateNetwork;
assert services.apollo-alert-verify-failure.serviceConfig.IPAddressDeny == "any";
assert services.apollo-alert-send.serviceConfig.UMask == "0077";
assert config.systemd.timers.apollo-alert-check.timerConfig.OnUnitActiveSec == "5min";
assert config.systemd.timers.apollo-alert-check.timerConfig.OnBootSec == "5min";
assert lib.hasInfix "observe %i" services."apollo-alert-failure@".serviceConfig.ExecStart;
assert lib.any (p: p.name == "apollo-alert-systemd-hooks") config.systemd.packages;
assert builtins.elem "d /persist/var/lib/apollo-alerts 0700 root root - -" config.systemd.tmpfiles.rules;
assert services.apollo-backup.unitConfig.OnSuccess == [ "apollo-backup-upload.service" ];
assert lib.hasInfix "apollo-backup-recover.service" services.apollo-backup.serviceConfig.ExecStopPost;
assert config.system.stateVersion == "23.11";
assert config.home-manager.users.mcp.home.stateVersion == "23.11";
{
  checks = "passed";
  smtpCredential = "runtime file only";
  failureHook = services."apollo-alert-failure@".serviceConfig.ExecStart;
  note = "Inspect generated service.d and exclusion drop-ins after building; evaluation does not send mail.";
}
