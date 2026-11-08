{
  # Request headers for backends that take the first X-Forwarded-For entry as
  # the client address. Apollo is the outermost proxy, so the connection's
  # address replaces whatever the client sent instead of being appended to it.
  # Use with `recommendedProxySettings = false`.
  clientAddressHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Host $host;
  '';
}
