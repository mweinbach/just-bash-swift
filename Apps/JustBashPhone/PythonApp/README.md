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
helpers. `pandas` and `scipy` are tracked in `requirements-native-ios.txt`, but
are intentionally left commented until compatible iOS wheels resolve.
`python-docx` is also tracked there and remains disabled because its upstream
`lxml` dependency does not resolve for this iOS target.

The app bundle root includes a pure-Python `lxml.etree` compatibility package
for the OOXML behavior exercised by cached Documents helpers: namespace-aware XPath,
parent/sibling mutation, parser options, and XML serialization. The smoke script
runs cached `set_protection.py` and `comments_strip.py` against generated DOCX
files with this staged package. Broader Documents support is still blocked on
helpers that import `python-docx` for the Word document model and low-level OOXML
constructors, plus replacements for `soffice`/Poppler-based rendering.

Runtime `pip install` is not the supported path on iPhone.
