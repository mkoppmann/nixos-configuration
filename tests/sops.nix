# A NixOS module for test nodes: a throwaway post-quantum key and the given
# secrets encrypted to it, decrypted by sops-nix like on Apollo.
{
  pkgs,
  inputs,
  secrets,
}:
let
  fixture =
    pkgs.runCommand "sops-fixture"
      {
        nativeBuildInputs = [
          pkgs.age
          pkgs.sops
        ];
        # JSON is valid YAML.
        secrets = builtins.toJSON secrets;
      }
      ''
        mkdir $out
        age-keygen -pq -o $out/key.txt
        printf '%s' "$secrets" > secrets.yaml
        sops encrypt --age "$(age-keygen -y $out/key.txt)" secrets.yaml > $out/secrets.yaml
      '';
in
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  # sops-nix rejects key files in the Nix store.
  system.activationScripts = {
    installTestKey.text = "install -D -m 400 ${fixture}/key.txt /var/lib/sops-nix/key.txt";
    setupSecrets.deps = [ "installTestKey" ];
  };

  sops = {
    defaultSopsFile = "${fixture}/secrets.yaml";
    # Validation would read the fixture during evaluation.
    validateSopsFiles = false;
    age.keyFile = "/var/lib/sops-nix/key.txt";
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
  };
}
