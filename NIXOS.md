# CIVS on NixOS

This fork can run CIVS either as a repo-local development instance or as a
NixOS-managed production service behind an HTTPS reverse proxy.

The production setup used by this fork has these properties:

- Apache serves CIVS as classic CGI from a state directory such as
  `/var/lib/civs`.
- Apache uses `mpm_prefork` with `mod_cgi`. CIVS is a classic CGI application;
  using a threaded Apache MPM can make Perl TLS calls hang in CGI children.
- CIVS does not send production mail through Perl `Net::SMTP`. Instead it can
  hand completed messages to a sendmail-compatible wrapper via `CIVS_SENDMAIL`.
  On NixOS, use an `msmtp` wrapper for this.
- Secrets are read from files, so they can be provided by `sops-nix`.
- Public URLs can be generated for an HTTPS domain while the backend listens on
  an internal HTTP port such as `18080`.

## Local Development

Fetch submodules, enter the Nix shell, install CIVS into `.civs-local`, and
start Apache:

```sh
git submodule update --init
nix-shell
scripts/civs-local-install
scripts/civs-local-httpd
```

Open:

```text
http://localhost:18080/civs/
```

The default local install uses `LOCALDEBUG=1`. In that mode, CIVS prints mail
and control links in the browser instead of requiring a real SMTP server.

Use another port by passing the same `CIVS_PORT` to both helpers:

```sh
CIVS_PORT=19090 scripts/civs-local-install
CIVS_PORT=19090 scripts/civs-local-httpd
```

Expose the dev backend to another machine by setting the public host and bind
address:

```sh
CIVS_HOST=192.0.2.10 CIVS_LISTEN_ADDR=0.0.0.0 scripts/civs-local-install
CIVS_HOST=192.0.2.10 CIVS_LISTEN_ADDR=0.0.0.0 scripts/civs-local-httpd
```

Run the local smoke test while the server is running:

```sh
scripts/civs-local-smoke
```

## Production Shape

Use an HTTPS reverse proxy in front of CIVS:

```text
internet -> https://vote.example.org/ -> reverse proxy -> http://VM-IP:18080/
```

The CIVS backend should listen only on the VM or internal network. If the
reverse proxy is on another host, restrict firewall access to port `18080` to
that proxy address.

For a public HTTPS hostname on the default HTTPS port, generate CIVS links like
this:

```sh
CIVS_HOST=vote.example.org \
CIVS_PROTO=https \
CIVS_PUBLIC_PORT= \
CIVS_LISTEN_ADDR=0.0.0.0 \
scripts/civs-local-install
```

`CIVS_PUBLIC_PORT=` intentionally means “do not append `:18080` to public
links”.

## Reverse Proxy

The proxy should forward to the backend and overwrite forwarding headers:

```nginx
location / {
  proxy_pass http://VM-IP:18080;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto https;
}
```

Do not pass untrusted client-supplied `X-Real-IP` or `X-Forwarded-For` headers
through unchanged. CIVS uses these headers when deciding voter IP identity.

## SOPS Secrets

A production deployment needs these secrets:

```yaml
civs:
  admin-key: "random hex string"
  email-salt: "random hex string"
  private-host-id: "random hex string"
  supervisor: "noreply@example.org"
  auth-sender: "noreply@example.org"
  smtp-auth-user: "smtp username"
  smtp-auth-passwd: "smtp password"
```

On the VM, derive the age recipient from the host SSH key:

```sh
nix shell nixpkgs#ssh-to-age -c \
  ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub
```

Create `.sops.yaml` in your NixOS config repository:

```yaml
keys:
  - &base_vm age1...
creation_rules:
  - path_regex: secrets/base-vm\.yaml$
    key_groups:
      - age:
          - *base_vm
```

Create or edit the encrypted secret file:

```sh
cd /path/to/nixos-config
nix shell nixpkgs#sops nixpkgs#ssh-to-age -c sh -c '
  SOPS_BIN=$(command -v sops)
  SSH_TO_AGE_BIN=$(command -v ssh-to-age)

  sudo env \
    EDITOR="${EDITOR:-nano}" \
    SOPS_AGE_KEY_CMD="$SSH_TO_AGE_BIN -private-key -i /etc/ssh/ssh_host_ed25519_key" \
    "$SOPS_BIN" secrets/base-vm.yaml
'
```

Generate random values with, for example:

```sh
openssl rand -hex 32
```

## NixOS Module

Create a module such as `hosts/base-vm/civs.nix` in your NixOS config and
import it from the host configuration.

Adjust these values:

- `civsDomain`
- `civsReverseProxyAddress`
- `civsSource`
- SMTP host, port, sender, and credentials
- secret file path if your SOPS layout differs

Example module:

