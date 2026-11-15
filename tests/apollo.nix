{ pkgs, inputs }:
let
  # Signs the hosts’ certificates. NixOS’ ACME module issues certificates from
  # the authority in its state directory until an order succeeds, and no order
  # runs here.
  ca = pkgs.runCommand "test-ca" { nativeBuildInputs = [ pkgs.minica ]; } ''
    mkdir $out
    minica --ca-key $out/key.pem --ca-cert $out/cert.pem --domains selfsigned.local
  '';

  # Matrix Authentication Service’s keys and mail password, and the secret it
  # shares with Synapse; none of them is in sops yet.
  masSecrets =
    pkgs.runCommand "mas-secrets.yaml"
      {
        nativeBuildInputs = [
          pkgs.matrix-authentication-service
          pkgs.yq-go
        ];
      }
      ''
        # mas-cli sets up its HTTP client for every command, which fails
        # without CA certificates.
        export SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt
        mas-cli config generate | yq '{"secrets": .secrets, "email": {"password": "testsecret"}}' > $out
      '';
  sharedSecret = pkgs.writeText "mas-shared-secret" "test-secret";

  secretValue =
    name:
    if pkgs.lib.hasPrefix "wireguard_" name then
      # 32 bytes in Base64.
      pkgs.lib.concatStrings (pkgs.lib.replicate 10 "dGVz") + "dGU="
    else if name == "pleroma_secret_key_base" then
      pkgs.lib.concatStrings (pkgs.lib.replicate 8 "test-key")
    else
      "testsecret";

  # The hosts that Nginx serves, without the catch-all for unknown names.
  webHosts =
    config:
    pkgs.lib.attrNames (
      pkgs.lib.filterAttrs (_: host: !host.rejectSSL) config.services.nginx.virtualHosts
    );

  # Their backends run on other machines.
  remoteBackends = [ "photos.mkoppmann.at" ];
