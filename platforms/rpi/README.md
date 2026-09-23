# Raspberry Pi / Linux SBC host

Canonical runtime-host and board packaging source lives here. `default.nix` packages the portable host-contract library using downstream-pinned nixpkgs. It is not a bootable image or service.

Next gate: extract/reuse the existing Common Lisp actor/supervisor implementation and tests; bind it to `star.edge.host`; create NixOS service and board-specific image definitions. Validate aarch64 builds, exact board/bootloader, offline startup, durable recovery and power scheduling before publishing an image. Raspberry Pi 4 and 5 need separate board evidence; a generic ARM build is not a boot test.

Generic P2P enrollment, transport selection, i2pd integration and versioned update clients belong upstream here. Actual fleet trust roots, inventory, WAN credentials and deployment promotion remain downstream. NixOS manages the machine; Lisp owns execution; Prolog/StarLang policy goes through the established APIs.
