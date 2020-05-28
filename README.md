# WIP: Scraping OpenSim Perf Metrics from Travis

This repo contains a pipeline for:

- Scraping all passed builds from travis (e.g. `travis logs`)
- Getting top-level build info for each build (via `travis show`)
- Getting all subbuild (osx, linux) logs for each build (via `travis logs`)
- Aggregating the info + logs for useful information (e.g. test durations)
- Analyzing the output
