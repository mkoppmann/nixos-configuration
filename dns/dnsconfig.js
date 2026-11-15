var REG_INWX = NewRegistrar("inwx");
var DSP_INWX = NewDnsProvider("inwx");

// Apollo’s addresses and web hosts. A flake check compares the file with the
// Nginx virtual hosts.
var apollo = require("./hosts.json");

// Hosts that have address records instead of an alias of their zone.
var noAlias = ["matrix.ncrypt.at"];

// Only Apollo’s ACME account may get certificates, and only by answering
// over HTTP.
function letsencrypt(ttl) {
  return CAA(
    "@",
    "issue",
    "letsencrypt.org; accounturi=https://acme-v02.api.letsencrypt.org/acme/acct/1884672326; validationmethods=http-01",
    CAA_CRITICAL,
    TTL(ttl)
  );
}

// The MX hosts of the domains with mail at mailbox.org. Their MTA-STS
// policies, which Apollo serves, read the same file.
function mailboxOrg() {
  return require("./mailbox-org.json").map(function (host) {
    return MX("@", 10, host + ".", TTL(10800));
  });
}

function webHosts(zone) {
  var records = [A("@", apollo.ipv4), AAAA("@", apollo.ipv6)];
  apollo.hosts.forEach(function (host) {
    if (host.slice(-zone.length - 1) !== "." + zone) {
      return;
    }
    var label = host.slice(0, -zone.length - 1);
    if (noAlias.indexOf(host) === -1) {
      records.push(CNAME(label, zone + "."));
    } else {
      records.push(A(label, apollo.ipv4), AAAA(label, apollo.ipv6));
    }
  });
  return records;
}

D(
  "ncrypt.at",
  REG_INWX,
  DnsProvider(DSP_INWX),
  NAMESERVER_TTL(86400),
  AUTODNSSEC_ON,
  webHosts("ncrypt.at"),
  letsencrypt(1800),
  MX("@", 10, "smtp-in0.prod0.webspace.bz.", TTL(3600)),
  MX("@", 20, "smtp-in1.prod0.webspace.bz.", TTL(3600)),
  TXT("@", "v=spf1 redirect=_spf.web-server.biz", TTL(10800)),
  TXT("prod0.webspacebz._domainkey", "v=DKIM1;k=rsa;p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA3vRezTQz50A0afbcwxW0j+NnEIYi2lLAuZh9hFEbRfPnOyONqc9qh7qW9E/F2mTAeTwnil0mfGTGcZMnSWjCg7ljo6AXpHXWv/BqACxKmIe0fuYuP3uS3Q3CmLV0xAFvBlOxXhbIIG0nxkaYMSTSo9MuH94O75zLC6dWFRoHegJVcKEA1GwG6zJKkKzNjGxwllLU7bh/nI6hMHkiksMFCz3GaNbmZk6KVfbyupkajtpPcsWMRDLxmzsAR6S2qAJJKz6x5f5rDvLX4jcNsBdKCsm/N9Wdq7nMtJZ+8I1/+8P2fcljzffg6Z5Tr4abgWlDjWh7cUzZxqFZyDYofUEDSwIDAQAB", TTL(3600)),
  TXT("_dmarc", "v=DMARC1; p=quarantine;", TTL(3600)),
);

