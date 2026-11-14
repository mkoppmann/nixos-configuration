# Runs `nginx -t` on Apollo’s generated configuration. Building the system
# doesn’t, so an error such as a log format defined after its use would only
# show when Nginx restarts on Apollo.
{ pkgs, apollo }:
let
  # With reloading, the module exposes the configuration file as an /etc entry.
  inherit (apollo.extendModules { modules = [ { services.nginx.enableReload = true; } ]; }) config;
  configFile = config.environment.etc."nginx/nginx.conf".source;
in
pkgs.runCommand "nginx-config"
  {
    nativeBuildInputs = [
      config.services.nginx.package
      pkgs.openssl
    ];
  }
  ''
    openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=test \
      -keyout key.pem -out cert.pem
    mkdir run log cache

    # The certificates and state directories only exist on Apollo, and the
    # build user may bind neither low ports nor, in every sandbox, IPv6.
    sed -E \
      -e "s#/var/lib/acme/[^/]+/(fullchain|chain)\.pem#$PWD/cert.pem#g" \
      -e "s#/var/lib/acme/[^/]+/key\.pem#$PWD/key.pem#g" \
      -e "s#/run/nginx/#$PWD/run/#g" \
      -e "s#/var/log/nginx/#$PWD/log/#g" \
      -e "s#/var/cache/nginx/#$PWD/cache/#g" \
      -e '/listen \[/d' \
      -e 's#(listen [0-9.]+):80([ ;])#\1:8080\2#' \
      -e 's#(listen [0-9.]+):443([ ;])#\1:8443\2#' \
      ${configFile} > nginx.conf

    nginx -t -c "$PWD/nginx.conf" -e stderr
    touch $out
  ''
