/*
Create final dataset according to Section 5:
	1. Basic filters in apply_basic_filters.do
	2. Source-fund-investor cells with any large negative CF shock
	3. 13 LPs for whom 2.7% of observations have any potential quality issues
	4. There is only 1 LP who has multiple sources per fund-quarter. This LP 
	   has a source whose name contains "Source ID for CF Data only", so we 
	   drop this source. All other fund-investor-quarters are unique
	5. There is another three further investors who have multiple sources per
	   fund_id-investor cell. We take the source with the most observations and
	   break ties with the source who has the latest data
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

*Within an fund-investor, keep source with most obs. Breaking ties w/ latest
egen source_count = count(yq), by(fund_id investorid source_id)
egen max_source = max(source_count), by(fund_id investorid)

egen last_source_date = max(yq), by(fund_id investorid source_id)
egen max_source_date = max(yq), by(fund_id investorid)

gen source_to_keep =  source_count == max_source ///
	& last_source_date == max_source_date
tab source_to_keep
keep if source_to_keep

*Check to make sure there are not multiple sources per fund-investor
egen unique_source = nvals(source_id), by(fund_id investorid) 
tab unique_source
drop unique_source source_count max_source last_source_date max_source_date ///
	source_to_keep

*Save
sort fund_id investorid yq
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
