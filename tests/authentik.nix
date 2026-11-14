{ pkgs, inputs }:
let
  password = "test-password";
  token = "test-token";
  api = "http://localhost:9000/api/v3";
in
# Apollo’s Authentik sandbox around a minimal Authentik.
pkgs.testers.runNixOSTest {
  name = "authentik";

  nodes.machine = {
    imports = [
      inputs.authentik-nix.nixosModules.default
      ../modules/authentik-sandbox.nix
    ];

    virtualisation = {
      cores = 3;
      memorySize = 3072;
    };

    # The bootstrap blueprint creates akadmin with this password and API token.
    environment.etc."authentik.env".text = ''
      AUTHENTIK_SECRET_KEY=test-secret-key
      AUTHENTIK_BOOTSTRAP_PASSWORD=${password}
      AUTHENTIK_BOOTSTRAP_TOKEN=${token}
    '';

    services.authentik = {
      enable = true;
      environmentFile = "/etc/authentik.env";
      settings.disable_update_check = true;
    };
  };

  testScript = ''
    import json

    machine.wait_for_unit("authentik.service")
    machine.wait_for_open_port(9000)
    machine.wait_until_succeeds("curl -fs http://localhost:9000/-/health/ready/")

    with subtest("The units run sandboxed"):
        for unit in ("authentik", "authentik-worker"):
            machine.succeed(f"systemctl show -P ProtectKernelTunables {unit}.service | grep -Fx yes")

    with subtest("The worker applies blueprints"):
        machine.wait_until_succeeds(
            "curl -fs -H 'Authorization: Bearer ${token}' ${api}/core/users/me/ | grep -q akadmin"
        )

    with subtest("Password login works"):
        def flow(payload=None):
            command = (
                "curl -fsSL -b /tmp/jar -c /tmp/jar -H 'Content-Type: application/json' "
                "'${api}/flows/executor/default-authentication-flow/?query='"
            )
            if payload is not None:
                command += f" -d '{json.dumps(payload)}'"
            return json.loads(machine.succeed(command))["component"]

        machine.wait_until_succeeds(
            "curl -fs '${api}/flows/executor/default-authentication-flow/?query=' | grep -q ak-stage-identification"
        )
        assert flow() == "ak-stage-identification"
        assert flow({"component": "ak-stage-identification", "uid_field": "akadmin"}) == "ak-stage-password"
        assert flow({"component": "ak-stage-password", "password": "${password}"}) == "xak-flow-redirect"
        me = json.loads(machine.succeed("curl -fs -b /tmp/jar ${api}/core/users/me/"))
        assert me["user"]["username"] == "akadmin", me

    with subtest("ak runs with the server’s sandbox"):
        output = machine.succeed("script -qec \"ak shell -c 'print(6 * 7)'\" /dev/null")
        assert "42" in output, output

    with subtest("Nothing ran into the sandbox"):
        machine.fail(
            "journalctl -u authentik -u authentik-worker"
            " | grep -i -E 'operation not permitted|read-only file system|status=31/SYS'"
        )
  '';
}
