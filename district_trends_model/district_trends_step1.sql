/*
  trends_2025_district_step2_core_2030_model
  v1.2
  adapted from trends_2025_step2_core_2030_model v55.0

  MUST BE RUN TWICE: ONCE EACH FOR HD/SD

  Projects each legislative district's electorate ~5 years forward using voter-level
  mortality, migration, youth maturation, and in-mover dynamics. Crosses the projected
  electorate against a scenario grid (demographic deltas × uniform swings) to produce
  district-level expected Democratic vote shares. Run once for HD, once for SD.

  Inputs:  TargetSmart voter file, ACS stability/mover rates, ACS maturation factors,
           ACS NatAm correction, age imputation thresholds, CDC race mortality rates,
           scenario table, state FIPS codes,
           NH district/floterial xrefs, combined_dem_baseline_[hd|sd]
  Outputs: core_model_outputs_[hd|sd], weighted_demo_shares_[hd|sd]

  v1.1 CHANGES (from v1.0):
  [IMP #1] Race-differentiated mortality: Replaced hardcoded pooled mortality CASE
           statement and flat 1.16/0.84 sex multiplier with CDC 2023 race-specific
           life tables (trends_2025_cdc_race_mortality_rates). Computes per-voter
           probability-weighted blend across 4 race groups × 8 age bands × 3 sex
           categories. Ported from state model Step 1 v2.0.
           JOIN uses LOWER() on age_band() output to resolve 85_PLUS/85_plus mismatch.
  [IMP #2] Age imputation thresholds: Swapped trends_2025_age_imputation_weights
           (youth-skewed, built from interstate-mover subpopulation) with
           trends_2025_age_imputation_thresholds (built from ACS total_pop with
           registered-voter reweighting). Fixes ~40% youth overassignment in NH/WI.
           Ported from state model Step 1 v2.6.
  [IMP #3] Maturation IFNULL safety: Changed IFNULL defaults from 1.0 to 0.0 for
           missing ACS maturation factors. Conservative: assumes no new registrants
           rather than neutral replacement when county data is missing.
           Ported from state model Step 1 v2.7.
*/

-- TOGGLES
DECLARE diagnostic_mode BOOL DEFAULT FALSE;              -- TRUE FOR DIAGNOSTICS: only balanced_Baseline @ swing 0
DECLARE make_table_mode BOOL DEFAULT TRUE;               -- FALSE FOR DIAGNOSTICS: SELECT to console instead of writing table
DECLARE export_weighted_demographics BOOL DEFAULT TRUE;  -- Writes weighted_demo_shares, required by Step 5

-- CONFIGURATION
DECLARE target_states ARRAY<STRING> DEFAULT
['AK','AZ','FL','GA','IA','KS','ME','MI','MN','NC','NH','NV','OH','PA','TX','VA','WI'];
--['GA','OH']; <--SET DIAGNOSTIC STATES

DECLARE target_district_level STRING DEFAULT 'SD'; -- 'HD' or 'SD'

-- Uniform swings as integer percentage points (e.g., -6 = 6 pts against Dems).
-- Stored as INT64 through pipeline output; divide by 100 only at display time
-- to prevent FLOAT64 PARTITION BY grouping errors downstream.
DECLARE uniform_swings ARRAY<INT64> DEFAULT [-6, -4, -2, 0, 2, 4, 6];

-- VOTER WEIGHTING PARAMETERS
DECLARE min_inmover_age INT64 DEFAULT 23;
DECLARE migration_stability_floor_under_25 FLOAT64 DEFAULT 0.05;
DECLARE migration_stability_floor_25_plus  FLOAT64 DEFAULT 0.25;

-- Fraction of ACS movers assumed to cross district boundaries
DECLARE migration_in_district_factor_sd FLOAT64 DEFAULT 0.92; -- SD and all AZ
DECLARE migration_in_district_factor_hd FLOAT64 DEFAULT 0.9;  -- HD (except AZ)

-- Healthy Voter Effect: registered voters have lower mortality than general population
DECLARE mortality_scalar FLOAT64 DEFAULT 0.95;

-- COLLEGE-TOWN YOUTH DAMPING
-- Districts with high youth concentration and low 18-19 stability get a maturation
-- scalar to prevent overestimation of youth aging-in. Two tiers by severity.
DECLARE apply_college_town_fix BOOL DEFAULT TRUE;
DECLARE college_tier1_stability_threshold FLOAT64 DEFAULT 0.20;
DECLARE college_tier1_pct_18_24_threshold FLOAT64 DEFAULT 0.18;
DECLARE college_tier1_churn_threshold     FLOAT64 DEFAULT 0.25;
DECLARE college_tier1_maturation_scalar   FLOAT64 DEFAULT 0.90;
DECLARE college_tier2_stability_threshold FLOAT64 DEFAULT 0.05;
DECLARE college_tier2_pct_18_24_threshold FLOAT64 DEFAULT 0.20;
DECLARE college_tier2_churn_threshold     FLOAT64 DEFAULT 0.32;
DECLARE college_tier2_maturation_scalar   FLOAT64 DEFAULT 0.80;

-- IN-MOVER PARTISAN OFFSET
-- Bayesian smoothing parameter: credibility weight = n/(n+k) where k = this value.
-- Below this count, district offset blends toward state-level prior.
DECLARE min_movers_for_district_offset INT64 DEFAULT 50;

-- Rate-ratio dampener threshold. Districts with mover rates below this fraction
-- of the state average get their state-level offset linearly dampened toward zero.
-- Prevents structurally low-migration districts (e.g., rural Bush Alaska) from
-- inheriting urban/suburban mover dynamics.
DECLARE mover_rate_dampening_threshold FLOAT64 DEFAULT 0.10;

-- GLOBAL COHORT ADJUSTMENTS
-- global_all_*: applied to ALL voters (present-day and projected)
-- global_non_present_*: applied only to projected (non-present-day) scenarios
DECLARE global_all_delta_hisp              FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_black             FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_asian             FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_white             FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_high_school_only  FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_college           FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_catholic          FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_evangelical       FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_18_24         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_25_34         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_35_44         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_45_54         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_55_64         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_65_74         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_75_84         FLOAT64 DEFAULT 0.00;
DECLARE global_all_delta_age_85_plus       FLOAT64 DEFAULT 0.00;

DECLARE global_non_present_delta_hisp              FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_black             FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_asian             FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_white             FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_high_school_only  FLOAT64 DEFAULT -0.005;
DECLARE global_non_present_delta_college           FLOAT64 DEFAULT 0.005;
DECLARE global_non_present_delta_catholic          FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_evangelical       FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_18_24         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_25_34         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_35_44         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_45_54         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_55_64         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_65_74         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_75_84         FLOAT64 DEFAULT 0.00;
DECLARE global_non_present_delta_age_85_plus       FLOAT64 DEFAULT 0.00;

