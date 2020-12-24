/*
Compare characteristics in data screened for quality control versus data
that passes all quality control
*/


* ------------------------------------------------------------------------------
* Setup + Data
* ------------------------------------------------------------------------------

*Load data with flags
use $derived/preqin_data_all_tags.dta, clear

*Compute TPI and DPI
gen tpi = (lp_distribution + fund_mkt_value) / lp_contribution
gen dpi = lp_distribution / lp_contribution

*Set age floor at zero
gen qtr_floor = qtrs_from_start
replace qtr_floor = 0 if qtrs_from_start < 0

*Compute vintage year buckets
gen vintage_bucket = "1990s" if fund_vintage < 2000
replace vintage_bucket = "2000s" if fund_vintage >= 2000 & fund_vintage < 2010
replace vintage_bucket = "2010s" if fund_vintage >= 2010 & fund_vintage < 2020

*Classify fund numbers
gen fund_number = "1-2" if fundnumberoverall <= 2
replace fund_number = "3-4" if inlist(fundnumberoverall, 3, 4)
replace fund_number = "5-6" if inlist(fundnumberoverall, 5, 6)
replace fund_number = "7-8" if inlist(fundnumberoverall, 7, 8)
replace fund_number = ">9" if fundnumberoverall >= 9

*Plot parameters
local bgplot graphregion(color(white)) bgcolor(white)
local barlabel blabel(bar, position(inside) format(%9.2f) color(white) size(medium))

tempfile main
save `main'

* ------------------------------------------------------------------------------
* Compute high-return funds, relative to vintage year
* ------------------------------------------------------------------------------

use `main', clear

*Drop young funds
drop if qtrs_from_start < 20 | fund_vintage > 2014

*For each vintage, compute year with most observed funds, break ties with age
egen funds_per_yv = nvals(fund_id), by(fund_vintage year)
egen max_funds = max(funds_per_yv), by(fund_vintage)
keep if funds_per_yv == max_funds

egen max_year_vint = max(year), by(fund_vintage)
keep if year == max_year_vint

*Compute within-fund dispersion 
gegen dispersion = range(dpi), by(fund_id yq)
egen num_investors = nvals(investorid), by(fund_id yq)
replace dispersion = . if num_investors < 2 			// Only Multi-LP funds
gen nonmiss_disp = 1 if ~mi(dispersion)
replace nonmiss_disp = 0 if mi(dispersion)

*Within each vintage-year, take the average of fund return
collapse (mean) fund_vintage dpi  ///
	     (sum) nonmiss_disp dispersion, by(fund_id)

*Compute average dispersion, when possible
replace dispersion = dispersion / nonmiss_disp

*Check to make sure there are sufficient funds to do quartile rankings
egen num_funds = nvals(fund_id), by(fund_vintage)
egen num_disp = total(~mi(dispersion)), by(fund_vintage)

*Within each vintage, compute quartile rankings of returns if sufficient data
gegen ret_bin = xtile(dpi), by(fund_vintage) nq(4)
replace ret_bin = . if num_funds < 20

*Within each vintage, compute above/below median dispersion if sufficient data
gegen disp_cut = xtile(dispersion), by(fund_vintage) nq(2)
replace disp_cut = . if num_disp < 20
gen disp_bin = "High" if disp_cut == 2
replace disp_bin = "Low" if disp_cut == 1

*Save
keep fund_id ret_bin disp_bin
tempfile rankings
save `rankings'


* ------------------------------------------------------------------------------
* Compute other fund-level characteristics, then merge back with original data
* ------------------------------------------------------------------------------

use `main', clear

*Size deciles for fund
bysort fund_id (finalclosesizeusdmn): keep if _n == _N
xtile size_bin = finalclosesizeusdmn, nq(5)
tempfile size
save `size'

*Merges
use `main', clear
merge m:1 fund_id using `rankings', keep(1 3) nogen
merge m:1 fund_id using `size', keep(1 3) nogen


