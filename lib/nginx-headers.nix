# Response-header snippets for Nginx `extraConfig`. A location with its own
# add_header must repeat the complete policy, so snippets are combinable.
rec {
  hsts = ''
    # Add HSTS header with preloading to HTTPS requests.
    add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload" always;
  '';
  # For proxied hosts: Nginx also answers by itself, with redirects, errors
  # and rate limits, and a backend’s own header would arrive twice. A location
  # with its own proxy_hide_header must repeat that line.
  proxy-hsts = hsts + ''
    proxy_hide_header Strict-Transport-Security;
  '';


  csp = ''
    # Enable CSP for your services.
    add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; upgrade-insecure-requests;" always;
  '';

  referrer-policy = ''
    # Minimize information leaked to other domains
    add_header 'Referrer-Policy' 'no-referrer' always;
  '';

  x-frame-options = ''
    # Disable embedding as a frame
    add_header X-Frame-Options DENY always;
  '';

  # Files in the Nix store all date from 1970. Without this header, browsers
  # derive from that date that a file stays fresh for years. With it they ask
  # every time, and Nginx answers 304 while the file’s store path is unchanged.
  revalidate = ''
    add_header Cache-Control "no-cache" always;
  '';

  x-content-type-options = ''
    # Prevent injection of code in other mime types (XSS Attacks)
    add_header X-Content-Type-Options nosniff always;
  '';

  default-headers = hsts + csp + referrer-policy + x-frame-options + x-content-type-options;

  default-headers-without-csp = hsts + referrer-policy + x-frame-options + x-content-type-options;
}
