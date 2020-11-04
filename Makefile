# This isn't really a standard "build" Makefile, and it requires
# running multiple times because of how dependency resolution works
# (e.g. the build cannot know some of its targets until it downloads
# the logs from travis)
#
# I'm just using `make` to pipeline the various `travis` CLI fetch
# steps because I can't be arsed trying to get a language client to
# work.
#
# With this approach, it's easy to parallelize the fetches (make
# -jN). It's also easy to perform incremental fetches (e.g. of logs),
# and it's easy to resume the pipeline if it fails midway (e.g. due to
# rate throttling from travis). These are all desirable qualities in a
# data pipeline and Make provides them out-the-box.

TO_SUBBUILD_CSV = $(subst ids/,subbuild_csvs/,$(wildcard ids/*))
TO_SUBBUILD_LOGS = $(subst subbuild_ids/,subbuild_logs/,$(wildcard subbuild_ids/*))
.PHONY: ids show subbuild_csvs subbuild_ids subbuild_logs analyze

# intermediate dirs used by build steps
ids/ show/ subbuild_csvs/ subbuild_ids/ subbuild_logs/:
	mkdir -p $@

# step 1) fetch an unfiltered repo build history from travis
history.txt:
	travis history --limit 20000 -r opensim-org/opensim-core > $@

# step 2) filter the build history to only contain builds that passed
history_passed.txt: history.txt
	grep -P "^#[^ ]+ passed:" $^ > $@

# step 3) extract the build ID from the passed builds
passed_ids.txt: history_passed.txt
	grep -oP "^#\d+" history_passed.txt | sed 's/#//' > $@

# step 4) explode out the passed build IDs into separate files
#
#         this is so that `make` can use the ID files as
#         targets/prerequisites and perform relevant dependency
#         analysis on it
ids: passed_ids.txt | ids/
	xargs -I {} touch -a ids/{} <passed_ids.txt

# step 5) for each ID in ids/ (the exploded form of `passed_ids.txt`),
#         fetch the build's details with `travis show`
#
#         separate ID files are used so that `make` can parallelize
#         the fetch (if possible) and enables incremental fetches
#         (e.g. this step can just be re-ran occasionally over time to
#         fetch more data)
show/%: ids/% | show/
	sleep 1  # crude rate-limiter
	travis show -r opensim-org/opensim-core $(subst ids/,,$<)  > $@

# step 6) expand each `travis show`n build into a CSV file that
#         contains one line per sub-build (e.g. OSX, Linux, gcc,
#         clang)
subbuild_csvs/%: show/% | subbuild_csvs/
	./flatten_to_csv <"$<" >"$@"

# (phony target for step 6): get all subbuild CSVs
subbuild_csvs: $(TO_SUBBUILD_CSV)

# step 7) aggregate all subbuild csvs into a single csv file that
#         contains all sub-builds (this seems like a round-about way
#         of doing it, but it's useful to have a single file for
#         plotting, etc.)
subbuild.csv: $(TO_SUBBUILD_CSV)
	cat $^ > $@

# step 8) explode the subbuild csv file into individual subbuild ID
#         files, so that Make can perform a parallel + resumable +
#         incremental log fetch
subbuild_ids: subbuild.csv | subbuild_ids/
	cut -d ',' -f 4 subbuild.csv | xargs -I {} touch -a subbuild_ids/{}

# step 9) for each subbuild ID, fetch its build log (which contains
#         the test timings)
subbuild_logs/%: subbuild_ids/% | subbuild_logs/
	sleep 1  # crude rate-limiter
	travis logs -r opensim-org/opensim-core $(subst subbuild_ids/,,$<) > $@

# (phony target for step 9): get all subbuild logs
subbuild_logs: $(TO_SUBBUILD_LOGS)

# step 10) extract + aggregate test timings from each subbuild log
#
#          all information is aggregated into a single CSV file with
#          headers: subbuild_id,test_name,duration_secs
subbuild_test_durations.csv: $(TO_SUBBUILD_LOGS)
	$(file >$@.in,$^)
	./extract_test_info @$@.in > $@

# step 11) inner-join sub-builds' top-level information (`travis
#          show`) with the test timings
#
#          this creates a single CSV file that aggregates all builds,
#          commits, dates, etc. with test performance. Aggregating it
#          like this makes it easier for (e.g.) R/pandas to process
final_test_timings.csv: subbuild.csv subbuild_test_durations.csv
	./final-join subbuild.csv subbuild_test_durations.csv > $@

# step 12) run analysis on the final aggregated data to produce
#          relevant plots
analyze:
	./analysis  # create individual plots
	montage linux_*.png -geometry '1x1+0+0<' out_linux.png
	montage osx_*.png -geometry '1x1+0+0<' out_osx.png
