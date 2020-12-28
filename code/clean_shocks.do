/*
After applying basic filters, analyze and screen shocks to commitments
and cashflow variables. Output raw data (basic filtered), plus new smoothed
variables and dummies identifying potential data for quality control.
*/


* ------------------------------------------------------------------------------
* Setup + Data
* ------------------------------------------------------------------------------

clear all
set more off

*Define tuning parameters

* A temporary shock for smoothing is defined as a spike up/down and then a
* spike down/up within SHORT_LAG quarters and with the sum of sizes within
* NARROW_TOL x the average absolute sizes of the spikes

local NARROW_TOL 0.05
local SHORT_LAG 4

* A spike is identified by a up/down spike followed immediately on the dataset
* with all moves of IGNORE_THRESH or smaller removed by a down/up spike that's
* sufficiently close. The notion of closeness is the same as for the smoothing.

local IGNORE_THRESH 0.02

* Threshold for an amortized negative contribution shock before it is flagged
* as suspicious, and threshold for negative distribution threshold

local neg_contribution_thresh 0.05
local neg_distribution_thresh 0.05

*Raw data after filters have been applied
use $derived/data_after_basic_filters.dta, clear

*Define dimensions of the panel
egen id_pair=group(fund_id investorid source_id)
tsset id_pair yq
sort id_pair yq

*Define calendar time variables
gen finalclosedate_fmt = date(finalclosedate, "YMD")
drop finalclosedate
rename finalclosedate_fmt finalclosedate
format finalclosedate %td

gen finalclosedateyq = qofd(finalclosedate)
gen qtrs_from_start = yq - finalclosedateyq
gen capped_age = qtrs_from_start / 4
replace capped_age = 1 if qtrs_from_start <= 4

bys id_pair (yq): gen qtrs_since_last = yq[_n] - yq[_n - 1]

* Create variables with shorter names to streamline
gen double commit = lp_commitment
gen double contrib = lp_contribution
gen double distrib = lp_distribution
gen double mkt_value = fund_mkt_value

* Store all of the initial variables
foreach var of varlist _all {
    disp "`var'"
	local start_vars `start_vars' `var'
}

*Load programs
do $code/helper_programs.do

* ------------------------------------------------------------------------------
* Normalize and compute changes in commitment and cashflow variables
* ------------------------------------------------------------------------------

*Within each cell, compute modal commitment for normalization
egen modal_commit = mode(commit), by(id_pair) maxmode

*Normalize commitment and cashflow vairables by commitment, and ammortize
local CASH_FLOWS commit contrib distrib mkt_value

foreach var of varlist `CASH_FLOWS' {
    bys id_pair (yq): gen norm_`var' = `var' / modal_commit
    bys id_pair (yq): gen delta_`var'=norm_`var'-norm_`var'[_n-1]
}

*Store data for later use
tempfile common
save `common', replace

use `common', clear

* ------------------------------------------------------------------------------
* Identify and size shocks of any kind
* ------------------------------------------------------------------------------

* Define lists of normalized cash flows and changes
local NORM_CASH
local CHANGE_CASH

foreach var of varlist `CASH_FLOWS'{
    local NORM_CASH `NORM_CASH' norm_`var'
    local CHANGE_CASH `CHANGE_CASH' delta_`var'
}

* Define shock identifiers and magnitudes
foreach var of varlist `CASH_FLOWS'{
    gen pos_delta_`var' = (delta_`var' > 0)
    gen neg_delta_`var' = (delta_`var' < 0)

    replace pos_delta_`var' = . if missing(delta_`var')
    replace neg_delta_`var' = . if missing(delta_`var')

    gen shock_`var' = ((pos_delta_`var' == 1) | (neg_delta_`var' == 1))
    replace shock_`var' = . if missing(pos_delta_`var') | missing(neg_delta_`var')

    gen abs_delta_`var' = abs(delta_`var')
}

* ------------------------------------------------------------------------------
* Tabulate distribution of number of commitment changes across cells
* ------------------------------------------------------------------------------

*Tabulate and output
freqbypair pos_delta_commit neg_delta_commit shock_commit

