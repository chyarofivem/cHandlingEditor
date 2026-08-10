# VanillaHandlingData

Data-only storage for model-specific `cHandlingEditor` runtime overrides. Start
this resource before `cHandlingEditor`; do not edit the JSON while the server is
running.

```cfg
ensure VanillaHandlingData
ensure cHandlingEditor
add_filesystem_permission cHandlingEditor write VanillaHandlingData
```

The store is tied to GTA build 3258. Back it up and recapture baselines before
changing the enforced game build.