* ------------------------------------------------------------------------------
* Plot incidence rates for subgroups
* ------------------------------------------------------------------------------

*Variable labels
label variable vintage_bucket "Vintage Year"
label variable fund_number "Fund Number"
label variable size_bin "Size Quintile"
label variable ret_bin "Return Quartile (by Vintage)"
label variable disp_bin "Dispersion Quartile (by Vintage)"

*Generic plot parameters
local yparam_basic ylabel(,labsize(medlarge)) ///
	ytitle("Incidence Rate of Large Negative Shocks (%)", size(medlarge))
local yparam_all ylabel(,labsize(medlarge)) ///
	ytitle("Incidence Rate of Any Quality Tag (%)", size(medlarge))	
	
*Make percentage incidence variable
gen prc_is_obs_basic = 100 * is_obs_basic
gen prc_is_obs_all = 100 * is_obs_all

*List variables to cycle through
local subgroups vintage_bucket fund_number size_bin ret_bin disp_bin

*Make plots
foreach var of local subgroups {
	
	*Get x-title lables
	local lab: variable label `var'
	
	*Now do the plots for basic and any QC tags
	foreach x in basic all {
	if "`x'" == "basic" {
		local pparm `yparam_basic'  `bgplot' `barlabel'
	}
	else if "`x'" == "all"{
		local pparm `yparam_all'  `bgplot' `barlabel'
	}
	
	graph bar prc_is_obs_`x', over(`var', label(labsize(medlarge))) ///
		b1title(`lab', size(medlarge)) ///
		`pparm'  
	graph export $figures/`x'_incidence_`var'.pdf, replace	
	}
}


* ------------------------------------------------------------------------------
* Plot incidence rates for different LPs
* ------------------------------------------------------------------------------

*Get commitments by investor
use `main', clear
collapse (max) lp_commitment, by(investorid fund_id)
collapse (sum) lp_commitment, by(investorid)
tempfile lp_commit
save `lp_commit'


*Get incidence rates
use `main', clear

collapse (mean) is_obs_basic is_obs_all (count) lp_count = is_obs_all, ///
	by(investorid)
	
merge 1:1 investorid using `lp_commit'
	
*Get commitment shares shares
egen pct_data = pc(lp_count)
egen pct_commit = pc(lp_commitment)

*Plot LP-CDFs and fraction of data dropped if LPs above threshold are discarded
foreach x in basic all {
	capture drop cumprc
	
	if "`x'" == "basic" {
		local xtitle "Incidence Rate of Large Negative Shocks"
		local obsxtitle "Threshold for Incidence of Negative Shocks"
		gsort -is_obs_`x'
	}
	else if "`x'" == "all" {
		local xtitle "Incidence Rate of Any Quality Tag"
		local obsxtitle "Threshold for Incidence of Any Quality Tag"
		gsort -is_obs_`x'	
	}
	
	*Plot CDF of incidence rates
	cdfplot is_obs_`x', xtitle(`xtitle') `bgplot'
	graph export $figures/lp_cdf_incidence_`x'.pdf, replace	
	
	*Cumulative percent of data lost above threshold
	gen cumprc = sum(pct_commit)
	line cumprc is_obs_`x', xtitle(`obsxtitle') ///
		ytitle("% of Total Commitments: LPs above Threshold") `bgplot'
	graph export $figures/lp_impact_incidence_`x'.pdf, replace	
		
	*Zoom in on large shares
	line cumprc is_obs_`x' if is_obs_`x' > 0.02 , xtitle(`obsxtitle') ///
		ytitle("% of Total Commitments: LPs above Threshold") `bgplot'	
	graph export $figures/zoom_lp_impact_incidence_`x'.pdf, replace
}

*Save LPs for whome > 2.7% of observations have any quality control issue
keep if is_obs_all > 0.027
keep investorid
save $derived/lps_to_drop.dta, replace

