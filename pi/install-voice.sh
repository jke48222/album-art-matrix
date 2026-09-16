#!/bin/bash
# The speech tools belong to this checkout, including on the shared Pi.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel 2>/dev/null || dirname "$(dirname "$(realpath "$0")")")
py="$root/.venv/bin/python"
revision=1d549b3cecc2d98d76d4ddc2edca0d1512f5d7a0
source_dir="$root/vendor/whisper.cpp"
mkdir -p "$root/vendor" "$root/bin" "$root/models/voice"
"$py" -m pip install 'cmake>=3.20' 'onnxruntime>=1.20,<2' 'scipy>=1.14,<2' 'scikit-learn>=1.5,<2' 'tqdm>=4,<5' 'requests>=2,<3'
# ONNX runs on both machines. The default dependency resolver also installs
# Linux-only TFLite and noise suppression, neither used by this integration.
"$py" -m pip install --no-deps 'openwakeword @ git+https://github.com/dscripka/openWakeWord@368c03716d1e92591906a84949bc477f3a834455'
if [ ! -d "$source_dir/.git" ]; then
    git clone https://github.com/ggml-org/whisper.cpp "$source_dir"
fi
git -C "$source_dir" checkout --detach "$revision"
"$root/.venv/bin/cmake" -S "$source_dir" -B "$source_dir/build-wall" -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF -DBUILD_SHARED_LIBS=OFF
"$root/.venv/bin/cmake" --build "$source_dir/build-wall" --target whisper-cli -j 2
install -m 755 "$source_dir/build-wall/bin/whisper-cli" "$root/bin/whisper-cli"
for model in melspectrogram embedding_model hey_jarvis_v0.1; do
    target="$root/models/voice/$model.onnx"
    if [ ! -s "$target" ]; then
        curl -fL --retry 3 "https://github.com/dscripka/openWakeWord/releases/download/v0.5.1/$model.onnx" -o "$target.part"
        mv "$target.part" "$target"
    fi
done
for model in tiny base; do
    target="$root/models/voice/ggml-$model.bin"
    if [ ! -s "$target" ]; then
        curl -fL --retry 3 "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$model.bin" -o "$target.part"
        mv "$target.part" "$target"
    fi
done
echo "[voice] whisper.cpp $revision built; Jarvis, tiny and base models ready"
