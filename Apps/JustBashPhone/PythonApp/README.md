# PythonApp

Files in this directory are copied into the Python-linked iPhone app bundle at
build time and added to `sys.path` before user code runs.

Use it for pure-Python helper modules or vendored dependencies that should ship
with the app. For example:

```bash
python3 -m pip install --target Apps/JustBashPhone/PythonApp requests
```

Native extension packages need iOS-compatible builds and must be bundled and
signed at build time; runtime `pip install` is not the supported path on iPhone.
