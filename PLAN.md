# On-demand vanilla vehicle handling support

## Summary

Extend `cHandlingEditor` with a model-specific runtime backend for GTA build 3258. Vehicles without editable resource metadata will be captured from the live vehicle, edited through the existing UI, and persisted in `[auti]/VanillaHandlingData`.

Use native-backed JSON overrides instead of generated `handling.meta`. This preserves complex stock handling data that cannot be captured safely and avoids restarting or deleting ambient vehicles.

## Key Changes

- Add `cHandlingEditor/config.lua`:

  ```lua
  CHandlingEditorConfig.vanilla = {
      enabled = true,
      resource = 'VanillaHandlingData',
      file = 'data/handling-overrides.json',
      gameBuild = 3258,
  }
  ```

- Turn `VanillaHandlingData` into a data-only FiveM resource with a manifest, README, and versioned JSON store:

  ```json
  {
    "schemaVersion": 1,
    "gameBuild": 3258,
    "revision": 0,
    "models": {
      "<unsigned-model-hash>": {
        "modelName": "adder",
        "captureVersion": 1,
        "revision": 1,
        "baseline": {},
        "overrides": {}
      }
    }
  }
  ```

  Field keys use `HandlingClass.fieldName`; values are finite numbers, integers, or `{x,y,z}` vectors. Baselines are captured once, while only explicitly saved fields are enforced.

- Add a server-controlled capture schema covering native-readable base and known sub-handling classes. Include scalar, integer/flag, and vector fields; omit arrays, repeated `CAdvancedData`, and opaque strings that cannot be round-tripped safely. Cfx supports reading and setting existing sub-handling classes through its [handling implementation](https://github.com/citizenfx/fivem/blob/master/code/components/handling-loader-five/src/HandlingLoader.cpp).

- Change vehicle resolution so existing resource-backed XML remains first priority. Only when no mapped or unresolved resource metadata exists does the vanilla runtime backend activate. This also safely supports otherwise unindexed add-on models without changing indexed add-on behavior.

- On first open, request a token-bound handling snapshot from the current driver's verified vehicle. Probe fields with a same-value get/set/readback check and expose only fields the client runtime confirms are supported. View-only users may inspect an ephemeral capture; the baseline is written only with the first authorized edit.

- Add a runtime save branch that preserves existing ACE, session, vehicle, stale-value, and finite-value validation. Serialize all vanilla writes through one file queue, re-read the JSON before saving, reject conflicts, confirm the write, and create the existing `.cHandlingEditor.bak` backup.

- Apply successful overrides model-wide on every client. Broadcast the complete override set and per-model revision after saves, on client/editor startup, and after the data resource starts. Clients apply fields immediately to matching vehicles and scan the local vehicle pool every 500 ms so newly streamed vehicles receive them. Cache successful entity/revision applications and retry failed ones.

- Keep overrides model-specific even when Rockstar models share an underlying handling ID. Never delete, respawn, or restart vehicles for this backend. Mark runtime sessions `restartSupported = false`, hide the restart UI, and defensively reject restart requests server-side. Existing XML-backed restart behavior remains unchanged.

- Validate the configured resource, relative file path, JSON schema, and enforced game build before enabling vanilla edits. Invalid or mismatched storage fails closed without overwriting data or affecting normal add-on editing.

- Start `VanillaHandlingData` before `[skripte]` and grant:

  ```cfg
  add_filesystem_permission cHandlingEditor write VanillaHandlingData
  ```

## Interfaces

- Add token-correlated capture events for server-requested field probing.
- Add full/model replacement sync events for runtime overrides; clients cannot choose resource names, paths, models, or field schemas.
- Extend the editor payload with `handling.backend = "vanilla_runtime"` and `handling.restartSupported = false`.
- Display `VanillaHandlingData` and the configured JSON path as the source in the existing UI.

## Test Plan

- Verify an untouched build-3258 stock car opens, captures fields, saves an override, updates all matching live vehicles, and affects newly spawned instances.
- Verify persistence after reconnecting, restarting `cHandlingEditor`, restarting `VanillaHandlingData`, and restarting the server.
- Test base fields plus car, bike, aircraft, trailer, and other available sub-handling fields; unsupported arrays and strings must not appear.
- Confirm indexed add-ons retain XML persistence and guarded restart behavior, including stock-model replacements.
- Confirm view-only users cause no filesystem writes, edit users can initialize data, missing filesystem permission gives the exact configuration fix, and simultaneous edits produce stale-value conflicts.
- Confirm malformed JSON, missing/stopped storage resources, build mismatches, changed mappings, invalid captures, and lost driver vehicles fail without corrupting the store.
- Run Lua/JavaScript syntax checks and a mocked-native test harness for capture validation, store migration/parsing, resolver priority, revision synchronization, and new-entity application.

## Assumptions

- Runtime JSON overrides are the selected "best" approach from the user's preference response.
- The server remains on enforced GTA build 3258; changing builds requires updating the configured build and regenerating affected baselines.
- `VanillaHandlingData` is the configurable resource name; `[auti]` is only its current category location.
- `cHandlingEditor` remains ensured during gameplay because it owns synchronization and application of persisted runtime overrides.
