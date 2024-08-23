{
  config,
  lib,
  pkgs,
  ...
}:
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
}
