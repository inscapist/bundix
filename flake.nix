# © 2023 Felix <zen9.felix@gmail.com>

{
  description =
    "Generates a Nix expression for your Bundler-managed application";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    fu.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, fu, ... }:
    with fu.lib;
    eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        ruby = pkgs.ruby_2_7.withPackages
          (ps: with ps; [ minitest rake solargraph rubocop ]);
        bundler = (pkgs.bundler.override { ruby = pkgs.ruby_3_1; });
        bundix = with pkgs;
          import ./default.nix {
            inherit pkgs ruby bundler nix nix-prefetch-git;
          };
      in {
        packages.default = bundix;

        apps.default = {
          type = "app";
          program = "${bundix}/bin/bundix";
        };

        devShells = rec {
          default = dev;
          dev = pkgs.mkShell {
            buildInputs = [ ruby bundler bundix ] ++ (with pkgs; [ rufo ]);
          };
        };
      });
}
