# ============================================================
# NO_CONN_001 - CERTIFIED nearest-neighbour distance via centroid
# pre-filter + provably-correct fallback for the small minority of rows
# where the pre-filter can't be trusted.
#
# BACKGROUND: nn_distance_centroid_prefilter() (pure centroid k-NN) was
# validated against exact ground truth twice - Femundsmarka (sparse test
# AOI, converged to 0 mismatches by k=50) and a real 20km Sørlandet
# window at true regional density (~6,350 polygons - NOT converging to
# zero even at k=600: still 0.276% mismatched, with individual errors up
# to tens of thousands of metres for elongated/irregular polygon shapes).
# A second real bug (unrelated MULTIPOLYGON mis-grouping from
# terra::patches() under chunked processing, since fixed at the source
# - the simplified per-region caches this reads no longer have it)
# explained PART of this, but a genuine residual approximation-error
# rate remained after that fix too.
# Given this pipeline's own documentation already flags that precision
# matters most exactly where min_myr_distance is small (near-touching
# polygons), an uncertified ~1% error rate isn't acceptable - this
# function makes the result exact everywhere, not just "usually right."
#
# CERTIFICATION, not just a heuristic threshold: for polygon i, let
#   r_k        = centroid distance to the k-th (furthest checked) candidate
#   approx_i   = true min boundary distance among the k checked candidates
#   R_i        = polygon i's own "reach" (max distance from ITS centroid
#                to any of its own vertices)
#   R_max      = the largest such reach among all UNCHECKED candidates
# By the triangle inequality, for ANY unchecked candidate j: boundary_
# distance(i,j) >= centroid_distance(i,j) - R_i - R_j >= r_k - R_i -
# R_max. So if r_k - R_i - R_max >= approx_i, no unchecked candidate can
# possibly beat approx_i - PROVEN, not just probably right. Rows that
# don't meet this bound fall back to a certified growing-buffer exact
# search (nn_distance_exact_for_subset(), below).
#
# GIANT-OUTLIER SEPARATION (added 2026-08-14, after a 43-hour real-world
# incident): a first full-Sørlandet attempt used a single GLOBAL R_max
# across all 374,397 polygons. Checked directly (2026-08-14): full-scale
# max reach is 5,056m - far worse than the 2,376m a smaller 6,351-polygon
# test window suggested - because the true worst-case outlier polygons
# aren't evenly distributed and a small window can easily miss them. That
# run only certified 25.2% of rows at k=600 (vs. 99.7% predicted from the
# small window), pushing 280,118 rows into the slow per-row fallback -
# which then ran 43+ hours with no progress signal before being killed.
# FIX: separate out the rare large-reach "giant" polygons (R > 500m -
# checked directly: only 837 of 374,397, 0.22%) from the general
# population. Giants are ALWAYS included as forced candidates for EVERY
# row (cheap - 837 extra exact-distance checks per row, a bounded, known
# cost), so the general certification bound only needs to defend against
# unchecked NON-giant candidates, whose reach is bounded by R_max_typical
# (499m at this threshold) instead of the punishing global 5,056m. This
# is what makes high certification rates achievable at full national
# scale, not just on a small test window.
# ============================================================

library(sf)
library(dplyr)

if (!requireNamespace("RANN", quietly = TRUE)) stop("RANN package required")

#' Max distance from each polygon's own centroid to any of its own
#' vertices ("reach" R_i in the header comment).
polygon_reach <- function(x) {
  centroids <- st_centroid(st_geometry(x))
  cc <- st_coordinates(centroids)
  vapply(seq_len(nrow(x)), function(i) {
    vc <- st_coordinates(x[i, ])[, 1:2, drop = FALSE]
    max(sqrt((vc[, 1] - cc[i, 1])^2 + (vc[, 2] - cc[i, 2])^2))
  }, numeric(1))
}

