# Pinned environment for the wetland_condition_indicators pipelines.
#
# Three layers of pinning, each recorded:
#   1. rocker/geospatial:4.6.1 pins R and the system GDAL/GEOS/PROJ that
#      sf and terra link against (README says the code targets R 4.6).
#      The tag alone is not enough: rocker republishes it (it changed
#      between 2026-09-15 and 2026-10-01), so the image is pinned by
#      digest. To move to a newer base on purpose, look up the digest with
#        docker buildx imagetools inspect rocker/geospatial:<tag>
#      and replace both the tag and the digest below.
#   2. Each indicator's renv.lock (NO_*/renv.lock, maintained upstream)
#      pins its R package versions. They never disagree on a version, so
#      all of them are installed into one library and every indicator gets
#      exactly the versions in its own lockfile.
#   3. Each lockfile entry names a dated Posit Package Manager snapshot.
#
# Build from the REPO ROOT so the lockfiles are in the build context:
#   docker build -f docker/Dockerfile -t wetland-indicators:r4.6.1 .
FROM rocker/geospatial:4.6.1@sha256:e67737e30c66e6d2237570cd647e2bfec59315e533713473ab2ba391992bfa2c

# renv downloads GitHub sources (ecTools) with the curl binary, which the base image lacks.
RUN apt-get update && apt-get install -y --no-install-recommends curl && rm -rf /var/lib/apt/lists/*

# Restore the lockfiles into the image's system library, so scripts run
# from any subfolder see the packages without renv activation. NO_NDVI_001
# is not run by the runners, but its packages are installed too, so its
# scripts work with docker/run_script.sh.
COPY NO_FUNC_003/renv.lock /tmp/renv/NO_FUNC_003/renv.lock
COPY NO_CONN_003/renv.lock /tmp/renv/NO_CONN_003/renv.lock
COPY NO_GJEN_001/renv.lock /tmp/renv/NO_GJEN_001/renv.lock
COPY NO_GJEN_002/renv.lock /tmp/renv/NO_GJEN_002/renv.lock
COPY NO_NDVI_001/renv.lock /tmp/renv/NO_NDVI_001/renv.lock
# Optional: --build-arg GITHUB_PAT=... to avoid GitHub API rate limits. An
# EMPTY value must not reach R: renv would then send an empty auth header,
# which GitHub rejects with 401.
ARG GITHUB_PAT=""
RUN if [ -z "$GITHUB_PAT" ]; then unset GITHUB_PAT; fi; Rscript -e ' \
      install.packages("renv", quiet = TRUE); \
      for (ind in c("NO_FUNC_003", "NO_CONN_003", "NO_GJEN_001", "NO_GJEN_002", "NO_NDVI_001")) { \
        message("=== renv::restore for ", ind); \
        renv::restore(project = file.path("/tmp/renv", ind), \
                      lockfile = file.path("/tmp/renv", ind, "renv.lock"), \
                      library = .libPaths()[1], prompt = FALSE); \
      }; \
      stopifnot(requireNamespace("ecTools"), requireNamespace("osmextract"), requireNamespace("RANN"))' \
    && rm -rf /tmp/renv /tmp/downloaded_packages

ENV R_DEFAULT_INTERNET_TIMEOUT=7200 \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

WORKDIR /work
