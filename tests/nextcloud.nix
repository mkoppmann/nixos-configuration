{ pkgs, package }:
let
  adminpass = "hunter2";
  curl = "curl -sSf -u root:${adminpass}";
  image = "${pkgs.nixos-icons}/share/icons/hicolor/64x64/apps/nix-snowflake.png";
in
# Apollo’s Nextcloud sandbox around a minimal Nextcloud.
pkgs.testers.runNixOSTest {
  name = "nextcloud";

  nodes.machine = {
    imports = [ ../modules/nextcloud-sandbox.nix ];

    virtualisation.memorySize = 2048;

    services.nextcloud = {
      enable = true;
      inherit package;
      hostName = "nextcloud";
      configureRedis = true;
      database.createLocally = true;
      notify_push = {
        enable = true;
        bendDomainToLocalhost = true;
        logLevel = "debug";
      };
      config = {
        dbtype = "pgsql";
        adminuser = "root";
        adminpassFile = toString (pkgs.writeText "adminpass" adminpass);
      };
      settings.trusted_proxies = [ "::1" ];
    };
  };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nextcloud-notify_push.service")

    with subtest("The units run sandboxed"):
        for unit in ("phpfpm-nextcloud", "nextcloud-cron", "nextcloud-notify_push"):
            machine.succeed(f"systemctl show -P ProtectSystem {unit}.service | grep -Fx strict")

    with subtest("php-fpm restarts and reloads"):
        machine.succeed("systemctl restart phpfpm-nextcloud.service")
        machine.succeed("${curl} http://nextcloud/status.php | grep -F '\"installed\":true'")
        machine.succeed("systemctl reload phpfpm-nextcloud.service")
        machine.wait_until_succeeds("${curl} http://nextcloud/status.php")

    with subtest("Uploads get previews"):
        machine.succeed("${curl} -T ${image} http://nextcloud/remote.php/dav/files/root/image.png")
        content_type = machine.succeed(
            "${curl} -o /dev/null -w '%{content_type}' "
            "'http://nextcloud/index.php/core/preview.png?file=/image.png&x=32&y=32'"
        )
        assert content_type.startswith("image/"), content_type

    with subtest("Background jobs run"):
        machine.succeed("systemctl start --wait nextcloud-cron.service")
        machine.succeed("systemctl show -P Result nextcloud-cron.service | grep -Fx success")
        machine.succeed("nextcloud-occ config:app:get core lastcron")

    with subtest("Push notifications reach clients"):
        machine.execute(
            "${pkgs.lib.getExe pkgs.nextcloud-notify_push.passthru.test_client} "
            "http://nextcloud root ${adminpass} >&2 &"
        )
        machine.wait_until_succeeds("journalctl -u nextcloud-notify_push | grep -q 'Sending ping to root'")

    with subtest("Nothing ran into the sandbox"):
        machine.fail(
            "journalctl -u phpfpm-nextcloud -u nextcloud-cron -u nextcloud-notify_push"
            " | grep -i -E 'operation not permitted|read-only file system|jit'"
        )
  '';
}
