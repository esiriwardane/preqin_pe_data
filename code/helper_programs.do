/* Helper programs to detect, smooth, and report on cashflow variables with
temporary shocks */

* ------------------------------------------------------------------------------
* Assemble levels from changes
* ------------------------------------------------------------------------------

capture program drop levelfromchange
program define levelfromchange

args var

/*
Reconstructs the level measure by adding up the changes normalized by modal_commit
:param var: -- the variable suffix of the change and level variables that
               are being Smoothed

This code assumes that delta_`var' is the change variable that you're aggregating
It will then replace norm_`var' and `var' with the cumulated changes

Example:

levelfrom change contrib

Aggregates delta_contrib into a norm_contrib variable, which is then multiplied
by modal_commit to get to a new contrib variable
*/

di "Reconstructing level variables from cleaned changes"

capture drop clean_delta_`var'

gen clean_delta_`var' = delta_`var'
replace clean_delta_`var' = norm_`var' if missing(delta_`var')
bys id_pair (yq): replace norm_`var' = sum(clean_delta_`var')
bys id_pair (yq): replace `var' = modal_commit * norm_`var'

drop clean_delta_`var'

end

* ------------------------------------------------------------------------------
* Aggregate observation-level dummies up to summaries of higher-level cells
* ------------------------------------------------------------------------------

capture program drop summbypair
program define summbypair

syntax varlist

eststo clear

// di "Share of Obs"
qui eststo: estpost tabstat `varlist', stats(mean) columns(statistics) listwise

// di "Share of Pairs"
preserve
collapse (max) `varlist', by(id_pair)
qui eststo: estpost tabstat `varlist', stats(mean) columns(statistics) listwise
restore

// di "Share of Obs in Affected Pairs"
preserve
collapse (max) `varlist' (count) yq, by(id_pair)
egen total_obs = total(yq)
foreach var of varlist `varlist'{
    replace `var' = `var' * yq / total_obs * _N
}
qui eststo: estpost tabstat `varlist', stats(mean) columns(statistics) listwise
restore

esttab, cell("mean") mlabels("Obs" "Pairs" "Obs in Pairs") varwidth(32)

end

* ------------------------------------------------------------------------------
* Tabulate distributions of occurrences of dummy variables across cells
* ------------------------------------------------------------------------------

capture program drop freqbypair
program define freqbypair

syntax varlist

eststo clear

preserve
collapse (sum) `varlist', by(id_pair)
qui eststo: estpost tabstat `varlist', stats(p1 p5 p10 p25 p50 p75 p90 p95 p99) columns(variables)
restore

esttab, cell("`varlist'")

end


* ------------------------------------------------------------------------------
* Define temporary spikes
* ------------------------------------------------------------------------------

capture program drop easyspikedetect
program define easyspikedetect

args var min_move_size tol num_lags

/*

Detects spikes as whenever there's a large move up/down and then the next large
move is approximately the same size but opposite signs and not too many
quarters away

:param var: -- the variable you're trying to detect spikes for, one of
               contrib or distrib
:param min_move_size: -- minimum threshold for absolute size of a shock to be
                         considered "large"
:param tol: -- approximation error for the shock. The sum of the up and down
               moves must be less than `tol' times the average absolute values
               of the up and down moves
num_lags -- the maximum lag length for the shock, in quarters

Example:

easyspikedetect contrib 0.02 0.10 8

Drops all moves less than 2% in absolute value, and requires temporary spikes
to have a move up (down) followed immediately by a move down (up) in this
restricted dataset.

To be identified as a spike, the sum of the moves would also have to be within
10% of the average absolute value of the two spikes and within 8 quarters of
each other.
*/

tempfile startprog
save `startprog'

capture drop easy_spike_*
capture drop easy_*_spike
capture drop easy_`var'_spike_lag
capture drop easy_`var'_ratio
capture drop easy_`var'_sum
capture drop easy_in_`var'_data
capture drop easy_temp_`var'_spike
capture drop easy_*_time
capture drop _merge

