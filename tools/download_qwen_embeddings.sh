#!/bin/zsh
set -euo pipefail

# The weights are operator data, not an application resource or a Git asset.
project_root="${0:A:h:h}"
model_directory="${1:-$project_root/data/qwen_embeddings}"
model_file="$model_directory/Qwen3-Embedding-0.6B-Q8_0.gguf"
expected_sha="06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439"
model_url="https://huggingface.co/Qwen/Qwen3-Embedding-0.6B-GGUF/resolve/370f27d7550e0def9b39c1f16d3fbaa13aa67728/Qwen3-Embedding-0.6B-Q8_0.gguf"

mkdir -p "$model_directory"
if [[ -f "$model_file" ]]; then
  actual_sha="$(/usr/bin/shasum -a 256 "$model_file" | /usr/bin/awk '{print $1}')"
  if [[ "$actual_sha" == "$expected_sha" ]]; then
    print "Qwen Q8 model is already verified: $model_file"
    exit 0
  fi
  print -u2 "Existing model has an unexpected checksum; it was not overwritten."
  exit 1
fi

print "Downloading Qwen3-Embedding-0.6B Q8 (639 MB) from Hugging Face..."
/usr/bin/curl --fail --location --silent --show-error --retry 3 \
  --continue-at - --output "$model_file.partial" "$model_url"
actual_sha="$(/usr/bin/shasum -a 256 "$model_file.partial" | /usr/bin/awk '{print $1}')"
if [[ "$actual_sha" != "$expected_sha" ]]; then
  print -u2 "Qwen download checksum failed; the partial file was not installed."
  exit 1
fi
mv "$model_file.partial" "$model_file"
print "Verified Qwen Q8 model: $model_file"