```nix
{ config, pkgs, ... }:

let
  civsDomain = "vote.example.org";
  civsPort = 18080;
  civsReverseProxyAddress = "192.0.2.5";
  civsSource = "/srv/civs";
  civsStateDir = "/var/lib/civs";

  htmlTagFilter = pkgs.perlPackages.buildPerlPackage {
    pname = "HTML-TagFilter";
    version = "1.03";
    src = pkgs.fetchurl {
      url = "https://cpan.metacpan.org/authors/id/W/WR/WROSS/HTML-TagFilter-1.03.tar.gz";
      sha256 = "1x9p0n2jygf5zy1y07br2xrf6janjnc33zry697nplb4z6sjiwns";
    };
    propagatedBuildInputs = with pkgs.perlPackages; [
      HTMLParser
      HTMLTagset
    ];
  };

  civsPerl = pkgs.perl.withPackages (p: with p; [
    AuthenSASL
    CGI
    DBFile
    HTMLParser
    HTMLTagset
    IOSocketSSL
    JSON
    MIMEBase64
    NetSMTP
    NetSSLeay
    Switch
    TextCSV
    TextCSVEncoded
    URI
    htmlTagFilter
  ]);

  civsSecret = name: config.sops.secrets."civs/${name}".path;

  civsSendmail = pkgs.writeShellScript "civs-sendmail" ''
    set -euo pipefail

    exec ${pkgs.msmtp}/bin/msmtp \
      --host=smtp.example.org \
      --port=465 \
      --tls=on \
      --tls-starttls=off \
      --auth=on \
      --user="$(${pkgs.coreutils}/bin/cat ${civsSecret "smtp-auth-user"})" \
      --passwordeval="${pkgs.coreutils}/bin/cat ${civsSecret "smtp-auth-passwd"}" \
      "$@"
  '';

  civsStart = pkgs.writeShellScript "civs-start" ''
    set -euo pipefail

    cd ${civsSource}

    export CIVS_LOCAL_ROOT=${civsStateDir}
    export CIVS_PORT=${toString civsPort}
    export CIVS_HOST=${civsDomain}
    export CIVS_PROTO=https
    export CIVS_PUBLIC_PORT=
    export CIVS_LISTEN_ADDR=0.0.0.0
    export CIVS_HTTPD_FOREGROUND=1
    export CIVS_LOCALDEBUG=0

    export CIVS_SUPERVISOR_FILE=${civsSecret "supervisor"}
    export CIVS_AUTH_SENDER_FILE=${civsSecret "auth-sender"}
    export CIVS_ADMIN_KEY_FILE=${civsSecret "admin-key"}
    export CIVS_EMAIL_SALT_FILE=${civsSecret "email-salt"}
    export CIVS_PRIVATE_HOST_ID_FILE=${civsSecret "private-host-id"}

    export CIVS_SMTP_HOST=smtp.example.org
    export CIVS_SENDMAIL=${civsSendmail}
    export CIVS_SMTP_PORT=465
    export CIVS_SMTP_USE_SSL=1
    export CIVS_SMTP_STARTTLS=0

    export CIVS_WEB_USER=civs
    export CIVS_WEB_GROUP=civs

    scripts/civs-local-install
    exec scripts/civs-local-httpd
  '';
in
{
  users.groups.civs = {};
  users.users.civs = {
    isSystemUser = true;
    group = "civs";
    home = civsSource;
    createHome = true;
  };

  networking.firewall = {
    extraCommands = ''
      iptables -A nixos-fw -p tcp -s ${civsReverseProxyAddress} --dport ${toString civsPort} -j nixos-fw-accept
    '';
    extraStopCommands = ''
      iptables -D nixos-fw -p tcp -s ${civsReverseProxyAddress} --dport ${toString civsPort} -j nixos-fw-accept || true
    '';
  };

  sops.defaultSopsFile = ../../secrets/base-vm.yaml;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
  sops.secrets = {
    "civs/admin-key" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/email-salt" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/private-host-id" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/supervisor" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/auth-sender" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/smtp-auth-user" = { owner = "civs"; group = "civs"; mode = "0400"; };
    "civs/smtp-auth-passwd" = { owner = "civs"; group = "civs"; mode = "0400"; };
  };

  systemd.services.civs-httpd = {
    description = "CIVS Apache CGI backend";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    unitConfig.ConditionPathExists = "${civsSource}/scripts/civs-local-install";

    path = with pkgs; [
      apacheHttpd
      bash
      coreutils
      curl
      gcc
      gnumake
      gnugrep
      gnused
      msmtp
      openssl
      civsPerl
    ];

    serviceConfig = {
      Type = "simple";
      User = "civs";
      Group = "civs";
      WorkingDirectory = civsSource;
      StateDirectory = "civs";
      ExecStart = civsStart;
      Restart = "on-failure";
      RestartSec = "10s";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "full";
    };
  };

  environment.systemPackages = with pkgs; [
    age
    git
    sops
    ssh-to-age
  ];
}
```

