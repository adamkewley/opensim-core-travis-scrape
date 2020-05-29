# This isn't really a standard "build" Makefile, and it requires
# running multiple times because of how dependency resolution works.
#
# I'm just using `make` to pipeline the various `travis` CLI fetch
# steps because I can't be arsed trying to get a language client to
# work.
#
# With this approach, it's easy to parallelize the fetches (make
# -jN). It's also easy to perform incremental fetches (e.g. of logs)
# over time, and it's easy to resume the pipeline if it fails midway
# (e.g. due to rate throttling from travis). All desirable qualities
# in a data pipeline.

TO_SHOW = $(subst ids/,show/,$(wildcard ids/*))
TO_SUBBUILD_CSV = $(subst ids/,subbuild_csvs/,$(wildcard ids/*))
TO_SUBBUILD_LOGS = $(subst subbuild_ids/,subbuild_logs/,$(wildcard subbuild_ids/*))

# unfiltered repo build history: just fetch a log list from travis
history.txt:
	travis history --limit 20000 -r opensim-org/opensim-core > $@

# filter the build history to only contain builds that passed
history_passed.txt: history.txt
	grep -P "^#[^ ]+ passed:" $^ > $@

# get the IDs of the builds that passed alone
passed_ids.txt: history_passed.txt
	grep -oP "^#\d+" history_passed.txt | sed 's/#//' > $@

# intermediate dirs used by build steps
ids/ show/ subbuild_csvs/ subbuild_ids/ subbuild_logs/:
	mkdir -p $@

# for each ID in ids/ (the exploded form of `passed_ids.txt`), show
# the build's details. It's coded this way (separate files) so that
# `make` can parallelize and perform incremental fetches.
show/%: ids/% | show/
	sleep 1  # crude rate-limiter
	travis show -r opensim-org/opensim-core $(subst ids/,,$<)  > $@

# for each "travis show"n build in show/, compile the output into a
# small csv file containing one line per "sub build" (OSX, Linux, gcc,
# clang, etc)
subbuild_csvs/%: show/% | subbuild_csvs/
	./flatten_to_csv <"$<" >"$@"

# aggregate all subbuild csvs in subbuild_csvs/ into a single csv file
# (easier to plot, etc)
subbuild.csv: $(TO_SUBBUILD_CSV)
	cat $^ > $@

# for each subbuild ID, fetch its log
subbuild_logs/%: subbuild_ids/% | subbuild_logs/
	sleep 1  # crude rate-limiter
	travis logs -r opensim-org/opensim-core $(subst subbuild_ids/,,$<) > $@

# for each subbuild log, regex out the test information (test name,
# duration) and aggregate that information into a single CSV file of
# subbuild_id,test_name,duration_secs
subbuild_test_durations.csv: $(TO_SUBBUILD_LOGS)
	./extract_test_info $^ > $@

# finally, perform an SQL-style inner-join between the top-level
# (travis show) and the bottom-level (test timings) information to
# create a single, fully expanded, CSV file that should be easy to
# slurp into memory and analyze with something like R
#
# this is effectively the raw data that feeds the analysis phase
final_test_timings.csv: subbuild.csv subbuild_test_durations.csv
	./final-join subbuild.csv subbuild_test_durations.csv > $@

.PHONY: ids show subbuild_csvs subbuild_ids subbuild_logs analyze

# explode out the passed build IDs into separate files (for
# incremental builds)
ids: passed_ids.txt | ids/
	xargs -I {} touch -a ids/{} <passed_ids.txt

show: $(TO_SHOW)

subbuild_csvs: $(TO_SUBBUILD_CSV)

# explode the subbuild csv into individual subbuild IDs, ready for a
# parallel + resumable log fetch
subbuild_ids: subbuild.csv | subbuild_ids/
	cut -d ',' -f 4 subbuild.csv | xargs -I {} touch -a subbuild_ids/{}

subbuild_logs: $(TO_SUBBUILD_LOGS)

analyze:
	./analysis
	montage linux_*.png -geometry '1x1+0+0<' out_linux.png
	montage osx_*.png -geometry '1x1+0+0<' out_osx.png
