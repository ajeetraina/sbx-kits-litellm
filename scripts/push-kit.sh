#!/usr/bin/env bash
# Validate and push this mixin kit to a registry as a tag.
#
#   ./scripts/push-kit.sh                 # pushes :latest from the repo root spec
#   TAG=v1 ./scripts/push-kit.sh          # pushes :v1
#   DOCKERHUB_NAMESPACE=me ./scripts/push-kit.sh
set -euo pipefail

namespace="${DOCKERHUB_NAMESPACE:-${DOCKER_NAMESPACE:-ajeetraina777}}"
kit_name="${KIT_NAME:-sbx-kits-litellm}"   # also the staged subdir name
tag="${TAG:-latest}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
image="docker.io/$namespace/$kit_name"

# publish SPEC_DIR IMAGE_TAG README_FILE
# Stages a kit (spec.yaml + README + LICENSE), validates it, and pushes one tag.
publish() {
  local spec_dir="$1" image_tag="$2" readme="$3"
  local stage
  stage="$(mktemp -d /tmp/sbx-kit-push.XXXXXX)"
  mkdir -p "$stage/$kit_name"
  cp "$spec_dir/spec.yaml" "$stage/$kit_name/spec.yaml"
  cp "$readme" "$stage/$kit_name/README.md"
  [ -f "$repo_root/LICENSE" ] && cp "$repo_root/LICENSE" "$stage/$kit_name/LICENSE"
  sbx kit validate "$stage/$kit_name"
  sbx kit push "$stage/$kit_name" "$image:$image_tag"
  rm -rf "$stage"
  echo "Pushed $image:$image_tag"
}

publish "$repo_root" "$tag" "$repo_root/README.md"
