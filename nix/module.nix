self: { config, lib, pkgs, ... }:
let
  cfg = config.programs.azeron-software;
  # The package is x86_64-linux-only (see meta.platforms / flake eachSystem), so
  # this lookup intentionally errors if the module is used on another host.
  pkg = self.packages.${pkgs.stdenv.hostPlatform.system}.azeron-software;
in
{
  options.programs.azeron-software = {
    enable = lib.mkEnableOption "Azeron keypad configuration software";
    enableXpad = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Load the xpad kernel module for XInput gamepad support and USB endpoint drain.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkg pkgs.dfu-util ];
    services.udev.packages = [ pkg ]; # installs 99-azeron.rules for /dev/hidraw* + DFU access
    boot.kernelModules = lib.optionals cfg.enableXpad [ "xpad" ];
  };
}
