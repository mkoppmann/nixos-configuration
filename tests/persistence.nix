# Evaluation only. Include untracked working-tree files without updating locks.
let
  flake = builtins.getFlake ("path:" + toString ../.);
  lib = flake.inputs.nixpkgs.lib;
  config = flake.nixosConfigurations.apollo.config;
  persistence = config.environment.persistence."/persist";
  directories = lib.listToAttrs (
    map (entry: lib.nameValuePair entry.dirPath entry) persistence.directories
  );
  files = lib.listToAttrs (
    map (entry: lib.nameValuePair entry.filePath entry) persistence.files
  );
  mountFor = path: lib.findFirst (mount: mount.where == path) null config.systemd.mounts;
  hasMount =
    path:
    let
      mount = mountFor path;
    in
    mount != null && mount.what == "/persist${path}" && lib.hasInfix "bind" mount.options;
  ownerMatches =
    path: user: group: mode:
    let
      entry = directories.${path};
      effectiveGroup = if entry.group == null then config.users.users.${entry.user}.group else entry.group;
    in
    entry.user == user && effectiveGroup == group && entry.mode == mode;
  seedServiceName = "persist-persist-var-lib-systemd-random\\x2dseed";
  seedUnit = "${seedServiceName}.service";
  seedPersistence = config.systemd.services.${seedServiceName};
  seed = config.systemd.services.systemd-random-seed;
  borg = config.services.borgbackup.jobs.sidechest;
  privatePermissions = config.system.activationScripts.apollo-private-state-permissions;
  newDirectories = [
    "/root/.config/borg"
    "/root/.cache/borg"
    "/var/lib/logrotate"
    "/var/lib/rabbitmq"
    "/var/lib/systemd/timers"
    "/var/lib/systemd/timesync"
  ];
  previousDirectories = [
    "/etc/nixos"
    "/root/.ssh"
    "/srv/www"
    "/var/backup"
    "/var/lib/acme"
    "/var/lib/bitwarden_rs"
    "/var/lib/matrix-synapse"
    "/var/lib/nextcloud"
    "/var/lib/nixos"
    "/var/lib/onlyoffice"
    "/var/lib/pleroma"
    "/var/lib/postgresql"
    "/var/lib/private/actual"
    "/var/lib/private/authentik"
    "/var/lib/private/matrix-authentication-service"
    "/var/lib/wireguard"
  ];
  timerSettings = lib.mapAttrs (_: timer: timer.timerConfig) (
    lib.filterAttrs (_: timer: timer.enable) config.systemd.timers
  );
  # Report declared service directories to cross-check against docs/storage.md.
  # Upstream systemd unit files and application-specific paths also need review.
  stateOptions = [ "StateDirectory" "CacheDirectory" "LogsDirectory" "RuntimeDirectory" ];
  serviceDirectories = lib.mapAttrs (_: service: {
    user = service.serviceConfig.User or null;
    dynamicUser = service.serviceConfig.DynamicUser or false;
    directories = lib.filterAttrs (name: _: builtins.elem name stateOptions) service.serviceConfig;
  }) (lib.filterAttrs (
    _: service: service.enable && lib.any (name: builtins.hasAttr name service.serviceConfig) stateOptions
  ) config.systemd.services);
in
assert builtins.seq config.system.build.toplevel.drvPath true;
assert persistence.enable && config.fileSystems."/persist".neededForBoot;
assert lib.all (path: builtins.hasAttr path directories && hasMount path) (
  newDirectories ++ previousDirectories
);
assert lib.all (path: ownerMatches path "root" "root" "0700") [
  "/root/.config/borg"
  "/root/.cache/borg"
  "/var/lib/logrotate"
];
assert ownerMatches "/var/lib/rabbitmq" "rabbitmq" "rabbitmq" "0700";
assert ownerMatches "/var/lib/systemd/timers" "root" "root" "0755";
assert ownerMatches "/var/lib/systemd/timesync" "systemd-timesync" "systemd-timesync" "0755";
assert config.services.rabbitmq.dataDir == "/var/lib/rabbitmq";
assert config.services.timesyncd.enable;
assert files."/var/lib/systemd/random-seed".method == "auto";
assert seedPersistence.enable && seedPersistence.serviceConfig.RemainAfterExit;
assert seedPersistence.unitConfig.RequiresMountsFor == [ "/persist/var/lib/systemd" ];
assert builtins.elem seedUnit seed.requires && builtins.elem seedUnit seed.after;
assert !seed.restartIfChanged;
assert builtins.elem "createPersistentStorageDirs" privatePermissions.deps;
assert lib.hasInfix "-o root -g root -m 0700" privatePermissions.text;
assert lib.hasInfix "/persist/var/lib/private /var/lib/private" privatePermissions.text;
assert lib.all (name: config.systemd.services.${name}.serviceConfig.DynamicUser) [
  "actual"
  "authentik"
  "matrix-authentication-service"
];
assert lib.all (path: !(builtins.hasAttr path directories)) [
  "/var/lib/private"
  "/var/lib/actual"
  "/var/lib/authentik"
  "/var/lib/matrix-authentication-service"
  "/var/lib/redis-nextcloud"
  "/var/cache/nginx"
  "/var/lib/systemd"
];
assert config.services.logrotate.enable;
assert config.services.logrotate.extraArgs == [ "--state" "/var/lib/logrotate/status" ];
assert !(builtins.hasAttr "/var/lib/logrotate/status" files);
assert lib.hasInfix "/var/lib/logrotate/status" config.systemd.services.logrotate.serviceConfig.ExecStart;
assert borg.paths == [ "/persist" "/var/log" ];
assert borg.exclude == [
  "/persist/var/lib/postgresql"
  "/persist/root/.cache/borg"
  "/persist/var/lib/systemd/random-seed"
  "/var/log/audit/audit.log"
  "/var/log/journal/e538f1c97e5f472581a47d4a0acd816c/system.journal"
  "/var/log/nginx/access.log"
];
assert borg.user == "root" && config.users.users.root.home == "/root";
assert lib.all (name: !(builtins.hasAttr name borg.environment)) [
  "BORG_BASE_DIR"
  "BORG_CONFIG_DIR"
  "BORG_CACHE_DIR"
  "BORG_SECURITY_DIR"
  "BORG_KEYS_DIR"
  "XDG_CONFIG_HOME"
  "XDG_CACHE_HOME"
  "HOME"
];
assert borg.repo == "ssh://u237324-sub2@u237324-sub2.your-storagebox.de:23/home/borg";
assert borg.encryption.mode == "repokey-blake2";
assert borg.prune.keep == {
  daily = 7;
  weekly = 4;
  monthly = 6;
};
assert !borg.persistentTimer;
assert timerSettings.borgbackup-job-sidechest.Persistent == false;
assert lib.toList timerSettings.borgbackup-job-sidechest.OnCalendar == [ "daily" ];
assert lib.toList config.services.postgresqlBackup.startAt == [ "*-*-* 23:05:00" ];
assert timerSettings.nix-gc.Persistent && timerSettings.nix-optimise.Persistent;
assert lib.toList timerSettings.logrotate.OnCalendar == [ "hourly" ];
assert config.system.stateVersion == "23.11";
assert config.home-manager.users.mcp.home.stateVersion == "23.11";
assert lib.any (file: file.file == ".local/share/fish/fish_history") persistence.users.mcp.files;
{
  coverage = "passed";
  inherit newDirectories serviceDirectories timerSettings;
  seedPersistenceUnit = seedUnit;
  archiveExclusions = borg.exclude;
  systemdVersion = config.systemd.package.version;
}
