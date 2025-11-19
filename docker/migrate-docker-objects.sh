#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

usage() {
  cat <<EOF2
Usage:
  $0 <image|volume> <name> --src <user@src-host> --dst <user@dst-host> \\
     [--src-tmp-path <path>] [--dst-tmp-path <path>] \\
     [--src-docker-become] [--dst-docker-become] \\
     [--src-port <port>] [--dst-port <port>] \\
     [--chunk-size-gb <N>] [--retry <N>] [--delete] [--local-src] [--local-dst]

Arguments:
  <image|volume>         What to transfer: a Docker image or a Docker volume.
  <name>                 Image name (e.g. my-app:latest) or volume name (e.g. my_volume).

  --src <user@host>      Source SSH/rsync endpoint (NOT required if --local-src).
  --dst <user@host>      Destination SSH/rsync endpoint (NOT required if --local-dst).
  --src-port <port>      SSH port for source host (default: 22).
  --dst-port <port>      SSH port for destination host (default: 22).

  --src-tmp-path <path>  Temporary path on source host (default: /tmp/migrate-docker-objects).
  --dst-tmp-path <path>  Temporary path on destination host (default: /tmp/migrate-docker-objects).

  --src-docker-become    Use sudo for Docker commands on the source.
  --dst-docker-become    Use sudo for Docker commands on the destination.

  --chunk-size-gb <N>    Split exported tar into N GiB chunks (rsync directories of chunks).
  --retry <N>            Max attempts for failed ssh/rsync commands (default: 1 = no retries).
  --delete               Delete temporary artifacts on src/dst/local without asking.
  --local-src            Treat the machine running this script as the source (no SSH/rsync from src).
  --local-dst            NOT IMPLEMENTED YET (will cause an error if used).

Notes:
  --local-src and --local-dst cannot be used together.
EOF2
  exit 1
}

if [[ $# -lt 5 ]]; then
  usage
fi

MODE="$1"
shift
case "$MODE" in
  image|volume) ;;
  *)
    echo "ERROR: First argument must be 'image' or 'volume', got '$MODE'." >&2
    usage
    ;;
esac

OBJECT_NAME="$1"
shift

