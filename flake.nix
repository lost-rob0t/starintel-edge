{
  description = "StarIntel Edge reproducible host-contract build and development environment";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/c93b0882c7def157c311ca297d30f18bc4e23e49";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        rec {
          edge-host-contract = import ./platforms/rpi/default.nix { inherit pkgs; };
          default = edge-host-contract;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          host-contract-package = self.packages.${system}.edge-host-contract;

          host-contract-tests = pkgs.runCommand "starintel-edge-host-contract-tests" {
            src = ./.;
            nativeBuildInputs = [
              pkgs.jdk
              pkgs.kotlin
              pkgs.python3
              pkgs.sbcl
            ];
          } ''
            cp -R "$src" source
            chmod -R u+w source
            cd source
            ./tools/check-host-contracts
            mkdir -p "$out"
            printf '%s\n' "StarIntel Edge host-contract checks passed" > "$out/result"
          '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.jdk
              pkgs.kotlin
              pkgs.nixfmt-rfc-style
              pkgs.python3
              pkgs.sbcl
            ];
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-rfc-style);
    };
}
