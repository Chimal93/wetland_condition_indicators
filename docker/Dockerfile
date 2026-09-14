# Pinned environment for the wetland_condition_indicators pipelines.
#
# Three layers of pinning, each recorded:
#   1. rocker/geospatial:4.6.1 pins R and the system GDAL/GEOS/PROJ that
#      sf and terra link against (README says the code targets R 4.6).
#   2. renv.lock (repo root) pins every R package version; it is the same
#      lockfile Windows/RStudio users restore from, so both audiences get
#      identical package versions.
#   3. The lockfile's repository is a dated Posit Package Manager snapshot.
#
# Build from the REPO ROOT so renv.lock is in the build context:
#   docker build -f docker/Dockerfile -t wetland-indicators:r4.6.1 .
FROM rocker/geospatial:4.6.1

# renv downloads GitHub sources (ecTools) with the curl binary, which the base image lacks.
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Restore the lockfile into the image's system library, so scripts run from
# any subfolder see the packages without renv activation.
COPY renv.lock /tmp/renv/renv.lock
# Optional: --build-arg GITHUB_PAT=... to avoid GitHub API rate limits. An
# EMPTY value must not reach R: renv would then send an empty auth header,
# which GitHub rejects with 401.
ARG GITHUB_PAT=""
RUN if [ -z "$GITHUB_PAT" ]; then unset GITHUB_PAT; fi; Rscript -e ' \
      install.packages("renv", quiet = TRUE); \
      renv::restore(project = "/tmp/renv", lockfile = "/tmp/renv/renv.lock", \
                    library = .libPaths()[1], prompt = FALSE); \
      stopifnot(requireNamespace("ecTools"), requireNamespace("osmextract"), requireNamespace("RANN"))' \
    && rm -rf /tmp/renv /tmp/downloaded_packages

# Inside the container the packages live in the system library, so the
# repo's .Rprofile must not switch R to an (empty) renv project library.
ENV RENV_CONFIG_AUTOLOADER_ENABLED=FALSE \
    R_DEFAULT_INTERNET_TIMEOUT=7200 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

WORKDIR /work