If your host uses flakes, add `sops-nix` and import both modules:

```nix
inputs.sops-nix = {
  url = "github:Mic92/sops-nix";
  inputs.nixpkgs.follows = "nixpkgs";
};

# inside the host module list
inputs.sops-nix.nixosModules.sops
./hosts/base-vm/civs.nix
```

Then apply the host configuration:

```sh
cd /path/to/nixos-config
sudo nixos-rebuild switch --flake .#your-host
```

On the first switch, `civs-httpd` may be skipped because `/srv/civs` does not
exist yet. Clone this fork as the service user, then start the service:

```sh
sudo -u civs git clone https://github.com/YOUR-ORG/civs.git /srv/civs
cd /srv/civs
sudo -u civs git submodule update --init
sudo systemctl restart civs-httpd
```

If you deploy from a local checkout instead of GitHub, copy or clone it to
`/srv/civs` and make sure it is writable by the service user:

```sh
sudo chown -R civs:civs /srv/civs
```

## Verify Production

Check the service:

```sh
systemctl status civs-httpd --no-pager
ss -ltnp | grep 18080
```

Check generated settings without printing secret values:

```sh
grep -E '^(CIVSHOME|PROTO|THISHOST|LOCALDEBUG|SMTP_HOST|SMTP_PORT|SMTP_USE_SSL|SMTP_STARTTLS|SENDMAIL)=' \
  /var/lib/civs/civs-local.conf
ls -l /var/lib/civs/civs-local.conf
```

Expected:

- `CIVSHOME=https://vote.example.org/civs`
- `PROTO=https`
- `LOCALDEBUG=0`
- `SENDMAIL=/nix/store/...-civs-sendmail`
- `/var/lib/civs/civs-local.conf` is mode `0600`

Check local and public HTTP:

```sh
curl -I http://127.0.0.1:18080/civs/
curl -I https://vote.example.org/
```

Check activation mail with one deliberate request:

```sh
curl -sS -m 50 -i \
  -X POST \
  --data-urlencode address=test-user@example.org \
  http://127.0.0.1:18080/cgi-bin/civs/request_activation.pl
```

Expected response body:

```text
OK
```

Then verify that the activation-code email arrives and is not classified as
spam.

Finally, run the browser workflow through the public URL:

1. Open `https://vote.example.org/`.
2. Create a poll.
3. Start the poll.
4. Use the voter link to cast a ballot.
5. Close the poll.
6. View results.

## Operations

Useful logs:

```sh
journalctl -u civs-httpd -n 200 --no-pager
tail -n 100 /var/lib/civs/apache/logs/error.log
tail -n 100 /var/lib/civs/apache/logs/access.log
tail -n 100 /var/lib/civs/data/log
tail -n 100 /var/lib/civs/data/cgi-log
```

Restart:

```sh
sudo systemctl restart civs-httpd
```

Stop any manually started Apache before returning to systemd:

```sh
httpd -f /var/lib/civs/apache/httpd.conf -k stop
sudo systemctl restart civs-httpd
```

Back up at least:

```text
/var/lib/civs/data/
```

The private host ID and election data are part of CIVS' identity and poll
state. Losing them can invalidate links or make existing data unusable.

## Troubleshooting

### Browser Gets 504 During Activation

Check Apache and CIVS logs:

```sh
tail -n 100 /var/lib/civs/apache/logs/error.log
tail -n 100 /var/lib/civs/data/log
```

If the CGI times out during SMTP, use the `CIVS_SENDMAIL`/`msmtp` path instead
of direct `Net::SMTP`.

### Direct SMTP Works but CGI Mail Hangs

This is the failure mode this fork avoids. Keep:

- `mpm_prefork` in `scripts/civs-local-httpd`
- `CIVS_SENDMAIL` set to an `msmtp` wrapper

### Service Is Running but Public Site Fails

Check:

```sh
curl -I http://127.0.0.1:18080/civs/
ss -ltnp | grep 18080
```

If local works but public HTTPS fails, debug the reverse proxy, firewall, and
the source address allowed to reach port `18080`.

### Generated Links Contain `:18080`

For public HTTPS on the default port, rebuild with:

```sh
CIVS_PUBLIC_PORT=
```

An empty value means “omit the public port”.

### Secrets Do Not Decrypt

If the SOPS file was encrypted to the host SSH age recipient, edit it on the VM
with:

```sh
sudo env \
  SOPS_AGE_KEY_CMD="$(command -v ssh-to-age) -private-key -i /etc/ssh/ssh_host_ed25519_key" \
  sops secrets/base-vm.yaml
```

If that fails, confirm the `.sops.yaml` recipient matches:

```sh
ssh-to-age -i /etc/ssh/ssh_host_ed25519_key.pub
```
