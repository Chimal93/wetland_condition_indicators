#!/usr/bin/env bash
# Check, BEFORE starting a run, that everything the selected indicators need
# is in place. Some inputs cannot be downloaded automatically (restricted
# access or publisher's supplementary material), and without this check a
# run would only fail or skip an indicator hours in.
#
# Prints one line per item (OK or MISSING) and, for every missing item,
# exactly what to do. Exits with an error if anything is missing.
# run_indicators.sh runs this automatically; you can also run it yourself:
#
#   bash docker/check_setup.sh                       # for the configured indicators
#   INDICATORS="GJEN" bash docker/check_setup.sh     # for one indicator
#
# Settings come from docker/config.env and docker/config.local.env.
set -u
DOCKER_DIR=$(cd "$(dirname "$0")" && pwd); REPO_DIR=$(cd "$DOCKER_DIR/.." && pwd)
if [ -f "$DOCKER_DIR/config.local.env" ]; then set -a; . "$DOCKER_DIR/config.local.env"; set +a; fi
set -a; . "$DOCKER_DIR/config.env"; set +a

missing=0
ok()   { echo "OK       $1"; }
miss() { echo "MISSING  $1"; missing=1; }
want() { [[ " $INDICATORS " == *" $1 "* ]]; }

echo "Checking setup for INDICATORS=\"$INDICATORS\" GJEN_SOURCE=$GJEN_SOURCE"
echo

# ---- Docker image ----------------------------------------------------------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ok "Docker image $IMAGE"
else
  miss "Docker image $IMAGE"
  echo "         Build it (a few minutes, needs internet):"
  echo "           bash docker/build_image.sh"
fi

# ---- NO_FUNC_003: Tyler et al. (2021) spreadsheet, manual download --------
if want FUNC; then
  f=NO_FUNC_003/data/OpenS_data/Tyler_data_raw.xlsx
  if [ -f "$REPO_DIR/$f" ]; then
    ok "NO_FUNC_003: $f"
  else
    miss "NO_FUNC_003: $f"
    echo "         The indicator values of Tyler et al. (2021) are the publisher's"
    echo "         supplementary material and cannot be downloaded by a script."
    echo "         1. Open https://doi.org/10.1016/j.ecolind.2020.106923"
    echo "         2. Under 'Supplementary material' / 'Appendix A', download the"
    echo "            spreadsheet that contains the \"Taxa\" sheet."
    echo "         3. Save it, unchanged and still .xlsx, as:"
    echo "              $REPO_DIR/$f"
    echo "         Then check the file with:"
    echo "           bash docker/run_script.sh NO_FUNC_003/R/get_tyler_data.R"
  fi
fi

# ---- NO_CONN_003: nothing manual (caches are downloaded by the runner) -----
if want CONN; then
  ok "NO_CONN_003: no manual inputs (about 2 GB of caches are downloaded on the first run)"
fi

# ---- NO_GJEN_002: nothing manual (NiN and bioclim are downloaded) --------
if want GJEN2; then
  ok "NO_GJEN_002: no manual inputs (recomputed from the committed canopy heights)"
fi

# ---- NO_GJEN_001: AR5 forest/mire layers, restricted access ---------------
if want GJEN; then
  case "$GJEN_SOURCE" in
    AR5)
      d=NO_GJEN_001/data/OpenS_data
      if [ -f "$REPO_DIR/$d/ar5_skog_national.gpkg" ] && [ -f "$REPO_DIR/$d/ar5_myr_national.gpkg" ]; then
        ok "NO_GJEN_001: $d/ar5_skog_national.gpkg and ar5_myr_national.gpkg"
      else
        miss "NO_GJEN_001: $d/ar5_skog_national.gpkg and ar5_myr_national.gpkg"
        echo "         GJEN_SOURCE=AR5 needs the national AR5 forest and mire layers."
        echo "         AR5 (FKB-AR5) has restricted access and cannot be downloaded here."
        echo "         If you have the municipal FKB-AR5 GeoPackages, build the layers with"
        echo "         (about 15 minutes):"
        echo "           bash docker/prepare_ar5_input/subset_and_merge_municipal_ar5.sh /path/to/FKB-AR5-folder"
        echo "         If you do not have FKB-AR5, use the public AR50 map instead:"
        echo "           GJEN_SOURCE=AR50 bash docker/run_indicators.sh"
        echo "         (or put GJEN_SOURCE=AR50 in docker/config.local.env)."
      fi ;;
    AR50)
      ok "NO_GJEN_001: GJEN_SOURCE=AR50, no manual inputs (AR50 is downloaded on the first run)" ;;
    *)
      miss "NO_GJEN_001: GJEN_SOURCE='$GJEN_SOURCE' is not valid (use AR5 or AR50)" ;;
  esac
fi

echo
if [ "$missing" -eq 0 ]; then
  echo "Everything needed is in place."
else
  echo "Something is missing (see above). Fix it, then run the check again."
  exit 1
fi