D(
  "mkoppmann.at",
  REG_INWX,
  DnsProvider(DSP_INWX),
  NAMESERVER_TTL(86400),
  AUTODNSSEC_ON,
  DefaultTTL(3600),
  webHosts("mkoppmann.at"),
  letsencrypt(10800),
  CNAME("autoconfig", "mailbox.org."),
  mailboxOrg(),
  SRV("_autodiscover._tcp", 0, 0, 443, "mailbox.org."),
  TXT("mbo0001._domainkey", "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2K4PavXoNY8eGK2u61LIQlOHS8f5sWsCK5b+HMOfo0M+aNHwfqlVdzi/IwmYnuDKuXYuCllrgnxZ4fG4yVaux58v\" \"9grVsFHdzdjPlAQfp5rkiETYpCMZwgsmdseJ4CoZaosPHLjPumFE/Ua2WAQQljnunsM9TONM9L6KxrO9t5IISD1XtJb0bq1lVI/e72k3mnPd/q77qzhTDmwN4TSNJZN8sxzUJx9HNSMRRoEIHSDLTI\" \"JUK+Up8IeCx0B7CiOzG5w/cHyZ3AM5V8lkqBaTDK46AwTkTVGJf59QxUZArG3FEH5vy9HzDmy0tGG+053/x4RqkhqMg5/ClDm+lpZqWwIDAQAB"),
  TXT("mbo0002._domainkey", "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqxEKIg2c48ecfmy/+rj35sBOhdfIYGNDCMeHy0b36DX6MNtS7zA/VDR2q5ubtHzraL5uUGas8kb/33wtrWFYxier\" \"LRXy12qj8ItdYCRugu9tXTByEED05WdBtRzJmrb8YBMfeK0E0K3wwoWfhIk/wzKbjMkbqYBOTYLlIcVGQWzOfN7/n3n+VChfu6sGFK3k2qrJNnw22iFy4C8Ks7j77+tCpm0PoUwA2hOdLrRw3ldx2E\" \"9PH0GVwIMJRgekY6cS7DrbHrj/AeGlwfwwCSi9T23mYvc79nVrh2+82ZqmkpZSTD2qq+ukOkyjdRuUPck6e2b+x141Nzd81dIZVfOEiwIDAQAB"),
  TXT("@", "keybase-site-verification=3mAPitVK7OAQtxqhmhy-A557ptSSm02XSc3ZTVNUbiE", TTL(10800)),
  TXT("@", "v=spf1 include:mailbox.org ~all", TTL(10800)),
  TXT("_dmarc", "v=DMARC1; p=quarantine; rua=mailto:admin@mkoppmann.at"),
  TXT("_mta-sts", "v=STSv1; id=20261115T000000Z;"),
  TXT("_smtp._tls", "v=TLSRPTv1; rua=mailto:admin@mkoppmann.at"),
);

D(
  "cypherpunk.observer",
  REG_INWX,
  DnsProvider(DSP_INWX),
  NAMESERVER_TTL(86400),
  AUTODNSSEC_ON,
  DefaultTTL(3600),
  webHosts("cypherpunk.observer"),
  letsencrypt(10800),
  CNAME("autoconfig", "mailbox.org."),
  mailboxOrg(),
  SRV("_autodiscover._tcp", 0, 0, 443, "mailbox.org."),
  TXT("@", "v=spf1 include:mailbox.org ~all", TTL(10800)),
  TXT("mbo0001._domainkey", "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEA2K4PavXoNY8eGK2u61LIQlOHS8f5sWsCK5b+HMOfo0M+aNHwfqlVdzi/IwmYnuDKuXYuCllrgnxZ4fG4yVaux58v\" \"9grVsFHdzdjPlAQfp5rkiETYpCMZwgsmdseJ4CoZaosPHLjPumFE/Ua2WAQQljnunsM9TONM9L6KxrO9t5IISD1XtJb0bq1lVI/e72k3mnPd/q77qzhTDmwN4TSNJZN8sxzUJx9HNSMRRoEIHSDLTI\" \"JUK+Up8IeCx0B7CiOzG5w/cHyZ3AM5V8lkqBaTDK46AwTkTVGJf59QxUZArG3FEH5vy9HzDmy0tGG+053/x4RqkhqMg5/ClDm+lpZqWwIDAQAB"),
  TXT("mbo0002._domainkey", "v=DKIM1; k=rsa; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAqxEKIg2c48ecfmy/+rj35sBOhdfIYGNDCMeHy0b36DX6MNtS7zA/VDR2q5ubtHzraL5uUGas8kb/33wtrWFYxier\" \"LRXy12qj8ItdYCRugu9tXTByEED05WdBtRzJmrb8YBMfeK0E0K3wwoWfhIk/wzKbjMkbqYBOTYLlIcVGQWzOfN7/n3n+VChfu6sGFK3k2qrJNnw22iFy4C8Ks7j77+tCpm0PoUwA2hOdLrRw3ldx2E\" \"9PH0GVwIMJRgekY6cS7DrbHrj/AeGlwfwwCSi9T23mYvc79nVrh2+82ZqmkpZSTD2qq+ukOkyjdRuUPck6e2b+x141Nzd81dIZVfOEiwIDAQAB"),
  TXT("_dmarc", "v=DMARC1; p=quarantine; rua=mailto:mcp@cypherpunk.observer"),
  TXT("_mta-sts", "v=STSv1; id=20261115T000000Z;"),
  TXT("_smtp._tls", "v=TLSRPTv1; rua=mailto:mcp@cypherpunk.observer"),
);
