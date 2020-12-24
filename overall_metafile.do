/*
This .do file runs over all the files required to replicate the results in
Begenau, Robles-Garcia, Siriwardane, and Wang (2020).
Please see the Read Me for details on the structure of the code.
*/


clear all
set linesize 255
macro drop _all

* ----------------------------
* Set globals
* ----------------------------
* globals for reading in data
global raw_data "../raw_data/"

* globals for derived data
global derived "derived_data/"

* globals for output
global figures "figures"
global tables "table"

* globals for code location
global code "code"

* ----------------------------
* Clean directories
* ----------------------------

*Adjust directory commands for operating system
if "`c(os)'" == "MacOSX" {
	local deldir "rm -r"
}
else {
	local deldir "rmdir /q /s"
}

shell `deldir' "$derived"
shell `deldir' "$figures"
shell `deldir' "$tables"

shell mkdir "$derived"
shell mkdir "$figures"
shell mkdir "$tables"

* ----------------------------
* Cleaning and analysis
* ----------------------------

do "${code}/apply_basic_filters.do"
do "${code}/clean_shocks.do"
do "${code}/covariate_balance_tests.do"
do "${code}/create_final_dataset.do"
