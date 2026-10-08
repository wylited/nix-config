{
  description = "Wyliteds multi-host nix config — DRAFT (plans: ~/nix-migration/)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    nix-darwin = {
      url = "github:nix-darwin/nix-darwin/master";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    zen-browser = {
      url = "github:0xc000022070/zen-browser-flake";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
      };
    };

    # hardware-specific NixOS modules (warden: Cezanne laptop — plan 03 input list)
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # TODO when asahi lands: nixos-apple-silicon input
    #   github:nix-community/nixos-apple-silicon (see plan 05)
  };

  outputs = inputs@{ self, nixpkgs, nix-darwin, home-manager, ... }: {
    # ===================== macOS (existing, ported 1:1) =====================
    darwinConfigurations.scout-darwin = nix-darwin.lib.darwinSystem {
      system = "aarch64-darwin";

      specialArgs = { inherit self inputs; };

      modules = [
        ./hosts/scout-darwin
        home-manager.darwinModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ===================== warden (Arch -> NixOS, plan 08) =====================
    nixosConfigurations.warden = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/warden
        home-manager.nixosModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ===================== asahi (same M1 Pro, other boot, plan 05) =====================
    nixosConfigurations.asahi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/asahi
        home-manager.nixosModules.home-manager {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            extraSpecialArgs = { inherit self inputs; };
            users.wyli = { imports = [ ./home/wyli.nix ]; };
          };
        }
      ];
    };

    # ===================== rpi5 (8 GB, sd image, plan 03) =====================
    nixosConfigurations.rpi5 = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/rpi5
      ];
    };
  };
}