// Drop to only large moves. Keep a dummy variable for merging back in to
// mark which moves were analyzed to identify spikes
drop if abs(delta_`var') < `min_move_size'
gen easy_in_`var'_data = 1

// Store whether an observation is associated with a spike (not necessarily temporary)
bys id_pair (yq): gen easy_pos_spike = (pos_delta_`var' == 1) & (neg_delta_`var'[_n + 1] == 1)
bys id_pair (yq): gen easy_neg_spike = (neg_delta_`var' == 1) & (pos_delta_`var'[_n + 1] == 1)
gen easy_`var'_spike = easy_pos_spike | easy_neg_spike

gen easy_`var'_sum = .
gen easy_spike_abs = .
gen easy_`var'_time = .
gen easy_`var'_ratio = .

// Track how many lags are between the up and down movements,
// throw out the spikes that span too long of a period
bys id_pair (yq): replace easy_`var'_time = yq[_n + 1] - yq[_n] if easy_`var'_spike
replace easy_`var'_spike = 0 if easy_`var'_time > `num_lags'
replace easy_`var'_time = . if easy_`var'_time > `num_lags'

// Check how close the two moves add up to zero
bys id_pair (yq): replace easy_`var'_sum = (delta_`var'[_n] + delta_`var'[_n + 1]) if easy_`var'_spike
bys id_pair (yq): replace easy_spike_abs = abs(delta_`var') if easy_`var'_spike
bys id_pair (yq): replace easy_`var'_ratio = abs(easy_`var'_sum) / (abs(delta_`var') + abs(delta_`var'[_n + 1])) * 2 if easy_`var'_spike
gen easy_temp_`var'_spike = easy_`var'_spike & easy_`var'_ratio < `tol'

// Keep track of which obs follow a temporary spike. Important for smoothing
bys id_pair (yq): gen easy_`var'_spike_lag = (easy_temp_`var'_spike[_n - 1] == 1)

// Pick spike measures to keep
keep id_pair yq easy_in_`var'_data easy_`var'_ratio easy_`var'_sum easy_temp_`var'_spike easy_`var'_spike_lag
tempfile easyspikes
save `easyspikes', replace

// Merge the spikes back
use `startprog', clear
capture drop _merge
merge 1:1 id_pair yq using `easyspikes'

end

* ------------------------------------------------------------------------------
* Define temporary spikes
* ------------------------------------------------------------------------------

capture program drop easyspikesmooth
program define easyspikesmooth

args var min_move_size tol num_lags

/*
Detects and smooths the spikes, where spikes are defined by easyspikedetect

Potentially you could make multiple passes, grouping together different Observations
as temporary shocks each time, In this version we only make one pass through as
we find subsequent passes through the data do not yield more temporary shocks

For definitions of parameters, see easyspikedetect
*/

capture drop any_spike_`var' any_lag_`var' any_spike_error_`var' any_in_`var'_data
capture drop norm_`var'_smooth delta_`var'_smooth `var'_smooth
capture drop temp_*`var'

// Temporarily store the old unsmoothed variables
gen double temp_norm_`var' = norm_`var'
gen double temp_delta_`var' = delta_`var'
gen double temp_`var' = `var'

// Code can be adapted to make multiple passes through the variable, recursively
// matching up spikes that add up to zero. Omitting that for now.
forvalues pass = 1/1 {
  di "Starting pass `pass'"

  qui easyspikedetect `var' `min_move_size' `tol' `num_lags'

  // Replace only the first spike. Need to identify the first obs that is
  // the front move of the spike (the first up or down) as well as the first
  // observation that's the down move (the subsequent down or up)

  bys id_pair (yq): gen cum_spike_`var' = sum(easy_temp_`var'_spike)
  bys id_pair (yq): gen cum_lag_`var' = sum(easy_`var'_spike_lag)
  by id_pair (yq): gen first_spike_`var' = (cum_spike_`var' == 1) & (cum_spike_`var'[_n - 1] == 0)
  by id_pair (yq): gen second_spike_`var' = (cum_lag_`var' == 1) & (cum_lag_`var'[_n - 1] == 0)

  // If part of a spike, need to set first move to the sum and then the second
  // move to zero.
  replace delta_`var' = easy_`var'_sum if first_spike_`var' == 1
  replace delta_`var' = 0 if second_spike_`var' == 1

  // Smooth the variables with the new changes
  levelfromchange `var'

  di "Storing results from pass `pass'"
  if `pass' == 1{
    // Save the results from the first pass
    gen any_spike_`var' = easy_temp_`var'_spike
    gen any_in_`var'_data = easy_in_`var'_data
    gen any_spike_error_`var' = easy_`var'_ratio
  }
  else{
    // Every time you run easyspikedetect it overwrites the variables, store
    // the results over many passes here.
    su easy_temp_`var'_spike
    replace any_spike_`var' = 1 if easy_temp_`var'_spike == 1
    replace any_spike_error_`var' = easy_`var'_ratio if easy_temp_`var'_spike == 1
  }

  drop cum_spike_`var' cum_lag_`var' first_spike_`var' second_spike_`var'

}

// Rename variables to get new smoothed versions in addition to old variables
rename norm_`var' norm_`var'_smooth
rename delta_`var' delta_`var'_smooth
rename `var' `var'_smooth

rename temp_norm_`var' norm_`var'
rename temp_delta_`var' delta_`var'
rename temp_`var' `var'

end
