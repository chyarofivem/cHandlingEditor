# cHandlingEditor

Framework-independent in-game editor for add-on vehicle `handling.meta` files.
It uses the installed `ox_lib` resource for top-left player notifications.

## Command and permissions

- `/handlingeditor`
- `chandlingeditor.view` opens the editor.
- `chandlingeditor.edit` enables editing, persistence, reset, and resource restart.

The supplied server configuration grants both ACEs to `group.admin`. The server's
existing `admin` ACE is also accepted as a compatibility grant for administrators;
view-only principals still require only `chandlingeditor.view`.

## Writable vehicle resources

FXServer requires a filesystem permission for every resource whose handling files may be changed. One line covers the entire resource, including a car pack with multiple vehicles and multiple metadata files:

```cfg
add_filesystem_permission cHandlingEditor write myCarPack
```

The guarded resource-restart button also needs the command ACEs supplied in
`permissions.cfg`: `command.restart`, `command.stop`, and `command.start` for
`resource.cHandlingEditor`.

Permissions cannot target a bracket category such as `[cars]`. Add one line for each actual vehicle resource. The editor reports the exact missing line when a save is denied.

Saving changes the source XML immediately. Supported numeric fields are also previewed on the current vehicle. The guarded **Restart resource** action snapshots every live vehicle model supplied by that resource, including its full `ox_lib` property set, transform, occupants, routing bucket, and Qbox garage/persistence identity. It then removes the entities, restarts the pack, preloads the affected models on nearby clients, and recreates the vehicles sequentially while collision is held. Each exact property set is acknowledged before occupants and Qbox persistence are restored; physics is released only after initialization, at rest. Garage-owned vehicles keep their `vehicleid`/persistence state and their exact live properties are synchronized back to `qbx_vehicles` without changing their garage/OUT state. If cleanup cannot be verified, the restart is cancelled and removed vehicles are rolled back.

Large streamed packs can expose a lightweight handling-only overlay with
`chandling_vehicle_metadata` manifest metadata. The editor uses those private
`vehicles.meta` files for indexing while only the overlay's `HANDLING_FILE` is
mounted. The guarded restart then reloads metadata without unloading the parent
pack's models, textures, audio, or other data files.
