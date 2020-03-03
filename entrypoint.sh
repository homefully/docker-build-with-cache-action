#!/usr/bin/env bash

set -e

# helper functions
_has_value() {
  local var_name=${1}
  local var_value=${2}
  if [ -z "$var_value" ]; then
    echo "INFO: Missing value $var_name" >&2
    return 1
  fi
}

_get_max_stage_number() {
  sed -nr 's/^([0-9]+): Pulling from.+/\1/p' "$PULL_STAGES_LOG" |
    sort -n |
    tail -n 1
}

_get_stages() {
  grep -EB1 '^Step [0-9]+/[0-9]+ : FROM' "$BUILD_LOG" |
    sed -rn 's/ *-*> (.+)/\1/p'
}

_get_full_image_name() {
  echo ${INPUT_REGISTRY:+$INPUT_REGISTRY/}${INPUT_IMAGE_NAME}
}

_push_git_tag() {
  [[ "$GITHUB_REF" =~ /tags/ ]] || return 0

  local git_tag=${GITHUB_REF##*/tags/}
  echo -e "\nPushing git tag: $git_tag"
  local image_with_git_tag
  image_with_git_tag="$(_get_full_image_name)":$git_tag
  docker tag "$(_get_full_image_name)":${INPUT_IMAGE_TAG} "$image_with_git_tag"
  docker push "$image_with_git_tag"
}


# action steps
check_required_input() {
  echo -e "\n[Action Step] Checking required input..."
  _has_value IMAGE_NAME "${INPUT_IMAGE_NAME}" \
    && _has_value IMAGE_TAG "${INPUT_IMAGE_TAG}" \
    && return
  exit 1
}

login_to_registry() {
  echo -e "\n[Action Step] Log in to registry..."
  if _has_value USERNAME "${INPUT_USERNAME}" && _has_value PASSWORD "${INPUT_PASSWORD}"; then
    echo "${INPUT_PASSWORD}" | docker login -u "${INPUT_USERNAME}" --password-stdin "${INPUT_REGISTRY}" \
      && return 0
    local log="Could not log in (please check credentials)"
  else
    local log="No credentials provided"
  fi

  not_logged_in=true
  echo "INFO: $log - If you are not allready logged into the correct docker registry (for example by using gcloud), you won't be able to pull from private repos, nor to push to public/private repos" >&2
}

pull_cached_stages() {
  if [ "$INPUT_PULL_IMAGE_AND_STAGES" != true ]; then
    return
  fi
  echo -e "\n[Action Step] Pulling image..."
  docker pull --all-tags "$(_get_full_image_name)"-stages 2> /dev/null | tee "$PULL_STAGES_LOG" || true
}

build_image() {
  echo -e "\n[Action Step] Building image..."
  max_stage=$(_get_max_stage_number)

  # create param to use (multiple) --cache-from options
  if [ "$max_stage" ]; then
    cache_from=$(eval "echo --cache-from=$(_get_full_image_name)-stages:{1..$max_stage}")
    echo "Use cache: $cache_from"
  fi

  # build image using cache
  set -x
  docker build \
    $cache_from \
    --tag "$(_get_full_image_name)":${INPUT_IMAGE_TAG} \
    --file ${INPUT_CONTEXT}/${INPUT_DOCKERFILE} \
    ${INPUT_BUILD_EXTRA_ARGS} \
    ${INPUT_CONTEXT} | tee "$BUILD_LOG"
  set +x
}

push_image_and_stages() {
  if [ "$INPUT_PUSH_IMAGE_AND_STAGES" != true ]; then
    return
  fi

  echo -e "\n[Action Step] Pushing image..."
  # push image
  echo "Pushing tag: ${INPUT_IMAGE_TAG}"
  docker push "$(_get_full_image_name)":${INPUT_IMAGE_TAG}
  if [ "$INPUT_PUSH_GIT_TAG" = true ]; then
    _push_git_tag
  fi

  # push each building stage
  stage_number=1
  for stage in $(_get_stages); do
    echo -e "\nPushing stage: $stage_number"
    stage_image=$(_get_full_image_name)-stages:$stage_number
    docker tag "$stage" "$stage_image"
    docker push "$stage_image"
    stage_number=$(( stage_number+1 ))
  done

  # push the image itself as a stage (the last one)
  echo -e "\nPushing stage: $stage_number"
  stage_image=$(_get_full_image_name)-stages:$stage_number
  docker tag "$(_get_full_image_name)":${INPUT_IMAGE_TAG} $stage_image
  docker push $stage_image
}

logout_from_registry() {
  if [ "$not_logged_in" ]; then
    return
  fi
  echo -e "\n[Action Step] Log out from registry..."
  docker logout "${INPUT_REGISTRY}"
}


# run the action
check_required_input
login_to_registry
pull_cached_stages
build_image
push_image_and_stages
logout_from_registry
