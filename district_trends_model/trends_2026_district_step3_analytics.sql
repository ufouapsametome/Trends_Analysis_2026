/*
  district_trends_2026_step3_analytics
  v2.1
  adapted from
  trends_2025_district_step5_analytics
  v1.4
  adapted from trends_2025_step5_district_analytics

  Builds the deep analytics profile for every legislative district. Serves as
  the intermediate table powering Step 4 explanation generation.

  Computes per-district: position metrics (margin/rank distance to median across
  all scenarios), volatility, trend alignment, demographic driver ranking
  (weighted distinctive influence), lever exposure, scenario tipping profile,
  religion driver evaluation, and tipping condition drivers.

  v1.4 changes:
    - NEW: Urbanicity classification from TargetSmart ts_tsmart_urbanicity.
      Adds 6 output columns: pct_urban, pct_suburban, pct_exurban, pct_rural,
      urbanicity_class (majority category or 'Mixed'), urbanicity_purity
      (share held by winning category). Controlled by urbanicity_majority_threshold
      DECLARE (default 0.50). Districts where no single category exceeds the
      threshold are classified 'Mixed'.
    - ts_tsmart_urbanicity uses a 6-tier coded scale (R1/R2/S3/S4/U5/U6),
      NOT the plain-text labels (Rural/Exurban/Suburban/Urban) documented in
      the pipeline reference §A.19. Mapping validated against
      ts_tsmart_urbanicity_rank continuous density measure:
        R1 → Rural, R2 → Exurban, S3+S4 → Suburban, U5+U6 → Urban.
    - ts_tsmart_urbanicity added to voter_base CTE, carried through
      voter_base_corrected and voter_district_mapped.
    - New CTE: district_urbanicity (Section 6b).
    - Joined in final assembly (Section 9).

  Inputs:
    core_model_outputs_hd/_sd          (Step 1)
    combined_dem_baseline_hd/_sd       (Preliminary)
    weighted_demo_shares_hd/_sd        (Step 1)
    tipping_point_analysis             (Step 2)
    trends_2026_scenarios              (scenario table)
    NH district/floterial xrefs
    TargetSmart voter file             (for raw demographic profiles + urbanicity)
    ACS natam correction, age imputation weights, state FIPS codes

  Output: district_analytics
*/

-- CONFIGURATION
DECLARE execution_mode STRING DEFAULT 'SELECT'; --<-- 'SELECT' for diagnostics, 'TABLE' for prod
DECLARE output_table STRING DEFAULT 'proj-tmc-mem-fm.main.trends_2025_district_analytics';
DECLARE baseline_vote_choice_scenario STRING DEFAULT 'balanced_Baseline';

DECLARE diagnostic_mode BOOL DEFAULT TRUE; --<--TRUE for diagnostics
DECLARE target_states ARRAY<STRING> DEFAULT [
'AK','AZ','FL','GA','IA','KS','ME','MI','MN','NC','NH','NV','OH','PA','TX','VA','WI'
];

DECLARE diagnostic_districts ARRAY<STRUCT<state STRING, chamber STRING, district_number STRING>> DEFAULT [
STRUCT('AK', 'hd', '005'), STRUCT('AK', 'hd', '018'),
STRUCT('AZ', 'hd', '009'), STRUCT('AZ', 'hd', '016'), STRUCT('AZ', 'sd', '016'),
STRUCT('FL', 'sd', '021'), STRUCT('FL', 'sd', '036'),
STRUCT('GA', 'hd', '128'), STRUCT('GA', 'sd', '048'),
STRUCT('IA', 'hd', '022'),
STRUCT('KS', 'hd', '016'),
STRUCT('ME', 'hd', '064'),
STRUCT('MI', 'hd', '039'), STRUCT('MI', 'sd', '028'),
STRUCT('MN', 'hd', '33B'), STRUCT('MN', 'hd', '55A'),
STRUCT('NC', 'hd', '035'),
STRUCT('NH', 'hd', 'ROCKINGHAM20'), STRUCT('NH', 'hd', 'HILLSBOROUGH37 (FLOTERIAL)'),
STRUCT('NV', 'hd', '003'), STRUCT('NV', 'sd', '003'),
STRUCT('OH', 'hd', '057'),
STRUCT('PA', 'hd', '028'), STRUCT('PA', 'hd', '120'),
STRUCT('TX', 'hd', '089'), STRUCT('TX', 'hd', '112'), STRUCT('TX', 'hd', '132'),
STRUCT('VA', 'hd', '020'),
STRUCT('WI', 'hd', '053'), STRUCT('WI', 'sd', '005')
];

-- =====================================================================
-- URBANICITY CLASSIFICATION THRESHOLDS
-- A district is assigned the urbanicity category that exceeds
-- urbanicity_majority_threshold AND where no other single category
-- exceeds urbanicity_runner_up_cap. If either condition fails, 'Mixed'.
--
-- Example at defaults (0.45 / 0.40):
--   49.4% Suburban + 32.7% Exurban → Suburban (runner-up < 40%)
--   54.8% Urban + 44.3% Suburban   → Mixed   (runner-up > 40%)
-- =====================================================================
DECLARE urbanicity_majority_threshold FLOAT64 DEFAULT 0.45;
DECLARE urbanicity_runner_up_cap FLOAT64 DEFAULT 0.40;

BEGIN
DECLARE sql_query STRING;

