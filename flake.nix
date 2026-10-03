{
  description = "StarIntel Edge reproducible host-contract development and validation";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
          edgeHostContract = import ./platforms/rpi/default.nix { inherit pkgs; };
        in {
          default = edgeHostContract;
          "edge-host-contract" = edgeHostContract;
        });

      checks = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          host-contract = self.packages.${system}.default;

          jvm-facades = pkgs.runCommand "starintel-edge-jvm-facade-check" {
            nativeBuildInputs = [ pkgs.jdk21_headless pkgs.kotlin ];
          } ''
            cp -R ${self.outPath} source
            chmod -R u+w source
            cd source
            mkdir -p build
            kotlinc platforms/android/EdgeHost.kt platforms/watch/WatchHost.kt platforms/glasses/GlassesHosts.kt tests/HostContractTest.kt -include-runtime -d build/host-tests.jar
            java -jar build/host-tests.jar
            mkdir -p "$out"
            echo ok > "$out/result"
          '';
        });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in {
          default = pkgs.mkShell {
            packages = [ pkgs.jdk21_headless pkgs.kotlin pkgs.python3 pkgs.sbcl ];
          };
        });
    };
}
