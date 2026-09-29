# Pass 17 evidence

Every manifest, wall frame and receipt from the final build is here, with the
before screens and the main screen of each page. The other captures, the 660
widget renders and the comparison gallery are left out to keep the repository
small. They come back with:

    .venv/bin/python scripts/qa/capture_batch17.py
    .venv/bin/python scripts/qa/render_widgets.py --app <Tessera.app> --out qa/batch-17/after/widgets
    .venv/bin/python scripts/qa/compare_batch17.py

`scripts/qa/verify_batch17.py` checks that every capture came from one build.
validation.json records the builds, tests and deployment.
