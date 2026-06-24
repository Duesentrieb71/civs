# CIVS on NixOS

This repo can run as a local Apache/CGI app from `shell.nix`.

First fetch the declared JavaScript submodules if they are not already present:

```sh
git submodule update --init
```

Then enter the Nix shell, install CIVS into a repo-local tree, and start Apache:

```sh
nix-shell
scripts/civs-local-install
scripts/civs-local-httpd
```

Open <http://localhost:18080/civs/> to use the CIVS web UI.

The local install goes under `.civs-local/`, which is ignored by git. The helper
config uses `LOCALDEBUG=1`, so CIVS prints mail/control links into the web page
instead of requiring a real SMTP server.

To use a different port, run both helpers with the same `CIVS_PORT`:

```sh
CIVS_PORT=19090 scripts/civs-local-install
CIVS_PORT=19090 scripts/civs-local-httpd
```

To access the local instance from another machine, set the public host used in
CIVS links and the address Apache should bind to:

```sh
CIVS_HOST=192.168.188.106 CIVS_LISTEN_ADDR=0.0.0.0 scripts/civs-local-install
CIVS_HOST=192.168.188.106 CIVS_LISTEN_ADDR=0.0.0.0 scripts/civs-local-httpd
```

Use `CIVS_HTTPD_FOREGROUND=0` with `scripts/civs-local-httpd` to start Apache
as a background daemon instead of foregrounding it in the terminal.

When CIVS is behind an HTTPS reverse proxy on the default HTTPS port, keep the
backend on `18080` but omit the public URL port:

```sh
CIVS_HOST=wahl.ksat-stuttgart.de CIVS_PROTO=https CIVS_PUBLIC_PORT= \
  CIVS_LISTEN_ADDR=0.0.0.0 scripts/civs-local-install
```

The local Apache helper intentionally uses `mpm_prefork` with `mod_cgi`.
CIVS is a classic CGI application, and its Perl SMTP/TLS path can hang when a
CGI child is forked from Apache's threaded `mpm_event` worker.

For production mail delivery, prefer setting `CIVS_SENDMAIL` to a
sendmail-compatible wrapper such as `msmtp` instead of letting CIVS use
`Net::SMTP` directly. The direct Perl TLS path can time out in CGI, while an
external mailer keeps SMTP/TLS handling in a separate process managed by Nix.

With the server running, this CLI smoke test creates a public poll, starts it,
casts one ballot, closes it, and fetches results:

```sh
scripts/civs-local-smoke
```