#' Exact nearest-OTHER-polygon distance for a subset of rows (by index)
#' within the full set `x`, via a certified growing-buffer search:
#' buffer by r, find candidates via the spatial index (st_intersects,
#' fast), take exact min distance among them; if that min is <= r, it's
#' certified correct (nothing outside the buffer could be closer);
#' otherwise grow r and retry. Now with real progress logging (added
#' 2026-08-14 - the previous version's total silence during a 43-hour
#' real run made it impossible to tell whether it was almost done or
#' barely started; never again).
nn_distance_exact_for_subset <- function(x, idx, initial_r = 300, growth = 4,
                                          max_r = 200000, verbose = TRUE) {
  out <- numeric(length(idx))
  t0 <- Sys.time()
  log_every <- max(1L, round(length(idx) / 200))
  for (ii in seq_along(idx)) {
    i <- idx[ii]
    r <- initial_r
    repeat {
      buf <- st_buffer(x[i, ], r)
      hits <- st_intersects(buf, x, sparse = TRUE)[[1]]
      hits <- hits[hits != i]
      if (length(hits) > 0) {
        dmin <- min(as.numeric(st_distance(x[i, ], x[hits, ])))
        if (dmin <= r) { out[ii] <- dmin; break }
      }
      if (r >= max_r) {
        dall <- as.numeric(st_distance(x[i, ], x[-i, ]))
        out[ii] <- min(dall)
        break
      }
      r <- r * growth
    }
    if (verbose && (ii %% log_every == 0 || ii == length(idx))) {
      elapsed <- as.numeric(difftime(Sys.time(), t0, units = "secs"))
      eta <- elapsed / ii * (length(idx) - ii)
      cat("    fallback row", ii, "/", length(idx), "- [timing]", round(elapsed, 1),
          "sec elapsed, ETA", round(eta / 60, 1), "min\n")
    }
  }
  out
}

