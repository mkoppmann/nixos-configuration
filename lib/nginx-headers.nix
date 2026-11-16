# Response-header snippets for Nginx `extraConfig`. A location with its own
# add_header must repeat the complete policy, so snippets are combinable.
rec {
  hsts = ''
    add_header Strict-Transport-Security "max-age=31536000; includeSubdomains; preload" always;
  '';

  # For proxied hosts: Nginx also answers by itself, with redirects, errors
  # and rate limits, and a backend’s own header would arrive twice. A location
  # with its own proxy_hide_header must repeat that line.
  proxy-hsts = hsts + ''
    proxy_hide_header Strict-Transport-Security;
  '';

  csp = ''
    add_header Content-Security-Policy "default-src 'none'; style-src 'self'; img-src 'self'; font-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'none'; upgrade-insecure-requests;" always;
  '';

  referrer-policy = ''
    add_header Referrer-Policy "no-referrer" always;
  '';

  x-frame-options = ''
    add_header X-Frame-Options DENY always;
  '';

  x-content-type-options = ''
    add_header X-Content-Type-Options nosniff always;
  '';

  # nixpkgs’ Nginx sends files from the Nix store with an ETag made of their
  # store path and without their date, which is the same for all of them. This
  # header makes browsers ask every time instead of leaving that to them.
  # Nginx answers 304 while the file’s store path is unchanged.
  revalidate = ''
    add_header Cache-Control "no-cache" always;
  '';

  default-headers = hsts + csp + referrer-policy + x-frame-options + x-content-type-options;

  default-headers-without-csp = hsts + referrer-policy + x-frame-options + x-content-type-options;
}
