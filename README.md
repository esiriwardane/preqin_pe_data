# An Empirical Guide to Investor-Level Private Equity Data from Preqin

This code replicates the results from Begenau, Robles-Garcia, Siriwardane, and Wang (2020). 

The code can be run from the metafile overall_metafile.do. The metafile runs over all of the code in the ``${code}`` directory. The input and output data used in this code cannot be released publicly. However, the globals that are defined in ``overall_metafile.do`` trace the exact datasets used by and produced by the code.  For example, the raw data provided to use from Preqin is stored in ``${raw_data}`` and all intermediate and final datasets are stored in ``${derived_data}``. The resulting figures and tables are stored in the ``${tables}`` and ``${figures}`` directories. The ``${derived}``, ``${tables}``, and ``${figures}`` directories are all created by ``overall_metafile.do``.