in
# Apollo’s complete configuration on a fresh disk, with generated secrets, a
# test certificate authority and no network beyond the machine itself.
pkgs.testers.runNixOSTest {
  name = "apollo";

  node = {
    specialArgs = { inherit inputs; };
    # The configuration sets its own platform.
    pkgsReadOnly = false;
  };

  nodes.apollo =
    { config, lib, ... }:
    {
      imports = [
        ../configuration.nix
        (import ./sops.nix {
          inherit pkgs inputs;
          secrets = lib.mapAttrs' (
            _: secret: lib.nameValuePair secret.key (secretValue secret.key)
          ) config.sops.secrets;
        })
      ];
      # Replaced by the fixture above.
      disabledModules = [ ../modules/system/secrets.nix ];

      virtualisation = {
        cores = 4;
        memorySize = 8192;
        diskSize = 8192;
      };

      # /persist is a directory on the VM’s disk: no pool, no passphrase and
      # so no unlock over SSH.
      disko.enableConfig = false;
      boot.initrd = {
        network.enable = lib.mkForce false;
        systemd.network.enable = lib.mkForce false;
        systemd.services.zfs-rollback.enable = false;
      };

      networking = {
        interfaces = lib.mkForce config.system.build.networkConfig.networking.interfaces;
        defaultGateway = lib.mkForce null;
        defaultGateway6 = lib.mkForce null;
        hosts."127.0.0.1" = webHosts config;
      };

      # Like on Apollo, instead of the test driver’s empty password.
      users.users.root.hashedPasswordFile = lib.mkForce null;

      # VMs switch it off, and with it the owner of its persisted directory.
      services.timesyncd.enable = lib.mkForce true;

      # No timer fires during the test: upgrades, backups and the periodic
      # checks need the pool or the internet.
      systemd.targets.timers.enable = false;

      security.pki.certificateFiles = [ "${ca}/cert.pem" ];
      systemd.services = lib.mapAttrs' (
        cert: _: lib.nameValuePair "acme-order-renew-${cert}" { enable = false; }
      ) config.security.acme.certs;

      # What a fresh /persist lacks and no unit creates.
      system.activationScripts = {
        testState = {
          deps = [
            "users"
            "groups"
          ];
          text = ''
            mkdir -p /persist/etc
            echo ${builtins.hashString "md5" "apollo"} > /persist/etc/machine-id

            install -D -o acme -g acme -m 600 -t /persist/var/lib/acme/.minica ${ca}/key.pem ${ca}/cert.pem

            mas=/persist/var/lib/private/matrix-authentication-service
            install -D -m 600 ${masSecrets} $mas/secrets.yaml
            install -m 600 ${sharedSecret} $mas/homeserver_secret

            synapse=/persist/var/lib/matrix-synapse
            install -d -o matrix-synapse -g matrix-synapse -m 700 $synapse
            install -o matrix-synapse -g matrix-synapse -m 600 ${sharedSecret} $synapse/mas_secret
          '';
        };
        createPersistentStorageDirs.deps = [ "testState" ];
        setupSecretsForUsers.deps = [ "installTestKey" ];
      };
    };

  testScript =
    { nodes, ... }:
    let
      frontend = nodes.apollo.services.authentik.authentikComponents.frontend;
    in
    ''
      import json

      hosts = json.loads('${builtins.toJSON (webHosts nodes.apollo)}')
      remote_backends = json.loads('${builtins.toJSON remoteBackends}')

      def status(url):
          return f"curl -sS -o /dev/null -w '%{{http_code}}' {url}"

      def no_unit_failed():
          failed = apollo.succeed("systemctl list-units --failed --plain --no-legend")
          assert not failed.strip(), failed

      apollo.wait_for_unit("multi-user.target", timeout=1800)

      with subtest("No unit failed during boot"):
          no_unit_failed()

      with subtest("The activation succeeded on an empty /persist"):
          # The first line shows that the journal holds the activation’s output.
          apollo.succeed("journalctl -b | grep -F \"Source directory '/persist/var/lib/postgresql' does not exist\"")
          apollo.fail("journalctl -b | grep 'Activation script snippet'")

      backends = [
          ("https://matrix.ncrypt.at/_matrix/client/versions", "unstable_features"),
          ("https://matrix.ncrypt.at/_matrix/client/v3/login", "flows"),
          ("https://auth.matrix.ncrypt.at/.well-known/openid-configuration", "authorization_endpoint"),
          ("https://idp.ncrypt.at/api/v3/root/config/", "capabilities"),
          ("https://cloud.ncrypt.at/status.php", '"installed":true'),
          ("https://pw.ncrypt.at/api/config", '"version"'),
          ("https://budget.ncrypt.at/account/needs-bootstrap", '"status":"ok"'),
          ("https://communicating.cypherpunk.observer/api/v1/instance", "cypherpunk"),
          ("https://chat.ncrypt.at/config.json", "matrix.ncrypt.at"),
      ]

      # Locations that set response headers of their own, where Nginx doesn’t
      # inherit the host’s.
      own_headers = [
          "https://idp.ncrypt.at/static/dist/chunks/missing.js",
          "https://ncrypt.at/.well-known/matrix/server",
          "https://ncrypt.at/.well-known/security.txt",
          "https://www.mkoppmann.at/_astro/missing.css",
      ]

      with subtest("The backends answer through Nginx"):
          for url, content in backends:
              apollo.wait_until_succeeds(f"curl -fsS {url} | grep -F '{content}'", timeout=600)

      with subtest("Only Nginx opens the backends’ sockets"):
          sockets = [
              ("matrix-synapse", "/run/matrix-synapse/nginx.sock"),
              ("pleroma", "/run/pleroma/http.sock"),
          ]
          for owner, socket in sockets:
              apollo.succeed(f"stat -c '%U %G %a' {socket} | grep -Fx '{owner} {owner} 660'")
              members = apollo.succeed(f"getent group {owner}").strip().split(":")[3]
              assert members == "nginx", f"{owner}: {members}"
          apollo.fail("ss -Htln | grep -F ':4000 '")

      with subtest("Synapse reaches Matrix Authentication Service"):
          apollo.succeed(
              "curl -fsS https://matrix.ncrypt.at/_matrix/client/v1/auth_metadata"
              " | grep -F https://auth.matrix.ncrypt.at/"
          )

      with subtest("Every virtual host answers"):
          for host in hosts:
              code = apollo.succeed(status(f"https://{host}/")).strip()
              if host in remote_backends:
                  assert code in ("502", "504"), f"{host}: {code}"
              else:
                  assert code != "000" and not code.startswith("5"), f"{host}: {code}"
              code = apollo.succeed(status(f"http://{host}/")).strip()
              assert code == "301", f"{host} without TLS: {code}"

      with subtest("Every response has one HSTS header"):
          urls = [f"https://{host}/" for host in hosts] + [url for url, _ in backends] + own_headers
          for url in urls:
              headers = apollo.succeed(f"curl -sS -o /dev/null -D - {url}").lower()
              count = headers.count("\nstrict-transport-security:")
              assert count == 1, f"{url}: {count} HSTS headers"

      with subtest("Nginx serves Authentik’s static files from the store"):
          def headers_of(path):
              response = apollo.succeed(f"curl -fsS -o /dev/null -D - https://idp.ncrypt.at{path}").lower()
              lines = [line.split(": ", 1) for line in response.splitlines() if ": " in line]
              return {name: value.strip() for name, value in lines}

          frontend = "${frontend}"
          chunk = apollo.succeed(f"find {frontend}/dist -path '*/chunks/*.js' -print -quit").strip()
          assert chunk, "the frontend has no chunks"
          chunk = "/static" + chunk.removeprefix(frontend)

          revalidated = [
              "/static/dist/assets/icons/icon.png",
              "/static/dist/flow/FlowInterface-${frontend.version}.js",
              "/static/dist/styles/flow-${frontend.version}.css",
          ]
          for path in revalidated + [chunk]:
              headers = headers_of(path)
              assert "last-modified" not in headers, f"{path}: {headers}"
              # Authentik’s own server starts it with the date.
              assert "etag" in headers and '"1.' not in headers["etag"], f"{path}: {headers}"
              expected = "no-cache" if path in revalidated else "public, max-age=31536000, immutable"
              assert headers["cache-control"] == expected, f"{path}: {headers}"
              if path.endswith(".js"):
                  assert "javascript" in headers["content-type"], f"{path}: {headers}"
              if path.endswith(".css"):
                  assert headers["content-type"].startswith("text/css"), f"{path}: {headers}"

          missing = apollo.succeed("curl -sS -o /dev/null -D - https://idp.ncrypt.at/static/dist/chunks/missing.js").lower()
          assert missing.startswith("http/2 404"), missing
          assert "cache-control:" not in missing, missing

      with subtest("A freshly booted system needs no reboot"):
          apollo.succeed("systemctl start pending-reboot-check.service")

      with subtest("No unit failed since"):
          no_unit_failed()
    '';
}
