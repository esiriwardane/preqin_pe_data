/*
Create final dataset according to Section 5:
	1. Basic filters in apply_basic_filters.do
	2. Source-fund-investor cells with any large negative CF shock
	3. 13 LPs for whom 2.7% of observations have any potential quality issues
	4. There is only 1 LP who has multiple sources per fund-quarter. This LP 
	   has a source whose name contains "Source ID for CF Data only", so we 
	   drop this source. All other fund-investor-quarters are unique.				 
*/


* Esttab options
local fragopt noobs nonumber label nonote replace booktabs nomtitles ///
	nonumbers

* ------------------------------------------------------------------------------
* Load data and make drops
* ------------------------------------------------------------------------------

*Load data (#1 already completed)
use $derived/preqin_data_all_tags.dta, clear

*Merge in LPs from Step #3. _merge == 3 indicates LPs to drop
merge m:1 investorid using $derived/lps_to_drop.dta

*Print stats on prevalance of each drop-category
sum _merge if is_cell_basic
sum _merge if source_id == 1354
sum _merge if _merge == 3

*Drop 
drop if is_cell_basic == 1 | source_id == 1354 | _merge == 3
drop _merge

*Save
save $derived/preqin_data_clean.dta, replace


* ------------------------------------------------------------------------------
* Tabulate final data
* ------------------------------------------------------------------------------

*Observation counts
gen no_obs = 1

*Tags are useful for flagging which obs to count
gsort fundmanagerid fund_id investorid year -qtr

egen investor_tag = tag(investorid)
egen fund_tag = tag(fund_id)
egen gp_tag = tag(fundmanagerid)
egen pair_tag = tag(investorid fund_id)

*Labels for table
label variable no_obs "Number of Observations"
label variable investor_tag "Number of LPs"
label variable fund_tag "Number of Funds"
label variable gp_tag "Number of General Partners"
label variable pair_tag "Number of LP-Fund Cells"

*Tabulate 
eststo clear

eststo: estpost tabstat no_obs pair_tag fund_tag gp_tag investor_tag, ///
	stats(sum) columns(stats)

esttab using $tables/final_dataset_sumstat.tex, ///	
	cells("sum(fmt(%15.0fc))") nolines collabels(none) `fragopt'
eststo clear
