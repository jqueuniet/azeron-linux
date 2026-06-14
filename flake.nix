{
  description = "Azeron keypad configuration software (unofficial Linux repackage)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachSystem [ "x86_64-linux" ] (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };
        azeron-software = pkgs.callPackage ./nix/package.nix { };
      in {
        packages.azeron-software = azeron-software;
        packages.default = azeron-software;
      })
    // {
      nixosModules.default = import ./nix/module.nix self;
    };
}
