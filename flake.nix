{
  description = "jupynvim development shell — Rust backend, Python test deps, Neovim";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" "x86_64-darwin" "aarch64-linux" "x86_64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          # tests/backend_integration.py speaks msgpack RPC to the core binary and
          # drives real kernels; the matplotlib bridge tests need a plotting stack.
          python = pkgs.python3.withPackages (ps: with ps; [
            msgpack
            jupyter-client
            ipykernel
            matplotlib
            ipympl
          ]);
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.rust-analyzer
              pkgs.neovim
              python
            ];

            # jupyter_client resolves kernelspecs through JUPYTER_PATH. Without
            # this the ipykernel spec that ships inside the python env is invisible
            # and every kernel test fails with "no kernelspec found for 'python3'".
            shellHook = ''
              export JUPYTER_PATH="${python}/share/jupyter''${JUPYTER_PATH:+:$JUPYTER_PATH}"
              export RUST_BACKTRACE=1
            '';
          };
        });
    };
}
