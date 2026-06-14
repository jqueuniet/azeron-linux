{ buildNpmPackage
, fetchNpmDeps
, fetchurl
, fetchzip
, autoPatchelfHook
, makeWrapper
, lib
, # Electron runtime libraries (DT_NEEDED of the electron binary + bundled .so's):
  glib
, nss
, nspr
, dbus
, atk
, at-spi2-atk
, at-spi2-core
, cups
, libdrm
, gtk3
, pango
, cairo
, expat
, libxkbcommon
, alsa-lib
, mesa
, libGL
, xorg
, # node-hid / usb backends:
  udev
, libusb1
}:
let
  electronVersion = "30.0.9";

  # Faithful assembly: fetch the exact Electron runtime upstream pins and tests
  # against (electron_30 is no longer packaged in nixpkgs). Same artifact the
  # PKGBUILD downloads. stripRoot=false keeps the flat zip layout (the `electron`
  # binary and bundled libs live at the archive root).
  electron = fetchzip {
    url = "https://github.com/electron/electron/releases/download/v${electronVersion}/electron-v${electronVersion}-linux-x64.zip";
    hash = "sha256-m4Lm97qgHG8REloaT1ZoUluaOzodH+zanJoitW2PUGo=";
    stripRoot = false;
  };

  # node-hid 2.2.0 ships its native addon only as N-API (napi-v3) prebuilds —
  # the exact binary `prebuild-install --runtime napi` fetches during a normal
  # install. N-API is ABI-stable across Node/Electron majors, so this works on
  # the Electron 30 runtime without an Electron-specific rebuild (the same way
  # usb and @serialport/bindings-cpp rely on their bundled N-API prebuilds).
  # Matches node-hid @ 2.2.0 pinned in app/package-lock.json — bump URL + hash together.
  nodeHidPrebuilt = fetchurl {
    url = "https://github.com/node-hid/node-hid/releases/download/v2.2.0/node-hid-v2.2.0-napi-v3-linux-x64.tar.gz";
    hash = "sha256-6IYIxlGFXnY39trHKs2fQLoiGu9qO0OYcfTQuGWmFB0=";
  };
in
buildNpmPackage {
  pname = "azeron-software";
  version = "1.5.6";
  src = ../.;

  # The app's runtime deps live in app/ with their own lockfile.
  npmRoot = "app";
  npmDeps = fetchNpmDeps {
    src = ../app;
    hash = "sha256-LLz3ihPDSdYBmVJnfVKhS03S5kWvU9W8NL35Uc0vz0Q=";
  };

  # Don't run the app's build (the dist is pre-built and committed).
  dontNpmBuild = true;

  # Native addon scripts handled explicitly below; skip lifecycle scripts now.
  npmFlags = [ "--ignore-scripts" ];

  nativeBuildInputs = [ autoPatchelfHook makeWrapper ];

  # usb and @serialport/bindings-cpp ship musl-libc prebuilds alongside the glibc
  # ones; node-gyp-build selects the glibc build at runtime, so the unused musl
  # variants' missing libc need not be satisfied.
  autoPatchelfIgnoreMissingDeps = [ "libc.musl-x86_64.so.1" ];

  # Runtime libraries for autoPatchelfHook to bind into the prebuilt Electron
  # binary, its bundled shared objects, and the native .node addons.
  buildInputs = [
    glib
    nss
    nspr
    dbus
    atk
    at-spi2-atk
    at-spi2-core
    cups
    libdrm
    gtk3
    pango
    cairo
    expat
    libxkbcommon
    alsa-lib
    mesa
    libGL
    # X libraries via the canonical `xorg` set: these names resolve on both
    # stable and unstable nixpkgs. The flat aliases (libx11, libxcb, …) only
    # exist on recent nixpkgs, so they would break a consumer that points this
    # package's nixpkgs at a stable channel (the sif flake does, via follows).
    # The deprecation warning on unstable is benign.
    xorg.libX11
    xorg.libXcomposite
    xorg.libXdamage
    xorg.libXext
    xorg.libXfixes
    xorg.libXrandr
    xorg.libxcb
    udev
    libusb1
  ];

  installPhase = ''
    runHook preInstall

    # Apply the 22 Linux-compatibility patches to the committed main bundle,
    # in place in the source tree (cwd is still the unpacked source here, before
    # anything is written to $out). The script exits non-zero if any search
    # string no longer matches, failing the build loudly — an early warning that
    # an upstream bundle change needs re-review on a version bump.
    node scripts/patch-main.js

    mkdir -p "$out/libexec/azeron"

    # Electron runtime: copy then make writable so autoPatchelfHook can patch it.
    cp -r "${electron}" "$out/libexec/azeron/electron"
    chmod -R u+w "$out/libexec/azeron/electron"

    # The app, with node_modules populated by buildNpmPackage.
    cp -r app "$out/libexec/azeron/app"

    # Place node-hid's N-API prebuilt binaries (skipped above by --ignore-scripts).
    # Both backends: HID_hidraw.node (the Linux default) and HID.node (libusb).
    mkdir -p "$TMPDIR/node-hid-prebuilt"
    tar -xzf "${nodeHidPrebuilt}" -C "$TMPDIR/node-hid-prebuilt"
    install -Dm755 "$TMPDIR/node-hid-prebuilt/build/Release/HID.node" \
      "$out/libexec/azeron/app/node_modules/node-hid/build/Release/HID.node"
    install -Dm755 "$TMPDIR/node-hid-prebuilt/build/Release/HID_hidraw.node" \
      "$out/libexec/azeron/app/node_modules/node-hid/build/Release/HID_hidraw.node"

    # Launch wrapper. The fix-wayland-scaling patch forces x11, so run under
    # XWayland; --no-sandbox because the SUID chrome-sandbox helper is not set up.
    makeWrapper "$out/libexec/azeron/electron/electron" "$out/bin/azeron-software" \
      --add-flags "$out/libexec/azeron/app" \
      --add-flags "--ozone-platform=x11" \
      --add-flags "--no-sandbox"

    install -Dm644 assets/99-azeron.rules \
      "$out/lib/udev/rules.d/99-azeron.rules"
    install -Dm644 build/icon.png \
      "$out/share/icons/hicolor/512x512/apps/azeron-software.png"

    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/azeron-software.desktop" <<'EOF'
    [Desktop Entry]
    Name=Azeron Software
    Comment=Configuration tool for Azeron keypads
    Exec=azeron-software %U
    Icon=azeron-software
    Terminal=false
    Type=Application
    Categories=Utility;HardwareSettings;
    EOF

    runHook postInstall
  '';

  meta = {
    description = "Configuration tool for Azeron keypads (unofficial Linux repackage)";
    homepage = "https://github.com/renatoi/azeron-linux";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.unfree;
    # Ships prebuilt binaries: the Electron release zip and node-hid's N-API addon.
    sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
    mainProgram = "azeron-software";
  };
}
