{ pkgs, inputs }:
let
  repo = "/var/lib/borg-repo";
  borg = "BORG_PASSPHRASE=test borg";
in
pkgs.testers.runNixOSTest {
  name = "backup";

  nodes.machine =
    { lib, pkgs, ... }:
    {
      imports = [
        (import ./sops.nix {
          inherit pkgs inputs;
          secrets = {
            borg_passphrase = "test";
            borg_ssh_key = "unused";
            healthchecks_backup_url = "http://127.0.0.1:9/";
          };
        })
        inputs.impermanence.nixosModules.impermanence
        ../modules/backup.nix
        ../modules/postgresql.nix
      ];

      environment.persistence = lib.mkForce { };
      boot.supportedFilesystems = [ "zfs" ];
      networking.hostId = "8425e349";
      virtualisation.emptyDiskImages = [ 1024 ];
      environment.systemPackages = [ pkgs.borgbackup ];

      services.borgbackup.jobs.sidechest.repo = lib.mkForce repo;
      services.postgresql = {
        ensureDatabases = [ "app" ];
        ensureUsers = [
          {
            name = "app";
            ensureDBOwnership = true;
          }
        ];
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("postgresql.target")
    machine.succeed(
        "zpool create -O mountpoint=none rpool /dev/vdb",
        "zfs create -p -o mountpoint=/persist rpool/safe/persist",
        "zfs create -o mountpoint=/mnt/log rpool/safe/log",
        # On Apollo, impermanence bind-mounts /var/backup from /persist.
        "mkdir -p /persist/var/backup && mount --bind /persist/var/backup /var/backup",
        "systemd-tmpfiles --create",
        "mkdir -p /persist/data /persist/var/lib/systemd /mnt/log/nginx",
        "echo original > /persist/data/file",
        "echo seed > /persist/var/lib/systemd/random-seed",
        "echo request > /mnt/log/nginx/access.log",
        "echo problem > /mnt/log/nginx/error.log",
        "runuser -u postgres -- psql -d app -c 'CREATE TABLE t (v int); INSERT INTO t VALUES (42)'",
        "${borg} init --encryption repokey-blake2 ${repo}",
    )

    with subtest("Backup run"):
        machine.succeed("systemctl start borgbackup-job-sidechest.service")
        machine.fail("zfs list -H -t snapshot -o name | grep @borg")
        archive = machine.succeed("${borg} list --short ${repo}").strip()
        assert archive.startswith("machine-sidechest-"), archive

    with subtest("Archive contents"):
        paths = machine.succeed(
            "${borg} list --format '{path}{NL}' ${repo}::" + archive
        ).split()
        for path in [
            "persist/data/file",
            "persist/var/backup/postgresql/app.sql",
            "persist/var/backup/postgresql/globals/globals.sql",
            "var/log/nginx/error.log",
        ]:
            assert path in paths, path
        for path in ["persist/var/lib/systemd/random-seed", "var/log/nginx/access.log"]:
            assert path not in paths, path

    with subtest("Restore"):
        machine.succeed(
            "rm /persist/data/file",
            "runuser -u postgres -- dropdb app",
            "mkdir /restore && cd /restore && ${borg} extract ${repo}::" + archive,
            "runuser -u postgres -- createdb -O app app",
            "runuser -u postgres -- pg_restore -d app /restore/persist/var/backup/postgresql/app.sql",
        )
        assert machine.succeed("cat /restore/persist/data/file").strip() == "original"
        assert machine.succeed("runuser -u postgres -- psql -tA -d app -c 'SELECT v FROM t'").strip() == "42"
        machine.succeed("grep -q 'CREATE ROLE app' /restore/persist/var/backup/postgresql/globals/globals.sql")

    with subtest("A failed run removes its snapshots"):
        machine.succeed("systemd-run --unit=hold-lock -E BORG_PASSPHRASE=test borg with-lock ${repo} ${pkgs.coreutils}/bin/sleep 300")
        machine.wait_until_succeeds("test -e ${repo}/lock.exclusive")
        machine.fail("systemctl start borgbackup-job-sidechest.service")
        machine.fail("zfs list -H -t snapshot -o name | grep @borg")
        machine.succeed("systemctl stop hold-lock")
  '';
}
