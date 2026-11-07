{ pkgs, inputs }:
let
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;
  homeAuthorizedKeys = pkgs.writeText "authorized_keys" keys.snakeOilPublicKey;
  ssh = "ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -o IdentitiesOnly=yes -o ConnectTimeout=5";
in
pkgs.testers.runNixOSTest {
  name = "hardening";

  nodes.server =
    { lib, ... }:
    {
      imports = [
        inputs.impermanence.nixosModules.impermanence
        ../modules/kernel.nix
        ../modules/nginx.nix
        ../modules/ssh.nix
      ];

      environment.persistence = lib.mkForce { };
      networking.firewall.allowedTCPPorts = [
        80
        443
      ];

      users.users = {
        mcp = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
        };
        root.openssh.authorizedKeys.keys = [ keys.snakeOilEd25519PublicKey ];
      };

      services.nginx.virtualHosts."known.test".locations = {
        "/".return = "200 known";
        "/form" = {
          root = pkgs.writeTextDir "form" "form";
          extraConfig = "limit_req zone=login burst=20 nodelay;";
        };
      };
    };

  nodes.client =
    { pkgs, ... }:
    {
      environment.systemPackages = [ pkgs.curl ];
    };

  testScript = ''
    start_all()
    server.wait_for_unit("sshd.service")
    server.wait_for_unit("nginx.service")
    for port in (22, 80, 443):
        server.wait_for_open_port(port)

    with subtest("Effective sshd configuration"):
        effective: dict[str, list[str]] = {}
        for line in server.succeed("sshd -T").splitlines():
            key, _, value = line.partition(" ")
            effective.setdefault(key.lower(), []).append(value)
        expected = {
            "allowusers": "mcp",
            "permitrootlogin": "no",
            "authenticationmethods": "publickey",
            "passwordauthentication": "no",
            "kbdinteractiveauthentication": "no",
            "authorizedkeysfile": "/etc/ssh/authorized_keys.d/%u",
            "hostkey": "/persist/etc/ssh/ssh_host_ed25519_key",
            "kexalgorithms": "mlkem768x25519-sha256,sntrup761x25519-sha512,sntrup761x25519-sha512@openssh.com",
            "allowtcpforwarding": "no",
            "allowagentforwarding": "no",
            "allowstreamlocalforwarding": "no",
            "x11forwarding": "no",
            "loglevel": "VERBOSE",
        }
        wrong = {k: effective.get(k) for k, v in expected.items() if effective.get(k) != [v]}
        assert not wrong, wrong

    client.succeed("install -m 600 ${keys.snakeOilEd25519PrivateKey} /root/declared")
    client.succeed("install -m 600 ${keys.snakeOilPrivateKey} /root/homedir")

    with subtest("Only mcp logs in, only with keys declared in Nix"):
        client.succeed("${ssh} -i /root/declared mcp@server true")
        client.fail("${ssh} -i /root/declared root@server true")
        server.succeed("install -d -m 700 -o mcp -g users /home/mcp/.ssh")
        server.succeed("install -m 600 -o mcp -g users ${homeAuthorizedKeys} /home/mcp/.ssh/authorized_keys")
        client.fail("${ssh} -i /root/homedir mcp@server true")

    with subtest("Classical key exchange is refused"):
        client.fail("${ssh} -i /root/declared -o KexAlgorithms=curve25519-sha256 mcp@server true")

    with subtest("Unknown host names get no response"):
        client.succeed("curl -sf -H 'Host: known.test' http://server/ | grep -q known")
        rc, _ = client.execute("curl -s -H 'Host: unknown.test' http://server/")
        assert rc == 52, f"plain HTTP: curl exit {rc}"
        rc, _ = client.execute("curl -sk https://server/")
        assert rc in (35, 56), f"TLS: curl exit {rc}"

    with subtest("Only login POSTs are rate-limited"):
        status = "curl -s -o /dev/null -w '%{http_code}\\n' -H 'Host: known.test'"
        reads = client.succeed(f"for i in $(seq 30); do {status} http://server/form; done").split()
        assert set(reads) == {"200"}, reads
        posts = client.succeed(f"for i in $(seq 30); do {status} -X POST http://server/form; done").split()
        assert posts[0] == "405" and "429" in posts, posts

    with subtest("Kernel settings"):
        for key, value in {
            "kernel.kptr_restrict": "2",
            "kernel.dmesg_restrict": "1",
            "kernel.unprivileged_bpf_disabled": "1",
            "net.core.bpf_jit_harden": "2",
            "kernel.yama.ptrace_scope": "1",
            "net.ipv4.conf.all.accept_redirects": "0",
            "net.ipv4.conf.all.send_redirects": "0",
            "net.ipv6.conf.all.accept_redirects": "0",
            "net.ipv4.conf.all.accept_source_route": "0",
            "net.ipv6.conf.all.accept_source_route": "0",
            "kernel.kexec_load_disabled": "1",
        }.items():
            actual = server.succeed(f"sysctl -n {key}").strip()
            assert actual == value, f"{key}: {actual}"
  '';
}