-- HELPER FUNCTIONS
CREATE TEMP FUNCTION clamp01(x FLOAT64) AS (
  GREATEST(0.0, LEAST(1.0, x))
);

CREATE TEMP FUNCTION age_band(age INT64) AS (
  CASE
    WHEN age IS NULL THEN 'UNKNOWN'
    WHEN age BETWEEN 18 AND 24 THEN '18_24'
    WHEN age BETWEEN 25 AND 34 THEN '25_34'
    WHEN age BETWEEN 35 AND 44 THEN '35_44'
    WHEN age BETWEEN 45 AND 54 THEN '45_54'
    WHEN age BETWEEN 55 AND 64 THEN '55_64'
    WHEN age BETWEEN 65 AND 74 THEN '65_74'
    WHEN age BETWEEN 75 AND 84 THEN '75_84'
    WHEN age >= 85 THEN '85_PLUS'
    ELSE 'UNDER_18'
  END
);

-- ===========================================================================
-- PART 1: VOTER-LEVEL WEIGHTING
-- Build _weighted_voters temp table with 5-year expected vote weights,
-- demographic flags, and mover offsets for every active registered voter.
-- ===========================================================================

CREATE TEMP TABLE _weighted_voters AS

WITH

  base_filtered AS (

    SELECT
      v.vb_voterbase_id,
      v.vb_tsmart_state AS state,
      v.vb_vf_source_state,
      v.vb_vf_sd,
      v.vb_vf_hd,
      v.vb_voterbase_age,

      -- EFFECTIVE AGE: hash-based ACS imputation for null-age voters.
      -- 10 states lack DOB in voter file (13-42% null rates). For these voters,
      -- a deterministic age is imputed from county-level ACS distributions
      -- (bias-corrected for commercial matching skew) via FARM_FINGERPRINT.
      -- Same voter always gets the same imputed age; distribution matches
      -- the corrected ACS prior. All downstream calculations use effective_age.
      CASE
        WHEN v.vb_voterbase_age IS NOT NULL THEN v.vb_voterbase_age
        WHEN aiw.cum_18_24 IS NOT NULL THEN
          CASE
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_18_24
              THEN 18 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 7)) AS INT64)
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_25_34
              THEN 25 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 10)) AS INT64)
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_35_44
              THEN 35 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 10)) AS INT64)
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_45_54
              THEN 45 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 10)) AS INT64)
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_55_64
              THEN 55 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 10)) AS INT64)
            WHEN ABS(MOD(FARM_FINGERPRINT(v.vb_voterbase_id), 10000)) / 10000.0 < aiw.cum_65_74
              THEN 65 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 10)) AS INT64)
            ELSE
              75 + CAST(ABS(MOD(FARM_FINGERPRINT(CONCAT(v.vb_voterbase_id, '_a')), 15)) AS INT64)
          END
        ELSE 40 -- Defensive fallback: county not in imputation table
      END AS effective_age,

      CASE
        WHEN v.vb_voterbase_age IS NOT NULL THEN 'voter_file'
        ELSE 'imputed'
      END AS age_source,

      v.vb_voterbase_gender,
      v.vb_vf_voter_status,
      v.vb_voterbase_registration_status,
      v.vb_voterbase_deceased_flag,
      v.vb_vf_earliest_registration_date,
      v.vb_tsmart_address_improvement_type,
      v.vb_tsmart_effective_date,
      v.vb_voterbase_mover_status,
      v.vb_voterbase_move_distance,
      v.vb_vf_county_code,
      v.ts_tsmart_partisan_score,
      v.ts_tsmart_presidential_general_turnout_score,
      v.ts_tsmart_midterm_general_turnout_score,
      v.ts_tsmart_college_graduate_score,
      v.ts_tsmart_high_school_only_score,
      v.ts_tsmart_catholic_raw_score,
      v.ts_tsmart_evangelical_raw_score,
      v.ts_tsmr_p_white,
      v.ts_tsmr_p_black,
      v.ts_tsmr_p_hisp,
      v.ts_tsmr_p_natam,
      v.ts_tsmr_p_asian,
      v.vb_tsmart_county_code,

      CONCAT(
        '0500000US',
        LPAD(CAST(f.STATE_FIPS AS STRING), 2, '0'),
        LPAD(CAST(v.vb_tsmart_county_code AS STRING), 3, '0')
      ) AS county_geo_id,

      -- NatAm ACS correction: deflates TargetSmart residual bucket to genuine
      -- Native American share using county-level ACS ground truth. Counties below
      -- 2% ACS Native share are suppressed to 0.0.
      COALESCE(nc.natam_correction_ratio, 0.0) AS natam_correction_ratio

    FROM
      `proj-tmc-mem-fm.targetsmart_enhanced.enh_targetsmart__ntl_current` v

    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_state_fips_codes` f
      ON v.vb_tsmart_state = f.STUSAB

    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_acs_natam_correction` nc
      ON nc.county_geo_id = CONCAT(
        '0500000US',
        LPAD(CAST(f.STATE_FIPS AS STRING), 2, '0'),
        LPAD(CAST(v.vb_tsmart_county_code AS STRING), 3, '0')
      )

    -- [IMP #2] Age imputation thresholds: rebuilt from ACS total_pop with
    -- registered-voter reweighting. Replaces trends_2025_age_imputation_weights
    -- which was built from interstate-mover subpopulation (severely youth-skewed:
    -- ~40% in 18-24, 0% in 55+). New table covers all ~3,144 counties with
    -- realistic registered-voter age proportions (~9% in 18-24, ~12% in 75+).
    -- For non-null-age states, this LEFT JOIN produces NULLs and effective_age
    -- takes the first CASE branch (vb_voterbase_age IS NOT NULL).
    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_age_imputation_thresholds` aiw
      ON aiw.county_geo_id = CONCAT(
        '0500000US',
        LPAD(CAST(f.STATE_FIPS AS STRING), 2, '0'),
        LPAD(CAST(v.vb_tsmart_county_code AS STRING), 3, '0')
      )

    WHERE
      v.vb_tsmart_state IN UNNEST(target_states)
      AND v.vb_vf_voter_status = 'Active'
      AND v.vb_voterbase_deceased_flag IS NULL
      AND v.vb_voterbase_registration_status = 'Registered'
      AND v.vb_tsmart_state = v.vb_vf_source_state
      AND v.vb_vf_sd IS NOT NULL
      AND v.vb_vf_hd IS NOT NULL
      AND (v.vb_voterbase_age >= 18 OR v.vb_voterbase_age IS NULL)

  ),

  nh_district_xref AS (
    SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_NH_District_Name_Counts_and_Designation_xref`
  ),

  nh_floterial_xref AS (
    SELECT * FROM `proj-tmc-mem-fm.main.trends_2025_NH_Floterial_xref_corrected`
  ),

  -- Assign each voter to their target district level. For NH HD, also
  -- generate synthetic floterial district rows by duplicating voters
  -- into their parent floterial district.
  with_district_level AS (
    SELECT
      *,
      CASE target_district_level
        WHEN 'SD' THEN vb_vf_sd
        WHEN 'HD' THEN vb_vf_hd
        ELSE vb_vf_hd
      END AS district_number,
      target_district_level AS district_level
    FROM base_filtered

    UNION ALL

    SELECT
      bf.*,
      CONCAT(fx.Floterial_HD_Name, ' (FLOTERIAL)') AS district_number,
      'HD' AS district_level
    FROM base_filtered bf
    JOIN nh_district_xref nm
      ON bf.state = 'NH'
      AND bf.vb_vf_hd = nm.voterbase_hd_name
    JOIN nh_floterial_xref fx
      ON nm.HD = fx.HD
    WHERE
      bf.state = 'NH'
      AND target_district_level = 'HD'
  ),

  -- Scale raw TargetSmart scores to [0,1] probabilities.
  -- NatAm probability deflated by ACS correction ratio; five race fields
  -- may sum to < 1.0 after correction. The residual receives neutral
  -- treatment (factor 1.0) in maturation, stability, and scenario deltas.
  scaled AS (
    SELECT
      vb_voterbase_id,
      state,
      county_geo_id,
      district_level,
      district_number,
      vb_voterbase_age,
      effective_age,
      age_source,
      vb_voterbase_gender,
      vb_vf_earliest_registration_date,
      vb_tsmart_address_improvement_type,
      vb_tsmart_effective_date,
      vb_voterbase_mover_status,
      vb_voterbase_move_distance,
      vb_vf_county_code,
      vb_tsmart_county_code,

      clamp01(ts_tsmart_partisan_score / 100.0) AS partisanship_prob,
      clamp01(ts_tsmart_presidential_general_turnout_score / 100.0) AS pres_turnout_prob,
      clamp01(ts_tsmart_midterm_general_turnout_score / 100.0) AS mid_turnout_prob,
      clamp01(ts_tsmart_college_graduate_score / 100.0) AS college_prob,
      clamp01(ts_tsmart_high_school_only_score / 100.0) AS high_school_only_prob,
      clamp01(ts_tsmart_catholic_raw_score / 100.0) AS catholic_prob,
      clamp01(ts_tsmart_evangelical_raw_score / 100.0) AS evangelical_prob,

      clamp01(ts_tsmr_p_white) AS p_white,
      clamp01(ts_tsmr_p_black) AS p_black,
      clamp01(ts_tsmr_p_hisp) AS p_hisp,
      clamp01(ts_tsmr_p_natam) * natam_correction_ratio AS p_natam,
      clamp01(ts_tsmr_p_asian) AS p_asian

    FROM with_district_level
  ),

  with_flags AS (
    SELECT
      *,
      CASE WHEN effective_age BETWEEN 18 AND 24 THEN 1.0 ELSE 0.0 END AS age_18_24_flag,
      CASE WHEN effective_age BETWEEN 25 AND 34 THEN 1.0 ELSE 0.0 END AS age_25_34_flag,
      CASE WHEN effective_age BETWEEN 35 AND 44 THEN 1.0 ELSE 0.0 END AS age_35_44_flag,
      CASE WHEN effective_age BETWEEN 45 AND 54 THEN 1.0 ELSE 0.0 END AS age_45_54_flag,
      CASE WHEN effective_age BETWEEN 55 AND 64 THEN 1.0 ELSE 0.0 END AS age_55_64_flag,
      CASE WHEN effective_age BETWEEN 65 AND 74 THEN 1.0 ELSE 0.0 END AS age_65_74_flag,
      CASE WHEN effective_age BETWEEN 75 AND 84 THEN 1.0 ELSE 0.0 END AS age_75_84_flag,
      CASE WHEN effective_age >= 85 THEN 1.0 ELSE 0.0 END AS age_85_plus_flag,

      CASE WHEN vb_voterbase_gender = 'Female' THEN 1.0 ELSE 0.0 END AS female_flag,
      CASE WHEN vb_voterbase_gender = 'Male' THEN 1.0 ELSE 0.0 END AS male_flag,

      CASE
        WHEN vb_vf_earliest_registration_date >= DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR)
          OR vb_tsmart_effective_date >= CAST(FORMAT_DATE('%Y%m', DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR)) AS INT64)
        THEN 1.0
        ELSE 0.0
      END AS is_recent_activity,

      (pres_turnout_prob + mid_turnout_prob) / 2.0 AS expected_individual_vote,

      -- COMPOSITE IN-MOVER FLAG
      -- Classifies voters as "meaningful movers" who relocated from a
      -- meaningfully different area. Used to compute district-level partisan
      -- offsets between in-movers and long-term residents.
      -- Hierarchy: (1) TS confirmed cross-county/state, (2) within-county 5+ mi,
      -- (3) registration county != current county, (4) NCOA-confirmed + age 23+.
      CASE
        WHEN vb_voterbase_mover_status IN (
          'Moved within State', 'Moved out of State', 'Moved Left No Address'
        ) THEN 1.0
        WHEN vb_voterbase_mover_status = 'Moved within County'
             AND vb_voterbase_move_distance >= 5 THEN 1.0
        WHEN vb_vf_county_code IS NOT NULL
             AND vb_tsmart_county_code IS NOT NULL
             AND LPAD(CAST(vb_vf_county_code AS STRING), 3, '0')
                 != LPAD(CAST(vb_tsmart_county_code AS STRING), 3, '0')
        THEN 1.0
        WHEN vb_tsmart_address_improvement_type IN (1, 2, 5, 6)
             AND vb_tsmart_effective_date >= CAST(
               FORMAT_DATE('%Y%m', DATE_SUB(CURRENT_DATE(), INTERVAL 5 YEAR))
               AS INT64)
             AND effective_age >= 23
        THEN 1.0
        ELSE 0.0
      END AS is_meaningful_mover

    FROM scaled
  ),

  -- STATE-LEVEL MOVER OFFSET (fallback prior)
  -- Turnout-weighted partisan average of movers minus non-movers per state.
  state_mover_offset AS (
    SELECT
      state,
      SAFE_DIVIDE(
        SUM(CASE WHEN is_meaningful_mover > 0 THEN partisanship_prob * expected_individual_vote END),
        SUM(CASE WHEN is_meaningful_mover > 0 THEN expected_individual_vote END)
      ) - SAFE_DIVIDE(
        SUM(CASE WHEN is_meaningful_mover = 0 THEN partisanship_prob * expected_individual_vote END),
        SUM(CASE WHEN is_meaningful_mover = 0 THEN expected_individual_vote END)
      ) AS state_mover_partisan_offset,
      SAFE_DIVIDE(SUM(is_meaningful_mover), CAST(COUNT(*) AS FLOAT64)) AS state_mover_rate
    FROM with_flags
    GROUP BY state
  ),

  -- DISTRICT-LEVEL MOVER OFFSET with Bayesian smoothing
  -- Blends district-level and state-level estimates using credibility weight n/(n+k).
  -- A rate-ratio dampener prevents structurally low-migration districts from inheriting
  -- the state prior. Final offset = dampener * (cred * local + (1-cred) * state).
  district_mover_offset AS (
    SELECT
      d.state,
      d.district_level,
      d.district_number,
      d.n_movers,
      d.raw_district_offset,
      d.n_movers / (d.n_movers + min_movers_for_district_offset) AS credibility_weight,
      d.district_mover_rate,
      COALESCE(
        LEAST(
          SAFE_DIVIDE(d.district_mover_rate,
            s.state_mover_rate * mover_rate_dampening_threshold),
          1.0
        ),
        0.0
      ) AS mover_rate_dampener,
      -- Bayesian blend: dampener * (credibility * local + (1-cred) * state)
      COALESCE(
        LEAST(
          SAFE_DIVIDE(d.district_mover_rate,
            s.state_mover_rate * mover_rate_dampening_threshold),
          1.0
        ),
        0.0
      ) * (
        (
          (d.n_movers / (d.n_movers + min_movers_for_district_offset))
          * COALESCE(d.raw_district_offset, 0.0)
        ) + (
          (1.0 - d.n_movers / (d.n_movers + min_movers_for_district_offset))
          * COALESCE(s.state_mover_partisan_offset, 0.0)
        )
      ) AS mover_partisan_offset

    FROM (
      SELECT
        state,
        district_level,
        district_number,
        CAST(SUM(is_meaningful_mover) AS INT64) AS n_movers,
        SAFE_DIVIDE(SUM(is_meaningful_mover), CAST(COUNT(*) AS FLOAT64)) AS district_mover_rate,
        SAFE_DIVIDE(
          SUM(CASE WHEN is_meaningful_mover > 0 THEN partisanship_prob * expected_individual_vote END),
          SUM(CASE WHEN is_meaningful_mover > 0 THEN expected_individual_vote END)
        ) - SAFE_DIVIDE(
          SUM(CASE WHEN is_meaningful_mover = 0 THEN partisanship_prob * expected_individual_vote END),
          SUM(CASE WHEN is_meaningful_mover = 0 THEN expected_individual_vote END)
        ) AS raw_district_offset
      FROM with_flags
      GROUP BY state, district_level, district_number
    ) d
    LEFT JOIN state_mover_offset s ON d.state = s.state
  ),

  -- District-level profile for college-town detection
  district_profile AS (
    SELECT
      state,
      district_level,
      district_number,
      COUNT(*) AS total_voters,
      SUM(age_18_24_flag) AS total_age_18_24,
      SAFE_DIVIDE(SUM(age_18_24_flag), COUNT(*)) AS pct_voters_18_24,
      SAFE_DIVIDE(SUM(is_recent_activity), COUNT(*)) AS pct_recent_activity_5yr
    FROM with_flags
    GROUP BY state, district_level, district_number
  ),

  district_county_dist AS (
    SELECT
      state, district_level, district_number, county_geo_id,
      COUNT(*) AS voters_in_county,
      ROW_NUMBER() OVER (
        PARTITION BY state, district_level, district_number
        ORDER BY COUNT(*) DESC
      ) AS rn
    FROM with_flags
    GROUP BY state, district_level, district_number, county_geo_id
  ),

  district_dominant_county AS (
    SELECT state, district_level, district_number, county_geo_id
    FROM district_county_dist
    WHERE rn = 1
  ),

  district_dominant_stability AS (
    SELECT
      d.state, d.district_level, d.district_number,
      s_age_18_19.five_year_stability_rate AS dominant_age_18_19_stability
    FROM district_dominant_county d
    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_age_18_19
      ON s_age_18_19.GEO_ID = d.county_geo_id
      AND s_age_18_19.cohort_group = 'age'
      AND s_age_18_19.cohort_name = 'age_18_19'
  ),

  -- College-town classification: two tiers by severity.
  -- Tier 2 (strong college) gets a heavier maturation scalar.
  -- Tier 1 explicitly excludes Tier 2 districts.
  district_college_flags AS (
    SELECT
      dp.state, dp.district_level, dp.district_number,
      dp.pct_voters_18_24,
      dp.pct_recent_activity_5yr,
      ds.dominant_age_18_19_stability,
      CASE
        WHEN ds.dominant_age_18_19_stability IS NOT NULL
             AND ds.dominant_age_18_19_stability <= college_tier2_stability_threshold
             AND dp.pct_voters_18_24 >= college_tier2_pct_18_24_threshold
             AND dp.pct_recent_activity_5yr >= college_tier2_churn_threshold
        THEN TRUE
        ELSE FALSE
      END AS is_college_tier2,
      CASE
        WHEN ds.dominant_age_18_19_stability IS NOT NULL
             AND ds.dominant_age_18_19_stability <= college_tier1_stability_threshold
             AND dp.pct_voters_18_24 >= college_tier1_pct_18_24_threshold
             AND dp.pct_recent_activity_5yr >= college_tier1_churn_threshold
             AND NOT (
               ds.dominant_age_18_19_stability <= college_tier2_stability_threshold
               AND dp.pct_voters_18_24 >= college_tier2_pct_18_24_threshold
               AND dp.pct_recent_activity_5yr >= college_tier2_churn_threshold
             )
        THEN TRUE
        ELSE FALSE
      END AS is_college_tier1
    FROM district_profile dp
    LEFT JOIN district_dominant_stability ds
      ON dp.state = ds.state
      AND dp.district_level = ds.district_level
      AND dp.district_number = ds.district_number
  ),

  -- Apply global_all cohort adjustments to partisanship probability
  with_global_all AS (
    SELECT
      *,
      clamp01(
        partisanship_prob
        + (p_hisp * global_all_delta_hisp)
        + (p_black * global_all_delta_black)
        + (p_asian * global_all_delta_asian)
        + (p_white * global_all_delta_white)
        + (high_school_only_prob * global_all_delta_high_school_only)
        + (college_prob * global_all_delta_college)
        + (catholic_prob * global_all_delta_catholic)
        + (evangelical_prob * global_all_delta_evangelical)
        + (age_18_24_flag * global_all_delta_age_18_24)
        + (age_25_34_flag * global_all_delta_age_25_34)
        + (age_35_44_flag * global_all_delta_age_35_44)
        + (age_45_54_flag * global_all_delta_age_45_54)
        + (age_55_64_flag * global_all_delta_age_55_64)
        + (age_65_74_flag * global_all_delta_age_65_74)
        + (age_75_84_flag * global_all_delta_age_75_84)
        + (age_85_plus_flag * global_all_delta_age_85_plus)
      ) AS partisanship_prob_all
    FROM with_flags
  ),

  -- ===========================================================================
  -- [IMP #1] RACE-DIFFERENTIATED MORTALITY
  -- Ported from state model Step 1 v2.0.
  --
  -- Replaces hardcoded pooled mortality CASE (age × flat sex multiplier) with
  -- CDC 2023 race-specific life tables. Per-voter survival is a probability-
  -- weighted blend: race_mort = Σ(p_race × mort_race) for each voter's race
  -- probability vector.
  --
  -- CDC table: trends_2025_cdc_race_mortality_rates (96 rows: 4 race × 8 age × 3 sex)
  -- Pivoted here to 24 rows (8 age bands × 3 genders) with race-specific columns.
  --
  -- Key differentials (Black/White at working ages): 1.4–2.4×
  -- Hispanic paradox: Hispanic mortality 0.77–0.85× White
  -- Asian/Other: 0.34–0.65× White
  --
  -- LOWER() on age_band() resolves UDF output '85_PLUS' vs CDC table '85_plus'.
  -- ===========================================================================

  cdc_mortality_pivot AS (
    SELECT
      mortality_age_band,
      gender,
      MAX(CASE WHEN race_group = 'nh_white' THEN five_year_mortality_rate END) AS mort_white,
      MAX(CASE WHEN race_group = 'nh_black' THEN five_year_mortality_rate END) AS mort_black,
      MAX(CASE WHEN race_group = 'hispanic' THEN five_year_mortality_rate END) AS mort_hisp,
      MAX(CASE WHEN race_group = 'other'    THEN five_year_mortality_rate END) AS mort_other
    FROM `proj-tmc-mem-fm.main.trends_2025_cdc_race_mortality_rates`
    GROUP BY mortality_age_band, gender
  ),

  -- 5-year mortality: race-differentiated CDC rates scaled by healthy-voter effect
  with_mortality AS (
    SELECT
      g.*,
      clamp01(1.0 - (
        (
          g.p_white * COALESCE(mort.mort_white, 0.0)
          + g.p_black * COALESCE(mort.mort_black, 0.0)
          + g.p_hisp  * COALESCE(mort.mort_hisp, 0.0)
          -- 'other' group receives Asian + NatAm + residual probability mass
          + (g.p_asian + g.p_natam
             + GREATEST(0.0, 1.0 - (g.p_white + g.p_black + g.p_hisp + g.p_asian + g.p_natam))
            ) * COALESCE(mort.mort_other, 0.0)
        )
        * mortality_scalar
      )) AS survival_prob_5yr
    FROM with_global_all g
    LEFT JOIN cdc_mortality_pivot mort
      ON mort.mortality_age_band = LOWER(age_band(g.effective_age))
      AND mort.gender = COALESCE(g.vb_voterbase_gender, 'Unknown')
  ),

  -- 5-year migration survival: weighted blend of age, race, and education
  -- ACS stability rates (60/30/10 weighting). Falls back to overall stability
  -- if all cohort-specific rates are NULL.
  -- Also computes race-weighted maturation factor from ACS youth composition shifts.
  with_migration AS (
    SELECT
      t.*,
      clamp01(
        CASE
          WHEN t.s_age_raw IS NOT NULL
               OR t.s_race_raw IS NOT NULL
               OR t.s_edu_raw IS NOT NULL
          THEN
            SAFE_DIVIDE(
              0.6 * IFNULL(t.s_age_raw, 0.0) +
              0.3 * IFNULL(t.s_race_raw, 0.0) +
              0.1 * IFNULL(t.s_edu_raw, 0.0),
              0.6 * IF(t.s_age_raw IS NULL, 0.0, 1.0) +
              0.3 * IF(t.s_race_raw IS NULL, 0.0, 1.0) +
              0.1 * IF(t.s_edu_raw IS NULL, 0.0, 1.0)
            )
          ELSE
            t.s_overall
        END
      ) AS migration_survival_prob_5yr,

      -- [IMP #3] Maturation IFNULL defaults changed from 1.0 to 0.0.
      -- When a county is missing from the ACS maturation table, this now
      -- assumes no new youth registrants (conservative) rather than neutral
      -- replacement (optimistic). Affects 2 counties across 17 target states.
      (
        (t.p_white * IFNULL(acs_growth.New_Reg_Factor_White, 1.0)) +
        (t.p_black * IFNULL(acs_growth.New_Reg_Factor_Black, 1.0)) +
        (t.p_hisp  * IFNULL(acs_growth.New_Reg_Factor_Hispanic, 1.0)) +
        (t.p_natam * IFNULL(acs_growth.New_Reg_Factor_NatAm, 1.0)) +
        (t.p_asian * IFNULL(acs_growth.New_Reg_Factor_Asian, 1.0))
        + (1.0 - (t.p_white + t.p_black + t.p_hisp + t.p_natam + t.p_asian)) * 1.0
      ) AS acs_race_weighted_maturation_factor

    FROM (
      SELECT
        m.*,
        s_overall.five_year_stability_rate AS s_overall,
        s_age.five_year_stability_rate AS s_age_raw,
        SAFE_DIVIDE(
          m.p_white * s_white.five_year_stability_rate +
          m.p_black * s_black.five_year_stability_rate +
          m.p_hisp  * s_hisp.five_year_stability_rate +
          m.p_natam * s_natam.five_year_stability_rate +
          m.p_asian * s_asian.five_year_stability_rate,
          NULLIF(m.p_white + m.p_black + m.p_hisp + m.p_natam + m.p_asian, 0.0)
        ) AS s_race_raw,
        SAFE_DIVIDE(
          m.high_school_only_prob * s_hs.five_year_stability_rate +
          m.college_prob * s_ba.five_year_stability_rate,
          NULLIF(m.high_school_only_prob + m.college_prob, 0.0)
        ) AS s_edu_raw
      FROM with_mortality m
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_overall
        ON s_overall.GEO_ID = m.county_geo_id AND s_overall.cohort_group = 'overall' AND s_overall.cohort_name = 'overall'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_age
        ON s_age.GEO_ID = m.county_geo_id AND s_age.cohort_group = 'age'
        AND s_age.cohort_name = CASE
          WHEN m.effective_age BETWEEN 18 AND 19 THEN 'age_18_19'
          WHEN m.effective_age BETWEEN 20 AND 24 THEN 'age_20_24'
          WHEN m.effective_age BETWEEN 25 AND 29 THEN 'age_25_29'
          WHEN m.effective_age BETWEEN 30 AND 34 THEN 'age_30_34'
          WHEN m.effective_age BETWEEN 35 AND 39 THEN 'age_35_39'
          WHEN m.effective_age BETWEEN 40 AND 44 THEN 'age_40_44'
          WHEN m.effective_age BETWEEN 45 AND 49 THEN 'age_45_49'
          WHEN m.effective_age BETWEEN 50 AND 54 THEN 'age_50_54'
          WHEN m.effective_age BETWEEN 55 AND 59 THEN 'age_55_59'
          WHEN m.effective_age BETWEEN 60 AND 64 THEN 'age_60_64'
          WHEN m.effective_age BETWEEN 65 AND 69 THEN 'age_65_69'
          WHEN m.effective_age BETWEEN 70 AND 74 THEN 'age_70_74'
          WHEN m.effective_age >= 75 THEN 'age_75_plus'
          ELSE 'age_18_19'
        END
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_hs
        ON s_hs.GEO_ID = m.county_geo_id AND s_hs.cohort_group = 'education' AND s_hs.cohort_name = 'hs_grad_or_less'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_ba
        ON s_ba.GEO_ID = m.county_geo_id AND s_ba.cohort_group = 'education' AND s_ba.cohort_name = 'college_grad'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_white
        ON s_white.GEO_ID = m.county_geo_id AND s_white.cohort_group = 'race_ethnicity' AND s_white.cohort_name = 'white'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_black
        ON s_black.GEO_ID = m.county_geo_id AND s_black.cohort_group = 'race_ethnicity' AND s_black.cohort_name = 'black'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_hisp
        ON s_hisp.GEO_ID = m.county_geo_id AND s_hisp.cohort_group = 'race_ethnicity' AND s_hisp.cohort_name = 'hispanic'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_natam
        ON s_natam.GEO_ID = m.county_geo_id AND s_natam.cohort_group = 'race_ethnicity' AND s_natam.cohort_name = 'natam'
      LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_stability_and_mover_rates` s_asian
        ON s_asian.GEO_ID = m.county_geo_id AND s_asian.cohort_group = 'race_ethnicity' AND s_asian.cohort_name = 'asian'
    ) AS t
    LEFT JOIN `proj-tmc-mem-fm.main.trends_2025_acs_race_maturation_factors` acs_growth
      ON acs_growth.GEO_ID = t.county_geo_id
  ),

  -- Compute per-voter maturation and mover factors, attach college-town flags
  weighted_prep AS (
    SELECT
      w.*,
      dcf.is_college_tier1,
      dcf.is_college_tier2,
      CASE
        WHEN w.state = 'AZ' THEN migration_in_district_factor_sd
        WHEN w.district_level = 'SD' THEN migration_in_district_factor_sd
        ELSE migration_in_district_factor_hd
      END AS mover_impact_fraction,

      -- Maturation factor for 18-22 year olds: 1 = existing young voters,
      -- + acs_factor = expected new voters aging in from 15-17 cohort
      CASE
        WHEN w.effective_age BETWEEN 18 AND 22
        THEN 1.0 + w.acs_race_weighted_maturation_factor
        ELSE 1.0
      END AS maturation_factor,

      CASE
        WHEN w.effective_age >= min_inmover_age
        THEN 1.0 + (
          (1.0 - w.migration_survival_prob_5yr) * CASE
            WHEN w.state = 'AZ' THEN migration_in_district_factor_sd
            WHEN w.district_level = 'SD' THEN migration_in_district_factor_sd
            ELSE migration_in_district_factor_hd
          END
        )
        ELSE 1.0
      END AS raw_mover_factor

    FROM with_migration w
    LEFT JOIN district_college_flags dcf
      ON w.state = dcf.state
      AND w.district_level = dcf.district_level
      AND w.district_number = dcf.district_number
  ),

  -- FINAL VOTER WEIGHTS
  -- Split expected_vote_weight into three components so replacement-mover
  -- voters can receive the district mover offset in the aggregation step.
  --   1. staying_weight: survive mortality AND stay in district
  --   2. replacement_youth_weight: 18-22yo aging-in (no mover offset)
  --   3. replacement_mover_weight: in-movers replacing out-movers (gets offset)
  weighted AS (
    SELECT
      vb_voterbase_id,
      w.state,
      w.district_level,
      w.district_number,
      county_geo_id,
      vb_voterbase_age,
      effective_age,
      age_source,
      vb_vf_earliest_registration_date,
      vb_tsmart_address_improvement_type,
      vb_tsmart_effective_date,
      partisanship_prob,
      partisanship_prob_all,
      p_white, p_black, p_hisp, p_natam, p_asian,
      college_prob, high_school_only_prob,
      catholic_prob, evangelical_prob,
      age_18_24_flag, age_25_34_flag, age_35_44_flag, age_45_54_flag,
      age_55_64_flag, age_65_74_flag, age_75_84_flag, age_85_plus_flag,
      female_flag, male_flag,
      expected_individual_vote,
      survival_prob_5yr,
      migration_survival_prob_5yr,
      maturation_factor,
      raw_mover_factor,
      mover_impact_fraction,

      GREATEST(
        CASE
          WHEN effective_age < 25 THEN migration_stability_floor_under_25
          ELSE migration_stability_floor_25_plus
        END,
        1.0 - mover_impact_fraction * (1.0 - migration_survival_prob_5yr)
      ) AS migration_survival_prob_5yr_eff,

      raw_mover_factor AS mover_factor,

      -- Component 1: STAYING WEIGHT
      expected_individual_vote * (
        survival_prob_5yr * GREATEST(
          CASE
            WHEN effective_age < 25 THEN migration_stability_floor_under_25
            ELSE migration_stability_floor_25_plus
          END,
          1.0 - mover_impact_fraction * (1.0 - migration_survival_prob_5yr)
        )
      ) AS staying_weight,

      -- Component 2: REPLACEMENT --- YOUTH MATURATION
      -- College-town scalar applied inside the LEAST() cap to prevent double-dampening.
      CASE
        WHEN effective_age BETWEEN 18 AND 22 THEN
          expected_individual_vote * (
            LEAST(
              (maturation_factor - 1.0) * CASE
                WHEN apply_college_town_fix AND is_college_tier2 THEN
                  college_tier2_maturation_scalar
                WHEN apply_college_town_fix AND is_college_tier1 THEN
                  college_tier1_maturation_scalar
                ELSE
                  1.0
              END,
              1.5
            )
          )
        ELSE 0.0
      END AS replacement_youth_weight,

      -- Component 3: REPLACEMENT --- IN-MOVERS
      -- Uses floored effective migration survival rate for consistency with staying_weight.
      CASE
        WHEN effective_age BETWEEN 18 AND 22 THEN 0.0
        ELSE
          expected_individual_vote * (
            1.0 - GREATEST(
              CASE
                WHEN effective_age < 25 THEN migration_stability_floor_under_25
                ELSE migration_stability_floor_25_plus
              END,
              1.0 - mover_impact_fraction * (1.0 - migration_survival_prob_5yr)
            )
          )
      END AS replacement_mover_weight,

      -- Total expected_vote_weight = staying + youth replacement + mover replacement
      (
        expected_individual_vote * (
          (
            survival_prob_5yr * GREATEST(
              CASE
                WHEN effective_age < 25 THEN migration_stability_floor_under_25
                ELSE migration_stability_floor_25_plus
              END,
              1.0 - mover_impact_fraction * (1.0 - migration_survival_prob_5yr)
            )
          )
          +
          CASE
            WHEN effective_age BETWEEN 18 AND 22 THEN
               LEAST(
                  (maturation_factor - 1.0) * CASE
                    WHEN apply_college_town_fix AND is_college_tier2 THEN
                      college_tier2_maturation_scalar
                    WHEN apply_college_town_fix AND is_college_tier1 THEN
                      college_tier1_maturation_scalar
                    ELSE
                      1.0
                  END,
                  1.5
               )
            ELSE
              1.0 - GREATEST(
                CASE
                  WHEN effective_age < 25 THEN migration_stability_floor_under_25
                  ELSE migration_stability_floor_25_plus
                END,
                1.0 - mover_impact_fraction * (1.0 - migration_survival_prob_5yr)
              )
          END
        )
      ) AS expected_vote_weight,

      dmo.mover_partisan_offset

    FROM weighted_prep w
    LEFT JOIN district_mover_offset dmo
      ON w.state = dmo.state
      AND w.district_level = dmo.district_level
      AND w.district_number = dmo.district_number
  )

SELECT * FROM weighted;

-- ===========================================================================
-- PART 2: SIMULATION & AGGREGATION
-- Cross every voter against the scenario grid (demographic deltas × uniform
-- swings) and aggregate to district-level expected Democratic vote share.
-- ===========================================================================

CREATE TEMP TABLE _final_results AS

WITH

  scenario_grid AS (
    SELECT
      vc.name AS vote_choice_scenario,
      vc.delta_hisp, vc.delta_black, vc.delta_asian, vc.delta_natam, vc.delta_white,
      vc.delta_high_school_only, vc.delta_college,
      vc.delta_catholic, vc.delta_evangelical,
      vc.delta_age_18_24, vc.delta_age_25_34, vc.delta_age_35_44, vc.delta_age_45_54,
      vc.delta_age_55_64, vc.delta_age_65_74, vc.delta_age_75_84, vc.delta_age_85_plus,
      vc.delta_female, vc.delta_male,
      us AS uniform_swing_scenario
    FROM `proj-tmc-mem-fm.main.trends_2026_scenarios` vc
    CROSS JOIN UNNEST(uniform_swings) us
    WHERE
      NOT diagnostic_mode
      OR (diagnostic_mode
          AND vc.name = 'balanced_Baseline'
          AND us = 0)
  ),

  -- Apply scenario deltas + global_non_present adjustments + uniform swing
  -- to each voter's adjusted partisanship probability
  per_voter_scenarios AS (
    SELECT
      p.state, p.district_level, p.district_number,
      sg.vote_choice_scenario,
      sg.uniform_swing_scenario,
      clamp01(
        p.partisanship_prob_all
        + (p.p_hisp * global_non_present_delta_hisp)
        + (p.p_black * global_non_present_delta_black)
        + (p.p_asian * global_non_present_delta_asian)
        + (p.p_white * global_non_present_delta_white)
        + (p.high_school_only_prob * global_non_present_delta_high_school_only)
        + (p.college_prob * global_non_present_delta_college)
        + (p.catholic_prob * global_non_present_delta_catholic)
        + (p.evangelical_prob * global_non_present_delta_evangelical)
        + (p.age_18_24_flag * global_non_present_delta_age_18_24)
        + (p.age_25_34_flag * global_non_present_delta_age_25_34)
        + (p.age_35_44_flag * global_non_present_delta_age_35_44)
        + (p.age_45_54_flag * global_non_present_delta_age_45_54)
        + (p.age_55_64_flag * global_non_present_delta_age_55_64)
        + (p.age_65_74_flag * global_non_present_delta_age_65_74)
        + (p.age_75_84_flag * global_non_present_delta_age_75_84)
        + (p.age_85_plus_flag * global_non_present_delta_age_85_plus)
        + (sg.uniform_swing_scenario / 100.0)
        + (p.p_hisp * sg.delta_hisp)
        + (p.p_black * sg.delta_black)
        + (p.p_asian * sg.delta_asian)
        + (p.p_natam * sg.delta_natam)
        + (p.p_white * sg.delta_white)
        + (p.high_school_only_prob * sg.delta_high_school_only)
        + (p.college_prob * sg.delta_college)
        + (p.catholic_prob * sg.delta_catholic)
        + (p.evangelical_prob * sg.delta_evangelical)
        + (p.age_18_24_flag * sg.delta_age_18_24)
        + (p.age_25_34_flag * sg.delta_age_25_34)
        + (p.age_35_44_flag * sg.delta_age_35_44)
        + (p.age_45_54_flag * sg.delta_age_45_54)
        + (p.age_55_64_flag * sg.delta_age_55_64)
        + (p.age_65_74_flag * sg.delta_age_65_74)
        + (p.age_75_84_flag * sg.delta_age_75_84)
        + (p.age_85_plus_flag * sg.delta_age_85_plus)
        + (p.female_flag * sg.delta_female)
        + (p.male_flag * sg.delta_male)
      ) AS dem_prob_scenario,
      p.staying_weight,
      p.replacement_youth_weight,
      p.replacement_mover_weight,
      p.expected_vote_weight,
      p.mover_partisan_offset
    FROM _weighted_voters p
    CROSS JOIN scenario_grid sg
  ),

  -- Aggregate to district level. Mover offset only applies to the
  -- replacement_mover_weight portion; staying voters and youth are unshifted.
  district_aggregates AS (
    SELECT
      state, district_level, district_number,
      vote_choice_scenario,
      uniform_swing_scenario,
      SUM(staying_weight * dem_prob_scenario)
      + SUM(replacement_youth_weight * dem_prob_scenario)
      + SUM(replacement_mover_weight * clamp01(dem_prob_scenario + COALESCE(mover_partisan_offset, 0.0)))
      AS total_expected_dem_votes,
      SUM(expected_vote_weight) AS total_expected_votes
    FROM per_voter_scenarios
    GROUP BY state, district_level, district_number, vote_choice_scenario, uniform_swing_scenario
  ),

  district_shares AS (
    SELECT
      state, district_level, district_number,
      vote_choice_scenario,
      uniform_swing_scenario,
      SAFE_DIVIDE(total_expected_dem_votes, total_expected_votes)
      AS expected_dem_vote_share
    FROM district_aggregates
  ),

  -- Present-day baseline: no 5-year churn, just global_all adjustments × turnout
  with_global_all_summary AS (
    SELECT
      state, district_level, district_number,
      SUM(expected_individual_vote * partisanship_prob_all) as sum_dem,
      SUM(expected_individual_vote) as sum_total
    FROM _weighted_voters
    GROUP BY state, district_level, district_number
  ),

  present_day_district_shares AS (
    SELECT
      state, district_level, district_number,
      'present_day_baseline' AS vote_choice_scenario,
      0 AS uniform_swing_scenario,
      SAFE_DIVIDE(sum_dem, sum_total) AS expected_dem_vote_share,
      sum_total AS total_expected_votes
    FROM with_global_all_summary
  ),

  district_shares_all AS (
    SELECT * FROM district_shares
    UNION ALL
    SELECT
      state, district_level, district_number,
      vote_choice_scenario,
      uniform_swing_scenario,
      expected_dem_vote_share
    FROM present_day_district_shares
  ),

  -- Join present-day baseline and total_expected_votes to every scenario row.
  -- COALESCE ensures the present_day_baseline row itself gets a non-NULL total.
  with_comparisons AS (
    SELECT
      ds.*,
      pd.expected_dem_vote_share AS present_day_dem_share,
      COALESCE(da.total_expected_votes, pd.total_expected_votes) AS total_expected_votes
    FROM district_shares_all ds
    LEFT JOIN present_day_district_shares pd
    USING (state, district_level, district_number)
    LEFT JOIN district_aggregates da
    ON ds.state = da.state
    AND ds.district_level = da.district_level
    AND ds.district_number = da.district_number
    AND ds.vote_choice_scenario = da.vote_choice_scenario
    AND ds.uniform_swing_scenario = da.uniform_swing_scenario
  )

-- FINAL OUTPUT
SELECT
  state,
  district_level,
  district_number,
  vote_choice_scenario,
  uniform_swing_scenario,
  expected_dem_vote_share,
  present_day_dem_share,
  (expected_dem_vote_share - present_day_dem_share) AS scenario_delta,
  total_expected_votes
FROM with_comparisons
ORDER BY
  state,
  vote_choice_scenario,
  uniform_swing_scenario,
  district_number;

-- ===========================================================================
-- PART 3: OUTPUT
-- ===========================================================================

BEGIN
  DECLARE output_table_name STRING;
  DECLARE demo_table_name STRING;

  IF make_table_mode THEN
    IF target_district_level = 'HD' THEN
      SET output_table_name = 'proj-tmc-mem-fm.main.trends_2025_core_model_outputs_hd';
      SET demo_table_name = 'proj-tmc-mem-fm.main.trends_2025_weighted_demo_shares_hd';
    ELSE
      SET output_table_name = 'proj-tmc-mem-fm.main.trends_2025_core_model_outputs_sd';
      SET demo_table_name = 'proj-tmc-mem-fm.main.trends_2025_weighted_demo_shares_sd';
    END IF;

    EXECUTE IMMEDIATE format("""
      CREATE OR REPLACE TABLE `%s` AS SELECT * FROM _final_results
    """, output_table_name);

    SELECT format('Successfully created table: %s', output_table_name) as status;

    -- Weighted demographics export (required by Step 5 for driver rankings
    -- using turnout-weighted denominators instead of raw headcounts)
    IF export_weighted_demographics THEN
      EXECUTE IMMEDIATE format("""
        CREATE OR REPLACE TABLE `%s` AS
        SELECT
          state,
          district_level,
          district_number,
          COUNT(*) as weighted_count,
          SUM(expected_vote_weight) as total_weight,
          SAFE_DIVIDE(SUM(expected_vote_weight * p_white), SUM(expected_vote_weight)) as weighted_pct_white,
          SAFE_DIVIDE(SUM(expected_vote_weight * p_black), SUM(expected_vote_weight)) as weighted_pct_black,
          SAFE_DIVIDE(SUM(expected_vote_weight * p_hisp), SUM(expected_vote_weight)) as weighted_pct_latino,
          SAFE_DIVIDE(SUM(expected_vote_weight * p_asian), SUM(expected_vote_weight)) as weighted_pct_asian,
          SAFE_DIVIDE(SUM(expected_vote_weight * p_natam), SUM(expected_vote_weight)) as weighted_pct_natam,
          SAFE_DIVIDE(SUM(expected_vote_weight * college_prob), SUM(expected_vote_weight)) as weighted_pct_college,
          SAFE_DIVIDE(SUM(expected_vote_weight * high_school_only_prob), SUM(expected_vote_weight)) as weighted_pct_high_school_only,
          SAFE_DIVIDE(SUM(expected_vote_weight * catholic_prob), SUM(expected_vote_weight)) as weighted_pct_catholic,
          SAFE_DIVIDE(SUM(expected_vote_weight * evangelical_prob), SUM(expected_vote_weight)) as weighted_pct_evangelical,
          SAFE_DIVIDE(SUM(expected_vote_weight * female_flag), SUM(expected_vote_weight)) as weighted_pct_female,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_18_24_flag), SUM(expected_vote_weight)) as weighted_pct_age_18_24,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_25_34_flag), SUM(expected_vote_weight)) as weighted_pct_age_25_34,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_35_44_flag), SUM(expected_vote_weight)) as weighted_pct_age_35_44,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_45_54_flag), SUM(expected_vote_weight)) as weighted_pct_age_45_54,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_55_64_flag), SUM(expected_vote_weight)) as weighted_pct_age_55_64,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_65_74_flag), SUM(expected_vote_weight)) as weighted_pct_age_65_74,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_75_84_flag), SUM(expected_vote_weight)) as weighted_pct_age_75_84,
          SAFE_DIVIDE(SUM(expected_vote_weight * age_85_plus_flag), SUM(expected_vote_weight)) as weighted_pct_age_85_plus
        FROM _weighted_voters
        GROUP BY 1, 2, 3
      """, demo_table_name);

      SELECT format('Successfully created weighted demographics table: %s', demo_table_name) as status;
    END IF;

  ELSE
    SELECT * FROM _final_results;
  END IF;

END;

-- END STEP 2
