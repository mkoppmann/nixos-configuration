{
  config,
  lib,
  pkgs,
  ...
}:
let
  secretsDir = "/var/lib/private/matrix-authentication-service";
in
{
  services.matrix-authentication-service = {
    enable = true;

    extraConfigFiles = [
      "${secretsDir}/secrets.yaml"
    ];

    settings = {
      http = {
        public_base = "https://auth.matrix.ncrypt.at/";
        listeners = [
          {
            name = "web";
            resources = [
              { name = "discovery"; }
              { name = "human"; }
              { name = "oauth"; }
              { name = "compat"; }
              { name = "graphql"; }
              { name = "assets"; }
            ];
            binds = [
              {
                host = "127.0.0.1";
                port = 8091;
              }
            ];
          }
          {
            name = "internal";
            resources = [
              { name = "health"; }
            ];
            binds = [
              {
                host = "127.0.0.1";
                port = 8092;
              }
            ];
          }
        ];
      };

      database = {
	socket = "/run/postgresql";
        username = "matrix-authentication-service";
        database = "matrix-authentication-service";
      };

      matrix = {
        kind = "synapse";
        homeserver = "ncrypt.at";
        endpoint = "http://127.0.0.1:8008";
        secret_file = "${secretsDir}/homeserver_secret";
      };

      email = {
        from = "\"Matrix Authentication Service\" <mas@ncrypt.at>";
        reply_to = "\"Matrix Authentication Service\" <mas@ncrypt.at>";
        transport = "smtp";
        mode = "tls";
        hostname = "smtp.webspace.bz";
        port = 465;
        username = "mas@ncrypt.at";
      };

      passwords = {
        enabled = false;
        schemes = [
          {
            version = 1;
            algorithm = "bcrypt";
            unicode_normalization = true;
          }
          {
            version = 2;
            algorithm = "argon2id";
          }
        ];
      };

      account = {
        email_change_allowed = true;
        displayname_change_allowed = true;
        password_registration_enabled = false;
      };

      telemetry = {
        tracing.exporter = "none";
        metrics.exporter = "none";
      };
    };
  };
}

