{
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
  services.pleroma = {
    enable = true;
    secretConfigFile = "/var/lib/pleroma/secret.exs";
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
          static_dir: "/var/lib/pleroma/static/"

        config :pleroma, :media_proxy,
          enabled: true

        config :pleroma, :shout,
          enabled: false

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
          subject: "mailto:shibayashi@cypherpunk.observer"

        config :pleroma, configurable_from_database: true
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
