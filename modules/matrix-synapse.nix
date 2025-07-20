{
  config,
  lib,
  pkgs,
  ...
}:
{
  services.matrix-synapse = {
    enable = true;
    extras = [ "oidc" ];
    extraConfigFiles = [ "/var/lib/matrix-synapse/secrets.yaml" ];
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
    };
  };

  services.synapse-auto-compressor = {
      enable = true;
  };
}
