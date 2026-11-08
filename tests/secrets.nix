{ pkgs, inputs }:
pkgs.testers.runNixOSTest {
  name = "secrets";

  nodes.machine =
    { config, ... }:
    {
      imports = [
        (import ./sops.nix {
          inherit pkgs inputs;
          secrets.password = "hunter2";
        })
      ];

      users.users.app = {
        isSystemUser = true;
        group = "app";
      };
      users.groups.app = { };

      sops = {
        secrets.password.owner = "app";
        templates."app.env" = {
          owner = "app";
          content = "PASSWORD=${config.sops.placeholder.password}";
        };
      };
    };

  testScript = ''
    machine.wait_for_unit("multi-user.target")

    with subtest("Secret file"):
        assert machine.succeed("cat /run/secrets/password") == "hunter2"
        assert machine.succeed("stat -L -c '%U %a' /run/secrets/password").strip() == "app 400"

    with subtest("Rendered template"):
        assert machine.succeed("cat /run/secrets/rendered/app.env") == "PASSWORD=hunter2"
        assert machine.succeed("stat -L -c '%U %a' /run/secrets/rendered/app.env").strip() == "app 400"
  '';
}
