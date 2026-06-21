{ pkgs ? import <nixpkgs> {} }:

let
  perlPackages = pkgs.perlPackages;

  htmlTagFilter = perlPackages.buildPerlPackage {
    pname = "HTML-TagFilter";
    version = "1.03";

    src = pkgs.fetchurl {
      url = "https://cpan.metacpan.org/authors/id/W/WR/WROSS/HTML-TagFilter-1.03.tar.gz";
      sha256 = "1x9p0n2jygf5zy1y07br2xrf6janjnc33zry697nplb4z6sjiwns";
    };

    propagatedBuildInputs = with perlPackages; [
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
in
pkgs.mkShell {
  packages = [
    civsPerl
    pkgs.apacheHttpd
    pkgs.coreutils
    pkgs.curl
    pkgs.gcc
    pkgs.gnumake
    pkgs.openssl
  ];

  shellHook = ''
    export CIVS_LOCAL_ROOT="''${CIVS_LOCAL_ROOT:-$PWD/.civs-local}"
    if [[ $- == *i* ]]; then
      echo "CIVS local root: $CIVS_LOCAL_ROOT"
      echo "Run: scripts/civs-local-install"
      echo "Then: scripts/civs-local-httpd"
    fi
  '';
}
