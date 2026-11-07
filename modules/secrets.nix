{ inputs, ... }:
{
  imports = [ inputs.sops-nix.nixosModules.sops ];

  sops = {
    defaultSopsFile = ../secrets/apollo.yaml;
    age.keyFile = "/persist/var/lib/sops-nix/key.txt";
    # SSH host keys would only add classical identities.
    age.sshKeyPaths = [ ];
    gnupg.sshKeyPaths = [ ];
  };
}
