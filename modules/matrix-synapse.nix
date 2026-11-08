{
  config,
  ...
}:
let
  inherit (config.sops) placeholder;

  # Synapse takes the first X-Forwarded-For entry as the client address.
  synapse = extraConfig: {
    proxyPass = "http://127.0.0.1:8008";
    recommendedProxySettings = false;
    extraConfig = (import ../lib/nginx-proxy.nix).clientAddressHeaders + extraConfig;
  };
in
{
  sops = {
    secrets = {
      synapse_registration_shared_secret = { };
      synapse_macaroon_secret_key = { };
      synapse_form_secret = { };
      synapse_smtp_password = { };
    };
    templates."synapse-secrets.yaml" = {
      owner = "matrix-synapse";
      # Synapse replaces whole top-level sections with those from extra config
      # files, so the complete email section lives here.
      content = builtins.toJSON {
        registration_shared_secret = placeholder.synapse_registration_shared_secret;
        macaroon_secret_key = placeholder.synapse_macaroon_secret_key;
        form_secret = placeholder.synapse_form_secret;
        email = {
          enable_notifs = true;
          force_tls = true;
          notif_for_new_users = false;
          notif_from = "Matrix ncrypt.at <matrix@ncrypt.at>";
          smtp_host = "smtp.webspace.bz";
          smtp_user = "matrix@ncrypt.at";
          smtp_pass = placeholder.synapse_smtp_password;
        };
      };
      restartUnits = [ "matrix-synapse.service" ];
    };
  };

  services.matrix-synapse = {
    enable = true;
    extras = [ "oidc" ];
    extraConfigFiles = [ config.sops.templates."synapse-secrets.yaml".path ];
    log.root.level = "WARNING";

    settings = {
      server_name = "ncrypt.at";
      public_baseurl = "https://matrix.ncrypt.at";
      require_auth_for_profile_requests = true;
      limit_profile_requests_to_users_who_share_rooms = true;

      listeners = [
        {
          port = 8008;
          bind_addresses = [ "127.0.0.1" ];
          type = "http";
          tls = false;
          x_forwarded = true;
          resources = [
            {
              names = [
                "client"
                "federation"
              ];
              compress = true;
            }
          ];
        }
      ];

      admin_contact = "mailto:admin+matrix@ncrypt.at";
      forgotten_room_retention_period = "7d";
      user_ips_max_age = "7d";
      federation_client_minimum_tls_version = "1.2";
      enable_authenticated_media = true;
      max_upload_size = "100M";
      dynamic_thumbnails = true;
      url_preview_accept_language = [
        "en"
        "de;q=0.9"
      ];
      enable_registration = false;
      auto_join_rooms = [
        "#ncrypt-announcements:ncrypt.at"
        "#ncrypt-services:ncrypt.at"
      ];
      suppress_key_server_warning = true;
      password_config.enabled = false;
      push.include_content = false;
      encryption_enabled_by_default_for_room_type = "invite";

      matrix_authentication_service = {
        enabled = true;
        endpoint = "http://127.0.0.1:8091/";
        secret_path = "/var/lib/matrix-synapse/mas_secret";
      };
    };
  };

  services.synapse-auto-compressor = {
    enable = true;
  };

  environment.persistence."/persist".directories = [
    "/var/lib/matrix-synapse"
  ];

  services.postgresql = {
    ensureDatabases = [ "matrix-synapse" ];
    ensureUsers = [
      {
        name = "matrix-synapse";
        ensureDBOwnership = true;
      }
    ];
  };

  services.nginx = {
    virtualHosts."matrix.ncrypt.at" = {
      enableACME = true;
      forceSSL = true;

      locations."/".return = "404";

      locations."~ ^/_matrix/client/(.*)/(login|logout|refresh)" = {
        proxyPass = "http://127.0.0.1:8091";
      };

      locations."/_matrix" = synapse "client_max_body_size 0;";

      # Other /_synapse paths stay internal, such as /_synapse/mas, which MAS
      # reaches directly.
      locations."/_synapse/client" = synapse "client_max_body_size 0;";
    };
  };
}
