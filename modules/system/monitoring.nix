{
  config,
  pkgs,
  ...
}:
let
  recipient = "admin@ncrypt.at";
  inherit (config.networking) hostName;

  # Every service reports its failure. The mailer must not report itself.
  onFailure = pkgs.runCommand "notify-failure-drop-ins" { } ''
    mkdir -p $out/lib/systemd/system/service.d $out/lib/systemd/system/notify-failure@.service.d
    printf '[Unit]\nOnFailure=notify-failure@%%N.service\n' > $out/lib/systemd/system/service.d/50-notify-failure.conf
    ln -s /dev/null $out/lib/systemd/system/notify-failure@.service.d/50-notify-failure.conf
  '';
in
{
  sops.secrets = {
    reporting_smtp_password = { };
    healthchecks_heartbeat_url = { };
  };

  programs.msmtp = {
    enable = true;
    setSendmail = true;
    accounts.default = {
      host = "smtp.webspace.bz";
      port = 465;
      tls = true;
      tls_starttls = false;
      auth = true;
      user = "reporting@ncrypt.at";
      from = "reporting@ncrypt.at";
      passwordeval = "cat ${config.sops.secrets.reporting_smtp_password.path}";
    };
  };

  systemd.packages = [ onFailure ];

  systemd.services."notify-failure@" = {
    description = "Mail about the failure of %i";
    scriptArgs = "%i";
    script = ''
      {
        printf 'To: %s\nSubject: [%s] %s failed\n\n' ${recipient} ${hostName} "$1"
        systemctl status --full --lines=30 --no-pager "$1" || true
      } | ${pkgs.msmtp}/bin/msmtp -t
    '';
    serviceConfig.Type = "oneshot";
  };

  services.zfs.zed.settings = {
    ZED_EMAIL_ADDR = [ recipient ];
    # Without @SUBJECT@, ZED writes the subject as a header for sendmail.
    ZED_EMAIL_OPTS = "@ADDRESS@";
    # Also reports finished scrubs, not only problems.
    ZED_NOTIFY_VERBOSE = true;
  };

  systemd.services.disk-space-check = {
    description = "Fail when the pool or the boot partition is more than 80% full";
    startAt = "daily";
    path = [
      config.boot.zfs.package
      pkgs.coreutils
    ];
    script = ''
      pool=$(zpool list -Hpo capacity rpool)
      boot=$(df --output=pcent /boot | tail -1 | tr -dc 0-9)
      echo "rpool: $pool%, /boot: $boot%"
      [ "$pool" -le 80 ] && [ "$boot" -le 80 ]
    '';
    serviceConfig.Type = "oneshot";
  };

  # healthchecks.io alerts when these pings stop, including when Apollo is down.
  systemd.services.healthchecks-heartbeat = {
    description = "Ping the healthchecks.io heartbeat";
    startAt = "*:0/5";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    script = ''
      ${pkgs.curl}/bin/curl -fsS -m 10 --retry 3 -o /dev/null \
        "$(cat ${config.sops.secrets.healthchecks_heartbeat_url.path})" || true
    '';
    serviceConfig.Type = "oneshot";
  };
}
