{
  description = "Vesper default dev workspace (Nix + LazyVim + LSPs)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.buildEnv {
          name = "vesper-dev-env";
          paths = with pkgs; [
            neovim
            tmux
            zsh
            oh-my-zsh
            zsh-autosuggestions
            zsh-syntax-highlighting
            lazygit
            ripgrep
            fd
            tree-sitter
            fzf
            gcc
            lua-language-server
            gopls
            pyright
            ruff
            typescript-language-server
            nixd
            nixfmt
            marksman
          ];
        };
      });
    };
}
