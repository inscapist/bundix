# © 2023 Felix <zen9.felix@gmail.com>

{
  description =
    "Generates a Nix expression for your Bundler-managed application";

  outputs = { self, nixpkgs, ... }:
  let
    eachDefaultSystem = with nixpkgs.lib; let
      nestInto = name: val: { ${name} = val; };
      specialize = block: sys: mapAttrs (_: nestInto sys) (block sys);
      mergeSets = foldl recursiveUpdate {};
      forEachSystem = forEach systems.flakeExposed;
    in
      perSystemBlock: mergeSets (forEachSystem (specialize perSystemBlock));

  in
    eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      rubyCurrent = pkgs.ruby_3_3;

      ruby = rubyCurrent.withPackages (ps: with ps; [
        minitest rake solargraph rubocop pry
      ]);

      bundler = pkgs.bundler.override { ruby = rubyCurrent; };

      bundix = pkgs.callPackage ./default.nix {
        ruby = rubyCurrent;
        inherit pkgs bundler;
        inherit (pkgs) nix nix-prefetch-git;
      };
    in {
      packages.default = bundix;

      apps.default = {
        type = "app";
        program = nixpkgs.lib.getExe bundix;
      };

      devShells.default = pkgs.mkShell {
        buildInputs = [ ruby bundler bundix pkgs.rufo ];
      };
    });
}
