/*
Read in raw data, apply basic filters, and summarize
*/


* ------------------------------------------------------------------------------
* Setup
* ------------------------------------------------------------------------------

clear all 
set more off


* Esttab options
local fragopt noobs nonumber label nonote replace booktabs nomtitles ///
	nonumbers


* ------------------------------------------------------------------------------
* Import data
* ------------------------------------------------------------------------------

*Raw data
import delimited using "$raw_data/HBS - Private Capital - Final.csv", clear

*Drop true duplicates
gduplicates drop

*Keep track of original variables
foreach var of varlist _all {
    local start_vars `start_vars' `var'
}

*Date variables
gen date_stata = date(date_reported, "YMD")
drop date_reported
rename date_stata date_reported
format date_reported %td

gen yq = qofd(date_reported)
gen qtr = quarter(date_reported)
gen year = year(date_reported)
format yq %tq

local timevars date_reported year qtr yq


*Note: Cell = source-fund-investor-quarter

* ------------------------------------------------------------------------------
* Generate flags for basic filters
* ------------------------------------------------------------------------------

*Flag obs with missing identifiers (treat as missing if identifier equals 0)
foreach idvar of varlist investorid fund_id fundmanagerid { 
    gen missing_`idvar' = missing(`idvar') | `idvar' == 0
}

*Flag observations with missing cash flow variables and dates
local CASH_FLOW lp_commitment lp_contribution lp_distribution fund_mkt_value

foreach var of varlist date_reported `CASH_FLOW'{
    gen missing_`var' = mi(`var')
}

*Flag missing vintages or pre-1990
gen vintage_flag = mi(fund_vintage) | fund_vintage < 1990

*Flag funds that do not invest in USD or fund value is not in USD
tab fundcurrency, sort
tab value_currency, sort
gen nonusd_flag = fundcurrency != "USD" | ///
	~inlist(value_currency, "USD", "uSD", "usd")

*Flag foreign LPs and non-pension funds
gen non_us_lp = country != "US" | inlist(investortype, "Foundation", ///
	"Insurance Company", "Private Sector Pension Fund")

*Flag "excess obs" within Source-LP-Fund-Quarter. 
bysort source_id fund_id investorid yq (date_reported): ///
	gen is_excess = 0 if _n == _N
replace is_excess = 1 if mi(is_excess)

*Generate variable for dropping variables (exclude excess obs)
egen any_drop = rowtotal(missing_investorid missing_fund_id ///
	missing_fundmanagerid missing_lp_commitment missing_lp_contribution ///
	missing_lp_distribution missing_fund_mkt_value missing_date_reported ///
	vintage_flag non_us_lp nonusd_flag)
		
* ------------------------------------------------------------------------------
* Get incidence in raw data before dropping
* Note: We do this because we want to make cells unique after dropping missings
* ------------------------------------------------------------------------------

*Tabulate
eststo clear
eststo sumtab: estpost tabstat ///
	missing_investorid missing_fund_id missing_fundmanagerid ///
	missing_lp_commitment missing_lp_contribution missing_lp_distribution ///
	missing_fund_mkt_value missing_date_reported vintage_flag ///
	nonusd_flag non_us_lp is_excess, ///
	stats(sum mean) columns(stats)
	
* ------------------------------------------------------------------------------
* Apply basic filters, then make uninque within source-investor-fund-quarter
* ------------------------------------------------------------------------------	
	
*Drop observations that do not pass basic filters (exclude duplicate cells)
keep if any_drop == 0
	
* Drop duplicate cells using last/largest report date, commitment, contribution, 
* distribution, then market value. Use fund name for remaning (1 instance)
bysort source_id fund_id investorid yq ///
	(date_reported lp_commitment lp_contribution lp_distribution ///
	 fund_mkt_value fund_name): keep if _n == _N 
		
* ------------------------------------------------------------------------------
* Finalize table on basic filters
* ------------------------------------------------------------------------------	

*Count number of remaining observations
qui sum fund_id
local pass_N = r(N)	

*Add observation count to table	
est restore sumtab
estadd scalar pass_N = `pass_N'

*Label variables
label variable missing_investorid "Missing Investor ID"
label variable missing_fund_id "Missing Fund ID"
label variable missing_fundmanagerid "Missing Fund Manager ID"
label variable missing_lp_commitment "Missing Committment Size"
label variable missing_lp_contribution "Missing LP Contribution"
label variable missing_lp_distribution "Missing LP Distribution"
label variable missing_fund_mkt_value "Missing Fund NAV"
label variable missing_date_reported "Missing Date"
label variable vintage_flag "Missing Fund Vintage or Vintage < 1990"
label variable nonusd_flag "Non-USD Denominated"
label variable non_us_lp "Foreign or Non-Pension LP"
label variable is_excess "Excess Observations within Source-LP-Fund-Quarter"

*Write out table			   
esttab using $tables/basic_filters.tex, ///
	cells("sum(fmt(%15.0fc)) mean(fmt(2))")  ///
	collabels("Total" "Fraction") `fragopt' ///
	stats(N pass_N, ///
		labels("Total Observations in Raw Data" ///
			   "Total Observations after Basic Filters"))	

*Retain original variables and time variables, then save	
keep `start_vars' `timevars'
save $derived/data_after_basic_filters.dta, replace			   
			   
* ------------------------------------------------------------------------------
* Additional Summary Statistics
* ------------------------------------------------------------------------------

// Tags are useful for flagging which obs to count
use $derived/data_after_basic_filters.dta, clear

gsort fundmanagerid fund_id investorid year -qtr

egen investor_tag = tag(investorid)
egen fund_tag = tag(fund_id)
egen gp_tag = tag(fundmanagerid)
egen pair_tag = tag(investorid fund_id)
egen pair_source_tag = tag(investorid fund_id source_id)
egen pair_year_tag = tag(investorid fund_id year)
egen investor_gp_tag = tag(investorid fundmanagerid)

list investorid fund_id year qtr pair_year_tag if _n < 20

gen no_missing = 1

label variable investor_tag "Number of LPs"
label variable fund_tag "Number of Funds"
label variable gp_tag "Number of General Partners"
label variable pair_tag "Number of LP-Fund Cells"
label variable no_missing "Number of Observations"
label variable pair_source_tag "Number of Source-LP-Fund Cells"


**** Total number of investors/Funds/GPs
eststo clear

eststo: estpost tabstat no_missing pair_source_tag fund_tag gp_tag investor_tag, stats(sum) columns(stats)

// Note: need noline because first hline in a tabular cannot come from an \input command

esttab using $tables/basic_filters_sumstat.tex, ///	
	cells("sum(fmt(%15.0fc))") nolines collabels(none) `fragopt'
eststo clear
