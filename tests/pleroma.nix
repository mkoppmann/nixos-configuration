{ pkgs, inputs }:
let
  # Runs a command as pleroma with the node’s cookie, like the units do.
  instance = "curl -fs --unix-socket /run/pleroma/http.sock http://localhost/api/v1/instance";
  withCookie = "runuser -u pleroma -- sh -c 'export RELEASE_COOKIE=$(cat ~/.cookie); exec \\\"$@\\\"' sh";

  # Two remote activities whose object doesn’t exist, and a local one. The
  # prune deletes only the remote ones.
  orphans = pkgs.writeText "orphans.sql" ''
    insert into activities (id, data, local, actor, recipients, inserted_at, updated_at) values
      (gen_random_uuid(), '{"id": "https://remote.example/activities/1", "type": "Create", "actor": "https://remote.example/users/a", "to": ["https://www.w3.org/ns/activitystreams#Public"], "object": "https://remote.example/notes/1"}', false, 'https://remote.example/users/a', '{https://www.w3.org/ns/activitystreams#Public}', now(), now()),
      (gen_random_uuid(), '{"id": "https://remote.example/activities/2", "type": "Like", "actor": "https://remote.example/users/a", "object": "https://remote.example/notes/2"}', false, 'https://remote.example/users/a', '{}', now(), now()),
      (gen_random_uuid(), '{"id": "https://local.example/activities/1", "type": "Like", "actor": "https://local.example/users/b", "object": "https://remote.example/notes/3"}', true, 'https://local.example/users/b', '{}', now(), now());
  '';
  psql = "runuser -u postgres -- psql pleroma -v ON_ERROR_STOP=1";
  count = where: "${psql} -Atc 'select count(*) from activities where ${where}'";
in
# Apollo’s Pleroma module with its sandbox, on Apollo’s PostgreSQL.
pkgs.testers.runNixOSTest {
  name = "pleroma";

  nodes.machine =
    { lib, ... }:
    {
      imports = [
        (import ./sops.nix {
          inherit pkgs inputs;
          secrets = {
            pleroma_secret_key_base = lib.concatStrings (lib.replicate 8 "test-key"); # gitleaks:allow
            pleroma_vapid_private_key = "unused";
          };
        })
        inputs.impermanence.nixosModules.impermanence
        ../modules/services/pleroma
        ../modules/services/postgresql.nix
      ];

      environment.persistence = lib.mkForce { };
      virtualisation.memorySize = 3072;
      # The VM has far less memory than Apollo.
      services.postgresql.settings.shared_buffers = lib.mkForce "128MB";

      # The prune unit pauses the upgrade timer.
      systemd.services.nixos-upgrade.script = "true";
      systemd.timers.nixos-upgrade = {
        wantedBy = [ "timers.target" ];
        timerConfig.OnCalendar = "yearly";
      };
    };

  testScript = ''
    machine.wait_for_unit("pleroma.service")
    machine.wait_until_succeeds("${instance} | grep -q cypherpunk")

    with subtest("The unit runs sandboxed"):
        machine.succeed("systemctl show -P ProtectSystem pleroma.service | grep -Fx strict")

    with subtest("pleroma_ctl reaches the node with the cookie file’s content"):
        pid = machine.succeed("${withCookie} pleroma pid").strip()
        assert pid.isdigit(), pid
        machine.fail("runuser -u pleroma -- env RELEASE_COOKIE=/var/lib/pleroma/.cookie pleroma pid")
        machine.succeed("stat -c '%U %a' /var/lib/pleroma/.cookie | grep -Fx 'pleroma 600'")

    with subtest("Only Pleroma’s group opens its socket"):
        machine.succeed("stat -c '%U %G %a' /run/pleroma/http.sock | grep -Fx 'pleroma pleroma 660'")
        machine.succeed("stat -c '%U %G %a' /run/pleroma | grep -Fx 'pleroma pleroma 750'")
        machine.fail("runuser -u nobody -- ${instance}")

    with subtest("Erlang listens on loopback only, and not for HTTP"):
        listeners = machine.succeed("ss -Htlnp | grep -E 'beam|epmd'").splitlines()
        assert listeners, "no listeners found"
        for listener in listeners:
            assert " 127.0.0.1:" in listener or " [::1]:" in listener, listener
            assert ":4000 " not in listener, listener

    with subtest("The monthly prune deletes orphaned activities and resumes the upgrade timer"):
        machine.succeed("${psql} -f ${orphans}")
        machine.succeed("systemctl start pleroma-prune.service")
        machine.succeed("systemctl is-active nixos-upgrade.timer")
        machine.succeed("${count "not local"} | grep -Fx 0")
        machine.succeed("${count "local"} | grep -Fx 1")

    with subtest("Pleroma stops and starts"):
        machine.succeed("systemctl restart pleroma.service")
        machine.wait_until_succeeds("${instance} | grep -q cypherpunk")
        machine.wait_until_succeeds("${withCookie} pleroma pid")

    with subtest("Nothing ran into the sandbox"):
        machine.fail(
            "journalctl -u pleroma -u pleroma-prune"
            " | grep -i -E 'operation not permitted|read-only file system|status=31/SYS'"
        )
  '';
}
