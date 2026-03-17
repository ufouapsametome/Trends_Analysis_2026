/*
  district_trends_2026_step2
  v1.0
  adapted from
  trends_2025_district_step3_4_tipping_point_analysis
  v1.2
  adapted from trends_2025_step3_weighted_2030_model and trends_2025_step4_tally_scenarios

  ONLY NEEDS TO BE RUN ONCE

  Merges Step 3 (weighted model outputs) and Step 4 (tipping point identification)
  into a single query. Reads HD and SD core model outputs + baselines via UNION ALL,
  processes both chambers in one pass, and writes to a single combined output table.

  Step 3 logic: joins scenario deltas from Step 2 to election baselines from Step 1b,
  synthesizes NH floterial baselines from child district weights, computes
  new_weighted_share = dem_weighted_baseline + scenario_delta, ranks within state.

  Step 4 logic: assigns seat counts (NH multi-member, AZ 2-member house), computes
  cumulative seats, identifies median/crossover district per scenario, applies tipping
  point classification (TARGETING_BOX hybrid with soft margin decay), aggregates
  favorable/unfavorable tipping counts per district.

  Inputs:  core_model_outputs_hd, core_model_outputs_sd,
           combined_dem_baseline_hd, combined_dem_baseline_sd,
           NH district/floterial xrefs
  Output:  tipping_point_analysis (combined, has chamber column)
*/

-- OUTPUT MODE
DECLARE make_table_mode BOOL DEFAULT TRUE;

-- TIPPING MODE CONFIGURATION
--   'TARGETING_BOX' = Hybrid: soft targets (tiny margin) + strategic targets (rank + decay)
--   'MARGIN'        = Binary: within margin threshold of median
--   'RANK'          = Binary: within seat-rank band of median
--   'BOTH'          = Binary: meets either margin or rank criterion
DECLARE tipping_mode STRING DEFAULT 'TARGETING_BOX';

DECLARE tipping_margin_threshold FLOAT64 DEFAULT 0.025;

-- Rank-band fraction: percentage of total chamber seats defining the "near median" zone.
-- Uses total_chamber_districts (not seats) for bracket selection to handle multi-member
-- chambers correctly (e.g., AZ House: 30 districts × 2 seats).
DECLARE tipping_rank_fraction_small_chambers FLOAT64 DEFAULT 0.1;   -- <= 50 districts
DECLARE tipping_rank_fraction_large_chambers FLOAT64 DEFAULT 0.07;  -- > 50 districts

-- TARGETING_BOX parameters
DECLARE tipping_margin_include    FLOAT64 DEFAULT 0.015;  -- Soft targets: always include if margin < 1.5%
DECLARE tipping_margin_exclude    FLOAT64 DEFAULT 0.04;   -- Strategic targets: max margin (4%)
DECLARE tipping_margin_decay_width FLOAT64 DEFAULT 0.015; -- Linear decay zone beyond exclude (4.0% → 5.5%)

-- STATE FILTER (optional diagnostic restriction)
DECLARE restrict_to_states BOOL DEFAULT FALSE;
DECLARE state_filter ARRAY<STRING> DEFAULT
['AK','AZ','FL','GA','IA','KS','ME','MI','MN','NC','NH','NV','OH','PA','TX','VA','WI'];

-- Baseline scenario name (must exist with uniform_swing_scenario = 0)
DECLARE baseline_vote_choice_scenario STRING DEFAULT 'balanced_Baseline';

-- NH DATA QUALITY ASSERTION
-- Halt if NH present_day_baseline is missing or has NULL votes (floterial synthesis
-- would produce garbage). Only relevant for HD chamber.
BEGIN
  DECLARE nh_data_failure BOOL DEFAULT FALSE;

  SET nh_data_failure = (
    SELECT
      EXISTS (
        SELECT 1
        FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_hd`
        WHERE state = 'NH'
          AND vote_choice_scenario = 'present_day_baseline'
          AND (total_expected_votes IS NULL OR total_expected_votes = 0)
      ) OR NOT EXISTS (
        SELECT 1
        FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_hd`
        WHERE state = 'NH' AND vote_choice_scenario = 'present_day_baseline'
      )
  );

  IF nh_data_failure THEN
    RAISE USING MESSAGE = 'CRITICAL FAILURE: NH present_day_baseline data is missing or contains NULL votes. Floterial synthesis cannot proceed.';
  END IF;