#delimit ;
esttab using $tables/table_commitment_shocks.tex,
	cells("pos_delta_commit(label(Positive Shocks) fmt(%15.0fc))
		   neg_delta_commit(label(Negative Shocks) fmt(%15.0fc))
		   shock_commit(label(Total Shocks) fmt(%15.0fc))")
	stats(N, fmt(%15.0fc) labels("\$N\$"))
	nonumbers nomtitles booktabs replace;
#delimit cr

* ------------------------------------------------------------------------------
* Tag and tabulate large negative shocks to contributions/distributions
* ------------------------------------------------------------------------------

* ---- Contributions ---- *
*Amortize contribution changes. For funds < 1, assume age is 4Q
bys id_pair (yq): gen ann_delta_contrib = delta_contrib / capped_age

*Define age buckets
egen fund_age_cat = cut(qtrs_from_start), at(-1000, 8, 16, 24, 32, 40, 1000)
label define age -1000 "< 2 Years" 8 "2 - 4 Years" 16 "4 - 6 Years" ///
	24 "6 - 8 Years" 32 "8 - 10 Years" 40 "10+ Years"
label values fund_age_cat age

*Define stats and format for tables
local shock_dist_stats p1 p10 p25 p50 p75 p90 p95 count
local shock_dist_fmt p1(fmt(2)) p10 p25 p50 p75 p90 p95 count(fmt(%15.0fc))

*Tabulate ammortized negative contributions
eststo clear
eststo: estpost tabstat ann_delta_contrib if delta_contrib < 0, ///
	by(fund_age_cat) stats(`shock_dist_stats') columns(stats) listwise nototal

esttab using $tables/table_neg_contrib_size_amort.tex, ///
	cells("`shock_dist_fmt'") nostar unstack noobs nomtitle nonumber ///
	label replace booktabs

*Tag large negative contribution shocks	(< -5% per annum)
gen is_obs_contrib_lrg_neg = ann_delta_contrib < -`neg_contribution_thresh'
egen is_cell_contrib_lrg_neg = max(is_obs_contrib_lrg_neg), by(id_pair)

* ---- Distributions ---- *
*Amortize distribution changes. For funds < 1, assume age is 4Q
bys id_pair (yq): gen ann_delta_distrib = delta_distrib / capped_age

*Tabulate negative distributions
eststo clear
eststo: estpost tabstat ann_delta_distrib if delta_distrib < 0, ///
	by(fund_age_cat) stats(`shock_dist_stats') columns(stats) listwise nototal
esttab using $tables/table_neg_distrib_size_amort.tex, ///
	cells("`shock_dist_fmt'") nostar unstack noobs nomtitle nonumber ///
	label replace booktabs

*Tag large negative distribution shocks 
gen is_obs_distrib_lrg_neg = ann_delta_distrib < -`neg_distribution_thresh'
egen is_cell_distrib_lrg_neg = max(is_obs_distrib_lrg_neg), by(id_pair)

* ------------------------------------------------------------------------------
* Identify temporary shocks in contributions and distributions
* ------------------------------------------------------------------------------

* ---- Contributions ---- *

*Define normalized contribution spikes
*Function also creates smoothed versions of the contribution variables
easyspikesmooth contrib `IGNORE_THRESH' `NARROW_TOL' `SHORT_LAG'

*Make identifiers
gen is_obs_contrib_temp = (any_spike_contrib == 1)
egen is_cell_contrib_temp = max(is_obs_contrib_temp), by(id_pair)

* ---- Distributions ---- *

*Define normalized distribution spikes
*Function also creates smoothed versions of the contribution variables
easyspikesmooth distrib `IGNORE_THRESH' `NARROW_TOL' `SHORT_LAG'

*Make identifiers
gen is_obs_distrib_temp = (any_spike_distrib == 1)
egen is_cell_distrib_temp = max(is_obs_contrib_temp), by(id_pair)

* ------------------------------------------------------------------------------
* Tabulate incidence of second-pass filters
* ------------------------------------------------------------------------------

*Create observation and cell-level dummies for any filter impact
gen is_obs_basic =  is_obs_contrib_lrg_neg | is_obs_distrib_lrg_neg
gen is_cell_basic = is_cell_contrib_lrg_neg | is_cell_distrib_lrg_neg

gen is_obs_all = is_obs_basic | is_obs_contrib_temp | is_obs_distrib_temp
gen is_cell_all = is_cell_basic | is_cell_contrib_temp | is_cell_distrib_temp

*Label variables.
label variable is_obs_contrib_lrg_neg "Large negative contribution"
label variable is_cell_contrib_lrg_neg "Cell has large negative contribution"

label variable is_obs_contrib_temp "Temporary contribution shock"
label variable is_cell_contrib_temp "Cell has a temporary contribution shock"

label variable is_obs_distrib_lrg_neg "Large negative distribution"
label variable is_cell_distrib_lrg_neg "Cell has large negative distribution"

label variable is_obs_distrib_temp "Temporary distribution shock"
label variable is_cell_distrib_temp "Cell has a temporary distribution shock"

label variable is_obs_basic "\hdashline Large negative shock"
label variable is_cell_basic "Cell has a large negative shock tag"

label variable is_obs_all "Any quality control tag"
label variable is_cell_all "Cell has a quality control tag"


*Get total N, number of cells, and total commitment (use modal)
egen pair_source_tag = tag(id_pair)
qui sum pair_source_tag
local total_cells = r(sum)
local N = r(N)

gen commit_summer = pair_source_tag * modal_commit
qui sum commit_summer
local total_commit = r(sum)

* ----  Build table ---- *
local i 1
foreach v of varlist is_obs_contrib_lrg_neg is_obs_distrib_lrg_neg ///
	is_obs_contrib_temp is_obs_distrib_temp is_obs_basic is_obs_all {


	*Recreate impacted cell tag for looping purposes (delete later)
	capture drop cell_tag
	egen cell_tag = max(`v'), by(id_pair)

	*Fraction of observations impacted
	qui sum `v'
	local frac_obs = r(mean) * 100

	*Fraction of cells impacted
	capture drop cell_summer
	gen cell_summer = pair_source_tag * cell_tag
	qui sum cell_summer
	local frac_cells = 100 * r(sum) / `total_cells'

	*Fraction of obs dropped if we drop affected cells
	qui sum cell_tag
	local frac_obs_drop_cell = 100 * r(mean)

	*Fraction of commitment dropped if we drop affected cells
	capture drop commit_summer
	gen commit_summer = pair_source_tag * cell_tag * modal_commit
	qui sum commit_summer
	local frac_comm_drop_cell = 100 * r(sum) / `total_commit'

	*Load into matrix
	#delimit ;
	matrix mat_`v' = `frac_obs' \ `frac_cells' \
					 `frac_obs_drop_cell' \ `frac_comm_drop_cell';
	#delimit cr

	*Save labels
	local label : var label `v'
	if `i' == 1 {
		matrix sumtable = mat_`v'
		local varlist "`label'"
	}
	else {
		matrix sumtable = sumtable, mat_`v'
		local varlist "`varlist'" "`label'"
	}

	local i = `i' + 1


}

*Add total size and number of Investors
matrix cells = `total_cells' \ .x \ .x \ .x
matrix N = `N' \ .x \ .x \ .x

*Construct matrix, define column names, and output
matrix sumtable = sumtable, cells, N
matrix sumtable = sumtable'

matrix rownames sumtable = "`varlist'" "\hline Source-Investor-Funds" "Total Observations"
matrix colnames sumtable = "Observations" "Cells" "Observations" "Commitments"

#delimit ;
esttab matrix(sumtable, fmt("2 2 2 2 2 2 %12.0gc  %12.0gc")) ///
	using "${tables}/incidence_rates.tex", replace ///
	booktabs nomtitles nonumber nodep nonotes ///
	prehead(\begin{tabular}{l*{4}{c}}  \toprule
	&\multicolumn{2}{c}{Incidence (\%)} &
	\multicolumn{2}{c}{Impact of Dropping Cells (\%)}
	\\ \cmidrule(l){2-3} \cmidrule(l){4-5}) ///
	substitute(\_ _ .x "" ^ .);
#delimit cr


* ------------------------------------------------------------------------------
* Tabulate incidence of second-pass filters, conditional on multi-LP funds
* ------------------------------------------------------------------------------

*Tag cells that have multiple LPs
egen num_lps = nvals(investorid), by(fund_id)
gen multi_lp = num_lps > 1

preserve
keep if multi_lp

qui sum pair_source_tag
local total_cells = r(sum)
local N = r(N)

capture drop commit_summer
gen commit_summer = pair_source_tag * modal_commit
qui sum commit_summer
local total_commit = r(sum)

* ----  Build table ---- *
local i 1
foreach v of varlist is_obs_contrib_lrg_neg is_obs_distrib_lrg_neg ///
	is_obs_contrib_temp is_obs_distrib_temp is_obs_basic is_obs_all {


	*Recreate impacted cell tag for looping purposes (delete later)
	capture drop cell_tag
	egen cell_tag = max(`v'), by(id_pair)

	*Fraction of observations impacted
	qui sum `v'
	local frac_obs = r(mean) * 100

	*Fraction of cells impacted
	capture drop cell_summer
	gen cell_summer = pair_source_tag * cell_tag
	qui sum cell_summer
	local frac_cells = 100 * r(sum) / `total_cells'

	*Fraction of obs dropped if we drop affected cells
	qui sum cell_tag
	local frac_obs_drop_cell = 100 * r(mean)

	*Fraction of commitment dropped if we drop affected cells
	capture drop commit_summer
	gen commit_summer = pair_source_tag * cell_tag * modal_commit
	qui sum commit_summer
	local frac_comm_drop_cell = 100 * r(sum) / `total_commit'

	*Load into matrix
	#delimit ;
	matrix mat_`v' = `frac_obs' \ `frac_cells' \
					 `frac_obs_drop_cell' \ `frac_comm_drop_cell';
	#delimit cr

	*Save labels
	local label : var label `v'
	if `i' == 1 {
		matrix sumtable = mat_`v'
		local varlist "`label'"
	}
	else {
		matrix sumtable = sumtable, mat_`v'
		local varlist "`varlist'" "`label'"
	}

	local i = `i' + 1


}

*Add total size and number of Investors
matrix cells = `total_cells' \ .x \ .x \ .x
matrix N = `N' \ .x \ .x \ .x

*Construct matrix, define column names, and output
matrix sumtable = sumtable, cells, N
matrix sumtable = sumtable'

matrix rownames sumtable = "`varlist'" "\hline Source-Investor-Funds" "Total Observations"
matrix colnames sumtable = "Observations" "Cells" "Observations" "Commitments"

#delimit ;
esttab matrix(sumtable, fmt("2 2 2 2 2 2 %12.0gc  %12.0gc")) ///
	using "${tables}/incidence_rates_multi_lp.tex", replace ///
	booktabs nomtitles nonumber nodep nonotes ///
	prehead(\begin{tabular}{l*{4}{c}}  \toprule
	&\multicolumn{2}{c}{Incidence (\%)} &
	\multicolumn{2}{c}{Impact of Dropping Cells (\%)}
	\\ \cmidrule(l){2-3} \cmidrule(l){4-5}) ///
	substitute(\_ _ .x "" ^ .);
#delimit cr

restore


* ------------------------------------------------------------------------------
* Smooth out temporary shocks to contributions and distributions
* ------------------------------------------------------------------------------

* Smoothing was already done above in the detection stage

*Plot an example of the procedure for the paper
gen temp_spike = norm_contrib * any_spike_contrib
label variable any_spike_contrib "Spike"
label variable norm_contrib "Original"
label variable norm_contrib_smooth "Smoothed"
label variable temp_spike "Spike"

tw (line norm_contrib qtrs_from_start) ///
	(line norm_contrib_smooth qtrs_from_start, lpattern("-.") lwidth(0.5))  ///
	(scatter temp_spike qtrs_from_start if any_spike_contrib == 1, ///
		msize(3) mcolor(blue%50)) if investorid == 2542 & fund_id == 225, ///
	xtitle("Age (Quarters)") ytitle("Contributions, Normalized by Commitments") ///
	xsize(6) ysize(4) legend(rows(1)) ///
	graphregion(color(white)) bgcolor(white)
graph export $figures/example_smooth.pdf, replace
drop temp_spike


* ------------------------------------------------------------------------------
* Adjust negative distributions by adding as contribution (recycling provision)
* ------------------------------------------------------------------------------

*Create adjusted variables
foreach var of varlist contrib distrib{
    gen `var'_smooth_adj = `var'_smooth
    gen norm_`var'_smooth_adj = norm_`var'_smooth
    gen delta_`var'_smooth_adj = delta_`var'_smooth
}

*Add back negative distributions to contribution
replace delta_contrib_smooth_adj = delta_contrib_smooth_adj - delta_distrib_smooth_adj ///
	if delta_distrib_smooth_adj < 0
replace delta_distrib_smooth_adj = 0 if delta_distrib_smooth_adj < 0

*Recreate levels
levelfromchange contrib_smooth_adj
levelfromchange distrib_smooth_adj

* ------------------------------------------------------------------------------
* Cleanup and output
* ------------------------------------------------------------------------------

*Collect variables
local adjvars

foreach var of varlist  contrib distrib {
    local adjvars `adjvars' `var'_smooth_adj
}

*Check to make sure original variables were not altered
gen alter_test = abs(lp_contribution - contrib) < 1
sum alter_test

*Retain only original variables, smoothed/adjusted CFs, and tags
keep `start_vars' `adjvars' is_*
drop commit contrib distrib mkt_value 	  // Unnecessary copies of original vars

*Relabel variables
label variable is_obs_basic "Any large negative shock"

*Save a dataset that retains all the tags and sources
save $derived/preqin_data_all_tags.dta, replace
