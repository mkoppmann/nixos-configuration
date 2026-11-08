{
  config,
  pkgs,
  ...
}:
let
  # A location with its own proxy_set_header does not inherit the parent's, so
  # the media location repeats them.
  pleroma-proxy-headers = ''
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  '';
in
{
  sops = {
    secrets.pleroma_secret_key_base = { };
    secrets.pleroma_vapid_private_key = { };
    templates."pleroma-secret.exs" = {
      owner = config.services.pleroma.user;
      content = ''
        import Config

        config :pleroma, Pleroma.Web.Endpoint,
          secret_key_base: "${config.sops.placeholder.pleroma_secret_key_base}"

        config :web_push_encryption, :vapid_details,
          private_key: "${config.sops.placeholder.pleroma_vapid_private_key}"
      '';
      restartUnits = [ "pleroma.service" ];
    };
  };

  services.pleroma = {
    enable = true;
    secretConfigFile = config.sops.templates."pleroma-secret.exs".path;
    configs = [
      ''
        import Config

        config :pleroma, Pleroma.Web.Endpoint,
          url: [host: "communicating.cypherpunk.observer", scheme: "https", port: 443],
          http: [ip: {127, 0, 0, 1}, port: 4000]

        config :pleroma, :instance,
          name: "pleroma/cypherpunk.observer",
          email: "shibayashi@cypherpunk.observer",
          limit: 9001,
          registrations_open: false,
          cleanup_attachments: true,
          safe_dm_mentions: true,
          static_dir: "/var/lib/pleroma/static/"

        config :pleroma, :restrict_unauthenticated,
          timelines: %{local: :if_instance_is_private, federated: true}

        config :pleroma, :frontend_configurations,
          pleroma_fe: %{
            background: "https://communicating.cypherpunk.observer/media/98ac7550-ed5e-4da3-9fde-bb50cc52a226/background.gif",
            logo: "/static/logo.png",
            theme: "pleroma-dark",
            alwaysShowSubjectInput: true,
            collapseMessageWithSubject: false,
            disableChat: true,
            greentext: true,
            hidePostStats: false,
            hideSitename: false,
            hideUserStats: false,
            redirectRootLogin: "/main/friends",
            redirectRootNoLogin: "/main/all",
            scopeCopy: true,
            showFeaturesPanel: false,
            showInstanceSpecificPanel: false,
            subjectLineBehavior: "email",
            enableEmojiPicker: true,
            formattingOptionsEnabled: true,
            scopeOptionsEnabled: true,
            stickers: true
          },
          masto_fe: %{showInstanceSpecificPanel: false}

        config :pleroma, :static_fe, enabled: false

        config :pleroma, :shout, enabled: false

        config :pleroma, :markup,
          allow_headings: true,
          allow_tables: true,
          allow_fonts: true

        config :pleroma, :mrf,
          policies: [
            Pleroma.Web.ActivityPub.MRF.ObjectAgePolicy,
            Pleroma.Web.ActivityPub.MRF.StealEmojiPolicy
          ]

        config :pleroma, :media_proxy,
          enabled: true,
          base_url: "https://media.communicating.cypherpunk.observer",
          proxy_opts: [redirect_on_failure: true],
          invalidation: [enabled: true]

        config :pleroma, :media_preview_proxy, enabled: true

        config :pleroma, :instances_favicons, enabled: true

        config :pleroma, Pleroma.Upload,
          filters: [
            Pleroma.Upload.Filter.Dedupe,
            Pleroma.Upload.Filter.AnonymizeFilename,
            Pleroma.Upload.Filter.Mogrify
          ]

        config :pleroma, Pleroma.Upload.Filter.Mogrify, args: ["strip", "auto-orient"]

        config :pleroma, Pleroma.Captcha, enabled: false

        config :pleroma, :oauth2, clean_expired_tokens: true

        config :pleroma, :rate_limit,
          search: [{1000, 10}, {1000, 30}],
          timeline: {500, 3},
          app_account_creation: {1_800_000, 25},
          relations_actions: {10_000, 10},
          relation_id_action: {60_000, 2},
          statuses_actions: {10_000, 15},
          status_id_action: {60_000, 3},
          authentication: {60_000, 15}

        config :pleroma, Pleroma.Repo,
          adapter: Ecto.Adapters.Postgres,
          database: "pleroma",
          socket_dir: "/var/run/postgresql",
          pool_size: 10

        config :pleroma, :http_security,
          sts: true,
          sts_max_age: 31_536_000,
          ct_max_age: 2_592_000,
          referrer_policy: "no-referrer"

        config :web_push_encryption, :vapid_details,
          subject: "mailto:shibayashi@cypherpunk.observer",
          public_key: "BAAFL_q8nM3gu75uK4VfcNQEmkn8wn3At_xl1gf3AN4ZqqrAHNleOYy78du2TdJyd7St6BDMc98ZZPaqGLRUHhg"

        # Settings changed in the admin interface would override this file.
        config :pleroma, configurable_from_database: false
      ''
    ];
  };

  systemd.services.pleroma.path = [
    pkgs.exiftool
    pkgs.ffmpeg
    pkgs.imagemagick
  ];

  environment.persistence."/persist".directories = [
    "/var/lib/pleroma"
  ];

  services.postgresql = {
    ensureDatabases = [ "pleroma" ];
    ensureUsers = [
      {
        name = "pleroma";
        ensureDBOwnership = true;
      }
    ];
  };

  services.nginx = {
    proxyCachePath."pleroma" = {
      enable = true;
      useTempPath = false;
      maxSize = "10g";
      levels = "1:2";
      keysZoneSize = "10m";
      keysZoneName = "pleroma_media_cache";
      inactive = "720m";
    };

    upstreams."phoenix" = {
      servers = {
        "127.0.0.1:4000" = {
          max_fails = 5;
          fail_timeout = "60s";
        };
      };
    };

    virtualHosts."communicating.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = ''
        etag on;

        proxy_http_version 1.1;
        ${pleroma-proxy-headers}

        client_max_body_size 100m;
      '';

      locations."/" = {
        recommendedProxySettings = false;
        proxyPass = "http://phoenix";
      };

      locations."/media" = {
        return = "301 https://media.communicating.cypherpunk.observer$request_uri";
      };

      locations."/proxy" = {
        return = "404";
      };

      # Admin API, admin frontend and dashboards only from WireGuard. The
      # resolver for WireGuard clients points this host at the tunnel.
      locations."~ ^/(api/v1/pleroma/admin|pleroma/(admin|live_dashboard|oban))(/|$)" = {
        recommendedProxySettings = false;
        proxyPass = "http://phoenix";
        extraConfig = ''
          allow 10.100.0.0/24;
          deny all;
        '';
      };
    };

    virtualHosts."media.communicating.cypherpunk.observer" = {
      enableACME = true;
      forceSSL = true;

      extraConfig = ''
        proxy_http_version 1.1;
      ''
      + pleroma-proxy-headers;

      locations."/" = {
        return = "404";
      };

      locations."~ ^/(media|proxy)" = {
        recommendedProxySettings = false;
        proxyPass = "http://phoenix";

        extraConfig = pleroma-proxy-headers + ''
          proxy_cache        pleroma_media_cache;
          proxy_cache_key    $host$uri$is_args$args;
          proxy_cache_valid  200 301 304 1h;
          proxy_cache_lock   on;
          proxy_ignore_client_abort on;
          proxy_buffering    on;
          chunked_transfer_encoding on;
        '';
      };
    };
  };
}