END;

-- =============================================================================
-- MAIN QUERY
-- =============================================================================

CREATE OR REPLACE TABLE `proj-tmc-mem-fm.main.trends_2025_tipping_point_analysis` AS

WITH

  -- Load model outputs from both chambers
  model_outputs AS (
    SELECT *, 'hd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_hd`
    UNION ALL
    SELECT *, 'sd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_sd`
  ),

  -- Load baselines from both chambers.
  -- Non-NH states pass through. NH HD baselines get code→name translation.
  standard_baselines_raw_hd AS (
    SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_combined_dem_baseline_hd`
  ),
  standard_baselines_raw_sd AS (
    SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_combined_dem_baseline_sd`
  ),

  standard_baselines AS (
    -- HD: Non-NH states pass through
    SELECT *, 'hd' AS chamber FROM standard_baselines_raw_hd WHERE State != 'NH'
    UNION ALL
    -- HD: NH code→name translation (exclude floterials from xref)
    SELECT
      b.State,
      nx.voterbase_hd_name AS District,
      b.dem_weighted_baseline,
      b.share_20_pres,
      b.share_24_pres,
      b.share_other,
      'hd' AS chamber
    FROM standard_baselines_raw_hd b
    JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nx
      ON b.District = nx.HD
    WHERE b.State = 'NH'
      AND nx.HD != 'Floterial'
    UNION ALL
    -- SD: all states pass through (NH Senate has no floterial complexity)
    -- Add fix for AK Senate district format mismatch
SELECT
  State,
  CASE WHEN State = 'AK' THEN LTRIM(District, '0') ELSE District END AS District,
  * EXCEPT(State, District),
  'sd' AS chamber
FROM standard_baselines_raw_sd
  ),

  -- Synthesize baselines for NH floterial districts (HD only).
  -- Weighted average of component child districts using present_day_baseline vote counts.
  nh_floterial_baselines AS (
    SELECT
      'NH' AS State,
      CONCAT(fx.Floterial_HD_Name, ' (FLOTERIAL)') AS District,
      SAFE_DIVIDE(SUM(b.dem_weighted_baseline * m.total_expected_votes), SUM(m.total_expected_votes)) AS dem_weighted_baseline,
      SAFE_DIVIDE(SUM(b.share_20_pres * m.total_expected_votes), SUM(m.total_expected_votes)) AS share_20_pres,
      SAFE_DIVIDE(SUM(b.share_24_pres * m.total_expected_votes), SUM(m.total_expected_votes)) AS share_24_pres,
      SAFE_DIVIDE(SUM(b.share_other * m.total_expected_votes), SUM(m.total_expected_votes)) AS share_other,
      'hd' AS chamber
    FROM (
      SELECT district_number, total_expected_votes
      FROM model_outputs
      WHERE state = 'NH'
        AND chamber = 'hd'
        AND vote_choice_scenario = 'present_day_baseline'
        AND uniform_swing_scenario = 0
        AND district_number NOT LIKE '%(FLOTERIAL)%'
    ) m
    JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nm
      ON m.district_number = nm.voterbase_hd_name
    JOIN `proj-tmc-mem-fm.main.trends_2025_NH_Floterial_xref_corrected` fx
      ON nm.HD = fx.HD
    JOIN standard_baselines b
      ON b.State = 'NH'
      AND b.District = m.district_number
      AND b.chamber = 'hd'
    GROUP BY 1, 2
  ),

  all_baselines AS (
    SELECT * FROM standard_baselines
    UNION ALL
    SELECT * FROM nh_floterial_baselines
  ),

  -- Join model outputs to baselines, compute new_weighted_share, rank within state.
  -- Excludes present_day_baseline rows (those are Step 2's internal reference,
  -- not a forward-looking scenario).
  calculated_shares AS (
    SELECT
      m.state,
      m.district_level,
      CAST(m.district_number AS STRING) AS district_number,
      m.vote_choice_scenario,
      m.uniform_swing_scenario,
      b.dem_weighted_baseline,
      m.scenario_delta,
      (b.dem_weighted_baseline + m.scenario_delta) AS new_weighted_share,
      b.share_20_pres AS reference_share_20_pres,
      b.share_24_pres AS reference_share_24_pres,
      b.share_other   AS reference_share_other,
      m.chamber
    FROM model_outputs m
    JOIN all_baselines b
      ON m.state = b.State
      AND CAST(m.district_number AS STRING) = b.District
      AND m.chamber = b.chamber
    WHERE m.vote_choice_scenario != 'present_day_baseline'
  ),

  ranked AS (
    SELECT
      *,
      RANK() OVER (
        PARTITION BY state, chamber, vote_choice_scenario, uniform_swing_scenario
        ORDER BY new_weighted_share DESC
      ) AS rank_within_state_scenario
    FROM calculated_shares
  ),

  -- =========================================================================
  -- STEP 4 LOGIC: Seat counts, cumulative seats, tipping point flags
  -- =========================================================================

  -- Apply optional state filter
  base AS (
    SELECT *
    FROM ranked
    WHERE NOT restrict_to_states
       OR state IN UNNEST(state_filter)
  ),

  -- Seat counts: NH multi-member from xref, AZ House = 2, all others = 1
  with_seat_counts AS (
    SELECT
      b.*,
      CASE
        WHEN b.state = 'NH' AND b.chamber = 'hd'
          THEN COALESCE(nx.Count_Reps, 1)
        WHEN b.state = 'AZ' AND b.chamber = 'hd' THEN 2
        ELSE 1
      END AS seat_count
    FROM base b
    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nx
      ON b.state = 'NH'
      AND b.chamber = 'hd'
      AND nx.voterbase_hd_name = REPLACE(b.district_number, ' (FLOTERIAL)', '')
  ),

  -- Cumulative seat count (most Dem → least Dem) and chamber totals
  cumulative_calc AS (
    SELECT
      *,
      SUM(seat_count) OVER (
        PARTITION BY state, chamber, vote_choice_scenario, uniform_swing_scenario
        ORDER BY new_weighted_share DESC, district_number
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS cumulative_seat_count,

      SUM(seat_count) OVER (
        PARTITION BY state, chamber, vote_choice_scenario, uniform_swing_scenario
      ) AS total_chamber_seats,

      -- District count for bracket selection (distinct from seats in multi-member chambers)
      COUNT(*) OVER (
        PARTITION BY state, chamber, vote_choice_scenario, uniform_swing_scenario
      ) AS total_chamber_districts

    FROM with_seat_counts
  ),

  -- Identify the crossover (median) district: the one whose cumulative seat count
  -- first reaches or exceeds the majority threshold
  median_stats AS (
    SELECT
      state,
      chamber,
      vote_choice_scenario,
      uniform_swing_scenario,
      FLOOR(MAX(total_chamber_seats) / 2) + 1 AS majority_threshold,
      MAX(total_chamber_seats) AS total_chamber_seats,
      MAX(total_chamber_districts) AS total_chamber_districts,
      MAX(new_weighted_share) AS median_share
    FROM cumulative_calc
    WHERE
      cumulative_seat_count >= (FLOOR(total_chamber_seats / 2) + 1)
      AND (cumulative_seat_count - seat_count) < (FLOOR(total_chamber_seats / 2) + 1)
    GROUP BY state, chamber, vote_choice_scenario, uniform_swing_scenario
  ),

  -- Apply tipping point classification per district per scenario
  district_with_tipping_flag AS (
    SELECT
      c.*,
      m.majority_threshold,
      m.median_share,
      CASE
        -- TARGETING_BOX: hybrid soft/strategic with margin decay
        WHEN tipping_mode = 'TARGETING_BOX' THEN
          CASE
            -- Rule A: Soft targets (always include if margin is tiny)
            WHEN ABS(c.new_weighted_share - m.median_share) <= tipping_margin_include
              THEN 1.0
            -- Rule B: Strategic targets (in rank zone, with margin decay)
            -- Seat-block aware distance: measures from nearest seat in the
            -- district's block to the majority threshold
            WHEN
              GREATEST(
                0,
                (c.cumulative_seat_count - c.seat_count + 1) - m.majority_threshold,
                m.majority_threshold - c.cumulative_seat_count
              ) <= (m.total_chamber_seats * IF(m.total_chamber_districts <= 50,
                    tipping_rank_fraction_small_chambers,
                    tipping_rank_fraction_large_chambers))
            THEN
              CASE
                WHEN ABS(c.new_weighted_share - m.median_share) <= tipping_margin_exclude
                  THEN 1.0
                WHEN ABS(c.new_weighted_share - m.median_share)
                     <= tipping_margin_exclude + tipping_margin_decay_width
                  THEN (tipping_margin_exclude + tipping_margin_decay_width
                        - ABS(c.new_weighted_share - m.median_share))
                       / tipping_margin_decay_width
                ELSE 0.0
              END
            ELSE 0.0
          END

        -- MARGIN: binary threshold on vote share distance
        WHEN tipping_mode = 'MARGIN' THEN
          IF(ABS(c.new_weighted_share - m.median_share) <= tipping_margin_threshold, 1.0, 0.0)

        -- RANK: binary threshold on seat-rank distance
        WHEN tipping_mode = 'RANK' THEN
          IF(
            GREATEST(
              0,
              (c.cumulative_seat_count - c.seat_count + 1) - m.majority_threshold,
              m.majority_threshold - c.cumulative_seat_count
            ) <= (m.total_chamber_seats * IF(m.total_chamber_districts <= 50,
                  tipping_rank_fraction_small_chambers,
                  tipping_rank_fraction_large_chambers)),
            1.0, 0.0)

        -- BOTH: meets either margin or rank criterion
        WHEN tipping_mode = 'BOTH' THEN
          IF(
            (ABS(c.new_weighted_share - m.median_share) <= tipping_margin_threshold)
            OR
            (
              GREATEST(
                0,
                (c.cumulative_seat_count - c.seat_count + 1) - m.majority_threshold,
                m.majority_threshold - c.cumulative_seat_count
              ) <= (m.total_chamber_seats * IF(m.total_chamber_districts <= 50,
                    tipping_rank_fraction_small_chambers,
                    tipping_rank_fraction_large_chambers))
            ),
            1.0, 0.0)

        ELSE 0.0
      END AS tipping_weight

    FROM cumulative_calc c
    JOIN median_stats m
      ON c.state = m.state
      AND c.chamber = m.chamber
      AND c.vote_choice_scenario = m.vote_choice_scenario
      AND c.uniform_swing_scenario = m.uniform_swing_scenario
  ),

  -- Baseline reference share per district per swing level (for effect classification)
  baseline_reference AS (
    SELECT
      state,
      chamber,
      district_number,
      uniform_swing_scenario,
      new_weighted_share AS baseline_share_at_swing
    FROM district_with_tipping_flag
    WHERE vote_choice_scenario = baseline_vote_choice_scenario
  ),

  -- Aggregate tipping weights per district: total, favorable, unfavorable, neutral
  tipping_counts AS (
    SELECT
      d.state,
      d.chamber,
      d.district_number,

      SUM(d.tipping_weight) AS tipping_scenario_count,

      -- Favorable: scenario helps Dems (epsilon-based classification)
      SUM(
        d.tipping_weight
        * IF(d.new_weighted_share > br.baseline_share_at_swing + 1e-9, 1.0, 0.0)
      ) AS favorable_tipping_scenario_count,

      -- Unfavorable: scenario hurts Dems
      SUM(
        d.tipping_weight
        * IF(d.new_weighted_share < br.baseline_share_at_swing - 1e-9, 1.0, 0.0)
      ) AS unfavorable_tipping_scenario_count,

      -- Neutral: no meaningful effect (within epsilon)
      SUM(
        d.tipping_weight
        * IF(ABS(d.new_weighted_share - br.baseline_share_at_swing) <= 1e-9, 1.0, 0.0)
      ) AS neutral_tipping_scenario_count,

      -- Per-district denominators (unweighted scenario counts)
      COUNTIF(d.new_weighted_share > br.baseline_share_at_swing + 1e-9) AS total_favorable_combos,
      COUNTIF(d.new_weighted_share < br.baseline_share_at_swing - 1e-9) AS total_unfavorable_combos,
      COUNTIF(ABS(d.new_weighted_share - br.baseline_share_at_swing) <= 1e-9) AS total_neutral_combos,

      COUNT(DISTINCT CONCAT(
        d.vote_choice_scenario, '::', CAST(d.uniform_swing_scenario AS STRING)
      )) AS total_scenarios

    FROM district_with_tipping_flag d
    LEFT JOIN baseline_reference br
      ON d.state = br.state
      AND d.chamber = br.chamber
      AND d.district_number = br.district_number
      AND d.uniform_swing_scenario = br.uniform_swing_scenario
    GROUP BY d.state, d.chamber, d.district_number
  ),

  -- Baseline-only and scenario-average shares per district
  baseline_and_avg AS (
    SELECT
      state,
      chamber,
      district_number,

      AVG(
        IF(
          vote_choice_scenario = baseline_vote_choice_scenario
          AND uniform_swing_scenario = 0,
          new_weighted_share,
          NULL
        )
      ) AS baseline_projected_share,

      AVG(new_weighted_share) AS avg_projected_share_all_scenarios,

      MAX(reference_share_20_pres) AS pres_2020_dem_2way,
      MAX(reference_share_24_pres) AS pres_2024_dem_2way,
      MAX(dem_weighted_baseline)   AS dem_weighted_baseline

    FROM base
    GROUP BY state, chamber, district_number
  )

-- =============================================================================
-- FINAL OUTPUT
-- =============================================================================

SELECT
  tc.state,
  tc.chamber,
  CAST(tc.district_number AS STRING) AS district,

  SAFE_DIVIDE(tc.tipping_scenario_count, tc.total_scenarios)
    AS percent_tipping_point,

  SAFE_DIVIDE(tc.favorable_tipping_scenario_count, tc.total_favorable_combos)
    AS pct_tipping_favorable,

  SAFE_DIVIDE(tc.unfavorable_tipping_scenario_count, tc.total_unfavorable_combos)
    AS pct_tipping_unfavorable,

  SAFE_DIVIDE(tc.favorable_tipping_scenario_count, tc.total_favorable_combos)
    - SAFE_DIVIDE(tc.unfavorable_tipping_scenario_count, tc.total_unfavorable_combos)
    AS tipping_skew,

  -- Raw tipping counts for Step 6 explanation reliability assessment
  tc.favorable_tipping_scenario_count,
  tc.unfavorable_tipping_scenario_count,
  tc.total_favorable_combos,
  tc.total_unfavorable_combos,

  ba.pres_2020_dem_2way,
  ba.pres_2024_dem_2way,
  ba.dem_weighted_baseline,

  (ba.avg_projected_share_all_scenarios - ba.dem_weighted_baseline)
    AS delta_avg_vs_present_day,

  ba.baseline_projected_share,
  ba.avg_projected_share_all_scenarios

FROM tipping_counts tc
JOIN baseline_and_avg ba
  ON tc.state = ba.state
  AND tc.chamber = ba.chamber
  AND tc.district_number = ba.district_number

ORDER BY
  tc.state,
  tc.chamber,
  SAFE_CAST(tc.district_number AS INT64),
  tc.district_number;

  -- END STEP 3_4
