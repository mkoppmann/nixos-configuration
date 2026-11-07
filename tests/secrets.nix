{ pkgs, inputs }:
let
  # A throwaway post-quantum key and a secret encrypted to it.
  fixture =
    pkgs.runCommand "sops-fixture"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
      }
      ''
        mkdir $out
        age-keygen -pq -o $out/key.txt
        printf 'password: hunter2\n' > secret.yaml
        sops encrypt --age "$(age-keygen -y $out/key.txt)" secret.yaml > $out/secret.yaml
      '';
in
pkgs.testers.runNixOSTest {
  name = "secrets";

  nodes.machine =
    { config, ... }:
    {
      imports = [ inputs.sops-nix.nixosModules.sops ];

      users.users.app = {
        isSystemUser = true;
        group = "app";
      };
      users.groups.app = { };

      system.activationScripts = {
        installTestKey.text = "install -D -m 400 ${fixture}/key.txt /var/lib/sops-nix/key.txt";
        setupSecrets.deps = [ "installTestKey" ];
      };

      sops = {
        defaultSopsFile = "${fixture}/secret.yaml";
        # Validation would read the fixture during evaluation.
        validateSopsFiles = false;
        age.keyFile = "/var/lib/sops-nix/key.txt";
        age.sshKeyPaths = [ ];
        gnupg.sshKeyPaths = [ ];
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
