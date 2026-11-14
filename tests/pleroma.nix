{ pkgs, inputs }:
let
  # Runs a command as pleroma with the node’s cookie, like the units do.
  withCookie = "runuser -u pleroma -- sh -c 'export RELEASE_COOKIE=$(cat ~/.cookie); exec \\\"$@\\\"' sh";
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
        ../modules/services/pleroma.nix
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
    machine.wait_for_open_port(4000)
    machine.wait_until_succeeds("curl -fs http://127.0.0.1:4000/api/v1/instance | grep -q cypherpunk")

    with subtest("The unit runs sandboxed"):
        machine.succeed("systemctl show -P ProtectSystem pleroma.service | grep -Fx strict")

    with subtest("pleroma_ctl reaches the node with the cookie file’s content"):
        pid = machine.succeed("${withCookie} pleroma pid").strip()
        assert pid.isdigit(), pid
        machine.fail("runuser -u pleroma -- env RELEASE_COOKIE=/var/lib/pleroma/.cookie pleroma pid")
        machine.succeed("stat -c '%U %a' /var/lib/pleroma/.cookie | grep -Fx 'pleroma 600'")

    with subtest("Erlang listens on loopback only"):
        listeners = machine.succeed("ss -Htlnp | grep -E 'beam|epmd'").splitlines()
        assert listeners, "no listeners found"
        for listener in listeners:
            assert " 127.0.0.1:" in listener or " [::1]:" in listener, listener

    with subtest("The monthly prune runs and resumes the upgrade timer"):
        machine.succeed("systemctl start pleroma-prune.service")
        machine.succeed("systemctl is-active nixos-upgrade.timer")

    with subtest("Pleroma stops and starts"):
        machine.succeed("systemctl restart pleroma.service")
        machine.wait_for_open_port(4000)
        machine.wait_until_succeeds("${withCookie} pleroma pid")

    with subtest("Nothing ran into the sandbox"):
        machine.fail(
            "journalctl -u pleroma -u pleroma-prune"
            " | grep -i -E 'operation not permitted|read-only file system|status=31/SYS'"
        )
  '';
}
