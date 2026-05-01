# PythonApp

Files in this directory are copied into the Python-linked iPhone app bundle at
build time and added to `sys.path` before user code runs.

Use it for pure-Python helper modules or vendored dependencies that should ship
with the app.

```bash
./scripts/install_python_app_packages.sh
```

That installs the pinned default package set from `requirements-default.txt` into
`site-packages/`. `Apps/JustBashPhone/generate_project.sh --with-python` runs
that installer automatically unless `JUSTBASH_PHONE_SKIP_PYTHON_PACKAGES=1` is
set.

Optional native iOS packages are handled separately because they need one wheel
per device/simulator architecture:

```bash
./scripts/install_python_native_packages.sh
```

The native installer currently targets packages with compatible CPython 3.14
iOS wheels: `numpy`, `pillow`, and the Pillow-backed `pdf2image`/`reportlab`
helpers. `lxml`, `pandas`, and `scipy` are tracked in
`requirements-native-ios.txt`, but are intentionally left commented until
compatible iOS wheels resolve.

The primary-runtime Documents skill currently remains blocked on iOS because
its helpers use real `lxml`/`python-docx` OOXML behavior: namespace-aware XPath,
parent/sibling mutation, parser options, and low-level Word XML constructors. A
minimal import shim would not be enough. The viable paths are compatible iOS
wheels/ports for those packages or a native in-process OOXML adapter that covers
the same behavior, plus a replacement for `soffice`/Poppler-based rendering.

Runtime `pip install` is not the supported path on iPhone.
