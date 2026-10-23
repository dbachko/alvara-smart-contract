# Generated contract artifacts

After dependencies are installed and the reviewed contract builds, export only the ABI with:

```sh
forge inspect AlvaraStorage abi > artifacts/AlvaraStorage.abi.json
```

`AlvaraStorage.abi.json` is the stable backend input. It contains no chain or deployed address;
those must come from a separately reviewed deployment manifest.
