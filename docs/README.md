# Layout

- `include/`
  Public framework headers.
- `src/`
  Public follow framework sources.
- `target/`
  Release archives named as `<TARGET_NAME>.a`.
- `scripts/`
  Scripts used for patching and firmware builds.

# Firmware Build

This framework directory can be copied into a clean Betaflight source tree, or placed next to it.

Build firmware with:

```bash
bash /path/to/framework/scripts/build_follow_firmware.sh /path/to/betaflight-4.5.2 BETAFPVF435
```

The build script will:

1. resolve `TARGET_NAME`
2. check `target/<TARGET_NAME>.a`
3. apply the patch to the Betaflight tree
4. copy the archive into `src/main/follow/target/`
5. run Betaflight `make`

If the matching archive is missing, the build stops before compilation.

# Delivery

For release delivery, ship:

- `include/`
- `src/`
- `target/`
- `scripts/`
- `README.md`
- `docs/`

# Notes

- `TARGET_NAME` may differ from the config name.
- Config-driven builds are supported as long as the matching `config.h` exists in the Betaflight tree.
- The release workflow is archive-based.
- Build metadata such as `FOLLOW_VERSION` and `FOLLOW_DESCRIPTION` can be passed at archive generation time and at final firmware build time.