#' Certified nearest-OTHER-polygon distance for every row in `x`. Exact
#' for every row, not approximate - see header for the proof sketch.
#'
#' @param x sf polygon object
#' @param k number of centroid-nearest candidates to check per polygon
#'   before falling back to exact search, IN ADDITION to the always-
#'   checked giant set (see giant_threshold_m below). DEFAULT 75 -
#'   re-validated 2026-08-14 after adding giant separation: k=75 alone
#'   (no longer needing k=600) now certifies 99.5% of rows on the real
#'   Sørlandet-density test window (vs. ~2% before giant separation),
#'   with 0 mismatches against exact ground truth - giants, not k, were
#'   always the real lever.
#' @param giant_threshold_m polygons with reach above this are treated
#'   as "giants" - always checked as a forced candidate for every row,
#'   and excluded from the R_max used in the general certification bound.
#'   500m default, chosen from the real full-scale Sørlandet reach
#'   distribution (2026-08-14): only 0.22% of polygons exceed it, and
#'   excluding them drops the effective bound from 5,056m to 499m.
nn_distance_certified <- function(x, k = 75, verbose = TRUE, batch_size = 8000,
                                   giant_threshold_m = 500) {
  n <- nrow(x)
  if (n < 2) stop("Need at least 2 polygons.")
  k <- min(k, n - 1)

  centroids <- st_centroid(st_geometry(x))
  coords <- st_coordinates(centroids)
  nn <- RANN::nn2(data = coords, query = coords, k = k + 1)
  cand_idx  <- nn$nn.idx
  cand_dist <- nn$nn.dists  # ascending per row; column 1 is self (dist 0)

  if (verbose) cat("  Computing per-polygon reach bounds...\n")
  R <- polygon_reach(x)
  giant_idx <- which(R > giant_threshold_m)
  R_max_typical <- if (length(giant_idx) < n) max(R[-giant_idx]) else max(R)
  if (verbose) {
    cat("  Giant polygons (reach >", giant_threshold_m, "m):", length(giant_idx),
        "of", n, "(", round(100 * length(giant_idx) / n, 3), "% ) - always checked directly.\n")
    cat("  R_max_typical (excl. giants):", round(R_max_typical), "m",
        "(vs. global max", round(max(R)), "m)\n")
  }
  n_giants <- length(giant_idx)

  # BATCHED pre-filter distance pass: k-nearest-by-centroid candidates
  # PLUS every giant polygon (forced), processed in fixed-size row
  # batches with an explicit gc() each batch - a real memory leak was
  # found and fixed here 2026-08-12 (large temporary sf subset objects
  # weren't being reclaimed promptly by R's GC in a tight loop; without
  # batching+gc(), RSS grew past 14GB on a full-region run).
  n_batches <- ceiling(n / batch_size)
  approx_dist <- numeric(n)
  t_batch0 <- Sys.time()
  for (b in seq_len(n_batches)) {
    rows_b <- ((b - 1) * batch_size + 1):min(b * batch_size, n)

    # k-NEAREST candidates: flattened by_element pairs (as before) - these
    # are distinct candidates per row, no duplication concern.
    cand_b <- cand_idx[rows_b, , drop = FALSE]
    i_vec <- rep(rows_b, times = k + 1)
    j_vec <- as.vector(cand_b)
    keep  <- i_vec != j_vec
    i_vec <- i_vec[keep]; j_vec <- j_vec[keep]
    d <- as.numeric(st_distance(x[i_vec, ], x[j_vec, ], by_element = TRUE))
    batch_min <- as.numeric(tapply(d, i_vec, min)[as.character(rows_b)])
    rm(i_vec, j_vec, keep, cand_b, d)

    # GIANTS: a real crash was found and fixed here (2026-08-14) - the
    # original version added giants to the SAME flattened by_element pair
    # list, which means each giant polygon's full (large, complex)
    # geometry gets duplicated once per query row in the batch (up to
    # 8,000x) before st_distance() ever runs - giants are by definition
    # the most vertex-heavy polygons, so this duplication blew memory out
    # (std::bad_alloc) on the very first batch of a full-region run, even
    # though the raw PAIR COUNT looked modest. Fixed by computing giant
    # distances as a proper x-by-y CROSS-DISTANCE MATRIX instead
    # (st_distance(rows, giants), no by_element) - GEOS iterates the
    # cross-product internally without any R-level geometry duplication.
    if (n_giants > 0) {
      gmat <- st_distance(x[rows_b, ], x[giant_idx, ])
      gmat <- matrix(as.numeric(gmat), nrow = length(rows_b))
      # self-exclusion: if a row in this batch IS itself a giant, blank
      # out its own self-distance (0) before taking the row minimum.
      self_pos <- match(rows_b, giant_idx)
      has_self <- !is.na(self_pos)
      if (any(has_self)) gmat[cbind(which(has_self), self_pos[has_self])] <- Inf
      giant_min <- apply(gmat, 1, min)
      batch_min <- pmin(batch_min, giant_min)
      rm(gmat, giant_min)
    }

    approx_dist[rows_b] <- batch_min
    rm(batch_min)
    gc(verbose = FALSE)

    if (verbose) {
      elapsed <- as.numeric(difftime(Sys.time(), t_batch0, units = "secs"))
      eta <- elapsed / b * (n_batches - b)
      mem_mb <- round(sum(gc()[, 2]))
      cat("  batch", b, "/", n_batches, "- [timing]", round(elapsed, 1),
          "sec elapsed, ETA", round(eta / 60, 1), "min, mem", mem_mb, "MB\n")
    }
  }

  r_k <- cand_dist[, k + 1]  # furthest KNN-checked centroid distance, per row
  # Giants are always checked directly regardless of r_k, so the bound
  # only needs to defend against unchecked NON-giant candidates - hence
  # R_max_typical, not the punishing global max.
  certified_ok <- (r_k - R - R_max_typical) >= approx_dist
  flagged <- which(!certified_ok)

  if (verbose) {
    cat("  Pre-filter (k=", k, " + ", n_giants, " giants): ", n - length(flagged), " of ", n,
        " rows certified correct (", round(100 * (n - length(flagged)) / n, 2),
        "% ), ", length(flagged), " flagged for exact fallback.\n", sep = "")
  }

  if (length(flagged) > 0) {
    t0 <- Sys.time()
    exact_vals <- nn_distance_exact_for_subset(x, flagged, verbose = verbose)
    approx_dist[flagged] <- exact_vals
    if (verbose) cat("  [timing] exact fallback for", length(flagged), "rows:",
                      round(as.numeric(difftime(Sys.time(), t0, units = "secs")), 1), "sec\n")
  }

  approx_dist
}
