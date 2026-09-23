# The downstream supplies its pinned nixpkgs. This packages the host contract
# library, not an SD image or a production daemon. No secret-bearing config input.
{ pkgs }:
pkgs.stdenvNoCC.mkDerivation {
  pname = "starintel-edge-host-contract";
  version = "0.1.0";
  src = ../..;
  nativeBuildInputs = [ pkgs.sbcl pkgs.python3 ];
  dontBuild = true;
  doCheck = true;
  checkPhase = ''
    python3 tools/check_contracts.py
    sbcl --script tests/runtime.lisp
  '';
  installPhase = ''
    mkdir -p "$out/share/starintel-edge"
    cp -r runtime contracts docs "$out/share/starintel-edge/"
  '';
  meta.description = "StarIntel Edge canonical host contract library (not a device image)";
}
