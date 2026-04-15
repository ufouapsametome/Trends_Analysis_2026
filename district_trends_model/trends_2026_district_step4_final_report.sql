/*
================================================================================
district_trends_2026_step4_final_report
v11.0
adapted from
trends_2025_district_step6_final_report
v8.2
adapted from trends_2025_step6_final_report
================================================================================
v11.0 CHANGES (from v10.1):
[REL #1] Mormon and Jewish added to the religion modifier system.
         driver_display_names CTE adds 'Mormon' and 'Jewish' STRUCTs (so
         they can render in tipping condition driver slots), and gains
         display_name_bare entries for both. The religion modifier inner
         CASE in all 7 explanation categories (Clear Noncomp, Peripheral
         Noncomp, Core 4a, Core 4b, Strong Comp, Conditional Comp,
         Marginal) extends from a 2-way Catholic/Evangelical pick to an
         explicit 4-way CASE that also handles Mormon and Jewish. The
         outer gate (religion_driver != 'None') is unchanged.
[REL #2] cohort_overrepresentation comment updated to note that Mormon
         and Jewish are also excluded (handled by religion modifier),
         consistent with the existing Catholic/Evangelical treatment.
         No structural change to the CTE itself — the unpivot inclusion
         list still covers only the 9 non-religious cohorts.
[REL #3] final_output gains 4 pass-through columns: pct_mormon,
         pct_jewish, idx_mormon_vs_state, idx_jewish_vs_state.
         Output column count: 47 -> 51.

         Requires: Step 3 v2.2+ (provides the new pct_*, idx_*_vs_state
         columns and a religion_driver field that can take values
         'Mormon' and 'Jewish' in addition to 'Catholic' / 'Evangelical' /
         'None').

Purpose:
Reads the Step 3 analytics table and produces a human-readable final
report with natural-language tipping-point explanations for every
district.
Generates two fields:
- district_archetype: 7-type structural classification (was 4-type)
- tipping_point_explanation: Interpretive natural-language explanation
focused on contextual insight rather than
data recitation. Scaled to explanatory need:
short for aligned districts, detailed for
grey-area disconnects.
v8.1 CHANGES (from v8.0):
[REV #56] ROUND removed from all band calculations:
Step 2 §17.3 defines band as total_chamber_seats × fraction (no ROUND).
Step 4 previously wrapped all band calculations in ROUND(), creating a
mismatch: for GA House, ROUND(180 × 0.07) = 13 vs raw 12.6. This masked
rank-cliff districts (GA-HD-070: rank 13, band 12.6, PTP = 1.18%) by
making them appear inside the band to exception flag logic.
ROUND removed from: rank_band, targeting_band, rule_b_rank_met, flag_e3,
flag_e5, flag_e6, flag_e7, flag_e8, flag_e9, and exception_priority CASE
(~17 instances total). Band values are now FLOAT64.
Impact: districts at the exact ROUND boundary may shift exception flags.
Expected to affect fewer than 10 districts across 2,620; all shifts are
corrections aligning Step 4 with Step 2's actual behavior.
[REV #57] E6 text enriched with binding-dimension specificity:
E6 structural context sentence now surfaces which dimension (rank vs
margin) is the binding constraint:
- Rank-cliff: margin ≤ 4% (passes Rule B) but rank outside band.
  Text: "The X-point margin is inside the model's competitive threshold,
  but at rank Y the district sits just outside the Z-seat competitive
  band — a rank-boundary effect..."
- Margin-cliff: rank inside band (rule_b_rank_met) but margin outside.
  Text: "The district is within the competitive rank band, but its
  X-point margin places it just outside the model's target zone."
- Both outside: retains generic fallback text.
Touch points: Peripheral Noncompetitive E6 (1 instance), Conditional
Competitive E6 (1 instance), Marginal E6 (1 instance).
v7.0 CHANGES (from v6.3):
[REV #44] PTP tier rebalance for scenario-directional framing:
Replaced 4-tier system (exit-only >= 0.93, wide-range 0.75-0.93,
two-sided 0.10-0.75, entry-only < 0.10) with 3-tier system:
Exit-only: PTP > 0.80
Two-sided: PTP 0.30–0.80
Entry-only: PTP < 0.30
The "wide-range" tier is eliminated. The primary_category classification
(7-way) is UNCHANGED; only scenario-direction sentence rendering is
affected. Touch points: Strong Competitive (split at 0.80 instead of
0.75), Conditional Competitive (new entry-only branch for PTP < 0.30),
Tipping-Point Core subcase 4b (unchanged, all PTP > 0.80 by definition).
[REV #45] Mirror-image exit clause simplification:
Exit clauses for two-sided framing replaced with "it falls out when the
reverse is true." Since exit_cohort_description is always the structural
inverse of entry_cohort_description, stating both is redundant. Applies
uniformly regardless of dominant_entry_direction (same-direction and
mixed-direction cases).
Exit-only framing (PTP > 0.80) still uses exit_cohort_description
directly, since no entry clause is present to serve as referent.
"Voters" deduplication: driver_display_names CTE now carries
display_name_bare (without trailing "voters"/"voters (qualifier)").
Same-direction two-driver entry/exit descriptions use bare names joined
with "and" + single trailing "voters". Opposite-direction descriptions
retain full display_name per clause (each clause needs its own "voters").
[REV #46] E2-inverse always uses 2030 projected values:
Removed e2_inverse_share_label and fmt_e2_inverse_share from classified
CTE. E2-inverse template now always uses fmt_dem_proj_pct (2030
projected share). Fixes math inconsistency where 2025 share was
displayed alongside 2030 baseline_margin_to_median (AZ-HD-009:
"current 52.6% Dem share... 4.3 points above" was actually 3.2 points).
[REV #47] Cohort overrepresentation statement:
New cohort_overrepresentation CTE unpivots 9 demographic index/share
pairs (White, Black, Latino, Asian, Native American, college-educated,
high-school-only, youth 18-34, senior 65+) per district. Female,
Catholic, and Evangelical excluded (Female near-parity everywhere;
religion handled by existing religion modifier).
Overrepresentation threshold: idx_cohort_vs_state >= 1.10 AND
pct_cohort >= 0.06. Top 3 by idx descending. (Sentence template
superseded by v7.1 REV #51; see below for current format.)
Statewide-average detection: when ALL cohorts with pct_cohort >= 0.02
have idx BETWEEN 0.95 AND 1.05, renders: "The demographics of this
district closely reflect the statewide averages across all cohorts."
Sentence inserted before religion modifier in Categories 2-7.
Safe Noncompetitive (Category 1) omitted (half-sentence dismissal).
[REV #48] "Very close" language softened:
"This district is very close to the median" → "This district is close
to the median" in Tipping-Point Core subcase 4a (3 instances).
v7.1 CHANGES (from v7.0):
[REV #49] "Most sensitive to" driver clause removed:
Removed from Tipping-Point Core (section 5) and Peripheral Noncompetitive.
The overrep sentence (REV #47) now covers demographic composition, and the
scenario-directional opening covers cohort sensitivity, making this clause
redundant. Affected districts: AK-HD-005, MN-HD-55A (Core), MI-SD-028
(Peripheral Noncompetitive).
[REV #50] Position statement deduplication:
When E7 fires, the position statement now renders margin-only (suppresses
rank component, since E7 template already states rank distance). Applies
to Core rank clause, Strong Competitive, Conditional Competitive, and
Marginal position statements.
When E2-inverse fires, the position statement now renders rank-only
(suppresses margin component, since E2-inverse template already states
margin to median). Applies to Conditional Competitive and Marginal
position statements.
[REV #51] Overrep sentence restructured:
Template changed from "This district has notably high concentrations of
[cohort] residents (X% of state avg)" to "District has high shares of
[cohort] (X% of state avg), [cohort] (Y%), and [cohort] voters (Z%)."
Shorter cohort labels (no "residents"), "% of state avg" on first cohort
only, "voters" as collective noun on final cohort. Singular form:
"District has a high share of [cohort] voters (X% of state avg)."
[REV #52] E8 template adds partisan direction:
"At X points from the median" → "At X points on the [D/R] side of the
median" in Strong Competitive, Conditional Competitive, and Marginal E8
templates.
[REV #53] E9 template text correction:
"Baseline position is outside the core competitive zone" → "Baseline
position is outside the tipping-point zone" in Strong Competitive,
Conditional Competitive, and Marginal E9 templates (3 instances).
[REV #54] Leading-space fix (LTRIM):
LTRIM wrapper added to Strong Competitive, Conditional Competitive
non-E1, and Marginal non-E1 outer CONCAT blocks. Mirrors existing
LTRIM in Tipping-Point Core subcase 4b. Fixes leading-space artifact
when scenario-directional opening returns empty string (e.g., FL-SD-036,
NC-HD-035).
v7.3 CHANGES (from v7.2):
[REV #55] Temporal disambiguation of explanation field:
Added explicit 2030 markers to projected metrics that previously read as
present-tense facts. Changes affect the following templates:
(A) E2 overlay: "The projected X% Dem share" -> "The projected 2030 Dem
share of X%"; "chamber median is at" -> "2030 chamber median is".
Touch points: Core 4b, Strong Competitive (2 instances).
(B) Inverse-E2: same pattern as (A). Touch points: Conditional
Competitive non-E1, Marginal non-E1 (2 instances).
(C2) E1 R-lean Conditional/Marginal: "the [chamber] is X% Dem" ->
"the [chamber] in 2030 will be X% Dem" (2 instances).
(C3) E1 D-lean all categories: "depends on districts near" ->
"in 2030 will depend on districts near" (4 instances).
(D) E4 NH multi-member: "from the NH House median" -> "from the
projected 2030 NH House median" (1 instance).
(E) E5 Rule A cliff: "from the [chamber] median" -> "from the
projected 2030 [chamber] median" (1 instance).
(G) E6 rank band (Peripheral Noncomp): "from the [chamber] median" ->
"from the 2030 [chamber] median" (1 instance).
(H) E8 decay zone lead: "side of the median" -> "side of the 2030
median" (3 instances: Strong Comp, Cond Comp, Marginal).
No logic, threshold, or category assignment changes. All edits are
string literal modifications in the with_explanation CTE.
v6.0 CHANGES (from v5.2):
[REV #29] Tipping condition driver sentences:
New tipping_condition_display CTE formats pre-computed tipping condition
drivers from Step 3 (v14.0, Section 8d) into natural-language entry/exit
cohort descriptions.
Step 3 performs the analytical work: classifies each vote_choice_scenario
as "tipping" or "non-tipping" per district using the targeting-box
definition, computes per-cohort differentials (tipping avg - non-tipping
avg), and ranks by absolute magnitude. Step 4 only formats and renders.
All scenario-dependent districts (0 < PTP < 1) with available drivers now
open with a sentence specifying the cohort dynamics that bring the
district into or out of the tipping-point zone.
Phrasing adapts to PTP tier: [v7.0 REV #44] exit-only for PTP > 0.80,
two-sided for PTP 0.30-0.80, entry-only for PTP < 0.30.
Edge-case fallback: districts where all 49 scenarios are unanimously
tipping or non-tipping (48/0 or 0/48 split) have NULL drivers; Step 4
omits the scenario sentence and relies on position/exception/convergence
blocks. Marginal districts with 0/48 splits get a specific fallback
noting swing-driven entry.
[REV #30] Output field expansion:
Removed: religion_driver_scenario_exposure_value.
Added 11 pass-through fields: pct_natam, pct_nonwhite, pct_college,
pct_high_school_only, pct_catholic, pct_evangelical, pct_female,
pct_youth_18_34, pct_senior_65plus, idx_natam_vs_state,
idx_female_vs_state.
Added 2 tipping diagnostic fields: tipping_scenario_count,
non_tipping_scenario_count.
Added ingestion-only: chamber_median_dem_share_2025, 9 tipping
condition driver fields.
Output columns: 35 -> 47.
[REV #31] Position statement rewrite:
"Sits X.X points" -> "Projected to sit X.X points ... in 2030"
across Categories 4-7.
Compact format for 100% PTP districts with no exceptions: references
rank and/or Dem share based on targeting-box rules.
[REV #32] Inverse-E2 flag:
New flag_e2_inverse detects districts near 50% with low PTP because
the median is also near 50% but on the opposite side.
Template: "The [current/projected] XX.X% Dem share may look
competitive, but ..."
Share selection: [v7.0 REV #46] always uses 2030 projected values.
[REV #33] Convergence/divergence decomposition:
Now decomposes the convergence magnitude into district shift and
median shift components.
Includes partisan direction ("toward Republicans/Democrats").
Uses chamber_median_dem_share_2025 (ingestion-only).
Stability gate: district shifts < 0.2 points suppressed entirely;
median shifts < 0.2 points treated as trivial.
[REV #34] Religion modifier rewrite:
New template: "This district is also sensitive to movement among
[Religion] voters, having a share of this cohort that is XXX% of
the state average."
Percentage sourced from idx_catholic_vs_state or
idx_evangelical_vs_state.
[REV #35] Removed E10 (asymmetric skew) flag and display text.
All "favorable/unfavorable environment" language removed.
[REV #36] Removed freestanding PTP percentage sentences.
[REV #37] Clear Noncompetitive simplification:
Non-E1 Clear Noncompetitive districts now display "Safe D/R."
(same as Safe Noncompetitive).
[REV #38] E3/E6 rewrite:
E3: Removed "competitive zone extends X seats" language. Added
investment-potential framing.
E6: "fell just outside the cutoff for the model's target zone."
[REV #39] E8 rewrite:
"transition zone where probability falls off" -> "outer edge of the
competitive range" with qualitative language.
[REV #40] Grey-area districts: chamber dynamics moved earlier in
explanation flow (E2 and E7 context now follows position statement,
before scenario-directional content).
[REV #41] Exception-flag band-base alignment (revised v6.2):
All exception flag band calculations (E3, E5, E6, E7, E8, E9),
rank_band, targeting_band, rule_b_rank_met, and exception_priority
CASE use a.total_chamber_seats as the multiplicand:
band = total_chamber_seats * fraction
-- [v8.1 REV #56] ROUND removed; Step 2 §17.3 does not ROUND.
The fraction bracket selector uses ep.effective_ranking_positions
(district count) to choose 10% (<=50 districts) vs 7% (>50).
This matches Step 2 §17.3 (unrounded band), where
rank_distance is seat-block-aware (measured in seats) and the band
must also be in seats for a valid comparison. The fraction is
conceptually "10% of districts" but expressed in seat-equivalents
via the total_chamber_seats multiplicand.
Effect on multi-member chambers:
AZ House: band = 60 * 0.10 = 6 seats (captures 3 districts)
NH House: band = 400 * 0.10 = 40 seats (captures ~20 districts)
Single-member chambers: unaffected (seats = districts).
The v6.0 version of this REV incorrectly used
ep.effective_ranking_positions (district count) as multiplicand,
creating a unit mismatch with seat-based rank_distance. That
produced bands of 3 (AZ) and ~20 (NH) compared against distances
measured in seats -- the root cause of the AZ-hd-016 tipping
count contradiction (PTP=1.0, tipping_scenario_count=1/48).
[REV #42] Position statement duplication prevention:
When E3, E6, or E8 fires in the structural-context step of
Categories 5/6/7, the position statement is either reduced (E8:
omit margin, state rank only) or omitted entirely (E3/E6: already
contain position info).
[REV #43] Dead code cleanup:
Removed: rank_overshoot, scenario_dominant_theme CASE block,
closest_scenario_direction CASE block, fmt_ptp, fmt_pct_fav,
fmt_pct_unfav, flag_e10.
Retained for reference: rank_band (with comment).
v5.0 CHANGES (from v4.2):
[REV #25] Explanation field overhaul:
- Explanations now lead with interpretive insight ("why is the PTP
what it is?") rather than restating values available in other
output columns. Labels like "structural bellwether" and "on the
competitive board" removed in favor of contextual reasoning.
- Length scaled to explanatory need: aligned Core districts get 1-2
sentences; grey-area districts with heuristic disconnects get full
structural explanation.
- Drivers are no longer listed as a rote clause. They appear only
when they illuminate district dynamics.
- Generic strategic implications removed.
[REV #26] Multi-member chamber display fix:
- rank_unit_word emits "district"/"districts" for multi-member chambers.
[REV #27] Scenario pattern classifier:
- [v6.0] Replaced by tipping_condition_display CTE (REV #29).
[REV #28] Terminology precision:
- "Competitive" (close to 50/50 line) vs "in the tipping-point zone"
(near chamber median / pivotal for chamber control) used precisely.
UNCHANGED FROM v5.2:
- 7-way primary category taxonomy
- Exception flags E1-E9 detection logic (band-base corrected per
REV #41, otherwise unchanged)
- district_archetype (4-way backward compat)
- Complement-aware driver rendering (invoked selectively for Cat 3/4)
- Multi-member chamber flag and rank unit word
- Diagnostic district list
- effective_positions CTE
- driver_display_names CTE
- "high-school only" terminology preserved
================================================================================
*/
--==============================================================================
-- CONFIGURATION
--==============================================================================
-- Set to FALSE to run full 2,620-district production output.
DECLARE diagnostic_mode BOOL DEFAULT FALSE; --TRUE for diagnostics
--============================================================================
-- DIAGNOSTIC DISTRICTS BLOCK (v3)
--============================================================================
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
--==============================================================================
-- MAIN QUERY
--==============================================================================
WITH
--======================================================================
-- 1. EFFECTIVE POSITIONS PER STATE/CHAMBER
-- (Unchanged from v2.4)
-- Counts distinct districts per state/chamber. Used as the fraction
-- bracket selector (<=50 -> 10%, >50 -> 7%) in all band calculations.
-- The band multiplicand is a.total_chamber_seats (from the analytics
-- table), not this district count. See REV #41.
--======================================================================
effective_positions AS (
SELECT
state,
chamber,
COUNT(DISTINCT district_number) AS effective_ranking_positions
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
GROUP BY state, chamber
),
--======================================================================
-- 2. DRIVER DISPLAY-NAME MAPPING
-- Maps raw driver labels from Step 3 to human-readable display names.
-- [REV #33] Consolidated age buckets: Age_18_To_34, Age_65_Plus.
-- [v4.1 REV #19] Catholic and Evangelical removed from trend driver
-- slots (separated into dedicated religion_driver system in Step 3
-- v13.1). Religion display for trend drivers handled inline in
-- explanation assembly when religion_driver != 'None'.
-- [v6.0 REV #29] Catholic and Evangelical RE-INCLUDED here because
-- they CAN appear in tipping condition driver slots (Step 3 v14.0,
-- Section 8d UNPIVOT includes them). These entries are consumed
-- only by the tipping_condition_display CTE, not by trend driver
-- rendering.
--======================================================================
driver_display_names AS (
SELECT raw_name, display_name,
-- [v7.0 REV #45] Bare display name (without "voters") for
-- same-direction two-driver descriptions. Trailing "voters"
-- is appended once after the conjunction instead of per-cohort.
CASE raw_name
WHEN 'Age_18_To_34' THEN 'young (under 35)'
WHEN 'Age_65_Plus' THEN 'older (65+)'
WHEN 'Asian' THEN 'Asian'
WHEN 'Black' THEN 'Black'
WHEN 'College' THEN 'college-educated'
WHEN 'Female' THEN 'female'
WHEN 'High_School_Only' THEN 'high-school-only'
WHEN 'Latino' THEN 'Latino'
WHEN 'Male' THEN 'male'
WHEN 'Natam' THEN 'Native American'
WHEN 'White' THEN 'White'
WHEN 'Catholic' THEN 'Catholic'
WHEN 'Evangelical' THEN 'Evangelical'
WHEN 'Mormon' THEN 'Mormon'
WHEN 'Jewish' THEN 'Jewish'
END AS display_name_bare
FROM UNNEST([
-- Consolidated age buckets
STRUCT('Age_18_To_34' AS raw_name, 'young voters (under 35)' AS display_name),
STRUCT('Age_65_Plus', 'older voters (65+)'),
-- Non-age drivers
STRUCT('Asian', 'Asian voters'),
STRUCT('Black', 'Black voters'),
STRUCT('College', 'college-educated voters'),
STRUCT('Female', 'female voters'),
STRUCT('High_School_Only', 'high-school-only voters'),
STRUCT('Latino', 'Latino voters'),
STRUCT('Male', 'male voters'),
STRUCT('Natam', 'Native American voters'),
STRUCT('White', 'White voters'),
-- Religion drivers: consumed only by tipping_condition_display CTE.
-- Cannot appear in primary/secondary/tertiary trend driver slots.
STRUCT('Catholic', 'Catholic voters'),
STRUCT('Evangelical', 'Evangelical voters'),
STRUCT('Mormon', 'Mormon voters'),
STRUCT('Jewish', 'Jewish voters')
])
),
--======================================================================
-- 2b. TIPPING CONDITION DISPLAY (NEW in v6.0, REV #29)
--
-- Formats pre-computed tipping condition driver fields from Step 3
-- (v14.0, Section 8d) into natural-language entry and exit cohort
-- descriptions for use in explanation text.
--
-- Step 3 performs the analytical work: for each district, it
-- classifies every vote_choice_scenario as "tipping" or "non-tipping"
-- using the targeting-box definition, computes per-cohort
-- differentials (mean tipping delta minus mean non-tipping delta),
-- and ranks cohorts by absolute differential magnitude. The top 3
-- cohorts are the tipping condition drivers.
--
-- This CTE only formats the top 2 drivers into display-ready text.
-- Driver 3 is NOT rendered.
--
-- Sign convention (from Step 3):
-- 'increases' = Dem support rising among this cohort is associated
-- with the district entering the tipping-point zone.
-- 'decreases' = Dem support falling among this cohort is associated
-- with the district entering the tipping-point zone.
-- Entry conditions use signs directly; exit conditions invert them.
--
-- NULL handling:
-- Drivers are NULL when PTP = 0 (no contrast group), PTP = 1.0
-- with 48/0 scenario split (all scenarios tipping), or 0 < PTP < 1
-- with a 48/0 or 0/48 split (unanimously tipping/non-tipping at
-- the scenario level). All outputs are NULL in these cases.
--======================================================================
tipping_condition_display AS (
SELECT
a.state,
a.chamber,
a.district_number,
----------------------------------------------------------------
-- ENTRY COHORT DESCRIPTION
-- Sentence fragment: what pushes the district INTO the zone.
-- Uses drivers 1 and 2 only (driver 3 not rendered).
----------------------------------------------------------------
CASE
-- No drivers available (NULL or empty)
WHEN a.tipping_condition_driver_1 IS NULL
OR a.tipping_condition_driver_1 = ''
THEN NULL
-- Only driver 1 populated
WHEN a.tipping_condition_driver_2 IS NULL
OR a.tipping_condition_driver_2 = ''
THEN CONCAT(
'Dem support ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN 'increases' ELSE 'drops' END,
' among ',
COALESCE(td1.display_name, a.tipping_condition_driver_1))
-- Both drivers share the same direction
-- [v7.0 REV #45] Uses display_name_bare + single trailing "voters"
WHEN a.tipping_condition_sign_1 = a.tipping_condition_sign_2
THEN CONCAT(
'Dem support ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN 'increases' ELSE 'drops' END,
' among ',
COALESCE(td1.display_name_bare, a.tipping_condition_driver_1),
' and ',
COALESCE(td2.display_name_bare, a.tipping_condition_driver_2),
' voters')
-- Opposite directions: lead with 'increases' cohort
ELSE CONCAT(
'Dem support increases among ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN COALESCE(td1.display_name, a.tipping_condition_driver_1)
ELSE COALESCE(td2.display_name, a.tipping_condition_driver_2)
END,
' while dropping among ',
CASE WHEN a.tipping_condition_sign_1 = 'decreases'
THEN COALESCE(td1.display_name, a.tipping_condition_driver_1)
ELSE COALESCE(td2.display_name, a.tipping_condition_driver_2)
END)
END AS entry_cohort_description,
----------------------------------------------------------------
-- EXIT COHORT DESCRIPTION
-- Sentence fragment: what pushes the district OUT of the zone.
-- Constructed by inverting all entry directions.
----------------------------------------------------------------
CASE
-- No drivers available
WHEN a.tipping_condition_driver_1 IS NULL
OR a.tipping_condition_driver_1 = ''
THEN NULL
-- Only driver 1 populated (inverted)
WHEN a.tipping_condition_driver_2 IS NULL
OR a.tipping_condition_driver_2 = ''
THEN CONCAT(
'Dem support ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN 'drops' ELSE 'increases' END,
' among ',
COALESCE(td1.display_name, a.tipping_condition_driver_1))
-- Both drivers share the same direction (inverted)
-- [v7.0 REV #45] Uses display_name_bare + single trailing "voters"
WHEN a.tipping_condition_sign_1 = a.tipping_condition_sign_2
THEN CONCAT(
'Dem support ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN 'drops' ELSE 'increases' END,
' among ',
COALESCE(td1.display_name_bare, a.tipping_condition_driver_1),
' and ',
COALESCE(td2.display_name_bare, a.tipping_condition_driver_2),
' voters')
-- Opposite directions (inverted): the driver that was
-- 'decreases' in entry becomes 'increases' in exit, and
-- vice versa.
ELSE CONCAT(
'Dem support increases among ',
CASE WHEN a.tipping_condition_sign_1 = 'decreases'
THEN COALESCE(td1.display_name, a.tipping_condition_driver_1)
ELSE COALESCE(td2.display_name, a.tipping_condition_driver_2)
END,
' while dropping among ',
CASE WHEN a.tipping_condition_sign_1 = 'increases'
THEN COALESCE(td1.display_name, a.tipping_condition_driver_1)
ELSE COALESCE(td2.display_name, a.tipping_condition_driver_2)
END)
END AS exit_cohort_description,
----------------------------------------------------------------
-- DOMINANT ENTRY DIRECTION
-- Derived from the predominant sign among top 2 drivers.
-- Both 'increases' → 'offense' (Dem-favorable conditions)
-- Both 'decreases' → 'defense' (Dem-unfavorable conditions)
-- One of each → 'mixed'
-- No drivers → NULL
-- When only driver 1 is populated, direction is based on
-- that single driver's sign.
----------------------------------------------------------------
CASE
WHEN a.tipping_condition_driver_1 IS NULL
OR a.tipping_condition_driver_1 = ''
THEN NULL
WHEN a.tipping_condition_driver_2 IS NULL
OR a.tipping_condition_driver_2 = ''
THEN CASE
WHEN a.tipping_condition_sign_1 = 'increases' THEN 'offense'
ELSE 'defense'
END
WHEN a.tipping_condition_sign_1 = 'increases'
AND a.tipping_condition_sign_2 = 'increases'
THEN 'offense'
WHEN a.tipping_condition_sign_1 = 'decreases'
AND a.tipping_condition_sign_2 = 'decreases'
THEN 'defense'
ELSE 'mixed'
END AS dominant_entry_direction
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics` a
LEFT JOIN driver_display_names td1
ON a.tipping_condition_driver_1 = td1.raw_name
LEFT JOIN driver_display_names td2
ON a.tipping_condition_driver_2 = td2.raw_name
),
--======================================================================
-- 3. CLASSIFICATION + DISPLAY PREPARATION
--
-- [v3.0 OVERHAUL] Massively expanded from v2.4.
-- [v3.1] Added chamber_lean, closest_tipping_scenario_1.
-- [v3.1] Revised median_strategic_framing for D-leaning chambers.
-- [v3.1] Added chamber-size guard to Priority 8.
-- [v3.1] Tightened E9 TPT lower threshold from 0.10 to 0.20.
-- [v5.0] Added is_multi_member_chamber, rank_unit_word,
-- closest_scenario_direction, scenario_dominant_theme.
-- [v6.0] Removed: scenario_dominant_theme, closest_scenario_direction
-- (replaced by tipping_condition_display CTE), rank_overshoot,
-- fmt_ptp, fmt_pct_fav, fmt_pct_unfav, flag_e10.
-- Added: tcd columns, convergence decomposition, inverse-E2,
-- targeting-box fields.
--
-- This CTE computes:
-- (a) 7-way primary_category (replaces 4-way district_archetype)
-- (b) 9 exception flag booleans (E1-E9; E10 removed in v6.0)
-- (c) Exception priority (first structural match wins)
-- (d) Complement pair detection for driver rendering
-- (e) Rank band calculation (overshoot removed in v6.0)
-- (f) Districts-closer-to-median count
-- (g) Strategic framing fields (median language, safe-seat direction)
-- (h) All formatted display values
-- (i) Chamber lean direction
-- (j) Closest tipping scenario (for E9 narrative)
-- (k) Multi-member chamber flag and rank unit word [NEW v5.0]
-- (l) Scenario pattern classifier fields [NEW v5.0]
--
-- Key design: exception flags detect structural reasons WHY a district
-- falls into its category. The primary_category determines explanation
-- LENGTH and TONE; the exception flags determine CONTENT.
--======================================================================
classified AS (
SELECT
a.*,
-- [v6.0 REV #30] The following Step 3 fields are carried through
-- via a.* for consumption by downstream CTEs (not in final_output):
-- chamber_median_dem_share_2025
-- tipping_condition_driver_1/2/3, tipping_condition_sign_1/2/3,
-- tipping_condition_diff_1/2/3
ep.effective_ranking_positions,
----------------------------------------------------------------
-- CHAMBER AVERAGE VOLATILITY (window function, from v2.0)
-- Used for relative volatility characterization.
-- [v4.0] Source field renamed: district_volatility →
-- district_raw_volatility (REV #22).
----------------------------------------------------------------
AVG(a.district_raw_volatility) OVER (PARTITION BY a.state, a.chamber)
AS chamber_avg_volatility,
----------------------------------------------------------------
-- DISTRICTS CLOSER TO MEDIAN (window function, NEW in v3.0)
-- Counts how many districts in this state/chamber have a smaller
-- |rank_distance| than this district.
-- RANK()-1 = count of districts with strictly smaller distance.
-- [v4.0] Source field renamed:
-- baseline_rank_distance_to_majority_2030
-- → baseline_rank_distance_to_median_2030 (REV #22).
----------------------------------------------------------------
RANK() OVER (
PARTITION BY a.state, a.chamber
ORDER BY ABS(a.baseline_rank_distance_to_median_2030) ASC
) - 1 AS districts_closer_to_median,
----------------------------------------------------------------
-- PRIMARY CATEGORY (7-way classification, NEW in v3.0)
--
-- Order of evaluation:
-- 1. TPT >= 0.93 → Tipping-Point Core (highest priority)
-- 2. TPT = 0 → Safe / Clear / Peripheral Noncompetitive
-- (subcategorized by |baseline_margin|)
-- 3. TPT >= 0.50 → Strong Competitive
-- 4. TPT >= 0.10 → Conditional Competitive
-- 5. TPT > 0 → Marginal (catch-all for 0 < TPT < 0.10)
--
-- Margin thresholds for noncompetitive subcategories use the
-- BASELINE margin (not the scenario-average), consistent with
-- exception flag detection logic.
----------------------------------------------------------------
CASE
WHEN a.percent_tipping_point >= 0.93
THEN 'Tipping-Point Core'
WHEN a.percent_tipping_point = 0
AND ABS(a.baseline_margin_to_median_2030) > 0.08
THEN 'Safe Noncompetitive'
WHEN a.percent_tipping_point = 0
AND ABS(a.baseline_margin_to_median_2030) > 0.05
THEN 'Clear Noncompetitive'
WHEN a.percent_tipping_point = 0
THEN 'Peripheral Noncompetitive'
WHEN a.percent_tipping_point >= 0.50
THEN 'Strong Competitive'
WHEN a.percent_tipping_point >= 0.10
THEN 'Conditional Competitive'
ELSE 'Marginal'
END AS primary_category,
-- Retain the old 4-way archetype for backward compatibility in output.
-- The explanation generation uses primary_category exclusively.
CASE
WHEN a.percent_tipping_point >= 0.93 THEN 'Tipping-Point Core'
WHEN a.percent_tipping_point = 0 THEN 'Non-Competitive'
WHEN a.avg_abs_margin_to_median_2030 <= 0.04 THEN 'Scenario-Dependent'
WHEN a.avg_abs_margin_to_median_2030 <= 0.05 THEN 'Fringe Competitive'
ELSE 'Non-Competitive'
END AS district_archetype,
----------------------------------------------------------------
-- CHAMBER DISPLAY STRINGS
----------------------------------------------------------------
CASE WHEN a.chamber = 'hd' THEN 'House' ELSE 'Senate' END
AS chamber_display,
CONCAT(
CAST(a.total_chamber_seats AS STRING), '-seat ',
CASE WHEN a.chamber = 'hd' THEN 'House' ELSE 'Senate' END
) AS chamber_context,
----------------------------------------------------------------
-- MULTI-MEMBER CHAMBER FLAG (NEW in v5.0, REV #26)
-- AZ House (60 seats / 30 districts) and NH House (400 seats /
-- ~203 districts) elect multiple members per district. Rank
-- distances in Step 3 are computed per-district (one row per
-- district), so the numeric values are correct. This flag
-- controls only the display label: "districts" vs "seats".
----------------------------------------------------------------
((a.state = 'AZ' AND a.chamber = 'hd')
OR (a.state = 'NH' AND a.chamber = 'hd')
) AS is_multi_member_chamber,
----------------------------------------------------------------
-- RANK BAND CALCULATION (NEW in v3.0)
-- Defines the competitive seat band around the majority threshold.
-- Smaller chambers (<=50 seats) use 10% of seats; larger use 7%.
-- This is the maximum rank distance at which a district can be
-- considered in the competitive zone under normal conditions.
-- [v6.0] Retained for diagnostic reference; not consumed by
-- explanation text (E3/E6 rewrites no longer reference rank_band).
----------------------------------------------------------------
-- [v6.2 REV #41 revised] Band multiplicand is total_chamber_seats
-- (seat count), aligned with Step 2 §17.3 (unrounded band). The
-- fraction bracket selector uses effective_ranking_positions (district
-- count) to choose 10% vs 7%. This ensures the band is in the same
-- units (seats) as baseline_rank_distance_to_median_2030.
-- Single-member chambers: unaffected (seats = districts).
-- Multi-member: AZ House band = 6 seats, NH House band = 40 seats.
-- [v8.1] ROUND removed. Step 2 §17.3 specifies "Band width =
-- total_chamber_seats × fraction" with no ROUND. ROUND(180*0.07)=13
-- masked rank-cliff districts like GA-HD-070 (rank 13, raw band 12.6).
a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07
END AS rank_band,
-- [v6.0 REV #38] rank_overshoot REMOVED — no longer referenced
-- after E3/E6 explanation rewrites.
----------------------------------------------------------------
-- MEDIAN / DISTRICT DISTANCE FROM 50% (NEW in v3.0)
-- Used for E1 (median-vs-50% disconnect) and E2 (tipping far
-- from 50%) detection.
-- [v4.0] Source field renamed: median_dem_share_2030
-- → chamber_median_dem_share_2030 (REV #22).
----------------------------------------------------------------
ABS(a.chamber_median_dem_share_2030 - 0.50) AS median_distance_from_50,
ABS(a.dem_baseline_projected_2030 - 0.50) AS district_distance_from_50,
----------------------------------------------------------------
-- FORMATTED DISPLAY VALUES
-- Carried from v2.4 + new fields for v3.0+
----------------------------------------------------------------
-- [v6.0 REV #36] fmt_ptp REMOVED — PTP percentage no longer
-- stated in explanation text; percent_tipping_point is in output.
-- Baseline margin from median (absolute, 1 decimal)
FORMAT('%.1f', ABS(a.baseline_margin_to_median_2030) * 100)
AS fmt_baseline_margin,
-- Average absolute margin (carried from v2.4 for backward compat)
FORMAT('%.1f', a.avg_abs_margin_to_median_2030 * 100) AS fmt_margin,
-- Rank distance from majority threshold (absolute, integer)
-- [v4.0] Source field renamed:
-- baseline_rank_distance_to_majority_2030
-- → baseline_rank_distance_to_median_2030 (REV #22).
FORMAT('%.0f', ABS(a.baseline_rank_distance_to_median_2030))
AS fmt_rank_dist,
-- Average rank distance from tipping point (integer, from v2.4)
-- [v4.0] Source field renamed: avg_seats_from_tipping_point dropped
-- (REV #23). Now uses avg_abs_rank_distance_to_median_2030.
FORMAT('%.0f', a.avg_abs_rank_distance_to_median_2030) AS fmt_seats,
-- Singular/plural for rank display
-- [v5.0 REV #26] Multi-member chambers use "district"/"districts".
CASE
WHEN (a.state = 'AZ' AND a.chamber = 'hd')
OR (a.state = 'NH' AND a.chamber = 'hd')
THEN CASE
WHEN ROUND(ABS(a.baseline_rank_distance_to_median_2030)) = 1
THEN 'district'
ELSE 'districts'
END
ELSE CASE
WHEN ROUND(ABS(a.baseline_rank_distance_to_median_2030)) = 1
THEN 'seat'
ELSE 'seats'
END
END AS rank_unit_word,
-- Proportional rank distance (NEW in v4.2, REV #24)
-- Rank distance as percentage of total chamber seats, enabling
-- cross-chamber comparisons in explanation text.
-- Uses baseline 2030 value (matches fmt_rank_dist).
FORMAT('%.1f', a.baseline_rank_pct_of_chamber_2030 * 100) AS fmt_rank_pct,
-- [v6.0 REV #35] fmt_pct_fav and fmt_pct_unfav REMOVED
-- (were consumed only by E10 display text, now deleted).
-- Partisan side of median (signed margin determines side)
CASE
WHEN a.baseline_margin_to_median_2030 >= 0 THEN 'Democratic'
ELSE 'Republican'
END AS partisan_side,
-- At-exact-median flag (margin rounds to 0.0)
(ABS(a.baseline_margin_to_median_2030) < 0.0005) AS at_exact_median,
-- Convergence magnitude (positive = moving toward median)
-- [v4.0] Source field renamed: margin_to_median_2025 →
-- baseline_margin_to_median_2025 (REV #22).
(ABS(a.baseline_margin_to_median_2025) - ABS(a.baseline_margin_to_median_2030))
AS convergence_magnitude,
FORMAT('%.1f',
ABS(ABS(a.baseline_margin_to_median_2025) - ABS(a.baseline_margin_to_median_2030)) * 100
) AS fmt_shift_pts,
----------------------------------------------------------------
-- [v6.0 REV #30/33] INGESTION-ONLY FIELDS
-- Consumed by explanation assembly CTEs (convergence/divergence
-- decomposition, Section VI-E) but NOT included in final_output.
----------------------------------------------------------------
-- Formatted 2025 median share (for convergence decomposition)
FORMAT('%.1f', a.chamber_median_dem_share_2025 * 100) AS fmt_median_2025_pct,
-- Median shift 2025→2030 (for divergence text)
(a.chamber_median_dem_share_2030 - a.chamber_median_dem_share_2025)
AS median_shift_2025_to_2030,
-- Formatted district shift magnitude (for convergence decomposition)
FORMAT('%.1f', ABS(a.delta_baseline_2030_vs_2025) * 100) AS fmt_district_shift_pts,
-- Volatility range (absolute distance from tipping point)
FORMAT('%.1f', a.min_abs_margin_to_median_2030 * 100) AS fmt_closest_approach,
FORMAT('%.1f', a.max_abs_margin_to_median_2030 * 100) AS fmt_farthest_margin,
-- Scenario range (NEW in v3.0, for E9 high-volatility narrative)
-- [v4.0] Source field renamed: margin_to_median_range_2030
-- → district_relative_volatility (REV #22).
FORMAT('%.1f', a.district_relative_volatility * 100) AS fmt_scenario_range,
-- Median dem share formatted (for strategic framing)
FORMAT('%.1f', a.chamber_median_dem_share_2030 * 100) AS fmt_median_pct,
-- Projected 2030 share formatted
FORMAT('%.1f', a.dem_baseline_projected_2030 * 100) AS fmt_dem_proj_pct,
-- Present-day (2025) baseline formatted (for E1 "today" language)
FORMAT('%.1f', a.dem_weighted_baseline_2025 * 100) AS fmt_baseline_2025_pct,
----------------------------------------------------------------
-- SAFE-SEAT DIRECTION (NEW in v3.0)
-- For E1 districts: "safe D" or "safe R" depending on whether
-- the district is on the D or R side of the median.
----------------------------------------------------------------
CASE
WHEN a.baseline_margin_to_median_2030 >= 0 THEN 'D'
ELSE 'R'
END AS dem_or_rep_safe,
----------------------------------------------------------------
-- CHAMBER LEAN DIRECTION (NEW in v3.1, FIX 2)
-- Whether the chamber median is on the D or R side of 50%.
-- Used to correctly orient E1 strategic framing language.
-- D-leaning chambers need different sentence structure because
-- "Democrats would need to be winning at X% Dem" is trivially
-- true when the median is already above 50%.
----------------------------------------------------------------
CASE
WHEN a.chamber_median_dem_share_2030 >= 0.50 THEN 'D'
ELSE 'R'
END AS chamber_lean,
----------------------------------------------------------------
-- MEDIAN STRATEGIC FRAMING (NEW in v3.0)
-- When the median is far from 50%, describes the environment
-- needed to flip the chamber. Used in E1 overlay language.
--
-- [v3.1 FIX 2] This field's VALUE is unchanged, but how it is
-- USED in E1 templates is now chamber-lean-aware.
----------------------------------------------------------------
CASE
WHEN a.chamber_median_dem_share_2030 < 0.47 THEN 'a strong Democratic year'
WHEN a.chamber_median_dem_share_2030 > 0.53 THEN 'a strong Republican year'
ELSE ''
END AS median_strategic_framing,
----------------------------------------------------------------
-- DRIVER DISPLAY NAMES
-- Carried from v2.4. The duplicate-catch for age rollups is
-- retained as a safety net, though consolidated age brackets
-- make collisions unlikely.
----------------------------------------------------------------
COALESCE(d1.display_name, a.primary_trend_driver) AS primary_display,
CASE
WHEN COALESCE(d2.display_name, a.secondary_trend_driver)
= COALESCE(d1.display_name, a.primary_trend_driver)
THEN COALESCE(d3.display_name, a.tertiary_trend_driver)
ELSE COALESCE(d2.display_name, a.secondary_trend_driver)
END AS secondary_display,
-- Tertiary: available only if not consumed by age-rollup swap
CASE
WHEN COALESCE(d2.display_name, a.secondary_trend_driver)
= COALESCE(d1.display_name, a.primary_trend_driver)
THEN NULL -- tertiary was consumed as effective secondary
ELSE COALESCE(d3.display_name, a.tertiary_trend_driver)
END AS tertiary_display,
----------------------------------------------------------------
-- DRIVER CATEGORY CLASSIFICATION (from v2.4)
-- Categories: race, education, gender, age.
-- Used for tertiary inclusion logic (different-category rule).
-- [v4.1 REV #19] Religion category removed. Catholic/Evangelical
-- can no longer appear in generic driver slots; handled by
-- dedicated religion_driver field.
----------------------------------------------------------------
CASE
WHEN a.primary_trend_driver IN ('Latino','Black','Asian','Natam','White') THEN 'race'
WHEN a.primary_trend_driver IN ('College','High_School_Only') THEN 'education'
WHEN a.primary_trend_driver IN ('Female','Male') THEN 'gender'
ELSE 'age'
END AS primary_cat,
-- Effective secondary category (accounts for age-rollup swap)
CASE
WHEN COALESCE(d2.display_name, a.secondary_trend_driver)
= COALESCE(d1.display_name, a.primary_trend_driver)
THEN CASE
WHEN a.tertiary_trend_driver IN ('Latino','Black','Asian','Natam','White') THEN 'race'
WHEN a.tertiary_trend_driver IN ('College','High_School_Only') THEN 'education'
WHEN a.tertiary_trend_driver IN ('Female','Male') THEN 'gender'
WHEN a.tertiary_trend_driver IS NULL THEN NULL
ELSE 'age'
END
ELSE CASE
WHEN a.secondary_trend_driver IN ('Latino','Black','Asian','Natam','White') THEN 'race'
WHEN a.secondary_trend_driver IN ('College','High_School_Only') THEN 'education'
WHEN a.secondary_trend_driver IN ('Female','Male') THEN 'gender'
WHEN a.secondary_trend_driver IS NULL THEN NULL
ELSE 'age'
END
END AS effective_secondary_cat,
CASE
WHEN a.tertiary_trend_driver IN ('Latino','Black','Asian','Natam','White') THEN 'race'
WHEN a.tertiary_trend_driver IN ('College','High_School_Only') THEN 'education'
WHEN a.tertiary_trend_driver IN ('Female','Male') THEN 'gender'
WHEN a.tertiary_trend_driver IS NULL THEN NULL
ELSE 'age'
END AS tertiary_cat,
-- Whether tertiary was consumed by age-rollup secondary swap
(COALESCE(d2.display_name, a.secondary_trend_driver)
= COALESCE(d1.display_name, a.primary_trend_driver)) AS tertiary_consumed,
----------------------------------------------------------------
-- COMPLEMENTARY DRIVER DETECTION (NEW in v3.0)
--
-- Three complementary pairs exist where naming both drivers is
-- redundant (e.g., "college and high-school-only" = everyone):
-- College + High_School_Only → "the education gap"
-- Female + Male → "the gender gap"
-- Age_18_To_34 + Age_65_Plus → "generational turnout dynamics"
--
-- Detection uses RAW driver names (not display names) since
-- display names have already been mapped.
----------------------------------------------------------------
(
(a.primary_trend_driver IN ('College','High_School_Only')
AND a.secondary_trend_driver IN ('College','High_School_Only'))
OR
(a.primary_trend_driver IN ('Female','Male')
AND a.secondary_trend_driver IN ('Female','Male'))
OR
(a.primary_trend_driver IN ('Age_18_To_34','Age_65_Plus')
AND a.secondary_trend_driver IN ('Age_18_To_34','Age_65_Plus'))
) AS is_complement_pair,
-- Dynamic description for the complement pair
CASE
WHEN a.primary_trend_driver IN ('College','High_School_Only')
AND a.secondary_trend_driver IN ('College','High_School_Only')
THEN 'the education gap'
WHEN a.primary_trend_driver IN ('Female','Male')
AND a.secondary_trend_driver IN ('Female','Male')
THEN 'the gender gap'
WHEN a.primary_trend_driver IN ('Age_18_To_34','Age_65_Plus')
AND a.secondary_trend_driver IN ('Age_18_To_34','Age_65_Plus')
THEN 'generational turnout dynamics'
ELSE NULL
END AS complement_display,
-- When complement detected, promote tertiary to the secondary slot
-- (only if tertiary is from a DIFFERENT category than the complement).
CASE
WHEN (
(a.primary_trend_driver IN ('College','High_School_Only')
AND a.secondary_trend_driver IN ('College','High_School_Only'))
OR (a.primary_trend_driver IN ('Female','Male')
AND a.secondary_trend_driver IN ('Female','Male'))
OR (a.primary_trend_driver IN ('Age_18_To_34','Age_65_Plus')
AND a.secondary_trend_driver IN ('Age_18_To_34','Age_65_Plus'))
)
-- Tertiary exists and is from a different category
AND a.tertiary_trend_driver IS NOT NULL
AND (
CASE
WHEN a.primary_trend_driver IN ('College','High_School_Only')
THEN a.tertiary_trend_driver NOT IN ('College','High_School_Only')
WHEN a.primary_trend_driver IN ('Female','Male')
THEN a.tertiary_trend_driver NOT IN ('Female','Male')
ELSE a.tertiary_trend_driver NOT IN ('Age_18_To_34','Age_65_Plus')
END
)
THEN COALESCE(d3.display_name, a.tertiary_trend_driver)
ELSE NULL
END AS promoted_tertiary,
----------------------------------------------------------------
-- EXCEPTION FLAG BOOLEANS (NEW in v3.0)
--
-- Each flag detects a specific structural reason why a district
-- falls into (or out of) the tipping-point zone. E1 and E2
-- are ADDITIVE (can combine with any structural exception).
-- [v6.0 REV #35] E10 removed.
-- E3-E9 are PRIORITIZED (first match wins).
----------------------------------------------------------------
-- E1: MEDIAN-VS-50% DISCONNECT (additive)
-- Fires when the median is far from 50% but the district is near 50%.
-- Explains why a "competitive-looking" district isn't a tipping point.
(ABS(a.chamber_median_dem_share_2030 - 0.50) > 0.03
AND ABS(a.dem_baseline_projected_2030 - 0.50) < 0.05
) AS flag_e1,
-- E2: TIPPING FAR FROM 50% (additive)
-- Fires when a tipping-point district is far from 50% absolute.
-- Explains why a "safe-looking" district is actually in the zone.
(a.percent_tipping_point > 0.50
AND ABS(a.dem_baseline_projected_2030 - 0.50) > 0.05
) AS flag_e2,
-- [v6.2 REV #41 revised] All exception flags below use the aligned
-- band formula: total_chamber_seats * fraction, where fraction
-- is selected by effective_ranking_positions (district count).
-- This matches Step 2 §17.3 (unrounded band) and Step 3's
-- scenario_tipping_flag. rank_distance values are seat-based;
-- band is now also seat-based.
-- [v8.1] ROUND removed from all band comparisons below.
-- Step 2 §17.3 does not ROUND; prior ROUND in earlier versions masked
-- rank-cliff districts (e.g., GA-HD-070 at rank 13 vs band 12.6).
-- E3: SMALL CHAMBER RANK EXCLUSION
-- Close margin but excluded because a small chamber's narrow
-- competitive band doesn't extend far enough.
(ABS(a.baseline_margin_to_median_2030) < 0.03
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND a.total_chamber_seats < 70
) AS flag_e3,
-- E4: NH MULTI-MEMBER MISMATCH
-- NH's 400-seat / 203-district structure inflates rank distances
-- far beyond what margins suggest.
(a.state = 'NH' AND a.chamber = 'hd'
AND ABS(a.baseline_margin_to_median_2030) < 0.03
AND ABS(a.baseline_rank_distance_to_median_2030) > 28
) AS flag_e4,
-- E5: RULE A BOUNDARY CLIFF
-- Districts in the 1.5-2.0pt margin zone where a fraction of a
-- point closer to the median would make them near-certain tipping
-- points, but they fall just on the wrong side of the threshold.
(ABS(a.baseline_margin_to_median_2030) BETWEEN 0.015 AND 0.020
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
) AS flag_e5,
-- E6: RANK BAND EXCLUSION
-- Just outside the competitive seat band (within 3 seats of it).
-- Close enough to warrant explanation but excluded by rank position.
(ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END) + 3
AND ABS(a.baseline_margin_to_median_2030) < 0.04
AND ABS(a.baseline_margin_to_median_2030) > 0.015
) AS flag_e6,
-- E7: LARGE CHAMBER INCLUSION
-- District is in the zone specifically because this chamber is
-- large enough to have a wide competitive band.
(ABS(a.baseline_margin_to_median_2030) BETWEEN 0.03 AND 0.05
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END) * 0.6
AND a.total_chamber_seats >= 100
) AS flag_e7,
-- E8: DECAY ZONE
-- In the 4.0-5.5pt margin range where tipping probability declines
-- proportionally with distance from the median.
(ABS(a.baseline_margin_to_median_2030) BETWEEN 0.04 AND 0.055
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
) AS flag_e8,
-- E9: HIGH VOLATILITY RESCUE
-- Baseline position is outside the competitive zone, but high
-- scenario volatility creates enough swing that the district
-- enters the zone in some scenarios.
-- [v3.1 FIX 4] TPT lower threshold tightened from 0.10 to 0.20.
-- [v4.0] Source field renamed: margin_to_median_range_2030
-- → district_relative_volatility (REV #22).
(a.district_relative_volatility > 0.05
AND a.percent_tipping_point BETWEEN 0.20 AND 0.75
AND (ABS(a.baseline_margin_to_median_2030) > 0.04
OR ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END))
) AS flag_e9,
-- [v6.0 REV #35] E10 (asymmetric skew) REMOVED.
-- All "favorable/unfavorable environment" language removed.
-- [v6.0 REV #29] SCENARIO PATTERN CLASSIFIER REMOVED.
-- closest_scenario_direction and scenario_dominant_theme were
-- computed here in v5.0-v5.2 by parsing closest_tipping_scenario
-- name tokens. Both are now replaced by the tipping_condition_display
-- CTE (entry_cohort_description, exit_cohort_description,
-- dominant_entry_direction), which sources from pre-computed
-- tipping condition driver fields in Step 3 v14.0.
----------------------------------------------------------------
-- EXCEPTION PRIORITY (NEW in v3.0)
-- For the structural exceptions (E3-E9), first match wins.
-- E1 and E2 are additive and handled separately.
-- [v6.0 REV #35] E10 removed.
--
-- Priority order (highest to lowest):
-- E4 (NH multi-member) → E5 (Rule A cliff) → E3 (small chamber)
-- → E6 (rank band) → E9 (high volatility) → E8 (decay zone)
-- → E7 (large chamber)
--
-- NULL = no structural exception fires.
--
-- [v3.1 FIX 1] Priority 8 includes total_chamber_seats >= 100
-- guard to prevent small-chamber districts from receiving E7
-- "wide competitive band" language.
-- [v3.1 FIX 4] Priority 5 (E9) TPT threshold tightened to 0.20.
----------------------------------------------------------------
-- [v6.2 REV #41 revised] Band in exception_priority uses same aligned
-- formula as flag definitions: total_chamber_seats * fraction.
-- [v8.1] ROUND removed to align with Step 2 §17.3.
CASE
-- Priority 1: NH Multi-Member
WHEN a.state = 'NH' AND a.chamber = 'hd'
AND ABS(a.baseline_margin_to_median_2030) < 0.03
AND ABS(a.baseline_rank_distance_to_median_2030) > 28
THEN 'E4'
-- Priority 2: Rule A Boundary Cliff
WHEN ABS(a.baseline_margin_to_median_2030) BETWEEN 0.015 AND 0.020
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
THEN 'E5'
-- Priority 3: Small Chamber Rank Exclusion
WHEN ABS(a.baseline_margin_to_median_2030) < 0.03
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND a.total_chamber_seats < 70
THEN 'E3'
-- Priority 4: Rank Band Exclusion
WHEN ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END) + 3
AND ABS(a.baseline_margin_to_median_2030) < 0.04
AND ABS(a.baseline_margin_to_median_2030) > 0.015
THEN 'E6'
-- Priority 5: High Volatility Rescue
-- [v3.1 FIX 4] TPT threshold tightened from 0.10 to 0.20.
WHEN a.district_relative_volatility > 0.05
AND a.percent_tipping_point BETWEEN 0.20 AND 0.75
AND (ABS(a.baseline_margin_to_median_2030) > 0.04
OR ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END))
THEN 'E9'
-- Priority 6: Decay Zone
WHEN ABS(a.baseline_margin_to_median_2030) BETWEEN 0.04 AND 0.055
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
THEN 'E8'
-- Priority 7: Large Chamber Inclusion
WHEN ABS(a.baseline_margin_to_median_2030) BETWEEN 0.03 AND 0.05
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND ABS(a.baseline_rank_distance_to_median_2030)
> (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END) * 0.6
AND a.total_chamber_seats >= 100
THEN 'E7'
-- Priority 8: Rule B Moderate Margin (E7 variant)
-- [v3.1 FIX 1] Added total_chamber_seats >= 100 guard.
WHEN ABS(a.baseline_margin_to_median_2030) BETWEEN 0.03 AND 0.045
AND ABS(a.baseline_rank_distance_to_median_2030)
<= (a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07 END)
AND a.percent_tipping_point > 0.70
AND a.total_chamber_seats >= 100
THEN 'E7'
ELSE NULL
END AS exception_priority,
----------------------------------------------------------------
-- [v6.0 REV #29] TIPPING CONDITION DISPLAY FIELDS
-- From tipping_condition_display CTE join.
----------------------------------------------------------------
tcd.entry_cohort_description,
tcd.exit_cohort_description,
tcd.dominant_entry_direction,
----------------------------------------------------------------
-- [v6.0 REV #33] CONVERGENCE DECOMPOSITION FIELDS
-- For partisan-direction decomposition in explanation text.
----------------------------------------------------------------
-- Formatted median shift magnitude
FORMAT('%.1f', ABS(a.chamber_median_dem_share_2030
- a.chamber_median_dem_share_2025) * 100) AS fmt_median_shift_pts,
-- District shift direction display
CASE
WHEN a.delta_baseline_2030_vs_2025 < 0 THEN 'toward Republicans'
ELSE 'toward Democrats'
END AS district_shift_direction,
-- Median shift direction display
CASE
WHEN (a.chamber_median_dem_share_2030
- a.chamber_median_dem_share_2025) < 0 THEN 'toward Republicans'
ELSE 'toward Democrats'
END AS median_shift_direction,
----------------------------------------------------------------
-- [v6.0 REV #32] INVERSE E2 FLAG
-- Detects districts near 50% with low PTP because the median
-- is far from 50% on the opposite side.
----------------------------------------------------------------
(a.percent_tipping_point < 0.50
AND LEAST(
ABS(a.dem_baseline_projected_2030 - 0.50),
ABS(a.dem_weighted_baseline_2025 - 0.50)
) < 0.05
AND ABS(a.baseline_margin_to_median_2030) > 0.03
AND NOT (
ABS(a.chamber_median_dem_share_2030 - 0.50) > 0.03
AND ABS(a.dem_baseline_projected_2030 - 0.50) < 0.05
) -- exclude E1 districts
) AS flag_e2_inverse,
-- [v7.0 REV #46] e2_inverse_share_label and fmt_e2_inverse_share REMOVED.
-- E2-inverse template now always uses fmt_dem_proj_pct (2030 projected).
-- Previous logic selected 2025 baseline when >= 0.5pp closer to 50%,
-- but fmt_baseline_margin always used 2030, causing math inconsistency.
----------------------------------------------------------------
-- [v6.2 REV #31/41] TARGETING BOX FIELDS (for Subcase 4a logic)
-- Band = total_chamber_seats * fraction, aligned with Step 2 §17.3
-- (unrounded band). Fraction bracket selected by district count.
-- rank_distance and band are both in seat units.
-- [v8.1] ROUND removed to align with Step 2 §17.3.
----------------------------------------------------------------
a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07
END AS targeting_band,
-- Rule A met (margin <= 1.5 pts)
(ABS(a.baseline_margin_to_median_2030) <= 0.015) AS rule_a_met,
-- Rule B rank met (rank <= band, both in seats)
-- [v8.1] ROUND removed to align with Step 2 §17.3.
(ABS(a.baseline_rank_distance_to_median_2030)
<= a.total_chamber_seats * CASE
WHEN ep.effective_ranking_positions <= 50 THEN 0.10
ELSE 0.07
END
) AS rule_b_rank_met,
-- Rule B margin met (margin <= 4.0 pts)
(ABS(a.baseline_margin_to_median_2030) <= 0.04) AS rule_b_margin_met
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics` a
JOIN effective_positions ep USING (state, chamber)
-- [v6.0 REV #29] Join tipping condition display for scenario sentences.
LEFT JOIN tipping_condition_display tcd USING (state, chamber, district_number)
LEFT JOIN driver_display_names d1 ON a.primary_trend_driver = d1.raw_name
LEFT JOIN driver_display_names d2 ON a.secondary_trend_driver = d2.raw_name
LEFT JOIN driver_display_names d3 ON a.tertiary_trend_driver = d3.raw_name
),
--======================================================================
-- 3b. COHORT OVERREPRESENTATION (NEW in v7.0, REV #47)
--
-- Unpivots 9 demographic index/share pairs per district to identify
-- cohorts that are notably overrepresented relative to the state
-- average. Excludes Female (near-parity everywhere), and all four
-- religion cohorts -- Catholic, Evangelical, Mormon, Jewish -- which
-- are handled by the religion modifier system.
-- [v10.2 REL #2] Mormon and Jewish added to the exclusion list,
-- consistent with the existing Catholic/Evangelical treatment.
-- No change to the unpivot inclusion list itself.
--
-- Two output modes:
-- (a) Overrepresentation: up to 3 cohorts where idx >= 1.10 AND
-- pct >= 0.06, ranked by idx descending. Formatted as sentence.
-- (b) Statewide-average: ALL cohorts with pct >= 0.02 have idx
-- BETWEEN 0.95 AND 1.05. Signals demographic neutrality.
-- (c) NULL: neither condition met (some overrep but below threshold,
-- or too few cohorts to characterize).
--
-- Consumed by explanation assembly (Section 4), inserted before
-- religion modifier in Categories 2-7. Omitted from Category 1
-- (Safe Noncompetitive, half-sentence dismissal).
--======================================================================
cohort_overrepresentation AS (
SELECT
state, chamber, district_number,
-- Overrepresentation sentence (top 3 cohorts above threshold)
CASE
WHEN COUNT(CASE WHEN idx >= 1.10 AND pct >= 0.06 THEN 1 END) >= 3
THEN CONCAT(
' District has high shares of ',
MAX(CASE WHEN overrep_rank = 1 THEN CONCAT(cohort_label, ' (', FORMAT('%.0f', idx * 100), '% of state avg)') END), ', ',
MAX(CASE WHEN overrep_rank = 2 THEN CONCAT(cohort_label, ' (', FORMAT('%.0f', idx * 100), '%)') END), ', and ',
MAX(CASE WHEN overrep_rank = 3 THEN CONCAT(cohort_label, ' voters (', FORMAT('%.0f', idx * 100), '%)') END), '.')
WHEN COUNT(CASE WHEN idx >= 1.10 AND pct >= 0.06 THEN 1 END) = 2
THEN CONCAT(
' District has high shares of ',
MAX(CASE WHEN overrep_rank = 1 THEN CONCAT(cohort_label, ' (', FORMAT('%.0f', idx * 100), '% of state avg)') END), ' and ',
MAX(CASE WHEN overrep_rank = 2 THEN CONCAT(cohort_label, ' voters (', FORMAT('%.0f', idx * 100), '%)') END), '.')
WHEN COUNT(CASE WHEN idx >= 1.10 AND pct >= 0.06 THEN 1 END) = 1
THEN CONCAT(
' District has a high share of ',
MAX(CASE WHEN overrep_rank = 1 THEN CONCAT(cohort_label, ' voters (', FORMAT('%.0f', idx * 100), '% of state avg)') END), '.')
ELSE NULL
END AS overrep_sentence,
-- Statewide-average sentence (all significant cohorts near 1.0)
CASE
WHEN COUNT(CASE WHEN idx >= 1.10 AND pct >= 0.06 THEN 1 END) = 0
AND COUNT(CASE WHEN pct >= 0.02 AND (idx < 0.95 OR idx > 1.05) THEN 1 END) = 0
THEN ' The demographics of this district closely reflect the statewide averages across all cohorts.'
ELSE NULL
END AS statewide_avg_sentence
FROM (
SELECT
state, chamber, district_number,
cohort_label, idx, pct,
ROW_NUMBER() OVER (
PARTITION BY state, chamber, district_number
ORDER BY CASE WHEN idx >= 1.10 AND pct >= 0.06 THEN idx ELSE 0 END DESC
) AS overrep_rank
FROM (
SELECT state, chamber, district_number, 'White' AS cohort_label,
idx_white_vs_state AS idx, pct_white AS pct
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'Black',
idx_black_vs_state, pct_black
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'Latino',
idx_latino_vs_state, pct_latino
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'Asian',
idx_asian_vs_state, pct_asian
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'Native American',
idx_natam_vs_state, pct_natam
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'college-educated',
idx_college_vs_state, pct_college
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'high-school-only',
idx_high_school_only_vs_state, pct_high_school_only
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'young (18-34)',
idx_18_to_34_vs_state, pct_youth_18_34
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
UNION ALL
SELECT state, chamber, district_number, 'older (65+)',
idx_65_plus_vs_state, pct_senior_65plus
FROM `proj-tmc-mem-fm.main.trends_2025_district_analytics`
) unpivoted
) ranked
GROUP BY state, chamber, district_number
),
--======================================================================
-- 4. EXPLANATION ASSEMBLY
--
-- [v5.0 REV #25] Complete overhaul.
--
-- Architecture:
-- CASE on primary_category (7-way)
-- → Each category: interpretive lead focused on WHY the PTP is
-- what it is, not what the PTP is.
-- → Within each: CASE on exception_priority for structural
-- exception clauses (E3-E9) -- these carry the main
-- explanatory weight for grey-area districts.
-- → Conditional overlays: E1 (median disconnect), E2 (far from 50%).
-- [v6.0 REV #35] E10 (skew) overlay removed.
-- → Mid-range PTP: scenario-directional sentences using
-- entry_cohort_description from the tipping_condition_display CTE.
-- [v7.0 REV #44] 3-tier system: exit-only (PTP > 0.80),
-- two-sided (PTP 0.30-0.80), entry-only (PTP < 0.30).
-- [v7.0 REV #45] Two-sided exit clause simplified to
-- "it falls out when the reverse is true."
-- [v7.3 REV #55] Temporal disambiguation: explicit 2030
-- markers added to E2, inverse-E2, E1 D-lean, E1 R-lean
-- Cond/Marg, E4, E5, E6 (Periph), and E8 templates.
-- → Drivers included selectively, only when they illuminate
-- district dynamics.
-- → Length inversely proportional to how well the PTP matches
-- the simple heuristic (close to median + low rank_pct → high PTP).
--
-- Driver clauses use complement-aware rendering when invoked:
-- if is_complement_pair → use complement_display + promoted_tertiary
-- else → use primary_display + secondary_display (with tertiary
-- inclusion per existing different-category rule)
--
-- [v5.0 REV #26] rank_unit_word replaces rank_seats_word throughout.
-- Multi-member chambers (AZ House, NH House) say "districts"
-- instead of "seats".
--======================================================================
with_explanation AS (
SELECT
c.*,
CASE c.primary_category
--==============================================================
-- CATEGORY 1: SAFE NONCOMPETITIVE
-- (TPT = 0, |baseline_margin| > 8pts)
--
-- Half-sentence dismissal. No changes from v4.2.
-- [v4.1 REV #19] Religion modifier intentionally omitted here.
--==============================================================
WHEN 'Safe Noncompetitive' THEN
CONCAT('Safe ', c.dem_or_rep_safe, '.')
--==============================================================
-- CATEGORY 2: CLEAR NONCOMPETITIVE
-- (TPT = 0, |baseline_margin| 5-8pts)
--
-- 1-2 sentences. Clear enough to not need detailed structural
-- explanation, but worth stating distance from the zone.
--
-- E1 overlay: district near 50% but median far from it.
-- Lead with the apparent competitiveness and explain why it
-- doesn't matter for chamber control.
--
-- [v3.1 FIX 2] E1 overlay branches on chamber_lean.
-- [v5.0] Non-E1 branch shortened.
--==============================================================
WHEN 'Clear Noncompetitive' THEN CONCAT(
CASE
-- E1: District near 50%, median far from 50%.
-- Directly addresses likely reader confusion: "this looks
-- competitive, why isn't it a tipping point?"
WHEN c.flag_e1 THEN
CASE
-- R-leaning chamber
WHEN c.chamber_lean = 'R' THEN CONCAT(
'Although this district is competitive today (',
c.fmt_baseline_2025_pct, '% Dem), Democrats would need to be ',
'winning districts at ', c.fmt_median_pct, '% Dem to control ',
'the ', c.state, ' ', c.chamber_display, ' in 2030. In an ',
'environment where that was possible, this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.'
)
-- D-leaning chamber
-- [v3.1 FIX 2] Avoids "Dems would need to win at X%" when X > 50%.
ELSE CONCAT(
'Although this district appears competitive today (',
c.fmt_baseline_2025_pct, '% Dem), control of the ',
c.state, ' ', c.chamber_display, ' in 2030 will depend on districts near ',
c.fmt_median_pct, '% Dem -- well above the 50-50 line.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' Flipping this chamber would require ',
c.median_strategic_framing,
', and in that environment this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.')
ELSE CONCAT(' In that environment, this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.')
END
)
END
-- No E1: collapse to same short form as Safe Noncompetitive.
-- [v6.0 REV #37] Non-E1 Clear Noncompetitive now displays
-- "Safe D." or "Safe R." — margin detail adds no insight.
ELSE CONCAT('Safe ', c.dem_or_rep_safe, '.')
END,
-- Religion driver modifier (v4.1 REV #19; v6.0 REV #34 rewrite)
-- [v6.0 REV #34] Religion modifier rewrite: index-based percentage.
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
)
--==============================================================
-- CATEGORY 3: PERIPHERAL NONCOMPETITIVE
-- (TPT = 0, |baseline_margin| <= 5pts)
--
-- 2-4 sentences. Highest explanation value among noncompetitive
-- districts: they LOOK competitive but don't tip. The exception
-- flags (E3-E6) do the heavy lifting, telling the reader WHY.
--
-- General framing: lead with the disconnect, then explain the
-- structural reason it doesn't translate to TPT.
--
-- [v3.1 FIX 2] E1 overlay branches on chamber_lean.
-- [v5.0] Tightened language; multi-member fix for E4.
--==============================================================
WHEN 'Peripheral Noncompetitive' THEN CONCAT(
CASE
-- E1 overlay takes precedence when applicable.
WHEN c.flag_e1 THEN
CASE
-- R-leaning chamber
WHEN c.chamber_lean = 'R' THEN CONCAT(
'Although this district is competitive today (',
c.fmt_baseline_2025_pct, '% Dem), Democrats would need to be ',
'winning districts at ', c.fmt_median_pct, '% Dem to control ',
'the ', c.state, ' ', c.chamber_display, ' in 2030. In an ',
'environment where that was possible, this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.'
)
-- D-leaning chamber
ELSE CONCAT(
'Although this district appears competitive today (',
c.fmt_baseline_2025_pct, '% Dem), control of the ',
c.state, ' ', c.chamber_display, ' in 2030 will depend on districts near ',
c.fmt_median_pct, '% Dem -- well above the 50-50 line.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' Flipping this chamber would require ',
c.median_strategic_framing,
', and in that environment this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.')
ELSE CONCAT(' In that environment, this district would be ',
'well into safe-', c.dem_or_rep_safe, ' territory, far from ',
'the tipping-point zone.')
END
)
END
---------------------------------------------------------------
-- E4: NH MULTI-MEMBER MISMATCH
-- [v5.0] Uses "districts" language for NH House.
---------------------------------------------------------------
WHEN c.exception_priority = 'E4' THEN CONCAT(
'This district sits just ', c.fmt_baseline_margin,
' points from the projected 2030 NH House median, but New Hampshire\'s ',
'400-seat / 203-district structure inflates rank distances ',
'far beyond what vote-share margins suggest. It is ',
c.fmt_rank_dist, ' ', c.rank_unit_word, ' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold -- well ',
'outside the competitive zone -- despite its close margin.'
)
---------------------------------------------------------------
-- E5: RULE A BOUNDARY CLIFF
---------------------------------------------------------------
WHEN c.exception_priority = 'E5' THEN CONCAT(
'At ', c.fmt_baseline_margin, ' points from the projected 2030 ', c.state, ' ',
c.chamber_display, ' median, this district sits just outside ',
'the tightest margin threshold for tipping-point status. ',
'Districts a fraction of a point closer are near-certain ',
'tipping points; this one falls on the other side of that ',
'boundary at rank ', c.fmt_rank_dist, ' (', c.fmt_rank_pct,
'% of the chamber).'
)
---------------------------------------------------------------
-- E3: SMALL CHAMBER RANK EXCLUSION
-- The NV-HD-003 pattern: close margin, small chamber, narrow band.
-- [v6.0 REV #38] Removed "competitive zone extends X seats"
-- language. Added investment-potential framing.
---------------------------------------------------------------
WHEN c.exception_priority = 'E3' THEN CONCAT(
'This district is projected at ', c.fmt_dem_proj_pct,
'% Dem in 2030, just ', c.fmt_baseline_margin,
' points from the ', c.state, ' ', c.chamber_display,
' median (', c.fmt_median_pct, '% Dem). But the ', c.state,
' ', c.chamber_display, ' is a small chamber (',
CAST(c.total_chamber_seats AS STRING), ' seats) with a tightly ',
'clustered competitive zone. ',
CAST(c.districts_closer_to_median AS STRING),
' other districts are closer in rank to the median; this district ',
'may represent a worthwhile investment depending on cycle dynamics ',
'or if the program budget allows for an unusually large field of ',
'targeted races.',
-- Convergence addendum
CASE
WHEN c.trend_alignment = 'Converging'
THEN CONCAT(' Demographic trends are narrowing this gap by ',
c.fmt_shift_pts, ' points.')
ELSE ''
END
)
---------------------------------------------------------------
-- E6: RANK BAND EXCLUSION
-- [v6.0 REV #38] Simplified: "fell just outside the cutoff
-- for the model's target zone."
-- [v8.1] Enriched: surfaces which dimension (rank vs margin) is
-- the binding constraint. Rank-cliff and margin-cliff branches.
---------------------------------------------------------------
WHEN c.exception_priority = 'E6' THEN CONCAT(
'Projected at ', c.fmt_dem_proj_pct,
'% Dem in 2030, ', c.fmt_baseline_margin, ' points from the 2030 ',
c.state, ' ', c.chamber_display, ' median.',
-- [v8.1] Dimension-specific E6 text
CASE
-- Rank is the binding constraint: margin passes Rule B but rank outside band
WHEN ABS(c.baseline_margin_to_median_2030) <= 0.04
THEN CONCAT(
' The margin is close enough to be competitive, but at rank ',
c.fmt_rank_dist, ' the district sits just outside the ',
CAST(CAST(FLOOR(c.targeting_band) AS INT64) AS STRING),
'-seat competitive band',
' — only extreme scenarios push it into range.')
-- Margin is the binding constraint: rank passes but margin outside
WHEN c.rule_b_rank_met
THEN CONCAT(
' The district is within the competitive rank band, but its ',
c.fmt_baseline_margin,
'-point margin places it just outside the model\'s target zone.')
-- Both just outside (generic fallback)
ELSE CONCAT(
' The margin is close, but the district fell just outside the ',
'cutoff for the model\'s target zone.')
END,
-- Low volatility addendum
CASE
WHEN c.district_raw_volatility < c.chamber_avg_volatility * 0.5
THEN ' Low scenario variability means it never drifts into range.'
ELSE ''
END
)
---------------------------------------------------------------
-- DEFAULT: Generic Peripheral Noncompetitive
-- No structural exception fires. Provide margin/trend context.
-- [v5.0] Shortened. Drivers included only when informative.
---------------------------------------------------------------
ELSE CONCAT(
'Projected at ', c.fmt_dem_proj_pct,
'% Dem in 2030, ', c.fmt_baseline_margin,
' points from the ', c.state, ' ', c.chamber_display,
' median (', c.fmt_median_pct, '% Dem), but no modeled ',
'scenarios bring it into the tipping-point zone.',
-- Driver context REMOVED (v7.1 REV #49).
-- Overrep sentence now covers demographic composition.
-- Convergence
CASE
WHEN c.trend_alignment = 'Converging'
THEN CONCAT(' Demographic trends are narrowing the gap by ',
c.fmt_shift_pts, ' points, potentially making this district ',
'relevant in future cycles.')
WHEN c.trend_alignment = 'Diverging'
THEN CONCAT(' Demographic trends are widening the gap by ',
c.fmt_shift_pts, ' points.')
ELSE ''
END
)
END,
-- Religion driver modifier (v4.1 REV #19; v6.0 REV #34 rewrite)
-- [v6.0 REV #34] Religion modifier rewrite: index-based percentage.
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
)
--==============================================================
-- CATEGORY 4: TIPPING-POINT CORE
-- (TPT >= 93%)
--
-- [v6.0] Major rewrite. Two subcases:
--
-- Subcase 4a: PTP = 1.0, no exceptions, no E2, trivial
-- convergence/divergence. Compact format referencing
-- rank and/or Dem share based on targeting-box rules.
--
-- Subcase 4b: PTP 93-99%, or PTP = 1.0 with exceptions,
-- E2, or notable convergence. Detailed format with
-- scenario-directional opening, E2/E7 context, revised
-- position statement, selective driver clause,
-- convergence decomposition, and religion modifier.
--
-- [v6.0 REV #29] Scenario-directional sentences use
-- exit_cohort_description from tipping_condition_display CTE.
-- [v6.0 REV #31] Compact format uses targeting-box rules
-- (rule_a_met, rule_b_rank_met, rule_b_margin_met).
-- [v6.0 REV #33] Convergence decomposition with partisan
-- direction and stability gate.
--==============================================================
WHEN 'Tipping-Point Core' THEN
CASE
--------------------------------------------------------
-- SUBCASE 4a: COMPACT FORMAT
-- PTP = 1.0, no E2, convergence <= 1.0 pts, and either
-- no exception or E3/E6 (whose "excluded from zone"
-- framing is semantically wrong for 100%-tipping districts;
-- the compact format is more appropriate).
-- [v6.1] E3/E6 added to gate after REV #41 band-base
-- correction caused E3 to fire for AZ House PTP=1.0
-- districts that were previously inside the inflated band.
--------------------------------------------------------
WHEN c.percent_tipping_point = 1.0
AND (c.exception_priority IS NULL
OR c.exception_priority IN ('E3', 'E6'))
AND NOT c.flag_e2
AND ABS(ABS(c.baseline_margin_to_median_2025)
- ABS(c.baseline_margin_to_median_2030)) <= 0.01
THEN CONCAT(
CASE
-- Both rank and share close
WHEN c.rule_b_rank_met AND (c.rule_a_met OR c.rule_b_margin_met)
THEN CONCAT(
'This district is close to the median in projected 2030 ',
'rank (', c.fmt_rank_dist, ' ', c.rank_unit_word, ', ',
c.fmt_rank_pct, '% of the chamber) and Dem share (',
c.fmt_baseline_margin, ' points to the ', c.partisan_side,
' side) across all scenarios.')
-- Rank close only
WHEN c.rule_b_rank_met
THEN CONCAT(
'This district is close to the median in projected 2030 ',
'rank (', c.fmt_rank_dist, ' ', c.rank_unit_word, ', ',
c.fmt_rank_pct, '% of the chamber) across all scenarios.')
-- Share close only
ELSE CONCAT(
'This district is close to the median in projected 2030 ',
'Dem share (', c.fmt_baseline_margin, ' points to the ',
c.partisan_side, ' side) across all scenarios.')
END,
-- Religion modifier (Section V)
-- [v6.0 REV #34] Religion modifier rewrite: index-based percentage.
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
)
--------------------------------------------------------
-- SUBCASE 4b: ALL OTHER CORE DISTRICTS
-- PTP 93-99% or PTP = 1.0 with E2/E5/E7-E9/notable
-- convergence.
-- [v6.1] LTRIM handles leading-space artifact when
-- steps (1)-(3) all produce empty strings (e.g.,
-- PTP=1.0 with notable convergence but no E2/E7).
--------------------------------------------------------
ELSE LTRIM(CONCAT(
-- (1) Scenario-directional sentence (exit-side only)
-- [v6.0 REV #29] Uses exit_cohort_description from
-- tipping_condition_display CTE.
-- [v7.0 REV #44] All Core districts are PTP > 0.80 → exit-only tier.
-- For PTP = 1.0 reaching this subcase: skip (explanation
-- carried by exception/convergence blocks).
-- NULL-driver fallback (48/0 split): omit sentence entirely.
CASE
WHEN c.percent_tipping_point < 1.0
AND c.exit_cohort_description IS NOT NULL
THEN CONCAT(
'The only scenarios where this district is not in the ',
'tipping-point zone are those where ',
c.exit_cohort_description, '.')
ELSE ''
END,
-- (2) E2 overlay (moved early)
-- Addresses "this doesn't look competitive" confusion.
CASE
WHEN c.flag_e2
THEN CONCAT(
CASE WHEN c.percent_tipping_point < 1.0
AND c.exit_cohort_description IS NOT NULL
THEN ' ' ELSE '' END,
'The projected 2030 Dem share of ', c.fmt_dem_proj_pct,
'% may not look competitive, but the 2030 chamber median ',
'is ', c.fmt_median_pct, '% Dem -- ',
CASE WHEN c.chamber_median_dem_share_2030 < 0.50
THEN 'well below' ELSE 'well above' END,
' the 50-50 line.')
ELSE ''
END,
-- (3) E7 chamber-dynamics overlay
CASE
WHEN c.exception_priority = 'E7'
THEN CONCAT(
' The ', CAST(c.total_chamber_seats AS STRING),
'-seat chamber has a wide competitive band that keeps this ',
'district in the tipping-point zone even though it sits ',
c.fmt_rank_dist, ' ', c.rank_unit_word, ' from the median; ',
'in a smaller legislature, this margin would likely place ',
'it outside.')
ELSE ''
END,
-- (4) Position statement (revised)
-- [v6.0 REV #31] "Projected to sit … in 2030"
CASE
WHEN c.at_exact_median
THEN ' Projected to sit essentially at the chamber median in 2030'
ELSE CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030')
END,
-- Rank clause
-- [v7.1 REV #50] E7 suppresses rank (E7 template already states it).
CASE
WHEN c.exception_priority = 'E7' THEN '.'
WHEN ABS(c.baseline_rank_distance_to_median_2030) <= 1
THEN ', at or immediately adjacent to the majority threshold.'
ELSE CONCAT(', ', c.fmt_rank_dist, ' ',
c.rank_unit_word, ' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
END,
-- (5) Driver clause REMOVED (v7.1 REV #49).
-- Overrep sentence now covers demographic composition;
-- scenario-directional opening covers cohort sensitivity.
-- (6) Convergence/divergence (revised per Section VI-E)
-- [v6.0 REV #33] Decomposition with partisan direction.
-- Threshold: |convergence_magnitude| > 0.01 (1.0 pts) for Core.
-- Stability gate: suppress if |district_shift| < 0.002 unless
-- |median_shift| > 0.005 (median doing the heavy lifting).
CASE
-- Below threshold: suppress entirely
WHEN ABS(c.convergence_magnitude) <= 0.01 THEN ''
-- Stability gate: district barely moved
WHEN ABS(c.delta_baseline_2030_vs_2025) < 0.002
AND ABS(c.median_shift_2025_to_2030) <= 0.005
THEN ''
-- DIVERGING
WHEN c.trend_alignment = 'Diverging' THEN
CASE
-- Median shift notable
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', widening the gap from the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
-- Median shift trivial
ELSE CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030, moving it further from the tipping-point zone.')
END
-- CONVERGING
WHEN c.trend_alignment = 'Converging' THEN
CASE
-- Median shift notable
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', narrowing the gap to the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
-- Median shift trivial
ELSE CONCAT(
' Demographic trends are projected to narrow the gap by ',
c.fmt_shift_pts, ' points by 2030, potentially making ',
'this district more relevant in future cycles.')
END
ELSE ''
END,
-- (7) Religion modifier (v4.1 REV #19; v6.0 REV #34 rewrite)
-- [v6.0 REV #34] Religion modifier rewrite: index-based percentage.
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
))
END
--==============================================================
-- CATEGORY 5: STRONG COMPETITIVE
-- (TPT 50-93%)
--
-- [v6.0] Major rewrite. Sentence order:
-- (1) Scenario-directional opening (NEW, from tipping_condition_display)
-- (2) E2 overlay
-- (3) Structural context (E7/E8/E9, reworded)
-- (4) Position statement (with E8/E3/E6 modifiers)
-- (5) Driver clause REMOVED (scenario opening carries cohort info)
-- (6) Convergence/divergence (Section VI-E)
-- (7) Religion modifier (Section V)
--==============================================================
WHEN 'Strong Competitive' THEN LTRIM(CONCAT(
-- (1) Scenario-directional opening
-- [v7.0 REV #44] 3-tier system replaces 4-tier.
-- Strong Competitive spans PTP 0.50-0.93:
-- PTP > 0.80 → exit-only
-- PTP 0.30-0.80 → two-sided (all Strong Comp >= 0.50, so 0.50-0.80)
-- [v7.0 REV #45] Two-sided exit clause: "the reverse is true."
CASE
-- PTP > 80%: exit-only framing
-- [v7.0 REV #44] Was "wide-range" at >= 0.75; now pure exit-only at > 0.80.
WHEN c.percent_tipping_point > 0.80
AND c.exit_cohort_description IS NOT NULL
THEN CONCAT(
'The only scenarios where this district is not in the ',
'tipping-point zone are those where ',
c.exit_cohort_description, '.')
-- PTP 50-80%: two-sided framing
-- [v7.0 REV #45] Exit clause simplified to "the reverse is true."
WHEN c.entry_cohort_description IS NOT NULL
THEN CONCAT(
'This district enters the tipping-point zone when ',
c.entry_cohort_description,
'; it falls out when the reverse is true.')
-- NULL-driver fallback: omit and proceed
ELSE ''
END,
-- (2) E2 overlay (moved earlier)
CASE
WHEN c.flag_e2
THEN CONCAT(
' The projected 2030 Dem share of ', c.fmt_dem_proj_pct,
'% may not look competitive, but the 2030 chamber median is ',
c.fmt_median_pct, '% Dem -- ',
CASE WHEN c.chamber_median_dem_share_2030 < 0.50
THEN 'well below' ELSE 'well above' END,
' the 50-50 line.')
ELSE ''
END,
-- (3) Structural context (E7/E8/E9, reworded)
-- [v6.0 REV #36] PTP percentages removed.
CASE
-- E9: High Volatility Rescue
WHEN c.exception_priority = 'E9' THEN CONCAT(
' Baseline position is outside the tipping-point zone, but ',
'high demographic sensitivity (a ', c.fmt_scenario_range,
'-point range across scenarios) creates enough swing to bring ',
'it into range.')
-- E8: Decay Zone (reworded for v6.0)
WHEN c.exception_priority = 'E8' THEN CONCAT(
' At ', c.fmt_baseline_margin,
' points on the ', c.partisan_side, ' side of the 2030 median, this district sits at the outer edge ',
'of the competitive range -- close enough that demographic ',
'shifts still push it into the zone across ',
CASE WHEN c.percent_tipping_point < 0.65
THEN 'a significant share' ELSE 'a majority' END,
' of scenarios.')
-- E7: Large Chamber Inclusion
WHEN c.exception_priority = 'E7' THEN CONCAT(
' The ', CAST(c.total_chamber_seats AS STRING), '-seat ',
c.state, ' ', c.chamber_display,
' has a wide competitive band; in a smaller chamber, a ',
c.fmt_baseline_margin,
'-point margin would typically fall outside the tipping-point zone.')
-- No structural exception: omit
ELSE ''
END,
-- (4) Position statement
-- [v6.0] E8 modifier: omit margin, state only rank.
-- [v6.0] E3/E6 modifier: omit entirely (those templates include position).
-- [v7.1 REV #50] E7 → margin-only (E7 template already states rank).
CASE
WHEN c.exception_priority IN ('E3', 'E6') THEN ''
WHEN c.exception_priority = 'E8' THEN CONCAT(
' Projected to sit ', c.fmt_rank_dist, ' ', c.rank_unit_word,
' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold on the ',
c.partisan_side, ' side of the ', c.state, ' ',
c.chamber_display, ' median in 2030.')
WHEN c.exception_priority = 'E7' THEN CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030.')
ELSE CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030, ', c.fmt_rank_dist, ' ',
c.rank_unit_word, ' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
END,
-- (5) Driver clause REMOVED (v6.0 REV #29).
-- Scenario-directional opening carries cohort info.
-- (6) Convergence/divergence (Section VI-E)
-- Threshold: |convergence_magnitude| > 0.005 (0.5 pts).
CASE
WHEN ABS(c.convergence_magnitude) <= 0.005 THEN ''
WHEN ABS(c.delta_baseline_2030_vs_2025) < 0.002
AND ABS(c.median_shift_2025_to_2030) <= 0.005
THEN ''
WHEN c.trend_alignment = 'Diverging' THEN
CASE
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', widening the gap from the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030, moving it further from the tipping-point zone.')
END
WHEN c.trend_alignment = 'Converging' THEN
CASE
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', narrowing the gap to the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' Demographic trends are projected to narrow the gap by ',
c.fmt_shift_pts, ' points by 2030, potentially making ',
'this district more relevant in future cycles.')
END
ELSE ''
END,
-- (7) Religion modifier (v6.0 REV #34)
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
))
--==============================================================
-- CATEGORY 6: CONDITIONAL COMPETITIVE
-- (TPT 10-50%)
--
-- [v6.0] Major rewrite.
--
-- E1 branch: Existing E1 framing retained as lead.
-- Append scenario-directional sentence (NEW).
-- Driver clause removed (scenario sentence replaces it).
-- E1 residual PTP note removed.
-- Convergence: suppressed (E1 framing is self-contained).
-- Religion modifier appended.
--
-- Non-E1 branch, sentence order:
-- (1) Scenario-directional opening (NEW)
-- (2) Inverse-E2 (NEW)
-- (3) Structural context (E3/E5/E6/E7/E8/E9)
-- (4) Position statement (with E8/E3/E6 modifiers)
-- (5) Driver clause REMOVED
-- (6) Convergence/divergence (Section VI-E)
-- (7) Religion modifier (Section V)
--
-- [v3.1 FIX 2] E1 overlay branches on chamber_lean.
-- [v6.0 REV #29] Scenario-directional sentences added.
-- [v6.0 REV #32] Inverse-E2 added.
--==============================================================
WHEN 'Conditional Competitive' THEN CONCAT(
CASE
--------------------------------------------------------
-- E1 BRANCH
--------------------------------------------------------
WHEN c.flag_e1 THEN CONCAT(
-- E1 lead framing (unchanged logic, unchanged chamber-lean branching)
CASE
-- R-leaning chamber
WHEN c.chamber_lean = 'R' THEN CONCAT(
'Even though this district is competitive today (',
c.fmt_baseline_2025_pct, '% Dem) and projected near 50% in ',
'2030 (', c.fmt_dem_proj_pct, '% Dem), the median district ',
'Democrats would need to win to control the ', c.state, ' ',
c.chamber_display, ' in 2030 will be ', c.fmt_median_pct, '% Dem.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' That would require ', c.median_strategic_framing,
', and in that environment this district would ',
'likely be a safe ', c.dem_or_rep_safe,
' seat outside the tipping-point zone.')
ELSE CONCAT(' In that environment this district would ',
'likely be a safe ', c.dem_or_rep_safe,
' seat outside the tipping-point zone.')
END
)
-- D-leaning chamber
ELSE CONCAT(
'Even though this district appears competitive today (',
c.fmt_baseline_2025_pct, '% Dem) and projected near 50% in ',
'2030 (', c.fmt_dem_proj_pct, '% Dem), control of the ',
c.state, ' ', c.chamber_display, ' in 2030 will depend on districts near ',
c.fmt_median_pct, '% Dem -- well above the 50-50 line.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' Flipping this chamber would require ',
c.median_strategic_framing,
', and in that environment this district would ',
'likely be a safe ', c.dem_or_rep_safe,
' seat outside the tipping-point zone.')
ELSE CONCAT(' In that environment this district would ',
'likely be a safe ', c.dem_or_rep_safe,
' seat outside the tipping-point zone.')
END
)
END,
-- [v6.0 REV #29] Scenario-directional sentence appended to E1 framing
-- [v7.0 REV #44] Split at PTP 0.30: two-sided vs entry-only.
-- [v7.0 REV #45] Two-sided exit clause: "the reverse is true."
CASE
-- PTP >= 0.30: two-sided framing
WHEN c.percent_tipping_point >= 0.30
AND c.entry_cohort_description IS NOT NULL
THEN CONCAT(
' This district enters the tipping-point zone when ',
c.entry_cohort_description,
'; it falls out when the reverse is true.')
-- PTP < 0.30: entry-only framing
WHEN c.entry_cohort_description IS NOT NULL
THEN CONCAT(
' The only scenarios where this district enters the ',
'tipping-point zone are those where ',
c.entry_cohort_description, '.')
ELSE ''
END
)
--------------------------------------------------------
-- NON-E1 BRANCH
--------------------------------------------------------
ELSE LTRIM(CONCAT(
-- (1) Scenario-directional opening
-- [v7.0 REV #44] Split at PTP 0.30: two-sided vs entry-only.
-- [v7.0 REV #45] Two-sided exit clause: "the reverse is true."
CASE
-- PTP >= 0.30: two-sided framing
WHEN c.percent_tipping_point >= 0.30
AND c.entry_cohort_description IS NOT NULL
THEN CONCAT(
'This district enters the tipping-point zone when ',
c.entry_cohort_description,
'; it falls out when the reverse is true.')
-- PTP < 0.30: entry-only framing
WHEN c.entry_cohort_description IS NOT NULL
THEN CONCAT(
'The only scenarios where this district enters the ',
'tipping-point zone are those where ',
c.entry_cohort_description, '.')
ELSE ''
END,
-- (2) Inverse-E2 (v6.0 REV #32; v7.0 REV #46 always 2030)
-- District near 50% but far from median → low PTP.
CASE
WHEN c.flag_e2_inverse
THEN CONCAT(
' The projected 2030 Dem share of ',
c.fmt_dem_proj_pct,
'% may look competitive, but the 2030 chamber median ',
'sits at ', c.fmt_median_pct,
'% Dem, placing this district ', c.fmt_baseline_margin,
' points ',
CASE WHEN c.baseline_margin_to_median_2030 > 0
THEN 'above' ELSE 'below' END,
' the tipping-point zone.')
ELSE ''
END,
-- (3) Structural context (E3/E5/E6/E7/E8/E9)
-- [v6.0] Reworded per VI-C and VI-F.
CASE
WHEN c.exception_priority = 'E9' THEN CONCAT(
' Baseline position is outside the tipping-point zone, but ',
'high demographic sensitivity (a ', c.fmt_scenario_range,
'-point range across scenarios) creates enough swing to bring ',
'it into range.')
WHEN c.exception_priority = 'E8' THEN CONCAT(
' At ', c.fmt_baseline_margin,
' points on the ', c.partisan_side, ' side of the 2030 median, this district sits at the outer ',
'edge of the competitive range -- close enough that ',
'demographic shifts still push it into the zone across ',
'a significant share of scenarios.')
WHEN c.exception_priority = 'E3' THEN CONCAT(
' The ', c.state, ' ', c.chamber_display, ' is a small ',
'chamber (', CAST(c.total_chamber_seats AS STRING),
' seats) with a tightly clustered competitive zone. ',
CAST(c.districts_closer_to_median AS STRING),
' other districts are closer in rank to the median; this ',
'district may represent a worthwhile investment depending on ',
'cycle dynamics or if the program budget allows for an ',
'unusually large field of targeted races.')
WHEN c.exception_priority = 'E5' THEN CONCAT(
' Sits just outside the tightest margin threshold for ',
'full tipping-point status.')
-- [v8.1] Enriched E6: surfaces binding dimension (rank vs margin).
WHEN c.exception_priority = 'E6' THEN
CASE
WHEN ABS(c.baseline_margin_to_median_2030) <= 0.04
THEN CONCAT(
' The ', c.fmt_baseline_margin,
'-point margin is inside the model\'s competitive threshold, ',
'but at rank ', c.fmt_rank_dist,
' the district sits just outside the ',
CAST(CAST(FLOOR(c.targeting_band) AS INT64) AS STRING),
'-seat competitive band — a rank-boundary effect that ',
'sharply limits its tipping-point probability.')
WHEN c.rule_b_rank_met
THEN CONCAT(
' The district is within the competitive rank band, but its ',
c.fmt_baseline_margin,
'-point margin places it just outside the model\'s target zone.')
ELSE CONCAT(
' The margin is close, but the district fell just outside ',
'the cutoff for the model\'s target zone.')
END
WHEN c.exception_priority = 'E7' THEN CONCAT(
' The ', CAST(c.total_chamber_seats AS STRING), '-seat ',
c.state, ' ', c.chamber_display,
' has a wide competitive band; in a smaller chamber, a ',
c.fmt_baseline_margin,
'-point margin would typically fall outside the ',
'tipping-point zone.')
ELSE ''
END,
-- (4) Position statement
-- [v6.0] E8 modifier: omit margin, state only rank.
-- [v6.0] E3/E6 modifier: omit entirely.
-- [v7.1 REV #50] E7 → margin-only; E2-inverse → rank-only.
CASE
WHEN c.exception_priority IN ('E3', 'E6') THEN ''
WHEN c.exception_priority = 'E8' THEN CONCAT(
' Projected to sit ', c.fmt_rank_dist, ' ', c.rank_unit_word,
' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold on the ',
c.partisan_side, ' side of the ', c.state, ' ',
c.chamber_display, ' median in 2030.')
WHEN c.flag_e2_inverse THEN CONCAT(
' Projected to sit ', c.fmt_rank_dist, ' ', c.rank_unit_word,
' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
WHEN c.exception_priority = 'E7' THEN CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030.')
ELSE CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030, ', c.fmt_rank_dist, ' ',
c.rank_unit_word, ' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
END
-- (5) Driver clause REMOVED (v6.0 REV #29).
-- Scenario-directional opening carries cohort info.
))
END,
-- (6) Convergence/divergence (Section VI-E)
-- E1: suppressed (self-contained framing).
-- Non-E1: threshold |convergence_magnitude| > 0.005 (0.5 pts).
CASE
WHEN c.flag_e1 THEN ''
WHEN ABS(c.convergence_magnitude) <= 0.005 THEN ''
WHEN ABS(c.delta_baseline_2030_vs_2025) < 0.002
AND ABS(c.median_shift_2025_to_2030) <= 0.005
THEN ''
WHEN c.trend_alignment = 'Diverging' THEN
CASE
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', widening the gap from the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030, moving it further from the tipping-point zone.')
END
WHEN c.trend_alignment = 'Converging' THEN
CASE
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', narrowing the gap to the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' Demographic trends are projected to narrow the gap by ',
c.fmt_shift_pts, ' points by 2030, potentially making ',
'this district more relevant in future cycles.')
END
ELSE ''
END,
-- (7) Religion modifier (v6.0 REV #34)
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
)
--==============================================================
-- CATEGORY 7: MARGINAL
-- (0 < TPT < 10%)
--
-- [v6.0] Major rewrite.
--
-- E1 branch: Existing E1 framing retained as lead.
-- Scenario-directional sentence appended (replaces driver clause).
-- Convergence: converging only, updated decomposition (VI-E).
-- Religion modifier appended.
--
-- Non-E1 branch, sentence order:
-- (1) Scenario-directional opening (one-sided, entry only)
-- (2) Inverse-E2 (NEW)
-- (3) Position statement (with E8/E3/E6 modifiers)
-- (4) Structural context if applicable
-- (5) Convergence (converging only, Section VI-E)
-- (6) Religion modifier (Section V)
--
-- [v3.1 FIX 2] E1 overlay branches on chamber_lean.
-- [v6.0 REV #29] Scenario-directional sentences added.
-- [v6.0 REV #32] Inverse-E2 added.
--==============================================================
WHEN 'Marginal' THEN CONCAT(
CASE
--------------------------------------------------------
-- E1 BRANCH
--------------------------------------------------------
WHEN c.flag_e1 THEN CONCAT(
-- E1 lead framing (unchanged logic, unchanged chamber-lean branching)
CASE
WHEN c.chamber_lean = 'R' THEN CONCAT(
'Even though this district is competitive today (',
c.fmt_baseline_2025_pct, '% Dem) and projected at ',
c.fmt_dem_proj_pct, '% Dem in 2030, the median district ',
'Democrats would need to win to control the ', c.state, ' ',
c.chamber_display, ' in 2030 will be ', c.fmt_median_pct, '% Dem.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' That would require ', c.median_strategic_framing,
', and in that environment this district would ',
'almost certainly be a safe ', c.dem_or_rep_safe,
' seat, well outside the tipping-point zone.')
ELSE CONCAT(' In that environment, this district would ',
'almost certainly be a safe ', c.dem_or_rep_safe,
' seat, well outside the tipping-point zone.')
END
)
ELSE CONCAT(
'Even though this district appears competitive today (',
c.fmt_baseline_2025_pct, '% Dem) and projected at ',
c.fmt_dem_proj_pct, '% Dem in 2030, control of the ',
c.state, ' ', c.chamber_display, ' in 2030 will depend on districts near ',
c.fmt_median_pct, '% Dem -- well above the 50-50 line.',
CASE
WHEN c.median_strategic_framing != ''
THEN CONCAT(' Flipping this chamber would require ',
c.median_strategic_framing,
', and in that environment this district would ',
'almost certainly be a safe ', c.dem_or_rep_safe,
' seat, well outside the tipping-point zone.')
ELSE CONCAT(' In that environment, this district would ',
'almost certainly be a safe ', c.dem_or_rep_safe,
' seat, well outside the tipping-point zone.')
END
)
END,
-- [v6.0 REV #29] Scenario-directional sentence appended to E1 framing
-- Replaces old driver clause for E1 Marginal districts.
CASE
WHEN c.entry_cohort_description IS NOT NULL
THEN CONCAT(
' The only scenarios where this district enters the ',
'tipping-point zone are those where ',
c.entry_cohort_description, '.')
ELSE ''
END,
-- Convergence for E1 Marginal (converging only, VI-E decomposition)
CASE
WHEN c.trend_alignment != 'Converging' THEN ''
WHEN ABS(c.convergence_magnitude) <= 0.005 THEN ''
WHEN ABS(c.delta_baseline_2030_vs_2025) < 0.002
AND ABS(c.median_shift_2025_to_2030) <= 0.005
THEN ''
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', narrowing the gap to the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' Demographic trends are projected to narrow the gap by ',
c.fmt_shift_pts, ' points by 2030, potentially making ',
'this district more relevant in future cycles.')
END
)
--------------------------------------------------------
-- NON-E1 BRANCH
--------------------------------------------------------
ELSE LTRIM(CONCAT(
-- (1) Scenario-directional opening (one-sided, entry only)
-- [v6.0 REV #29] Marginal districts use entry-only framing.
CASE
WHEN c.entry_cohort_description IS NOT NULL
THEN CONCAT(
'The only scenarios where this district enters the ',
'tipping-point zone are those where ',
c.entry_cohort_description, '.')
-- NULL-driver fallback (uniform-swing-driven tipping)
ELSE CONCAT(
'This district enters the tipping-point zone only under ',
'specific uniform-swing conditions, not through demographic ',
'scenario differences.')
END,
-- (2) Inverse-E2 (v6.0 REV #32; v7.0 REV #46 always 2030)
CASE
WHEN c.flag_e2_inverse
THEN CONCAT(
' The projected 2030 Dem share of ',
c.fmt_dem_proj_pct,
'% may look competitive, but the 2030 chamber median ',
'sits at ', c.fmt_median_pct,
'% Dem, placing this district ', c.fmt_baseline_margin,
' points ',
CASE WHEN c.baseline_margin_to_median_2030 > 0
THEN 'above' ELSE 'below' END,
' the tipping-point zone.')
ELSE ''
END,
-- (3) Position statement
-- [v6.0] E8 modifier: omit margin, state only rank.
-- [v6.0] E3/E6 modifier: omit entirely.
-- [v7.1 REV #50] E2-inverse → rank-only; E7 → margin-only.
CASE
WHEN c.exception_priority IN ('E3', 'E6') THEN ''
WHEN c.exception_priority = 'E8' THEN CONCAT(
' Projected to sit ', c.fmt_rank_dist, ' ', c.rank_unit_word,
' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold on the ',
c.partisan_side, ' side of the ', c.state, ' ',
c.chamber_display, ' median in 2030.')
WHEN c.flag_e2_inverse THEN CONCAT(
' Projected to sit ', c.fmt_rank_dist, ' ', c.rank_unit_word,
' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
WHEN c.exception_priority = 'E7' THEN CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030.')
ELSE CONCAT(
' Projected to sit ', c.fmt_baseline_margin,
' points to the ', c.partisan_side,
' side of the ', c.state, ' ', c.chamber_display,
' median in 2030, ', c.fmt_rank_dist, ' ',
c.rank_unit_word, ' (', c.fmt_rank_pct,
'% of the chamber) from the majority threshold.')
END,
-- (4) Structural context (if applicable)
-- [v6.0] Reworded per VI-C and VI-F.
CASE
WHEN c.exception_priority = 'E6' THEN
-- [v8.1] Enriched E6: surfaces binding dimension (rank vs margin).
CASE
WHEN ABS(c.baseline_margin_to_median_2030) <= 0.04
THEN CONCAT(
' The ', c.fmt_baseline_margin,
'-point margin is inside the model\'s competitive threshold, ',
'but at rank ', c.fmt_rank_dist,
' the district sits just outside the ',
CAST(CAST(FLOOR(c.targeting_band) AS INT64) AS STRING),
'-seat competitive band — a rank-boundary effect that ',
'sharply limits its tipping-point probability.')
WHEN c.rule_b_rank_met
THEN CONCAT(
' The district is within the competitive rank band, but its ',
c.fmt_baseline_margin,
'-point margin places it just outside the model\'s target zone.')
ELSE ' This district fell just outside the cutoff for the model\'s target zone.'
END
WHEN c.exception_priority = 'E9' THEN CONCAT(
' Baseline position is outside the tipping-point zone, but ',
'high demographic sensitivity (a ', c.fmt_scenario_range,
'-point range across scenarios) creates enough swing to bring ',
'it into range.')
WHEN c.exception_priority = 'E8' THEN CONCAT(
' At ', c.fmt_baseline_margin,
' points on the ', c.partisan_side, ' side of the 2030 median, this district sits at the outer ',
'edge of the competitive range -- close enough that ',
'demographic shifts still push it into the zone across ',
'a significant share of scenarios.')
WHEN c.exception_priority = 'E3' THEN CONCAT(
' The ', c.state, ' ', c.chamber_display, ' is a small ',
'chamber (', CAST(c.total_chamber_seats AS STRING),
' seats) with a tightly clustered competitive zone. ',
CAST(c.districts_closer_to_median AS STRING),
' other districts are closer in rank to the median; this ',
'district may represent a worthwhile investment depending on ',
'cycle dynamics or if the program budget allows for an ',
'unusually large field of targeted races.')
WHEN c.exception_priority = 'E7' THEN CONCAT(
' The ', CAST(c.total_chamber_seats AS STRING), '-seat ',
c.state, ' ', c.chamber_display,
' has a wide competitive band; in a smaller chamber, a ',
c.fmt_baseline_margin,
'-point margin would typically fall outside the ',
'tipping-point zone.')
ELSE ''
END,
-- (5) Convergence (converging only, Section VI-E)
-- Marginal: divergence suppressed (less interesting).
-- Threshold > 0.005.
CASE
WHEN c.trend_alignment != 'Converging' THEN ''
WHEN ABS(c.convergence_magnitude) <= 0.005 THEN ''
WHEN ABS(c.delta_baseline_2030_vs_2025) < 0.002
AND ABS(c.median_shift_2025_to_2030) <= 0.005
THEN ''
WHEN ABS(c.median_shift_2025_to_2030) >= 0.002
THEN CONCAT(
' The district is projected to shift ',
c.fmt_district_shift_pts, ' points ',
c.district_shift_direction,
' by 2030 while the state median moves ',
c.fmt_median_shift_pts, ' points ',
c.median_shift_direction,
', narrowing the gap to the tipping-point zone by ',
c.fmt_shift_pts, ' points.')
ELSE CONCAT(
' Demographic trends are projected to narrow the gap by ',
c.fmt_shift_pts, ' points by 2030, potentially making ',
'this district more relevant in future cycles.')
END
))
END,
-- (6) Religion modifier (v6.0 REV #34)
-- [v7.0 REV #47] Cohort overrepresentation sentence
COALESCE(cor.overrep_sentence, cor.statewide_avg_sentence, ''),
CASE
WHEN c.religion_driver != 'None' THEN CONCAT(
' This district is also sensitive to movement among ',
c.religion_driver,
' voters, having a share of this cohort that is ',
FORMAT('%.0f',
CASE
WHEN c.religion_driver = 'Catholic' THEN c.idx_catholic_vs_state * 100
WHEN c.religion_driver = 'Evangelical' THEN c.idx_evangelical_vs_state * 100
WHEN c.religion_driver = 'Mormon' THEN c.idx_mormon_vs_state * 100
WHEN c.religion_driver = 'Jewish' THEN c.idx_jewish_vs_state * 100
END),
'% of the state average.')
ELSE ''
END
)
ELSE 'Classification error: unrecognized primary category.'
END AS tipping_point_explanation
FROM classified c
-- [v7.0 REV #47] Join cohort overrepresentation for demographic sentences.
LEFT JOIN cohort_overrepresentation cor
USING (state, chamber, district_number)
),
--======================================================================
-- 5. FINAL OUTPUT
-- (51 columns: 33 carry-over + 16 added pass-through + 2 generated)
--
-- [v11.0 REL #3] +4 pass-through fields: pct_mormon, pct_jewish,
-- idx_mormon_vs_state, idx_jewish_vs_state. Total 47 -> 51.
--
-- [v6.0 REV #30] Output field changes:
-- Removed: religion_driver_scenario_exposure_value (-1).
-- Added pass-through: pct_natam, pct_nonwhite, pct_college,
-- pct_high_school_only, pct_catholic, pct_evangelical, pct_female,
-- pct_youth_18_34, pct_senior_65plus, idx_natam_vs_state,
-- idx_female_vs_state, tipping_scenario_count,
-- non_tipping_scenario_count (+13).
-- Net: 35 → 47.
-- Ingestion-only (NOT in final_output): chamber_median_dem_share_2025,
-- fmt_median_2025_pct, median_shift_2025_to_2030,
-- fmt_district_shift_pts, plus 9 tipping_condition_driver fields
-- (flow via a.*).
--
-- [v4.2] REV #24: +2 columns (rank_pct_of_chamber_2025,
-- baseline_rank_pct_of_chamber_2030).
-- [v4.1] REV #19: +2 columns (religion_driver,
-- religion_driver_scenario_exposure_value).
-- [v4.0] Carry-over field renames applied per Step 3 v13.1:
-- REV #22: 5 renamed fields in carry-over list.
-- REV #23: avg_seats_from_tipping_point →
-- avg_abs_rank_distance_to_median_2030.
-- REV #20: 10 pct_*_vs_state → idx_*_vs_state.
--
-- Unchanged from v4.2 except explanation field content (REV #25).
-- district_archetype uses the OLD 4-way classification for
-- backward compatibility. The explanation uses primary_category
-- (7-way) exclusively.
--======================================================================
final_output AS (
SELECT
-- Identity
state, chamber, district_number,
-- Tipping frequency
percent_tipping_point,
-- Partisan share trajectory
dem_weighted_baseline_2025,
delta_baseline_2030_vs_2025,
dem_baseline_projected_2030,
chamber_median_dem_share_2030,
-- Structural position
avg_abs_rank_distance_to_median_2030,
total_chamber_seats,
-- Proportional rank position (v4.2, REV #24)
rank_pct_of_chamber_2025,
baseline_rank_pct_of_chamber_2030,
-- Drivers
primary_trend_driver,
secondary_trend_driver,
tertiary_trend_driver,
-- Religion driver (v4.1, REV #19)
-- [v6.0 REV #30] religion_driver_scenario_exposure_value removed.
religion_driver,
-- Volatility & trend
district_raw_volatility,
trend_alignment,
-- Raw demographic shares (from Step 3)
pct_white,
pct_black,
pct_latino,
pct_asian,
-- [v6.0 REV #30] Additional raw demographic shares (pass-through from Step 3)
-- [v11.0 REL #3] pct_mormon and pct_jewish added.
pct_natam,
pct_nonwhite,
pct_college,
pct_high_school_only,
pct_catholic,
pct_evangelical,
pct_mormon,
pct_jewish,
pct_female,
pct_youth_18_34,
pct_senior_65plus,
-- Demographic vs-state concentration indices (from Step 3)
-- [v4.0] Renamed from pct_*_vs_state to idx_*_vs_state (REV #20).
idx_white_vs_state,
idx_black_vs_state,
idx_latino_vs_state,
idx_asian_vs_state,
idx_18_to_34_vs_state,
idx_65_plus_vs_state,
idx_high_school_only_vs_state,
idx_college_vs_state,
idx_catholic_vs_state,
idx_evangelical_vs_state,
-- [v6.0 REV #30] Additional demographic indices (pass-through from Step 3)
-- [v11.0 REL #3] idx_mormon_vs_state and idx_jewish_vs_state added.
idx_mormon_vs_state,
idx_jewish_vs_state,
idx_natam_vs_state,
idx_female_vs_state,
-- [v6.0 REV #30] Tipping-condition diagnostic fields (pass-through from Step 3)
tipping_scenario_count,
non_tipping_scenario_count,
-- Generated columns
district_archetype,
tipping_point_explanation
FROM with_explanation
WHERE
(NOT diagnostic_mode)
OR (STRUCT(state, chamber, district_number)
IN UNNEST(diagnostic_districts))
)
SELECT * FROM final_output
ORDER BY state, chamber, district_number;
-- END STEP 4