SRC=""
DST=""
SRC_PORT=22
DST_PORT=22
SRC_TMP_PATH="/tmp/migrate-docker-objects"
DST_TMP_PATH="/tmp/migrate-docker-objects"
SRC_DOCKER_BECOME=false
DST_DOCKER_BECOME=false
CHUNK_SIZE_GB=""
CHUNK_SIZE_BYTES=0
CHUNKING_ENABLED=false
DELETE_MODE=false
LOCAL_SRC=false
LOCAL_DST=false
RETRY_ATTEMPTS=1
IN_CLEANUP=false
HELPER_IMAGE="migrate-docker-objects:latest"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --src)
      [[ $# -ge 2 ]] || { echo "ERROR: --src requires an argument." >&2; exit 1; }
      SRC="$2"
      shift 2
      ;;
    --dst)
      [[ $# -ge 2 ]] || { echo "ERROR: --dst requires an argument." >&2; exit 1; }
      DST="$2"
      shift 2
      ;;
    --src-port)
      [[ $# -ge 2 ]] || { echo "ERROR: --src-port requires an argument." >&2; exit 1; }
      SRC_PORT="$2"
      if ! [[ "$SRC_PORT" =~ ^[0-9]+$ ]] || [[ "$SRC_PORT" -lt 1 || "$SRC_PORT" -gt 65535 ]]; then
        echo "ERROR: --src-port must be an integer between 1 and 65535." >&2
        exit 1
      fi
      shift 2
      ;;
    --dst-port)
      [[ $# -ge 2 ]] || { echo "ERROR: --dst-port requires an argument." >&2; exit 1; }
      DST_PORT="$2"
      if ! [[ "$DST_PORT" =~ ^[0-9]+$ ]] || [[ "$DST_PORT" -lt 1 || "$DST_PORT" -gt 65535 ]]; then
        echo "ERROR: --dst-port must be an integer between 1 and 65535." >&2
        exit 1
      fi
      shift 2
      ;;
    --src-tmp-path)
      [[ $# -ge 2 ]] || { echo "ERROR: --src-tmp-path requires an argument." >&2; exit 1; }
      SRC_TMP_PATH="$2"
      shift 2
      ;;
    --dst-tmp-path)
      [[ $# -ge 2 ]] || { echo "ERROR: --dst-tmp-path requires an argument." >&2; exit 1; }
      DST_TMP_PATH="$2"
      shift 2
      ;;
    --src-docker-become)
      SRC_DOCKER_BECOME=true
      shift 1
      ;;
    --dst-docker-become)
      DST_DOCKER_BECOME=true
      shift 1
      ;;
    --chunk-size-gb)
      [[ $# -ge 2 ]] || { echo "ERROR: --chunk-size-gb requires an argument." >&2; exit 1; }
      CHUNK_SIZE_GB="$2"
      if ! [[ "$CHUNK_SIZE_GB" =~ ^[0-9]+$ ]] || [[ "$CHUNK_SIZE_GB" -le 0 ]]; then
        echo "ERROR: --chunk-size-gb must be a positive integer." >&2
        exit 1
      fi
      shift 2
      ;;
    --retry)
      [[ $# -ge 2 ]] || { echo "ERROR: --retry requires an argument." >&2; exit 1; }
      RETRY_ATTEMPTS="$2"
      if ! [[ "$RETRY_ATTEMPTS" =~ ^[0-9]+$ ]] || [[ "$RETRY_ATTEMPTS" -le 0 ]]; then
        echo "ERROR: --retry must be a positive integer." >&2
        exit 1
      fi
      shift 2
      ;;
    --delete)
      DELETE_MODE=true
      shift 1
      ;;
    --local-src)
      LOCAL_SRC=true
      shift 1
      ;;
    --local-dst)
      LOCAL_DST=true
      shift 1
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      usage
      ;;
  esac
done

# Validate local-src / local-dst flags
if $LOCAL_SRC && $LOCAL_DST; then
  echo "ERROR: --local-src and --local-dst cannot both be used." >&2
  exit 1
fi

if $LOCAL_DST; then
  echo "ERROR: --local-dst is not implemented yet." >&2
  exit 1
fi

# Only require --src / --dst if corresponding --local-* is NOT set
if ! $LOCAL_SRC && [[ -z "$SRC" ]]; then
  echo "ERROR: --src must be specified unless --local-src is used." >&2
  usage
fi

if ! $LOCAL_DST && [[ -z "$DST" ]]; then
  echo "ERROR: --dst must be specified unless --local-dst is used." >&2
  usage
fi

if [[ -n "$CHUNK_SIZE_GB" ]]; then
  CHUNKING_ENABLED=true
  CHUNK_SIZE_BYTES=$((CHUNK_SIZE_GB * 1024 * 1024 * 1024))
fi

sanitize_name() {
  local name="$1"
  name="${name//\//_}"
  name="${name//:/_}"
  echo "$name"
}

run_with_retry() {
  local attempts="$RETRY_ATTEMPTS"
  local attempt=1
  local cmd_desc
  cmd_desc="$(printf '%q ' "$@")"

  while (( attempt <= attempts )); do
    if "$@"; then
      return 0
    fi

    if (( attempt < attempts )); then
      echo "Command failed (attempt $attempt/$attempts), retrying in 2 seconds..." >&2
      sleep 2
    else
      printf '\e[31mERROR:\e[0m Command failed after %d attempt(s): %s\n' "$attempts" "$cmd_desc" >&2
      echo "Temporary artifacts may remain on source/destination/local." >&2
      if ! $IN_CLEANUP; then
        local ans="n"
        if ! $DELETE_MODE; then
          read -r -p "Attempt to clean up temporary artifacts now? [y/N]: " ans || ans="n"
        else
          ans="y"
        fi
        case "$ans" in
          [yY][eE][sS]|[yY])
            IN_CLEANUP=true
            maybe_cleanup
            ;;
          *)
            echo "Skipping automatic cleanup." >&2
            ;;
        esac
      fi
      exit 1
    fi
    ((attempt++))
  done
}

# Ensure helper image with xz is present on source side (local or remote)
# Ensure helper image with xz is present on source side (local or remote)
ensure_helper_image_src() {
  local img="$HELPER_IMAGE"

  if $LOCAL_SRC; then
    # LOCAL SOURCE: use an array so "sudo docker" works even with custom IFS
    local docker_cmd=(docker)
    if $SRC_DOCKER_BECOME; then
      docker_cmd=(sudo docker)
    fi

    if ! "${docker_cmd[@]}" image inspect "$img" >/dev/null 2>&1; then
      echo ">>> Building helper image '$img' locally (source) ..."
      printf '%s\n' \
'FROM ubuntu:25.04' \
'RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils tar ca-certificates && rm -rf /var/lib/apt/lists/*' \
'WORKDIR /work' \
        | "${docker_cmd[@]}" build -t "$img" -
    fi
  else
    # REMOTE SOURCE: build snippet string for ssh, keep as simple text
    local docker_cmd_str="docker"
    if $SRC_DOCKER_BECOME; then
      docker_cmd_str="sudo docker"
    fi

    ssh_src "if ! $docker_cmd_str image inspect '$img' >/dev/null 2>&1; then
  echo '>>> Building helper image $img on source host...' >&2
  printf '%s\n' \
'FROM ubuntu:25.04' \
'RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils tar ca-certificates && rm -rf /var/lib/apt/lists/*' \
'WORKDIR /work' \
    | $docker_cmd_str build -t '$img' -
fi"
  fi
}

# Ensure helper image with xz is present on destination host
ensure_helper_image_dst() {
  local img="$HELPER_IMAGE"
  local docker_cmd="docker"
  if $DST_DOCKER_BECOME; then
    docker_cmd="sudo docker"
  fi
  ssh_dst "if ! $docker_cmd image inspect '$img' >/dev/null 2>&1; then
  echo '>>> Building helper image $img on destination host...' >&2
  printf '%s\n' \
'FROM ubuntu:25.04' \
'RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends xz-utils tar ca-certificates && rm -rf /var/lib/apt/lists/*' \
'WORKDIR /work' \
    | $docker_cmd build -t '$img' -
fi"
}

# SSH and rsync helpers (use ports, with retry)
ssh_src() {
  run_with_retry ssh -p "$SRC_PORT" "$SRC" "$@"
}

ssh_dst() {
  run_with_retry ssh -p "$DST_PORT" "$DST" "$@"
}

rsync_from_src() {
  # pass full rsync args to this, including "SRC:PATH" etc.
  run_with_retry rsync -avz --progress --partial --append-verify -e "ssh -p $SRC_PORT" "$@"
}

rsync_to_dst() {
  run_with_retry rsync -avz --progress --partial --append-verify -e "ssh -p $DST_PORT" "$@"
}

WORKDIR="$(pwd)"
SANITIZED_NAME="$(sanitize_name "$OBJECT_NAME")"
TIMESTAMP="$(date +%Y%m%d%H%M%S)"

SRC_FILES=()
SRC_CHUNK_DIRS=()
DST_FILES=()
DST_CHUNK_DIRS=()
LOCAL_FILES=()
LOCAL_CHUNK_DIRS=()

echo "Mode          : $MODE"
echo "Object        : $OBJECT_NAME"
echo "Source host   : ${SRC:-<local>} (port ${SRC_PORT})"
echo "Dest host     : ${DST:-<local>} (port ${DST_PORT})"
echo "Source tmp    : $SRC_TMP_PATH"
echo "Dest tmp      : $DST_TMP_PATH"
echo "Local workdir : $WORKDIR"
echo "SRC docker sudo : $SRC_DOCKER_BECOME"
echo "DST docker sudo : $DST_DOCKER_BECOME"
echo "Local as src  : $LOCAL_SRC"
echo "Local as dst  : $LOCAL_DST"
echo "Chunking      : $CHUNKING_ENABLED"
if $CHUNKING_ENABLED; then
  echo "Chunk size    : ${CHUNK_SIZE_GB} GiB (${CHUNK_SIZE_BYTES} bytes)"
fi
echo "Retry attempts: $RETRY_ATTEMPTS"
echo "Auto delete   : $DELETE_MODE"
echo

transfer_image() {
  local remote_src_file remote_dst_file local_file
  local remote_src_chunks_dir local_chunks_dir remote_dst_chunks_dir

  remote_src_file="${SRC_TMP_PATH}/docker-image-${SANITIZED_NAME}-${TIMESTAMP}.tar"
  local_file="${WORKDIR}/$(basename "$remote_src_file")"
  remote_dst_file="${DST_TMP_PATH}/$(basename "$remote_src_file")"

  echo ">>> Preparing source tmp directory ..."
  if $LOCAL_SRC; then
    mkdir -p "$SRC_TMP_PATH"
  else
    ssh_src "mkdir -p '$SRC_TMP_PATH'"
  fi

  echo ">>> Ensuring source artifact does not already exist: $remote_src_file"
  if $LOCAL_SRC; then
    if [[ -e "$remote_src_file" ]]; then
      echo "ERROR: Source artifact file already exists: $remote_src_file" >&2
      exit 1
    fi
  else
    ssh_src "test ! -e '$remote_src_file'" || {
      echo "ERROR: Source artifact file already exists: $SRC:$remote_src_file" >&2
      exit 1
    }
  fi

  echo ">>> Exporting Docker image on source via docker save ..."
  if $LOCAL_SRC; then
    if $SRC_DOCKER_BECOME; then
      sudo docker save -o "$remote_src_file" "$OBJECT_NAME"
    else
      docker save -o "$remote_src_file" "$OBJECT_NAME"
    fi
    sudo chmod 644 "$remote_src_file" 2>/dev/null || chmod 644 "$remote_src_file" 2>/dev/null || true
  else
    if $SRC_DOCKER_BECOME; then
      ssh_src "sudo docker save -o '$remote_src_file' '$OBJECT_NAME'"
    else
      ssh_src "docker save -o '$remote_src_file' '$OBJECT_NAME'"
    fi
    ssh_src "sudo chmod 644 '$remote_src_file' 2>/dev/null || chmod 644 '$remote_src_file' 2>/dev/null || true"
  fi

  SRC_FILES+=("$remote_src_file")

  if $CHUNKING_ENABLED; then
    echo ">>> Creating chunks directory and splitting tar on source ..."
    remote_src_chunks_dir="${SRC_TMP_PATH}/docker-chunks-${SANITIZED_NAME}-${TIMESTAMP}"
    if $LOCAL_SRC; then
      mkdir -p "$remote_src_chunks_dir"
      split -b "$CHUNK_SIZE_BYTES" -d -a 4 "$remote_src_file" "$remote_src_chunks_dir/chunk_"
    else
      ssh_src "mkdir -p '$remote_src_chunks_dir'"
      ssh_src "split -b ${CHUNK_SIZE_BYTES} -d -a 4 '$remote_src_file' '$remote_src_chunks_dir/chunk_'"
    fi

    SRC_CHUNK_DIRS+=("$remote_src_chunks_dir")

    local_chunks_dir="${WORKDIR}/$(basename "$remote_src_chunks_dir")"
    mkdir -p "$local_chunks_dir"

    if $LOCAL_SRC; then
      echo ">>> Copying chunks directory from source tmp -> local workdir ..."
      cp -a "$remote_src_chunks_dir/." "$local_chunks_dir/"
    else
      echo ">>> rsync chunks directory from source -> local ..."
      rsync_from_src "${SRC}:${remote_src_chunks_dir}/" "$local_chunks_dir/"
    fi

    LOCAL_CHUNK_DIRS+=("$local_chunks_dir")

    echo ">>> Preparing dest tmp directory and chunks dir on $DST ..."
    remote_dst_chunks_dir="${DST_TMP_PATH}/$(basename "$remote_src_chunks_dir")"
    ssh_dst "mkdir -p '$remote_dst_chunks_dir'"

    DST_CHUNK_DIRS+=("$remote_dst_chunks_dir")

    echo ">>> rsync chunks directory from local -> dest ..."
    rsync_to_dst "$local_chunks_dir/" "${DST}:${remote_dst_chunks_dir}/"

    echo ">>> Ensuring dest tar file does not already exist: $remote_dst_file"
    ssh_dst "test ! -e '$remote_dst_file'" || {
      echo "ERROR: Dest artifact file already exists: $DST:$remote_dst_file" >&2
      exit 1
    }

    echo ">>> Reassembling tarball on dest via cat ..."
    ssh_dst "cat '$remote_dst_chunks_dir'/chunk_* > '$remote_dst_file'"

  else
    echo ">>> Ensuring local artifact does not already exist: $local_file"
    if [[ -e "$local_file" ]]; then
      echo "ERROR: Local artifact file already exists: $local_file" >&2
      exit 1
    fi

    if $LOCAL_SRC; then
      echo ">>> Copying tar from source tmp -> local workdir ..."
      cp -a "$remote_src_file" "$local_file"
    else
      echo ">>> rsync tar from source -> local ..."
      rsync_from_src "${SRC}:${remote_src_file}" "$local_file"
    fi

    LOCAL_FILES+=("$local_file")

    echo ">>> Preparing dest tmp directory on $DST ..."
    ssh_dst "mkdir -p '$DST_TMP_PATH'"

    echo ">>> Ensuring dest artifact does not already exist: $remote_dst_file"
    ssh_dst "test ! -e '$remote_dst_file'" || {
      echo "ERROR: Dest artifact file already exists: $DST:$remote_dst_file" >&2
      exit 1
    }

    echo ">>> rsync tar from local -> dest ..."
    rsync_to_dst "$local_file" "${DST}:${remote_dst_file}"
  fi

  DST_FILES+=("$remote_dst_file")

  echo ">>> Importing Docker image on dest via docker load ..."
  if $DST_DOCKER_BECOME; then
    ssh_dst "sudo docker load -i '$remote_dst_file'"
  else
    ssh_dst "docker load -i '$remote_dst_file'"
  fi

  echo ">>> Docker image transfer completed successfully."
}

transfer_volume() {
  local remote_src_file remote_dst_file local_file tar_filename
  local remote_src_chunks_dir local_chunks_dir remote_dst_chunks_dir

  remote_src_file="${SRC_TMP_PATH}/docker-volume-${SANITIZED_NAME}-${TIMESTAMP}.tar.xz"
  local_file="${WORKDIR}/$(basename "$remote_src_file")"
  remote_dst_file="${DST_TMP_PATH}/$(basename "$remote_src_file")"
  tar_filename="$(basename "$remote_dst_file")"

  echo ">>> Preparing source tmp directory ..."
  if $LOCAL_SRC; then
    mkdir -p "$SRC_TMP_PATH"
  else
    ssh_src "mkdir -p '$SRC_TMP_PATH'"
  fi

  echo ">>> Ensuring source artifact does not already exist: $remote_src_file"
  if $LOCAL_SRC; then
    if [[ -e "$remote_src_file" ]]; then
      echo "ERROR: Source artifact file already exists: $remote_src_file" >&2
      exit 1
    fi
  else
    ssh_src "test ! -e '$remote_src_file'" || {
      echo "ERROR: Source artifact file already exists: $SRC:$remote_src_file" >&2
      exit 1
    }
  fi

  echo ">>> Exporting Docker volume on source via tar (xz compressed) ..."
  if $LOCAL_SRC; then
    ensure_helper_image_src
    if $SRC_DOCKER_BECOME; then
      sudo docker run --rm \
        -v "$OBJECT_NAME":/source:ro \
        -v "$SRC_TMP_PATH":/backup \
        "$HELPER_IMAGE" tar cJvf "/backup/$(basename "$remote_src_file")" -C /source .
    else
      docker run --rm \
        -v "$OBJECT_NAME":/source:ro \
        -v "$SRC_TMP_PATH":/backup \
        "$HELPER_IMAGE" tar cJvf "/backup/$(basename "$remote_src_file")" -C /source .
    fi
    sudo chmod 644 "$remote_src_file" 2>/dev/null || chmod 644 "$remote_src_file" 2>/dev/null || true
  else
    ensure_helper_image_src
    if $SRC_DOCKER_BECOME; then
      ssh_src "sudo docker run --rm \
        -v '$OBJECT_NAME':/source:ro \
        -v '$SRC_TMP_PATH':/backup \
        '$HELPER_IMAGE' tar cJvf '/backup/$(basename \"$remote_src_file\")' -C /source ."
    else
      ssh_src "docker run --rm \
        -v '$OBJECT_NAME':/source:ro \
        -v '$SRC_TMP_PATH':/backup \
        '$HELPER_IMAGE' tar cJvf '/backup/$(basename \"$remote_src_file\")' -C /source ."
    fi
    ssh_src "sudo chmod 644 '$remote_src_file' 2>/dev/null || chmod 644 '$remote_src_file' 2>/dev/null || true"
  fi

  SRC_FILES+=("$remote_src_file")

  if $CHUNKING_ENABLED; then
    echo ">>> Creating chunks directory and splitting tar.xz on source ..."
    remote_src_chunks_dir="${SRC_TMP_PATH}/docker-chunks-${SANITIZED_NAME}-${TIMESTAMP}"
    if $LOCAL_SRC; then
      mkdir -p "$remote_src_chunks_dir"
      split -b "$CHUNK_SIZE_BYTES" -d -a 4 "$remote_src_file" "$remote_src_chunks_dir/chunk_"
    else
      ssh_src "mkdir -p '$remote_src_chunks_dir'"
      ssh_src "split -b ${CHUNK_SIZE_BYTES} -d -a 4 '$remote_src_file' '$remote_src_chunks_dir/chunk_'"
    fi

    SRC_CHUNK_DIRS+=("$remote_src_chunks_dir")

    local_chunks_dir="${WORKDIR}/$(basename "$remote_src_chunks_dir")"
    mkdir -p "$local_chunks_dir"

    if $LOCAL_SRC; then
      echo ">>> Copying chunks directory from source tmp -> local workdir ..."
      cp -a "$remote_src_chunks_dir/." "$local_chunks_dir/"
    else
      echo ">>> rsync chunks directory from source -> local ..."
      rsync_from_src "${SRC}:${remote_src_chunks_dir}/" "$local_chunks_dir/"
    fi

    LOCAL_CHUNK_DIRS+=("$local_chunks_dir")

    echo ">>> Preparing dest tmp directory and chunks dir on $DST ..."
    remote_dst_chunks_dir="${DST_TMP_PATH}/$(basename "$remote_src_chunks_dir")"
    ssh_dst "mkdir -p '$remote_dst_chunks_dir'"

    DST_CHUNK_DIRS+=("$remote_dst_chunks_dir")

    echo ">>> rsync chunks directory from local -> dest ..."
    rsync_to_dst "$local_chunks_dir/" "${DST}:${remote_dst_chunks_dir}/"

    echo ">>> Ensuring dest tar.xz file does not already exist: $remote_dst_file"
    ssh_dst "test ! -e '$remote_dst_file'" || {
      echo "ERROR: Dest artifact file already exists: $DST:$remote_dst_file" >&2
      exit 1
    }

    echo ">>> Reassembling tar.xz on dest via cat ..."
    ssh_dst "cat '$remote_dst_chunks_dir'/chunk_* > '$remote_dst_file'"

  else
    echo ">>> Ensuring local artifact does not already exist: $local_file"
    if [[ -e "$local_file" ]]; then
      echo "ERROR: Local artifact file already exists: $local_file" >&2
      exit 1
    fi

    if $LOCAL_SRC; then
      echo ">>> Copying tar.xz from source tmp -> local workdir ..."
      cp -a "$remote_src_file" "$local_file"
    else
      echo ">>> rsync tar.xz from source -> local ..."
      rsync_from_src "${SRC}:${remote_src_file}" "$local_file"
    fi

    LOCAL_FILES+=("$local_file")

    echo ">>> Preparing dest tmp directory on $DST ..."
    ssh_dst "mkdir -p '$DST_TMP_PATH'"

    echo ">>> Ensuring dest artifact does not already exist: $remote_dst_file"
    ssh_dst "test ! -e '$remote_dst_file'" || {
      echo "ERROR: Dest artifact file already exists: $DST:$remote_dst_file" >&2
      exit 1
    }

    echo ">>> rsync tar.xz from local -> dest ..."
    rsync_to_dst "$local_file" "${DST}:${remote_dst_file}"
  fi

  DST_FILES+=("$remote_dst_file")

  echo ">>> Creating Docker volume on dest if it does not exist ..."
  if $DST_DOCKER_BECOME; then
    ssh_dst "sudo docker volume create '$OBJECT_NAME' >/dev/null"
  else
    ssh_dst "docker volume create '$OBJECT_NAME' >/dev/null"
  fi

  echo ">>> Importing data into Docker volume on dest via tar xJvf ..."
  ensure_helper_image_dst
  if $DST_DOCKER_BECOME; then
    ssh_dst "sudo docker run --rm \
      -v '$OBJECT_NAME':/dest \
      -v '$DST_TMP_PATH':/backup \
      '$HELPER_IMAGE' bash -c 'cd /dest && tar xJvf /backup/$tar_filename'"
  else
    ssh_dst "docker run --rm \
      -v '$OBJECT_NAME':/dest \
      -v '$DST_TMP_PATH':/backup \
      '$HELPER_IMAGE' bash -c 'cd /dest && tar xJvf /backup/$tar_filename'"
  fi

  echo ">>> Docker volume transfer completed successfully."
}

safe_rm_local_under() {
  local path="$1"
  local base="$2"
  local label="$3"

  if [[ -z "$path" ]]; then
    echo "WARNING: Skipping empty $label path" >&2
    return
  fi

  case "$path" in
    "$base"/*)
      if [[ -e "$path" ]]; then
        rm -rf -- "$path" || echo "WARNING: Failed to delete $label $path" >&2
      fi
      ;;
    *)
      echo "WARNING: Refusing to delete $label outside $base: $path" >&2
      ;;
  esac
}

maybe_cleanup() {
  if (( ${#SRC_FILES[@]} == 0 && ${#SRC_CHUNK_DIRS[@]} == 0 \
      && ${#DST_FILES[@]} == 0 && ${#DST_CHUNK_DIRS[@]} == 0 \
      && ${#LOCAL_FILES[@]} == 0 && ${#LOCAL_CHUNK_DIRS[@]} == 0 )); then
    return 0
  fi

  if ! $DELETE_MODE && ! $IN_CLEANUP; then
    echo
    echo "Do you want to delete temporary artifacts (tar files and chunk dirs) on src/dst/local?"
    read -r -p "[y/N]: " ans
    case "$ans" in
      [yY][eE][sS]|[yY]) ;;
      *)
        echo "Skipping deletion of temporary artifacts."
        return 0
        ;;
    esac
  fi

  echo
  echo ">>> Deleting temporary artifacts ..."

  # Local files
  for f in "${LOCAL_FILES[@]}"; do
    safe_rm_local_under "$f" "$WORKDIR" "local file"
  done
  # Local chunk dirs
  for d in "${LOCAL_CHUNK_DIRS[@]}"; do
    safe_rm_local_under "$d" "$WORKDIR" "local chunk dir"
  done

  # Source side
  if $LOCAL_SRC; then
    for f in "${SRC_FILES[@]}"; do
      safe_rm_local_under "$f" "$SRC_TMP_PATH" "source file (local)"
    done
    for d in "${SRC_CHUNK_DIRS[@]}"; do
      safe_rm_local_under "$d" "$SRC_TMP_PATH" "source chunk dir (local)"
    done
  else
    for f in "${SRC_FILES[@]}"; do
      ssh_src "case '$f' in '$SRC_TMP_PATH'/*) if [ -f '$f' ]; then rm -f '$f' || true; fi ;; *) echo 'WARNING: Refusing to delete unsafe source file: $f' >&2 ;; esac" || \
        echo "WARNING: Failed to delete source file $SRC:$f" >&2
    done
    for d in "${SRC_CHUNK_DIRS[@]}"; do
      ssh_src "case '$d' in '$SRC_TMP_PATH'/*) if [ -d '$d' ]; then rm -rf '$d' || true; fi ;; *) echo 'WARNING: Refusing to delete unsafe source dir: $d' >&2 ;; esac" || \
        echo "WARNING: Failed to delete source chunk dir $SRC:$d" >&2
    done
  fi

  # Dest files
  for f in "${DST_FILES[@]}"; do
    ssh_dst "case '$f' in '$DST_TMP_PATH'/*) if [ -f '$f' ]; then rm -f '$f' || true; fi ;; *) echo 'WARNING: Refusing to delete unsafe dest file: $f' >&2 ;; esac" || \
      echo "WARNING: Failed to delete dest file $DST:$f" >&2
  done
  # Dest chunk dirs
  for d in "${DST_CHUNK_DIRS[@]}"; do
    ssh_dst "case '$d' in '$DST_TMP_PATH'/*) if [ -d '$d' ]; then rm -rf '$d' || true; fi ;; *) echo 'WARNING: Refusing to delete unsafe dest dir: $d' >&2 ;; esac" || \
      echo "WARNING: Failed to delete dest chunk dir $DST:$d" >&2
  done

  echo ">>> Temporary artifacts cleanup attempt completed."
}

case "$MODE" in
  image)
    transfer_image
    ;;
  volume)
    transfer_volume
    ;;
esac

echo
echo "=================================================="
echo "Transfer complete. The following artifact paths were created:"
echo

if ((${#SRC_FILES[@]})) || ((${#SRC_CHUNK_DIRS[@]})); then
  if $LOCAL_SRC; then
    echo "On SOURCE (local machine):"
    for path in "${SRC_FILES[@]}"; do
      echo "  FILE: $path"
    done
    for path in "${SRC_CHUNK_DIRS[@]}"; do
      echo "  CHUNK DIR: $path"
    done
  else
    echo "On SOURCE host ($SRC):"
    for path in "${SRC_FILES[@]}"; do
      echo "  FILE: $SRC:$path"
    done
    for path in "${SRC_CHUNK_DIRS[@]}"; do
      echo "  CHUNK DIR: $SRC:$path"
    done
  fi
  echo
fi

if ((${#DST_FILES[@]})) || ((${#DST_CHUNK_DIRS[@]})); then
  echo "On DEST host ($DST):"
  for path in "${DST_FILES[@]}"; do
    echo "  FILE: $DST:$path"
  done
  for path in "${DST_CHUNK_DIRS[@]}"; do
    echo "  CHUNK DIR: $DST:$path"
  done
  echo
fi

if ((${#LOCAL_FILES[@]})) || ((${#LOCAL_CHUNK_DIRS[@]})); then
  echo "On LOCAL machine (workdir artifacts):"
  for path in "${LOCAL_FILES[@]}"; do
    echo "  FILE: $path"
  done
  for path in "${LOCAL_CHUNK_DIRS[@]}"; do
    echo "  CHUNK DIR: $path"
  done
  echo
fi

maybe_cleanup

echo "=================================================="
echo "Done."

