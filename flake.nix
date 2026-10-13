{
  description = "Odin + Vulkan dev shell";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      forAllSystems =
        f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (s: f nixpkgs.legacyPackages.${s});
    in
    {
      devShells = forAllSystems (
        pkgs:
        let
          runtimeLibs = with pkgs; [
            vulkan-loader
            glfw

            wayland
            libxkbcommon
            libx11
            libxcursor
            libxrandr
            libxi
            libxinerama
            libxext
          ];

          vulkanSdk = pkgs.symlinkJoin {
            name = "vulkan-sdk";
            paths = with pkgs; [
              vulkan-headers
              vulkan-loader
              vulkan-validation-layers
              vulkan-tools
              vulkan-tools-lunarg
              shader-slang
              shaderc
              spirv-tools
            ];
          };
        in
        {
          default = pkgs.mkShell {
            packages = with pkgs; [
              odin
              ols
              lldb

              shader-slang
              shaderc
              spirv-tools

              vulkan-headers
              vulkan-validation-layers
              vulkan-tools
              vulkan-tools-lunarg
              renderdoc
            ];

            buildInputs = runtimeLibs;

            LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            VULKAN_SDK = vulkanSdk;
            VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          };
        }
      );
    };
}
