{
  description = "Wylited's homelab config — fleet: warden, scout-darwin, scout-asahi, rogue-glyph, artificer (plan: ./../PLAN.md)";

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

    # TODO when scout-asahi lands: nixos-apple-silicon input
    #   github:nix-community/nixos-apple-silicon (see nix-migration plan 05)
  };

  outputs = inputs@{ self, nixpkgs, nix-darwin, home-manager, ... }: {
    # ============ scout-darwin (sd — M1 Pro MacBook, macOS boot) ============
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

    # ============ warden (wa — homeserver, all of PLAN.md) ============
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

    # ============ scout-asahi (sa — same M1 Pro, Asahi NixOS boot, plan 05) ============
    nixosConfigurations.scout-asahi = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/scout-asahi
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

    # ============ artificer (an — rpi5, 8 GB, NixOS sd-image). Archetype
    #               named 2026-10-11; hosting deferred. Provisioning route
    #               decided 2026-10-11: build the sd-image on warden (binfmt),
    #               dd to card/USB-SSD, boot — then remote rebuilds from
    #               warden. nixos-anywhere skipped: kexec is the flaky part
    #               on Pi kernels, and the sd-image module owns the Pi-5
    #               firmware/boot files for us. ============
    nixosConfigurations.artificer-nixos = nixpkgs.lib.nixosSystem {
      system = "aarch64-linux";
      specialArgs = { inherit self inputs; };
      modules = [
        ./hosts/artificer
      ];
    };
  };
}
