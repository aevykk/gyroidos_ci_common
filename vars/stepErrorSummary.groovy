// Cross-job summary
//
// Every CML test stage archives its deduplicated faults as out-<buildtype>/cml_errors.json
// (written by parse_dedup_cml_errors.py in stepIntegrationTest). This step collects
// those reports from the current build and prints the faults that did NOT occur in
// all test jobs; uniform faults are visible in every per-job report anyway.

def call(Map target = [:]) {
	// this build's own test artifacts - unlike the image copies, which use BUILDSELECTOR
	step([$class: 'CopyArtifact',
		projectName: env.JOB_NAME,
		selector: specific("${env.BUILD_NUMBER}"),
		filter: 'out-*/cml_errors.json',
		optional: true])

	summary_script = libraryResource('parse_dedup_cml_errors.py')
	writeFile file: "parse_dedup_cml_errors.py", text: "${summary_script}"

	// nonzero exit (differing faults found) marks this stage UNSTABLE, build stays green
	catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
		sh label: "CML error summary", script: """#!/bin/bash -e
			# nullglob: no reports (all test stages skipped/failed) -> empty merge list
			shopt -s nullglob
			python3 parse_dedup_cml_errors.py --merge out-*/cml_errors.json
		"""
	}
}
