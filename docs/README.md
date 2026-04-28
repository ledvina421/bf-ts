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

To override the built-in follow PID defaults at build time, pass a PID file:

```bash
bash /path/to/framework/scripts/build_follow_firmware.sh \
  /path/to/betaflight-4.5.2 \
  BETAFPVF435 \
  --pid-file /path/to/follow_pid_defaults.txt
```

The build script will:

1. resolve `TARGET_NAME`
2. check `target/<TARGET_NAME>.a`
3. apply the patch to the Betaflight tree
4. copy the archive into `src/main/follow/target/`
5. run Betaflight `make`

If the matching archive is missing, the build stops before compilation.

## PID Defaults At Build Time

- `--pid-file <path>` replaces the compiled-in `followDefaultPidTable` values before Betaflight build.
- The PID file must contain exactly 6 lines.
- Each line must contain exactly 28 comma-separated float values.
- A ready-to-edit example is provided in `docs/follow_pid_defaults_template.txt`.
- If `--pid-file` is not provided, the built-in defaults from `include/follow/follow_pid_defaults.h` are used.

## Follow PID CLI

After patching the Betaflight tree, the CLI adds `followPID`:

```text
followPID get <index>
followPID set <index> <float...>
followPID save
```

- `index` is `0` to `5`, corresponding to the 6 follow PID groups.
- `followPID get <index>` prints the full parameter group for that index.
- `followPID set <index> <float...>` writes up to 28 float values.
- If fewer than 28 values are provided, the remaining values are filled with `0`.
- If more than 28 values are provided, extra values are ignored.
- `followPID save` stores the modified PID table to flash through the normal Betaflight save path.

## Dump And Diff

- `dump` exports the current saved follow PID values as replayable CLI lines:
  `followPID set 0 ...` through `followPID set 5 ...`
- `dump` also includes `followPID save`
- `diff` exports the same replayable `followPID set` lines, but does not append `followPID save`
- These lines can be copied back into CLI to restore follow PID settings
- The exported values come from the saved runtime configuration, not from the compiled defaults

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
