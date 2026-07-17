# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) — builds ON TOP of the org C/C++ base image
# (ghcr.io/mayhemheroes/base), which already provides debian + clang/llvm + libFuzzer/afl++ +
# the identities + the build-contract ENV. This only adds the per-commit UHDM build.
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t uhdm-commit:test .

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an empty value
# breaks clang ("must be a non-negative decimal integer"). build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default.
# --build-arg SANITIZER_FLAGS="..." overrides it; an undefaulted ARG (no '=') lets the base ENV flow
# through to build.sh when not passed.
ARG SANITIZER_FLAGS
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# UHDM's CMake model-code generation (scripts/generate.py) requires the Python `orderedmultidict`
# package. Install it as root before the build (re-pin apt to SOURCE_DATE_EPOCH for reproducibility
# when set — repro-sources-list.sh ships in the base). It is a pure-Python dep available from apt.
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
      python3-orderedmultidict \
 && rm -rf /var/lib/apt/lists/* \
 && install -d -o mayhem -g mayhem /opt/toolchains/uhdm-capnp
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history) is
# copied to /mayhem as `mayhem`; build.sh builds in place (and inits the vendored submodules).
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

# UHDM_CAPNP_PREFILL=1: this first build also compiles the VENDORED capnproto once into
# /opt/toolchains/uhdm-capnp with the build's own flags, stamped with a hash of its sources + flags
# (see build.sh). The graded offline re-runs reuse it only while that stamp still matches the tree;
# otherwise they build capnproto from third_party/ in-tree. UHDM's own code is always rebuilt.
RUN UHDM_CAPNP_PREFILL=1 bash mayhem/build.sh

# Lock the prebuilt dependency: root-owned and read-only, so nothing at the PATCH tier can alter it.
USER root
RUN chown -R root:root /opt/toolchains/uhdm-capnp && chmod -R a-w,a+rX /opt/toolchains/uhdm-capnp
USER mayhem

# Run the project's functional tests at build time (mayhem/test.sh is present — UHDM ships a real
# GoogleTest suite). A failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
