#!/bin/bash
# Native C Olaf, kept in this checkout, with no system-wide installation.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(realpath "$0")")")
source_dir="$root/vendor/Olaf"
revision=532f1991ba170b39d2156b43935428814e833614
if [ ! -d "$source_dir/.git" ]; then
    mkdir -p "$root/vendor"
    git clone https://github.com/JorenSix/Olaf "$source_dir"
fi
git -C "$source_dir" checkout --detach "$revision"
python3 - "$source_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
path = root / 'src/olaf_config.c'
text = path.read_text().replace('getenv("HOME")', 'getenv("OLAF_DB_ROOT")')
text = text.replace('"/.olaf/db/"', '"/db/"')
path.write_text(text)
path = root / 'src/olaf.c'
text = path.read_text().replace('olaf_runner_new(runner_mode, config, NULL, NULL)', 'olaf_runner_new(runner_mode, config, stdout, stdout)')
path.write_text(text)
path = root / 'src/olaf_stream_processor.c'
text = path.read_text()
needle = '\n\t\tOlaf_Resource_Meta_data meta_data;\n\t\tmeta_data.duration = (float) audioDuration;'
# Store already flushes the final batch. Print must do the same or a saved
# hash list cannot later remove every fingerprint from the database.
old = 'OLAF_RUNNER_MODE_CACHE){\n\n\t\tOlaf_Resource_Meta_data meta_data;'
new = 'OLAF_RUNNER_MODE_CACHE){\n\n\t\tif(fingerprints != NULL) olaf_fp_file_writer_write(fp_file_writer,fingerprints);\n\t\tOlaf_Resource_Meta_data meta_data;'
text = text.replace(old, new)
path.write_text(text)
path = root / 'Makefile'
text = path.read_text().replace('-std=c11', '-std=gnu11')
if 'compile_core:\n\tgcc -c src/olaf_fft.c' not in text:
    text = text.replace('compile_core:\n', 'compile_core:\n\tgcc -c src/olaf_fft.c -O2 -std=c11\n')
path.write_text(text)
PY
make -C "$source_dir" compile_core
mkdir -p "$root/bin"
install -m 755 "$source_dir/bin/olaf_core" "$root/bin/olaf"
cc -O2 -std=c11 -I "$source_dir/src" "$root/pi/olaf_forget.c" \
    "$source_dir/olaf_db.o" "$source_dir/olaf_db_id.o" \
    "$source_dir/mdb.o" "$source_dir/midl.o" -lm -pthread -o "$root/bin/olaf-forget"
echo "[teach] Olaf $revision built in $root/bin; AGPL source in $source_dir"
