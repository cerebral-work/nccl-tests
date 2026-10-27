#!/bin/bash
###
#SBATCH --job-name=scorcher_bench
#SBATCH --nodes=8
#SBATCH --ntasks-per-node=1
#SBATCH --gpus-per-node=8
#SBATCH --time=20:00
#SBATCH --output="%x_%j.out" # Use %x for job name and %j for slurm job ID in output file name
#SBATCH --exclusive # Use --exclusive to ensure no other jobs run on the same nodes

# One scorcher process per node. No MPI, so no --mpi=pmix and no NCCL_/UCX_ exports.

# Image: pinned by digest, pulled from the private Harbor registry.
scorcher_digest="sha256:c24561a00914fa50ad7d45900786e24d5c6f961226c0b1c4331fc0541a76c048"

# Enroot credentials for the private registry.
# Enroot reads $ENROOT_CONFIG_PATH/.credentials on the node that runs `enroot import`
# (the allocation head node). Add one netrc line, file mode 0600:
#   machine harbor.unsigned.gg login <robot> password <token>
# The digest-import syntax below (docker://host#path@sha256:...) has not been
# tested: enroot is not available where this was written. Confirm it on the
# Slurm head node before the first real run.

# Create a directory to store container images. You can change this
# or use an existing directory below.

CONTAINER_DIR="$(realpath -s images)"
mkdir -p "$CONTAINER_DIR"
fstype="$(stat '-fc%T' "$CONTAINER_DIR")"
if [ "$fstype" != "nfs" ] ; then
  echo 'You must specify a container directory that is mounted on all cluster nodes.' >&2
  exit 1
fi

# Pull the container image, if not already pulled. For large parallel jobs, this
# will save time by not hitting the repository from each task. This will
# be executed once on the head node of the allocation.

CONTAINER_IMAGE="${CONTAINER_DIR}/scorcher_${scorcher_digest#sha256:}.sqsh"
if [ -f "$CONTAINER_IMAGE" ]; then
   echo "Container image for scorcher $scorcher_digest already exists, no need to pull."
else
   echo "Pulling container image for scorcher: $scorcher_digest and saving to $CONTAINER_IMAGE"
   if ! enroot import -o "$CONTAINER_IMAGE" "docker://harbor.unsigned.gg#platform/scorcher@${scorcher_digest}"; then
       echo "Failed to pull container image: harbor.unsigned.gg/platform/scorcher@${scorcher_digest}" >&2
       exit 1
   fi
fi

# Per-node JSON results land here, one file per hostname.
RESULTS_DIR="${RESULTS_DIR:-$(realpath -s results)/${SLURM_JOB_ID:-manual}}"
mkdir -p "$RESULTS_DIR"

# Log the assigned nodes
echo "Using nodes: $SLURM_JOB_NODELIST"

# The srun command inherits the SBATCH flags set above
# and will be launched once on each of the 8 B200 nodes. The image has no shell, so
# scorcher expands the {hostname} token in --output itself, once per process.

srun --container-image="$CONTAINER_IMAGE" \
     --container-mounts="$RESULTS_DIR:/results" \
     --no-container-mount-home --kill-on-bad-exit=1 \
     /usr/local/bin/scorcher bench --iters 1000 --json --output "/results/{hostname}.json"