SET sql_query = """

WITH

-- =====================================================================
-- 0. SOURCE UNIONS
-- =====================================================================

-- MODEL OUTPUTS: UNION core model outputs from Step 1 (still separate tables)
core_model_union AS (
  SELECT *, 'hd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_hd`
  UNION ALL
  SELECT *, 'sd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_core_model_outputs_sd`
),

-- BASELINES: Load from preliminary Dem baseline query and synthesize NH floterial baselines.
-- Previously this join was done in a separate query and materialized as weighted_model_outputs.
-- Now inlined here since Step 2 no longer materializes that intermediate.
standard_baselines_raw_hd AS (
  SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_combined_dem_baseline_hd`
),
standard_baselines_raw_sd AS (
  SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_combined_dem_baseline_sd`
),

standard_baselines AS (
  SELECT *, 'hd' AS chamber FROM standard_baselines_raw_hd WHERE State != 'NH'
  UNION ALL
  SELECT
    b.State, nx.voterbase_hd_name AS District,
    b.dem_weighted_baseline, b.share_20_pres, b.share_24_pres, b.share_other,
    'hd' AS chamber
  FROM standard_baselines_raw_hd b
  JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nx
    ON b.District = nx.HD
  WHERE b.State = 'NH' AND nx.HD != 'Floterial'
  UNION ALL
    -- Add fix for AK Senate district format mismatch
SELECT
  State,
  CASE WHEN State = 'AK' THEN LTRIM(District, '0') ELSE District END AS District,
  * EXCEPT(State, District),
  'sd' AS chamber
FROM standard_baselines_raw_sd
),

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
    FROM core_model_union
    WHERE state = 'NH' AND chamber = 'hd'
      AND vote_choice_scenario = 'present_day_baseline'
      AND uniform_swing_scenario = 0
      AND district_number NOT LIKE '%(FLOTERIAL)%'
  ) m
  JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nm
    ON m.district_number = nm.voterbase_hd_name
  JOIN `proj-tmc-mem-fm.main.trends_2025_NH_Floterial_xref_corrected` fx
    ON nm.HD = fx.HD
  JOIN standard_baselines b
    ON b.State = 'NH' AND b.District = m.district_number AND b.chamber = 'hd'
  GROUP BY 1, 2
),

all_baselines AS (
  SELECT * FROM standard_baselines
  UNION ALL
  SELECT * FROM nh_floterial_baselines
),

-- WEIGHTED UNION: reconstructs the per-scenario new_weighted_share that was
-- previously materialized as weighted_model_outputs_hd/_sd.
-- Join = dem_weighted_baseline + scenario_delta.
weighted_union AS (
  SELECT
    m.state, m.chamber,
    CAST(m.district_number AS STRING) AS district_number,
    m.vote_choice_scenario,
    m.uniform_swing_scenario,
    (b.dem_weighted_baseline + m.scenario_delta) AS new_weighted_share,
    b.dem_weighted_baseline
  FROM core_model_union m
  JOIN all_baselines b
    ON m.state = b.State
    AND CAST(m.district_number AS STRING) = b.District
    AND m.chamber = b.chamber
  WHERE m.vote_choice_scenario != 'present_day_baseline'
),

-- TIPPING UNION: reads directly from Step 2 output.
-- Previously UNION'd _hd + _sd with column aliasing.
tipping_union AS (
  SELECT
    state, chamber,
    district AS district_number,
    percent_tipping_point,
    pct_tipping_favorable,
    pct_tipping_unfavorable,
    tipping_skew,
    favorable_tipping_scenario_count,
    unfavorable_tipping_scenario_count,
    total_favorable_combos,
    total_unfavorable_combos,
    pres_2020_dem_2way,
    pres_2024_dem_2way,
    dem_weighted_baseline,
    delta_avg_vs_present_day,
    baseline_projected_share,
    avg_projected_share_all_scenarios
  FROM `proj-tmc-mem-fm.main.trends_2025_tipping_point_analysis`
),

-- WEIGHTED DEMOGRAPHICS: still separate tables from Step 1
weighted_demo_union AS (
  SELECT *, 'hd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_weighted_demo_shares_hd`
  UNION ALL
  SELECT *, 'sd' AS chamber FROM `proj-tmc-mem-fm.main.trends_2025_weighted_demo_shares_sd`
),

-- =====================================================================
-- 1. SEAT COUNTS & BASE PREP
-- =====================================================================

base AS (
  SELECT
    w.state, w.chamber, w.district_number,
    w.vote_choice_scenario, w.uniform_swing_scenario,
    w.new_weighted_share,
    w.dem_weighted_baseline
  FROM weighted_union w
),

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
    ON b.state = 'NH' AND b.chamber = 'hd'
    AND nx.voterbase_hd_name = REPLACE(b.district_number, ' (FLOTERIAL)', '')
),

-- =====================================================================
-- 2. CUMULATIVE RANK & MEDIAN IDENTIFICATION
-- =====================================================================

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
    ) AS total_chamber_seats
  FROM with_seat_counts
),

median_stats AS (
  SELECT
    state, chamber, vote_choice_scenario, uniform_swing_scenario,
    FLOOR(MAX(total_chamber_seats) / 2) + 1 AS majority_threshold,
    MAX(total_chamber_seats) AS total_chamber_seats,
    MAX(new_weighted_share) AS median_share
  FROM cumulative_calc
  WHERE
    cumulative_seat_count >= (FLOOR(total_chamber_seats / 2) + 1)
    AND (cumulative_seat_count - seat_count) < (FLOOR(total_chamber_seats / 2) + 1)
  GROUP BY state, chamber, vote_choice_scenario, uniform_swing_scenario
),

-- =====================================================================
-- 3. PER-DISTRICT SCENARIO STATS
-- =====================================================================

district_scenario_stats AS (
  SELECT
    c.state, c.chamber, c.district_number,
    c.vote_choice_scenario, c.uniform_swing_scenario,
    c.new_weighted_share,
    c.dem_weighted_baseline,
    c.cumulative_seat_count,
    c.seat_count,
    m.median_share,
    m.majority_threshold,
    m.total_chamber_seats,
    (c.new_weighted_share - m.median_share) AS margin_to_median,
    -- Seat-block-aware rank distance
    CASE
      WHEN CAST(m.majority_threshold AS FLOAT64)
        BETWEEN (CAST(c.cumulative_seat_count AS FLOAT64) - c.seat_count + 1)
        AND CAST(c.cumulative_seat_count AS FLOAT64)
      THEN 0.0
      WHEN CAST(c.cumulative_seat_count AS FLOAT64) < CAST(m.majority_threshold AS FLOAT64)
      THEN CAST(c.cumulative_seat_count AS FLOAT64) - CAST(m.majority_threshold AS FLOAT64)
      ELSE (CAST(c.cumulative_seat_count AS FLOAT64) - c.seat_count + 1) - CAST(m.majority_threshold AS FLOAT64)
    END AS rank_distance_to_majority
  FROM cumulative_calc c
  JOIN median_stats m
    USING (state, chamber, vote_choice_scenario, uniform_swing_scenario)
),

-- =====================================================================
-- 2b. PRESENT-DAY MEDIAN & POSITION
-- =====================================================================

present_day_ranked AS (
  SELECT
    state, chamber, district_number,
    dem_weighted_baseline,
    seat_count,
    SUM(seat_count) OVER (
      PARTITION BY state, chamber
      ORDER BY dem_weighted_baseline DESC, district_number
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS pd_cumulative_seat_count,
    SUM(seat_count) OVER (
      PARTITION BY state, chamber
    ) AS pd_total_chamber_seats
  FROM district_scenario_stats
  WHERE vote_choice_scenario = @baseline_scenario
    AND uniform_swing_scenario = 0
),

present_day_median AS (
  SELECT
    state, chamber,
    FLOOR(MAX(pd_total_chamber_seats) / 2) + 1 AS pd_majority_threshold,
    MAX(pd_total_chamber_seats) AS pd_total_chamber_seats,
    MAX(dem_weighted_baseline) AS pd_median_share
  FROM present_day_ranked
  WHERE
    pd_cumulative_seat_count >= (FLOOR(pd_total_chamber_seats / 2) + 1)
    AND (pd_cumulative_seat_count - seat_count) < (FLOOR(pd_total_chamber_seats / 2) + 1)
  GROUP BY state, chamber
),

present_day_position AS (
  SELECT
    r.state, r.chamber, r.district_number,
    r.dem_weighted_baseline,
    (r.dem_weighted_baseline - m.pd_median_share) AS present_day_margin_to_median,
    CASE
      WHEN CAST(m.pd_majority_threshold AS FLOAT64)
        BETWEEN (CAST(r.pd_cumulative_seat_count AS FLOAT64) - r.seat_count + 1)
        AND CAST(r.pd_cumulative_seat_count AS FLOAT64)
      THEN 0.0
      WHEN CAST(r.pd_cumulative_seat_count AS FLOAT64) < CAST(m.pd_majority_threshold AS FLOAT64)
      THEN CAST(r.pd_cumulative_seat_count AS FLOAT64) - CAST(m.pd_majority_threshold AS FLOAT64)
      ELSE (CAST(r.pd_cumulative_seat_count AS FLOAT64) - r.seat_count + 1) - CAST(m.pd_majority_threshold AS FLOAT64)
    END AS present_day_rank_distance_to_majority
  FROM present_day_ranked r
  JOIN present_day_median m USING (state, chamber)
),

-- =====================================================================
-- 4. AGGREGATE POSITION METRICS
-- =====================================================================

district_position AS (
  SELECT
    state, chamber, district_number,
    AVG(margin_to_median) AS avg_margin_to_median,
    AVG(rank_distance_to_majority) AS avg_rank_distance_to_majority,
    AVG(ABS(margin_to_median)) AS avg_abs_margin_to_median,
    AVG(ABS(rank_distance_to_majority)) AS avg_abs_rank_distance,
    MIN(ABS(margin_to_median)) AS min_abs_margin_to_median,
    MAX(ABS(margin_to_median)) AS max_abs_margin_to_median,
    AVG(IF(vote_choice_scenario = @baseline_scenario AND
           uniform_swing_scenario = 0, margin_to_median, NULL)) AS projected_2030_baseline_margin_to_median,
    AVG(IF(vote_choice_scenario = @baseline_scenario AND
           uniform_swing_scenario = 0, rank_distance_to_majority, NULL)) AS projected_2030_baseline_rank_distance_to_majority,
    MAX(new_weighted_share) - MIN(new_weighted_share) AS district_volatility,
    MAX(margin_to_median) - MIN(margin_to_median) AS margin_to_median_volatility,
    MAX(total_chamber_seats) AS total_chamber_seats,
    AVG(IF(ABS(margin_to_median) <= 0.01, 1.0, 0.0)) AS pct_within_1pt,
    AVG(IF(ABS(margin_to_median) <= 0.02, 1.0, 0.0)) AS pct_within_2pts,
    AVG(IF(ABS(rank_distance_to_majority) <= 1, 1.0, 0.0)) AS pct_within_1_seat,
    STDDEV_POP(margin_to_median) AS margin_to_median_stddev
  FROM district_scenario_stats
  GROUP BY state, chamber, district_number
),

-- Crowding CTEs retained for potential future use (outputs dropped in v12.0)
per_scenario_crowding AS (
  SELECT
    d.state, d.chamber, d.district_number,
    d.vote_choice_scenario, d.uniform_swing_scenario,
    CASE
      WHEN CAST(d.majority_threshold AS FLOAT64)
        BETWEEN (CAST(d.cumulative_seat_count AS FLOAT64) - d.seat_count + 1)
        AND CAST(d.cumulative_seat_count AS FLOAT64)
      THEN 0
      WHEN CAST(d.cumulative_seat_count AS FLOAT64) < CAST(d.majority_threshold AS FLOAT64)
      THEN CAST(d.majority_threshold AS FLOAT64) - CAST(d.cumulative_seat_count AS FLOAT64) - 1
      ELSE (CAST(d.cumulative_seat_count AS FLOAT64) - d.seat_count + 1) - CAST(d.majority_threshold AS FLOAT64) - 1
    END AS seats_between_me_and_median
  FROM district_scenario_stats d
),

district_crowding AS (
  SELECT
    state, chamber, district_number,
    AVG(GREATEST(seats_between_me_and_median, 0)) AS avg_seats_between_me_and_median
  FROM per_scenario_crowding
  GROUP BY state, chamber, district_number
),

-- =====================================================================
-- 5. STATE-LEVEL COMPETITIVE SHARES
-- =====================================================================

avg_crowding AS (
  SELECT
    state, chamber,
    AVG(seats_in_zone) AS avg_seats_within_2pts_of_median
  FROM (
    SELECT
      state, chamber, vote_choice_scenario, uniform_swing_scenario,
      SUM(seat_count) AS seats_in_zone
    FROM district_scenario_stats
    WHERE ABS(margin_to_median) <= 0.02
    GROUP BY state, chamber, vote_choice_scenario, uniform_swing_scenario
  )
  GROUP BY state, chamber
),

state_competitive_counts AS (
  SELECT
    state, chamber,
    COUNT(*) AS total_districts,
    SAFE_DIVIDE(COUNTIF(percent_tipping_point > 0), COUNT(*)) AS state_chamber_tipping_share
  FROM tipping_union
  GROUP BY state, chamber
),

-- =====================================================================
-- 6. RAW DEMOGRAPHIC COMPOSITION (from voter file)
-- =====================================================================

-- Re-reads the voter file independently from Step 2 for raw demographic shares.
-- Applies the same ACS natam correction and age imputation as Step 1.
-- [v1.4] Now also reads ts_tsmart_urbanicity for district urbanicity classification.
voter_base AS (
  SELECT
    v.vb_tsmart_state AS state, v.vb_vf_hd, v.vb_vf_sd,
    v.vb_voterbase_age, v.vb_voterbase_gender,
    -- Hash-based age imputation for null-age voters (10 affected states)
    CASE
      WHEN v.vb_voterbase_age IS NOT NULL THEN v.vb_voterbase_age
      ELSE (
        CASE
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_18_24
            THEN 18 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 7)
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_25_34
            THEN 25 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 10)
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_35_44
            THEN 35 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 10)
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_45_54
            THEN 45 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 10)
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_55_64
            THEN 55 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 10)
          WHEN MOD(ABS(FARM_FINGERPRINT(v.vb_voterbase_id)), 10000) / 10000.0 < aiw.cum_65_74
            THEN 65 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 10)
          ELSE
            75 + MOD(ABS(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_age'))), 16)
        END
      )
    END AS effective_age,
    CASE
      WHEN v.vb_voterbase_age IS NOT NULL THEN 'voter_file'
      ELSE 'imputed'
    END AS age_source,
    v.ts_tsmr_p_white, v.ts_tsmr_p_black, v.ts_tsmr_p_hisp,
    v.ts_tsmr_p_asian, v.ts_tsmr_p_natam,
    v.ts_tsmart_college_graduate_score, v.ts_tsmart_high_school_only_score,
    v.ts_tsmart_catholic_raw_score, v.ts_tsmart_evangelical_raw_score,
    v.vb_tsmart_county_code,
    -- [v1.4] Urbanicity for district classification
    v.ts_tsmart_urbanicity
  FROM `proj-tmc-mem-fm.targetsmart_enhanced.enh_targetsmart__ntl_current` v
  LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_state_fips_codes` fips_age
    ON fips_age.STUSAB = v.vb_tsmart_state
  LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_age_imputation_thresholds` aiw
    ON aiw.county_geo_id = CONCAT(
      '0500000US',
      LPAD(CAST(fips_age.STATE_FIPS AS STRING), 2, '0'),
      LPAD(CAST(v.vb_tsmart_county_code AS STRING), 3, '0'))
    AND aiw.state = v.vb_tsmart_state
  WHERE v.vb_tsmart_state IN UNNEST(@target_states)
    AND v.vb_vf_voter_status = 'Active'
    AND v.vb_voterbase_deceased_flag IS NULL
    AND v.vb_voterbase_registration_status = 'Registered'
    AND v.vb_tsmart_state = v.vb_vf_source_state
    AND (v.vb_voterbase_age >= 18 OR v.vb_voterbase_age IS NULL)
    AND v.vb_vf_sd IS NOT NULL
    AND v.vb_vf_hd IS NOT NULL
),

-- ACS-calibrated NatAm correction (mirrors Step 1)
voter_base_corrected AS (
  SELECT vb.*,
    LEAST(GREATEST(vb.ts_tsmr_p_natam, 0), 1)
      * COALESCE(nc.natam_correction_ratio, 0.0) AS adjusted_p_natam
  FROM voter_base vb
  LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_state_fips_codes` f
    ON vb.state = f.STUSAB
  LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_acs_natam_correction` nc
    ON nc.county_geo_id = CONCAT(
      '0500000US',
      LPAD(CAST(f.STATE_FIPS AS STRING), 2, '0'),
      LPAD(CAST(vb.vb_tsmart_county_code AS STRING), 3, '0')
    )
),

-- Map voters to districts (HD, NH floterial duplicates, SD)
-- [v1.4] Now carries ts_tsmart_urbanicity through to district mapping
voter_district_mapped AS (
  SELECT state, 'hd' AS chamber, vb_vf_hd AS district_number,
    effective_age, vb_voterbase_gender,
    ts_tsmr_p_white, ts_tsmr_p_black, ts_tsmr_p_hisp,
    ts_tsmr_p_asian, adjusted_p_natam AS ts_tsmr_p_natam,
    ts_tsmart_college_graduate_score, ts_tsmart_high_school_only_score,
    ts_tsmart_catholic_raw_score, ts_tsmart_evangelical_raw_score,
    ts_tsmart_urbanicity
  FROM voter_base_corrected WHERE vb_vf_hd IS NOT NULL
  UNION ALL
  SELECT vb.state, 'hd' AS chamber, CONCAT(fx.Floterial_HD_Name, ' (FLOTERIAL)'),
    vb.effective_age, vb.vb_voterbase_gender,
    vb.ts_tsmr_p_white, vb.ts_tsmr_p_black, vb.ts_tsmr_p_hisp,
    vb.ts_tsmr_p_asian, vb.adjusted_p_natam AS ts_tsmr_p_natam,
    vb.ts_tsmart_college_graduate_score, vb.ts_tsmart_high_school_only_score,
    vb.ts_tsmart_catholic_raw_score, vb.ts_tsmart_evangelical_raw_score,
    vb.ts_tsmart_urbanicity
  FROM voter_base_corrected vb
  JOIN `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref` nx
    ON vb.state = 'NH' AND vb.vb_vf_hd = nx.voterbase_hd_name
  JOIN `proj-tmc-mem-fm.main.trends_2025_NH_Floterial_xref_corrected` fx
    ON nx.HD = fx.HD
  WHERE vb.state = 'NH'
  UNION ALL
  SELECT state, 'sd' AS chamber, vb_vf_sd AS district_number,
    effective_age, vb_voterbase_gender,
    ts_tsmr_p_white, ts_tsmr_p_black, ts_tsmr_p_hisp,
    ts_tsmr_p_asian, adjusted_p_natam AS ts_tsmr_p_natam,
    ts_tsmart_college_graduate_score, ts_tsmart_high_school_only_score,
    ts_tsmart_catholic_raw_score, ts_tsmart_evangelical_raw_score,
    ts_tsmart_urbanicity
  FROM voter_base_corrected WHERE vb_vf_sd IS NOT NULL
),

district_demographics_raw AS (
  SELECT
    state, chamber, district_number,
    COUNT(*) AS voter_count,
    AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS pct_white,
    AVG(LEAST(GREATEST(ts_tsmr_p_hisp, 0), 1)) AS pct_latino,
    AVG(LEAST(GREATEST(ts_tsmr_p_black, 0), 1)) AS pct_black,
    AVG(LEAST(GREATEST(ts_tsmr_p_asian, 0), 1)) AS pct_asian,
    AVG(LEAST(GREATEST(ts_tsmr_p_natam, 0), 1)) AS pct_natam,
    1.0 - AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS pct_nonwhite,
    AVG(LEAST(GREATEST(ts_tsmart_college_graduate_score / 100.0, 0), 1)) AS pct_college,
    AVG(LEAST(GREATEST(ts_tsmart_high_school_only_score / 100.0, 0), 1)) AS pct_high_school_only,
    AVG(LEAST(GREATEST(ts_tsmart_catholic_raw_score / 100.0, 0), 1)) AS pct_catholic,
    AVG(LEAST(GREATEST(ts_tsmart_evangelical_raw_score / 100.0, 0), 1)) AS pct_evangelical,
    SAFE_DIVIDE(COUNTIF(vb_voterbase_gender = 'Female'), COUNT(*)) AS pct_female,
    SAFE_DIVIDE(COUNTIF(effective_age BETWEEN 18 AND 34), COUNT(*)) AS pct_youth_18_34,
    SAFE_DIVIDE(COUNTIF(effective_age >= 65), COUNT(*)) AS pct_senior_65plus
  FROM voter_district_mapped
  WHERE district_number IS NOT NULL
  GROUP BY state, chamber, district_number
),

-- =====================================================================
-- 6b. URBANICITY CLASSIFICATION [v1.4 — NEW]
-- =====================================================================
-- Computes per-district urbanicity composition shares from TS categorical
-- field ts_tsmart_urbanicity (Rural / Exurban / Suburban / Urban).
-- Classification rule: majority category wins if it exceeds
-- @urbanicity_majority_threshold; otherwise 'Mixed'.
-- Voters with NULL urbanicity are excluded from share computation
-- (they still count for all other demographics above).

-- TargetSmart ts_tsmart_urbanicity uses a 6-tier coded scale, not plain-text
-- labels. Mapping validated against ts_tsmart_urbanicity_rank (continuous
-- density measure, ascending = denser). Average ranks confirm clean gradient:
--   R1 (26K) → R2 (62K) → S3 (94K) → S4 (134K) → U5 (186K) → U6 (225K)
--
-- 4-way mapping:
--   R1       → Rural
--   R2       → Exurban  (intermediate density; avg rank between R1 and S3)
--   S3 + S4  → Suburban (two density tiers within the suburban band)
--   U5 + U6  → Urban    (U6 = urban core, ~1.3M voters; collapsed with U5)
--
-- Null/empty values (~3K of ~40M in 4-state sample) excluded from denominator.
district_urbanicity AS (
  SELECT
    state, chamber, district_number,
    -- Composition shares (denominator = voters with non-null, non-empty urbanicity)
    SAFE_DIVIDE(
      COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
      COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')
    ) AS pct_urban,
    SAFE_DIVIDE(
      COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
      COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')
    ) AS pct_suburban,
    SAFE_DIVIDE(
      COUNTIF(ts_tsmart_urbanicity = 'R2'),
      COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')
    ) AS pct_exurban,
    SAFE_DIVIDE(
      COUNTIF(ts_tsmart_urbanicity = 'R1'),
      COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')
    ) AS pct_rural,
    -- Null/empty rate for diagnostics (not output, but available if needed)
    SAFE_DIVIDE(
      COUNTIF(ts_tsmart_urbanicity IS NULL OR ts_tsmart_urbanicity = ''),
      COUNT(*)
    ) AS urbanicity_null_rate,
    -- Classification: majority category with runner-up cap, or 'Mixed'.
    -- Requires: (1) winning category >= @urbanicity_threshold, AND
    --           (2) no other single category > @runner_up_cap.
    CASE
      WHEN SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) >= @urbanicity_threshold
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R2'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R1'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        THEN 'Urban'
      WHEN SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) >= @urbanicity_threshold
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R2'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R1'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        THEN 'Suburban'
      WHEN SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R2'),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) >= @urbanicity_threshold
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R1'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        THEN 'Exurban'
      WHEN SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R1'),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) >= @urbanicity_threshold
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        AND SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R2'),
          COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')) <= @runner_up_cap
        THEN 'Rural'
      ELSE 'Mixed'
    END AS urbanicity_class,
    -- Purity: share held by the winning category (or the max share if Mixed)
    GREATEST(
      SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('U5', 'U6')),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')),
      SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity IN ('S3', 'S4')),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')),
      SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R2'),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != '')),
      SAFE_DIVIDE(COUNTIF(ts_tsmart_urbanicity = 'R1'),
        COUNTIF(ts_tsmart_urbanicity IS NOT NULL AND ts_tsmart_urbanicity != ''))
    ) AS urbanicity_purity
  FROM voter_district_mapped
  WHERE district_number IS NOT NULL
  GROUP BY state, chamber, district_number
),

-- Raw state averages (for demographic index computation)
state_demo_averages AS (
  SELECT
    state, 'hd' AS chamber,
    AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS state_avg_pct_white,
    AVG(LEAST(GREATEST(ts_tsmr_p_hisp, 0), 1)) AS state_avg_pct_latino,
    AVG(LEAST(GREATEST(ts_tsmr_p_black, 0), 1)) AS state_avg_pct_black,
    AVG(LEAST(GREATEST(ts_tsmr_p_asian, 0), 1)) AS state_avg_pct_asian,
    AVG(LEAST(GREATEST(adjusted_p_natam, 0), 1)) AS state_avg_pct_natam,
    1.0 - AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS state_avg_pct_nonwhite,
    AVG(LEAST(GREATEST(ts_tsmart_college_graduate_score / 100.0, 0), 1)) AS state_avg_pct_college,
    AVG(LEAST(GREATEST(ts_tsmart_high_school_only_score / 100.0, 0), 1)) AS state_avg_pct_high_school_only,
    AVG(LEAST(GREATEST(ts_tsmart_catholic_raw_score / 100.0, 0), 1)) AS state_avg_pct_catholic,
    AVG(LEAST(GREATEST(ts_tsmart_evangelical_raw_score / 100.0, 0), 1)) AS state_avg_pct_evangelical,
    SAFE_DIVIDE(COUNTIF(vb_voterbase_gender = 'Female'), COUNT(*)) AS state_avg_pct_female,
    SAFE_DIVIDE(COUNTIF(effective_age BETWEEN 18 AND 34), COUNT(*)) AS state_avg_pct_youth_18_34,
    SAFE_DIVIDE(COUNTIF(effective_age >= 65), COUNT(*)) AS state_avg_pct_senior_65plus
  FROM voter_base_corrected WHERE vb_vf_hd IS NOT NULL GROUP BY state
  UNION ALL
  SELECT
    state, 'sd' AS chamber,
    AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS state_avg_pct_white,
    AVG(LEAST(GREATEST(ts_tsmr_p_hisp, 0), 1)) AS state_avg_pct_latino,
    AVG(LEAST(GREATEST(ts_tsmr_p_black, 0), 1)) AS state_avg_pct_black,
    AVG(LEAST(GREATEST(ts_tsmr_p_asian, 0), 1)) AS state_avg_pct_asian,
    AVG(LEAST(GREATEST(adjusted_p_natam, 0), 1)) AS state_avg_pct_natam,
    1.0 - AVG(LEAST(GREATEST(ts_tsmr_p_white, 0), 1)) AS state_avg_pct_nonwhite,
    AVG(LEAST(GREATEST(ts_tsmart_college_graduate_score / 100.0, 0), 1)) AS state_avg_pct_college,
    AVG(LEAST(GREATEST(ts_tsmart_high_school_only_score / 100.0, 0), 1)) AS state_avg_pct_high_school_only,
    AVG(LEAST(GREATEST(ts_tsmart_catholic_raw_score / 100.0, 0), 1)) AS state_avg_pct_catholic,
    AVG(LEAST(GREATEST(ts_tsmart_evangelical_raw_score / 100.0, 0), 1)) AS state_avg_pct_evangelical,
    SAFE_DIVIDE(COUNTIF(vb_voterbase_gender = 'Female'), COUNT(*)) AS state_avg_pct_female,
    SAFE_DIVIDE(COUNTIF(effective_age BETWEEN 18 AND 34), COUNT(*)) AS state_avg_pct_youth_18_34,
    SAFE_DIVIDE(COUNTIF(effective_age >= 65), COUNT(*)) AS state_avg_pct_senior_65plus
  FROM voter_base_corrected WHERE vb_vf_sd IS NOT NULL GROUP BY state
),

-- =====================================================================
-- 7. LEVER RANGES & WEIGHTED EXPOSURE
-- =====================================================================

scenario_lever_ranges AS (
  SELECT
    ABS(MAX(delta_hisp) - MIN(delta_hisp)) AS range_latino,
    ABS(MAX(delta_black) - MIN(delta_black)) AS range_black,
    ABS(MAX(delta_asian) - MIN(delta_asian)) AS range_asian,
    ABS(MAX(delta_natam) - MIN(delta_natam)) AS range_natam,
    ABS(MAX(delta_white) - MIN(delta_white)) AS range_white,
    ABS(MAX(delta_college) - MIN(delta_college)) AS range_college,
    ABS(MAX(delta_high_school_only) - MIN(delta_high_school_only)) AS range_high_school_only,
    ABS(MAX(delta_catholic) - MIN(delta_catholic)) AS range_catholic,
    ABS(MAX(delta_evangelical) - MIN(delta_evangelical)) AS range_evangelical,
    ABS(MAX(delta_female) - MIN(delta_female)) AS range_female,
    ABS(MAX(delta_male) - MIN(delta_male)) AS range_male,
    ABS(MAX(delta_age_18_24 + delta_age_25_34) - MIN(delta_age_18_24 + delta_age_25_34))
      AS range_age_18_to_34,
    ABS(MAX(delta_age_65_74 + delta_age_75_84 + delta_age_85_plus)
      - MIN(delta_age_65_74 + delta_age_75_84 + delta_age_85_plus))
      AS range_age_65_plus
  FROM `proj-tmc-mem-fm.main.trends_2026_scenarios`
),

-- Weighted state averages for benchmarking (uses turnout-weighted shares from Step 1)
state_weighted_averages AS (
  SELECT
    state, chamber,
    SAFE_DIVIDE(SUM(weighted_pct_white * total_weight), SUM(total_weight)) AS w_avg_white,
    SAFE_DIVIDE(SUM(weighted_pct_black * total_weight), SUM(total_weight)) AS w_avg_black,
    SAFE_DIVIDE(SUM(weighted_pct_latino * total_weight), SUM(total_weight)) AS w_avg_latino,
    SAFE_DIVIDE(SUM(weighted_pct_asian * total_weight), SUM(total_weight)) AS w_avg_asian,
    SAFE_DIVIDE(SUM(weighted_pct_natam * total_weight), SUM(total_weight)) AS w_avg_natam,
    SAFE_DIVIDE(SUM(weighted_pct_college * total_weight), SUM(total_weight)) AS w_avg_college,
    SAFE_DIVIDE(SUM(weighted_pct_high_school_only * total_weight), SUM(total_weight)) AS w_avg_high_school_only,
    SAFE_DIVIDE(SUM(weighted_pct_catholic * total_weight), SUM(total_weight)) AS w_avg_catholic,
    SAFE_DIVIDE(SUM(weighted_pct_evangelical * total_weight), SUM(total_weight)) AS w_avg_evangelical,
    SAFE_DIVIDE(SUM(weighted_pct_female * total_weight), SUM(total_weight)) AS w_avg_female,
    SAFE_DIVIDE(SUM((weighted_pct_age_18_24 + weighted_pct_age_25_34) * total_weight),
      SUM(total_weight)) AS w_avg_age_18_to_34,
    SAFE_DIVIDE(SUM((weighted_pct_age_65_74 + weighted_pct_age_75_84 + weighted_pct_age_85_plus) * total_weight),
      SUM(total_weight)) AS w_avg_age_65_plus
  FROM weighted_demo_union
  GROUP BY state, chamber
),

-- Per-district lever exposure (weighted demographic share × scenario range)
district_lever_exposure AS (
  SELECT
    d.state, d.chamber, d.district_number,
    d.weighted_pct_latino * slr.range_latino AS exposure_latino,
    d.weighted_pct_black * slr.range_black AS exposure_black,
    d.weighted_pct_asian * slr.range_asian AS exposure_asian,
    d.weighted_pct_natam * slr.range_natam AS exposure_natam,
    d.weighted_pct_white * slr.range_white AS exposure_white,
    d.weighted_pct_college * slr.range_college AS exposure_college,
    d.weighted_pct_high_school_only * slr.range_high_school_only AS exposure_high_school_only,
    d.weighted_pct_catholic * slr.range_catholic AS exposure_catholic,
    d.weighted_pct_evangelical * slr.range_evangelical AS exposure_evangelical,
    d.weighted_pct_female * slr.range_female AS exposure_female,
    (1.0 - d.weighted_pct_female) * slr.range_male AS exposure_male,
    (d.weighted_pct_age_18_24 + d.weighted_pct_age_25_34) * slr.range_age_18_to_34
      AS exposure_age_18_to_34,
    (d.weighted_pct_age_65_74 + d.weighted_pct_age_75_84 + d.weighted_pct_age_85_plus) * slr.range_age_65_plus
      AS exposure_age_65_plus
  FROM weighted_demo_union d
  CROSS JOIN scenario_lever_ranges slr
),

-- =====================================================================
-- 8. DRIVER IDENTIFICATION (Weighted Distinctive Influence)
-- =====================================================================

-- DI = GREATEST(district_share - state_avg, 0) × lever_range × signal_gate
-- Signal gate = LEAST(district_share / 0.10, 1.0) suppresses tiny cohorts.
-- Catholic/Evangelical computed but excluded from UNPIVOT (separate religion driver).
district_distinctive_influence AS (
  SELECT
    d.state, d.chamber, d.district_number,
    GREATEST(d.weighted_pct_latino - sa.w_avg_latino, 0) * slr.range_latino * LEAST(1.0, d.weighted_pct_latino / 0.10) AS di_latino,
    GREATEST(d.weighted_pct_black - sa.w_avg_black, 0) * slr.range_black * LEAST(1.0, d.weighted_pct_black / 0.10) AS di_black,
    GREATEST(d.weighted_pct_asian - sa.w_avg_asian, 0) * slr.range_asian * LEAST(1.0, d.weighted_pct_asian / 0.10) AS di_asian,
    GREATEST(d.weighted_pct_natam - sa.w_avg_natam, 0) * slr.range_natam * LEAST(1.0, d.weighted_pct_natam / 0.10) AS di_natam,
    GREATEST(d.weighted_pct_white - sa.w_avg_white, 0) * slr.range_white * LEAST(1.0, d.weighted_pct_white / 0.10) AS di_white,
    GREATEST(d.weighted_pct_college - sa.w_avg_college, 0) * slr.range_college * LEAST(1.0, d.weighted_pct_college / 0.10) AS di_college,
    GREATEST(d.weighted_pct_high_school_only - sa.w_avg_high_school_only, 0) * slr.range_high_school_only * LEAST(1.0, d.weighted_pct_high_school_only / 0.10) AS di_high_school_only,
    GREATEST(d.weighted_pct_catholic - sa.w_avg_catholic, 0) * slr.range_catholic * LEAST(1.0, d.weighted_pct_catholic / 0.10) AS di_catholic,
    GREATEST(d.weighted_pct_evangelical - sa.w_avg_evangelical, 0) * slr.range_evangelical * LEAST(1.0, d.weighted_pct_evangelical / 0.10) AS di_evangelical,
    GREATEST(d.weighted_pct_female - sa.w_avg_female, 0) * slr.range_female * LEAST(1.0, d.weighted_pct_female / 0.10) AS di_female,
    GREATEST((1.0 - d.weighted_pct_female) - (1.0 - sa.w_avg_female), 0) * slr.range_male * LEAST(1.0, (1.0 - d.weighted_pct_female) / 0.10) AS di_male,
    GREATEST((d.weighted_pct_age_18_24 + d.weighted_pct_age_25_34) - sa.w_avg_age_18_to_34, 0)
      * slr.range_age_18_to_34 * LEAST(1.0, (d.weighted_pct_age_18_24 + d.weighted_pct_age_25_34) / 0.10) AS di_age_18_to_34,
    GREATEST((d.weighted_pct_age_65_74 + d.weighted_pct_age_75_84 + d.weighted_pct_age_85_plus) - sa.w_avg_age_65_plus, 0)
      * slr.range_age_65_plus * LEAST(1.0, (d.weighted_pct_age_65_74 + d.weighted_pct_age_75_84 + d.weighted_pct_age_85_plus) / 0.10) AS di_age_65_plus
  FROM weighted_demo_union d
  JOIN state_weighted_averages sa USING (state, chamber)
  CROSS JOIN scenario_lever_ranges slr
),

driver_ranking AS (
  SELECT
    state, chamber, district_number, driver_name, di_value,
    ROW_NUMBER() OVER(
      PARTITION BY state, chamber, district_number
      ORDER BY di_value DESC
    ) as rn
  FROM district_distinctive_influence
  UNPIVOT(
    di_value FOR driver_name IN (
      di_latino, di_black, di_asian, di_natam, di_white,
      di_college, di_high_school_only,
      di_female, di_male,
      di_age_18_to_34, di_age_65_plus
    )
  )
  WHERE di_value IS NOT NULL AND di_value > 0
),

ranked_drivers AS (
  SELECT
    state, chamber, district_number,
    MAX(CASE WHEN rn = 1 THEN INITCAP(REPLACE(driver_name, 'di_', '')) END) AS primary_trend_driver,
    MAX(CASE WHEN rn = 1 THEN di_value END) AS primary_driver_scenario_exposure_value,
    MAX(CASE WHEN rn = 2 THEN INITCAP(REPLACE(driver_name, 'di_', '')) END) AS secondary_trend_driver,
    MAX(CASE WHEN rn = 2 THEN di_value END) AS secondary_driver_scenario_exposure_value,
    MAX(CASE WHEN rn = 3 THEN INITCAP(REPLACE(driver_name, 'di_', '')) END) AS tertiary_trend_driver,
    MAX(CASE WHEN rn = 3 THEN di_value END) AS tertiary_driver_scenario_exposure_value
  FROM driver_ranking
  WHERE rn <= 3
  GROUP BY state, chamber, district_number
),

-- =====================================================================
-- 8b. SCENARIO TIPPING PROFILE
-- =====================================================================

scenario_proximity_raw AS (
  SELECT
    state, chamber, district_number,
    vote_choice_scenario,
    AVG(margin_to_median) AS avg_margin_for_scenario,
    AVG(ABS(margin_to_median)) AS avg_abs_margin_for_scenario
  FROM district_scenario_stats
  GROUP BY state, chamber, district_number, vote_choice_scenario
),

scenario_tipping_profile AS (
  SELECT
    *,
    ROW_NUMBER() OVER(
      PARTITION BY state, chamber, district_number
      ORDER BY avg_abs_margin_for_scenario ASC
    ) AS proximity_rank,
    ROW_NUMBER() OVER(
      PARTITION BY state, chamber, district_number
      ORDER BY avg_abs_margin_for_scenario DESC
    ) AS distance_rank
  FROM scenario_proximity_raw
),

district_scenario_detail AS (
  SELECT
    state, chamber, district_number,
    MAX(CASE WHEN proximity_rank = 1 THEN vote_choice_scenario END) AS closest_tipping_scenario_1,
    MAX(CASE WHEN proximity_rank = 1 THEN avg_abs_margin_for_scenario END) AS closest_tipping_margin_1,
    MAX(CASE WHEN proximity_rank = 2 THEN vote_choice_scenario END) AS closest_tipping_scenario_2,
    MAX(CASE WHEN proximity_rank = 2 THEN avg_abs_margin_for_scenario END) AS closest_tipping_margin_2,
    MAX(CASE WHEN proximity_rank = 3 THEN vote_choice_scenario END) AS closest_tipping_scenario_3,
    MAX(CASE WHEN proximity_rank = 3 THEN avg_abs_margin_for_scenario END) AS closest_tipping_margin_3,
    MAX(CASE WHEN distance_rank = 1 THEN vote_choice_scenario END) AS farthest_tipping_scenario,
    MAX(CASE WHEN distance_rank = 1 THEN avg_abs_margin_for_scenario END) AS farthest_tipping_margin
  FROM scenario_tipping_profile
  GROUP BY state, chamber, district_number
),

-- =====================================================================
-- 8c. RELIGION DRIVER
-- Dedicated evaluation: qualifies when weighted share >= 1.10x state avg
-- AND exposure >= 1.10x state mean exposure for that cohort.
-- =====================================================================

state_mean_religion_exposure AS (
  SELECT
    state, chamber,
    AVG(exposure_catholic) AS state_mean_exposure_catholic,
    AVG(exposure_evangelical) AS state_mean_exposure_evangelical
  FROM district_lever_exposure
  GROUP BY state, chamber
),

religion_driver_eval AS (
  SELECT
    d.state, d.chamber, d.district_number,
    CASE
      WHEN SAFE_DIVIDE(d.weighted_pct_catholic, sa.w_avg_catholic) >= 1.10
        AND SAFE_DIVIDE(dle.exposure_catholic, sme.state_mean_exposure_catholic) >= 1.10
      THEN dle.exposure_catholic
      ELSE NULL
    END AS catholic_qualified_exposure,
    CASE
      WHEN SAFE_DIVIDE(d.weighted_pct_evangelical, sa.w_avg_evangelical) >= 1.10
        AND SAFE_DIVIDE(dle.exposure_evangelical, sme.state_mean_exposure_evangelical) >= 1.10
      THEN dle.exposure_evangelical
      ELSE NULL
    END AS evangelical_qualified_exposure
  FROM weighted_demo_union d
  JOIN state_weighted_averages sa USING (state, chamber)
  JOIN district_lever_exposure dle USING (state, chamber, district_number)
  JOIN state_mean_religion_exposure sme USING (state, chamber)
),

religion_driver_ranked AS (
  SELECT
    state, chamber, district_number,
    CASE
      WHEN catholic_qualified_exposure IS NOT NULL AND evangelical_qualified_exposure IS NOT NULL
        THEN CASE WHEN catholic_qualified_exposure >= evangelical_qualified_exposure THEN 'Catholic' ELSE 'Evangelical' END
      WHEN catholic_qualified_exposure IS NOT NULL THEN 'Catholic'
      WHEN evangelical_qualified_exposure IS NOT NULL THEN 'Evangelical'
      ELSE 'None'
    END AS religion_driver,
    CASE
      WHEN catholic_qualified_exposure IS NOT NULL AND evangelical_qualified_exposure IS NOT NULL
        THEN GREATEST(catholic_qualified_exposure, evangelical_qualified_exposure)
      WHEN catholic_qualified_exposure IS NOT NULL THEN catholic_qualified_exposure
      WHEN evangelical_qualified_exposure IS NOT NULL THEN evangelical_qualified_exposure
      ELSE NULL
    END AS religion_driver_scenario_exposure_value
  FROM religion_driver_eval
),

-- =====================================================================
-- 8d. TIPPING CONDITION DRIVERS
-- Differential approach: classify each vote_choice_scenario as tipping
-- or non-tipping per district, compute mean cohort deltas for tipping
-- minus non-tipping. Top 3 by |diff × cohort_share| are the conditions
-- that most strongly determine tipping behavior.
-- =====================================================================

-- District counts for fraction-bracket selection (seats vs districts distinction)
chamber_district_counts AS (
  SELECT state, chamber,
    COUNT(DISTINCT district_number) AS total_chamber_districts
  FROM tipping_union
  GROUP BY state, chamber
),

-- Classify scenarios: a vote_choice_scenario is "tipping" if ANY uniform_swing
-- places the district inside the targeting box (Rule A: |margin| <= 1.5pp OR
-- Rule B: |rank_distance| <= band AND |margin| <= 5.5pp)
scenario_tipping_flag AS (
  SELECT
    dss.state, dss.chamber, dss.district_number,
    dss.vote_choice_scenario,
    MAX(
      CASE
        WHEN ABS(dss.margin_to_median) <= 0.015 THEN 1
        WHEN ABS(dss.rank_distance_to_majority)
             <= dss.total_chamber_seats
                * (CASE WHEN cdc.total_chamber_districts <= 50 THEN 0.10 ELSE 0.07 END)
             AND ABS(dss.margin_to_median) <= 0.055
        THEN 1
        ELSE 0
      END
    ) AS is_tipping_scenario
  FROM district_scenario_stats dss
  JOIN chamber_district_counts cdc USING (state, chamber)
  GROUP BY dss.state, dss.chamber, dss.district_number, dss.vote_choice_scenario
),

-- Per-cohort differentials (tipping avg - non-tipping avg)
tipping_cohort_differential AS (
  SELECT
    stf.state, stf.chamber, stf.district_number,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_hisp, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_hisp, NULL)) AS diff_latino,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_black, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_black, NULL)) AS diff_black,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_asian, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_asian, NULL)) AS diff_asian,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_natam, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_natam, NULL)) AS diff_natam,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_white, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_white, NULL)) AS diff_white,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_college, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_college, NULL)) AS diff_college,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_high_school_only, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_high_school_only, NULL)) AS diff_high_school_only,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_catholic, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_catholic, NULL)) AS diff_catholic,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_evangelical, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_evangelical, NULL)) AS diff_evangelical,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_female, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_female, NULL)) AS diff_female,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_male, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_male, NULL)) AS diff_male,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_age_18_24 + s.delta_age_25_34, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_age_18_24 + s.delta_age_25_34, NULL)) AS diff_age_18_to_34,
    AVG(IF(stf.is_tipping_scenario = 1, s.delta_age_65_74 + s.delta_age_75_84 + s.delta_age_85_plus, NULL))
      - AVG(IF(stf.is_tipping_scenario = 0, s.delta_age_65_74 + s.delta_age_75_84 + s.delta_age_85_plus, NULL)) AS diff_age_65_plus,
    COUNTIF(stf.is_tipping_scenario = 1) AS tipping_scenario_count,
    COUNTIF(stf.is_tipping_scenario = 0) AS non_tipping_scenario_count
  FROM scenario_tipping_flag stf
  JOIN `proj-tmc-mem-fm.main.trends_2026_scenarios` s
    ON stf.vote_choice_scenario = s.name
  GROUP BY stf.state, stf.chamber, stf.district_number
),

-- Rank by |diff × cohort_share| to suppress phantom signals from
-- cohorts with zero local population
tipping_driver_ranking AS (
  SELECT
    state, chamber, district_number,
    cohort_name, diff_value,
    CASE WHEN diff_value > 0 THEN 'increases' ELSE 'decreases' END AS entry_direction,
    ROW_NUMBER() OVER(
      PARTITION BY state, chamber, district_number
      ORDER BY ABS(diff_value * cohort_share) DESC
    ) AS rn
  FROM (
    SELECT
      u.state, u.chamber, u.district_number,
      u.cohort_name, u.diff_value,
      CASE u.cohort_name
        WHEN 'diff_latino' THEN wdu.weighted_pct_latino
        WHEN 'diff_black' THEN wdu.weighted_pct_black
        WHEN 'diff_asian' THEN wdu.weighted_pct_asian
        WHEN 'diff_natam' THEN wdu.weighted_pct_natam
        WHEN 'diff_white' THEN wdu.weighted_pct_white
        WHEN 'diff_college' THEN wdu.weighted_pct_college
        WHEN 'diff_high_school_only' THEN wdu.weighted_pct_high_school_only
        WHEN 'diff_catholic' THEN wdu.weighted_pct_catholic
        WHEN 'diff_evangelical' THEN wdu.weighted_pct_evangelical
        WHEN 'diff_female' THEN wdu.weighted_pct_female
        WHEN 'diff_male' THEN 1.0 - wdu.weighted_pct_female
        WHEN 'diff_age_18_to_34' THEN wdu.weighted_pct_age_18_24 + wdu.weighted_pct_age_25_34
        WHEN 'diff_age_65_plus' THEN wdu.weighted_pct_age_65_74 + wdu.weighted_pct_age_75_84 + wdu.weighted_pct_age_85_plus
        ELSE 0.0
      END AS cohort_share
    FROM tipping_cohort_differential
    UNPIVOT(
      diff_value FOR cohort_name IN (
        diff_latino, diff_black, diff_asian, diff_natam, diff_white,
        diff_college, diff_high_school_only,
        diff_catholic, diff_evangelical,
        diff_female, diff_male,
        diff_age_18_to_34, diff_age_65_plus
      )
    ) u
    LEFT JOIN weighted_demo_union wdu
      ON u.state = wdu.state AND u.chamber = wdu.chamber AND u.district_number = wdu.district_number
    WHERE u.diff_value IS NOT NULL
  )
  WHERE ABS(diff_value * cohort_share) > 0.001
),

tipping_condition_drivers AS (
  SELECT
    state, chamber, district_number,
    MAX(CASE WHEN rn = 1 THEN INITCAP(REPLACE(cohort_name, 'diff_', '')) END) AS tipping_condition_driver_1,
    MAX(CASE WHEN rn = 1 THEN entry_direction END) AS tipping_condition_sign_1,
    MAX(CASE WHEN rn = 1 THEN diff_value END) AS tipping_condition_diff_1,
    MAX(CASE WHEN rn = 2 THEN INITCAP(REPLACE(cohort_name, 'diff_', '')) END) AS tipping_condition_driver_2,
    MAX(CASE WHEN rn = 2 THEN entry_direction END) AS tipping_condition_sign_2,
    MAX(CASE WHEN rn = 2 THEN diff_value END) AS tipping_condition_diff_2,
    MAX(CASE WHEN rn = 3 THEN INITCAP(REPLACE(cohort_name, 'diff_', '')) END) AS tipping_condition_driver_3,
    MAX(CASE WHEN rn = 3 THEN entry_direction END) AS tipping_condition_sign_3,
    MAX(CASE WHEN rn = 3 THEN diff_value END) AS tipping_condition_diff_3
  FROM tipping_driver_ranking
  WHERE rn <= 3
  GROUP BY state, chamber, district_number
),

-- =====================================================================
-- 9. FINAL ASSEMBLY
-- =====================================================================

assembled AS (
  SELECT
    -- Keys
    dp.state, dp.chamber, tp.district_number,

    -- Tipping point metrics
    tp.percent_tipping_point,
    tp.pct_tipping_favorable,
    tp.pct_tipping_unfavorable,
    tp.tipping_skew AS tipping_fav_unfav_skew,

    -- Share fields
    tp.dem_weighted_baseline AS dem_weighted_baseline_2025,
    tp.delta_avg_vs_present_day AS delta_avg_2030_vs_baseline_2025,
    tp.baseline_projected_share AS dem_baseline_projected_2030,
    tp.avg_projected_share_all_scenarios AS avg_dem_share_all_scenarios_2030,
    (tp.baseline_projected_share - tp.dem_weighted_baseline) AS delta_baseline_2030_vs_2025,

    -- Present-day position
    pdp.present_day_margin_to_median AS baseline_margin_to_median_2025,
    pdp.present_day_rank_distance_to_majority AS rank_distance_to_median_2025,

    -- Projected position geometry
    dp.avg_margin_to_median AS avg_margin_to_median_2030,
    dp.avg_rank_distance_to_majority AS avg_rank_distance_to_median_2030,
    dp.avg_abs_margin_to_median AS avg_abs_margin_to_median_2030,
    dp.avg_abs_rank_distance AS avg_abs_rank_distance_to_median_2030,
    dp.min_abs_margin_to_median AS min_abs_margin_to_median_2030,
    dp.max_abs_margin_to_median AS max_abs_margin_to_median_2030,
    dp.projected_2030_baseline_margin_to_median AS baseline_margin_to_median_2030,
    dp.projected_2030_baseline_rank_distance_to_majority AS baseline_rank_distance_to_median_2030,

    -- Proportional rank position (cross-chamber comparable)
    SAFE_DIVIDE(
      ABS(pdp.present_day_rank_distance_to_majority),
      dp.total_chamber_seats
    ) AS rank_pct_of_chamber_2025,
    SAFE_DIVIDE(
      ABS(dp.projected_2030_baseline_rank_distance_to_majority),
      dp.total_chamber_seats
    ) AS baseline_rank_pct_of_chamber_2030,

    -- Trend alignment (converging/diverging/stable relative to median)
    CASE
      WHEN ABS(dp.projected_2030_baseline_margin_to_median) <
           ABS(pdp.present_day_margin_to_median) - 0.002
      THEN 'Converging'
      WHEN ABS(dp.projected_2030_baseline_margin_to_median) >
           ABS(pdp.present_day_margin_to_median) + 0.002
      THEN 'Diverging'
      ELSE 'Stable'
    END AS trend_alignment,

    -- Rank drift: positive = scenario-avg more Dem-favorable than present day
    dp.avg_rank_distance_to_majority -
      pdp.present_day_rank_distance_to_majority AS delta_avg_rank_2030_vs_2025,

    dp.projected_2030_baseline_margin_to_median -
      pdp.present_day_margin_to_median AS delta_margin_to_median_2025_to_2030,

    -- Volatility
    dp.district_volatility AS district_raw_volatility,
    dp.margin_to_median_volatility AS district_relative_volatility,
    dp.margin_to_median_stddev AS district_relative_volatility_stddev,

    -- Drivers (weighted distinctive influence)
    td.primary_trend_driver,
    td.primary_driver_scenario_exposure_value,
    td.secondary_trend_driver,
    td.secondary_driver_scenario_exposure_value,
    td.tertiary_trend_driver,
    td.tertiary_driver_scenario_exposure_value,

    -- Dedicated religion driver
    rd.religion_driver,
    rd.religion_driver_scenario_exposure_value,

    -- Scenario tipping profile
    dsd.closest_tipping_scenario_1,
    dsd.closest_tipping_margin_1,
    dsd.closest_tipping_scenario_2,
    dsd.closest_tipping_margin_2,
    dsd.closest_tipping_scenario_3,
    dsd.closest_tipping_margin_3,
    dsd.farthest_tipping_scenario,
    dsd.farthest_tipping_margin,
    (dsd.closest_tipping_scenario_1 = @baseline_scenario) AS is_baseline_closest_scenario,

    -- State-level context
    scc.state_chamber_tipping_share,
    dp.total_chamber_seats,

    -- Chamber median dem share (constant per state/chamber, denormalized)
    (tp.dem_weighted_baseline - pdp.present_day_margin_to_median) AS chamber_median_dem_share_2025,
    (tp.baseline_projected_share -
      dp.projected_2030_baseline_margin_to_median) AS chamber_median_dem_share_2030,

    -- Tipping raw counts (for Step 4 reliability assessment)
    tp.favorable_tipping_scenario_count,
    tp.unfavorable_tipping_scenario_count,
    tp.total_favorable_combos,
    tp.total_unfavorable_combos,

    -- Target-zone frequency
    dp.pct_within_1pt AS pct_scenarios_within_1pt,
    dp.pct_within_2pts AS pct_scenarios_within_2pts,
    dp.pct_within_1_seat AS pct_scenarios_within_1_seat,

    -- Demographics: raw shares
    dd.pct_white, dd.pct_latino, dd.pct_black, dd.pct_asian,
    dd.pct_natam, dd.pct_nonwhite,
    dd.pct_college, dd.pct_high_school_only,
    dd.pct_catholic, dd.pct_evangelical,
    dd.pct_female,
    dd.pct_youth_18_34, dd.pct_senior_65plus,

    -- Demographics: smoothed relative index (centered at 1.0)
    1.0 + (SAFE_DIVIDE(dd.pct_white, GREATEST(sa.state_avg_pct_white, 0.01)) - 1.0)
      * LEAST(dd.pct_white / 0.02, 1.0) AS idx_white_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_latino, GREATEST(sa.state_avg_pct_latino, 0.01)) - 1.0)
      * LEAST(dd.pct_latino / 0.02, 1.0) AS idx_latino_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_black, GREATEST(sa.state_avg_pct_black, 0.01)) - 1.0)
      * LEAST(dd.pct_black / 0.02, 1.0) AS idx_black_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_asian, GREATEST(sa.state_avg_pct_asian, 0.01)) - 1.0)
      * LEAST(dd.pct_asian / 0.02, 1.0) AS idx_asian_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_natam, GREATEST(sa.state_avg_pct_natam, 0.01)) - 1.0)
      * LEAST(dd.pct_natam / 0.02, 1.0) AS idx_natam_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_nonwhite, GREATEST(sa.state_avg_pct_nonwhite, 0.01)) - 1.0)
      * LEAST(dd.pct_nonwhite / 0.02, 1.0) AS idx_nonwhite_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_college, GREATEST(sa.state_avg_pct_college, 0.01)) - 1.0)
      * LEAST(dd.pct_college / 0.02, 1.0) AS idx_college_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_high_school_only, GREATEST(sa.state_avg_pct_high_school_only, 0.01)) - 1.0)
      * LEAST(dd.pct_high_school_only / 0.02, 1.0) AS idx_high_school_only_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_catholic, GREATEST(sa.state_avg_pct_catholic, 0.01)) - 1.0)
      * LEAST(dd.pct_catholic / 0.02, 1.0) AS idx_catholic_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_evangelical, GREATEST(sa.state_avg_pct_evangelical, 0.01)) - 1.0)
      * LEAST(dd.pct_evangelical / 0.02, 1.0) AS idx_evangelical_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_female, GREATEST(sa.state_avg_pct_female, 0.01)) - 1.0)
      * LEAST(dd.pct_female / 0.02, 1.0) AS idx_female_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_youth_18_34, GREATEST(sa.state_avg_pct_youth_18_34, 0.01)) - 1.0)
      * LEAST(dd.pct_youth_18_34 / 0.02, 1.0) AS idx_18_to_34_vs_state,
    1.0 + (SAFE_DIVIDE(dd.pct_senior_65plus, GREATEST(sa.state_avg_pct_senior_65plus, 0.01)) - 1.0)
      * LEAST(dd.pct_senior_65plus / 0.02, 1.0) AS idx_65_plus_vs_state,

    -- Lever exposures (weighted, prefixed with "scenario_")
    dle.exposure_latino AS scenario_exposure_latino,
    dle.exposure_black AS scenario_exposure_black,
    dle.exposure_asian AS scenario_exposure_asian,
    dle.exposure_natam AS scenario_exposure_natam,
    dle.exposure_white AS scenario_exposure_white,
    dle.exposure_college AS scenario_exposure_college,
    dle.exposure_high_school_only AS scenario_exposure_high_school_only,
    dle.exposure_catholic AS scenario_exposure_catholic,
    dle.exposure_evangelical AS scenario_exposure_evangelical,
    dle.exposure_female AS scenario_exposure_female,
    dle.exposure_male AS scenario_exposure_male,
    dle.exposure_age_18_to_34 AS scenario_exposure_age_18_to_34,
    dle.exposure_age_65_plus AS scenario_exposure_age_65_plus,

    -- Tipping condition drivers
    tcd.tipping_condition_driver_1,
    tcd.tipping_condition_sign_1,
    tcd.tipping_condition_diff_1,
    tcd.tipping_condition_driver_2,
    tcd.tipping_condition_sign_2,
    tcd.tipping_condition_diff_2,
    tcd.tipping_condition_driver_3,
    tcd.tipping_condition_sign_3,
    tcd.tipping_condition_diff_3,
    tdf.tipping_scenario_count,
    tdf.non_tipping_scenario_count,

    -- [v1.4] Urbanicity composition and classification
    du.pct_urban,
    du.pct_suburban,
    du.pct_exurban,
    du.pct_rural,
    du.urbanicity_class,
    du.urbanicity_purity

  FROM district_position dp
  JOIN tipping_union tp USING (state, chamber, district_number)
  LEFT JOIN present_day_position pdp USING (state, chamber, district_number)
  LEFT JOIN ranked_drivers td USING (state, chamber, district_number)
  LEFT JOIN religion_driver_ranked rd USING (state, chamber, district_number)
  LEFT JOIN district_scenario_detail dsd USING (state, chamber, district_number)
  LEFT JOIN state_competitive_counts scc USING (state, chamber)
  LEFT JOIN district_demographics_raw dd USING (state, chamber, district_number)
  LEFT JOIN state_demo_averages sa USING (state, chamber)
  LEFT JOIN district_lever_exposure dle USING (state, chamber, district_number)
  LEFT JOIN tipping_condition_drivers tcd USING (state, chamber, district_number)
  LEFT JOIN tipping_cohort_differential tdf USING (state, chamber, district_number)
  LEFT JOIN district_urbanicity du USING (state, chamber, district_number)
),

-- =====================================================================
-- 10. DIAGNOSTIC FILTERING
-- =====================================================================

final_output AS (
  SELECT *
  FROM assembled
  WHERE
    (NOT @diagnostic_mode)
    OR (STRUCT(state, chamber, district_number) IN UNNEST(@diagnostic_districts))
)

SELECT * FROM final_output
ORDER BY state, chamber, district_number

""";

-- EXECUTION BLOCK
IF execution_mode = 'TABLE' THEN
  EXECUTE IMMEDIATE FORMAT(
    "CREATE OR REPLACE TABLE `%s` AS \n%s",
    output_table, sql_query
  ) USING baseline_vote_choice_scenario AS baseline_scenario,
    target_states AS target_states,
    diagnostic_mode AS diagnostic_mode,
    diagnostic_districts AS diagnostic_districts,
    urbanicity_majority_threshold AS urbanicity_threshold,
    urbanicity_runner_up_cap AS runner_up_cap;
  SELECT FORMAT('Successfully created table: %s', output_table) AS status;
ELSE
  EXECUTE IMMEDIATE sql_query
  USING baseline_vote_choice_scenario AS baseline_scenario,
    target_states AS target_states,
    diagnostic_mode AS diagnostic_mode,
    diagnostic_districts AS diagnostic_districts,
    urbanicity_majority_threshold AS urbanicity_threshold,
    urbanicity_runner_up_cap AS runner_up_cap;
END IF;

END;

-- END STEP 3
