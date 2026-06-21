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

With the server running, this CLI smoke test creates a public poll, starts it,
casts one ballot, closes it, and fetches results:

```sh
scripts/civs-local-smoke
```
