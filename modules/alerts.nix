{ config, lib, pkgs, ... }:
let
  state = "/persist/var/lib/apollo-alerts";
  credential = "smtp-password:/persist/credentials/reporting_smtp_password";
  settings = pkgs.writeText "apollo-alerts.json" (builtins.toJSON {
    inherit state;
    host = config.networking.hostName;
    smtpHost = "smtp.webspace.bz";
    smtpPort = 465;
    smtpUser = "reporting@ncrypt.at";
    sender = "reporting@ncrypt.at";
    recipient = "admin@ncrypt.at";
    caFile = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    backupState = "/persist/var/lib/apollo-backup";
    archivePrefix = config.services.borgbackup.jobs.sidechest.archiveBaseName;
    filesystems = [ "/" "/nix" "/persist" "/var/log" "/boot" ];
    certificates = lib.mapAttrs (_: cert: "${cert.directory}/fullchain.pem") config.security.acme.certs;
  });
  path = lib.makeBinPath [ config.systemd.package pkgs.zfs pkgs.util-linux pkgs.openssl ];
  program = pkgs.writeShellScriptBin "apollo-alert" ''
    export LC_ALL=C
    export PATH=${path}:$PATH
    exec ${pkgs.python3}/bin/python3 ${../scripts/alerts.py} ${settings} "$@"
  '';
  verification = pkgs.writeShellScriptBin "apollo-alert-verify" ''
    export LC_ALL=C
    export PATH=${path}:$PATH
    exec ${pkgs.python3}/bin/python3 ${../scripts/alert-verification.py} ${settings} ${../scripts/alerts.py} "$@"
  '';
  command = "${program}/bin/apollo-alert";
  verify = "${verification}/bin/apollo-alert-verify";
  # Packaging drop-ins lets NixOS merge them into the generated unit tree,
  # including upstream services, without replacing any service definitions.
  hooks = pkgs.runCommand "apollo-alert-systemd-hooks" { } ''
    mkdir -p $out/lib/systemd/system/service.d
    cat > $out/lib/systemd/system/service.d/50-apollo-alerts.conf <<'EOF'
    [Unit]
    OnFailure=apollo-alert-failure@%N.service
    EOF
    for directory in apollo-alert-.service.d apollo-backup-test@.service.d; do
      mkdir -p "$out/lib/systemd/system/$directory"
      ln -s /dev/null "$out/lib/systemd/system/$directory/50-apollo-alerts.conf"
    done
  '';
  common = {
    unitConfig.RequiresMountsFor = [ "/persist" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectHome = true;
      ProtectSystem = "strict";
      ReadWritePaths = [ state ];
      TimeoutStartSec = "180s";
      TimeoutStopSec = "5s";
    };
  };
  delivery = lib.recursiveUpdate common {
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${command} deliver";
      LoadCredential = [ credential ];
      TimeoutStartSec = "90s";
    };
  };
in
{
  environment.systemPackages = [ program verification ];
  systemd.packages = [ hooks ];
  systemd.tmpfiles.rules = [ "d ${state} 0700 root root - -" ];
  systemd.services = {
    "apollo-alert-failure@" = lib.recursiveUpdate common {
      description = "Record Apollo service failure (%i)";
      serviceConfig.ExecStart = "${command} observe %i";
    };
    apollo-alert-check = lib.recursiveUpdate common {
      description = "Reconcile Apollo service, backup, storage and certificate health";
      serviceConfig.ExecStart = "${command} check";
    };
    apollo-alert-send = delivery // { description = "Deliver pending Apollo email alerts"; };
    apollo-alert-verify-failure = lib.recursiveUpdate delivery {
      description = "Isolated Apollo SMTP failure verification";
      serviceConfig = {
        ExecStart = "${verify} worker-failure";
        PrivateNetwork = true;
        # Even a host resolver reached over a Unix socket cannot enable SMTP.
        IPAddressDeny = "any";
      };
    };
    apollo-alert-verify-retry = lib.recursiveUpdate delivery {
      description = "Deliver isolated Apollo verification message";
      serviceConfig.ExecStart = "${verify} worker-retry";
    };
  };
  systemd.timers = {
    apollo-alert-check = {
      wantedBy = [ "timers.target" ];
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "5min"; AccuracySec = "1s"; };
    };
    apollo-alert-send = {
      wantedBy = [ "timers.target" ];
      # The durable deliveryNext timestamp enforces the 15-minute retry delay.
      timerConfig = { OnBootSec = "5min"; OnUnitActiveSec = "1min"; AccuracySec = "1s"; };
    };
  };
}
