import groovy.transform.Field
import org.jenkinsci.plugins.pipeline.modeldefinition.Utils

def integrationTestX86(Map target = [:]) {
	def srcBuild = target.artifact_buildtype ?: target.buildtype

	stepWipeWs(target.workspace, target.manifest_path)

	if (('SUCCESS' != currentBuild.currentResult) && ("" != target.hsm_serial)) {
		echo "Skipping integration test as current build result is '${currentBuild.currentResult}' and SC-HSM is to be used"
		Utils.markStageSkippedForConditional(STAGE_NAME)
		return
	}

	step ([$class: 'CopyArtifact',
		projectName: env.JOB_NAME,
		selector: target.selector,
		filter: "out-${srcBuild}/**/gyroidosimage.tar.zst, ${target.source_tarball}",
		flatten: true]);


	dir("${target.workspace}/test_certificates") {
		step ([$class: 'CopyArtifact',
			projectName: env.JOB_NAME,
			selector: target.selector,
			filter: "out-${srcBuild}/test_certificates/**",
			flatten: true]);
	}
	sh "ls -al ${target.workspace}/test_certificates"

	dir("${target.workspace}/kernel") {
		step ([$class: 'CopyArtifact',
			projectName: env.JOB_NAME,
			selector: target.selector,
			filter: "out-${srcBuild}/**/cml_updates/kernel-*.tar",
			flatten: true]);
		sh label: "Extract kernel update", script: 'tar -xf kernel-*.tar'
	}
	sh "ls -al ${target.workspace}/kernel"

	artifact_build_no = utilGetArtifactBuildNo(workspace: target.workspace, selector: target.selector)

	echo "Using artifacts of build number determined by selector: ${artifact_build_no}"

	sh "echo \"Unpacking sources\" && tar -C \"${target.workspace}\" -xf ${target.source_tarball} && rm -f ${target.source_tarball}"

	sh label: "Extract image", script: 'tar --zstd -xf gyroidosimage.tar.zst && rm -f gyroidosimage.tar.zst'


	testscript = libraryResource('VM-container-tests.sh')	
	container_commands = libraryResource('VM-container-commands.sh')
	vm_commands = libraryResource('VM-management.sh')
	testsettings = libraryResource('settings.sh')
	testdata = libraryResource('testdata.sh')	

	writeFile file: "${target.workspace}/VM-container-tests.sh", text: "${testscript}"
	writeFile file: "${target.workspace}/VM-container-commands.sh", text: "${container_commands}"
	writeFile file: "${target.workspace}/VM-management.sh", text: "${vm_commands}"
	writeFile file: "${target.workspace}/settings.sh", text: "${testsettings}"
	writeFile file: "${target.workspace}/testdata.sh", text: "${testdata}"

	// CML ERROR/FATAL allowlist lives on the yocto mirror so it can change without a merge
	allowlistPath = "/${env.YOCTO_MIRROR_DIR}/ci/cml_error_allowlist.txt"
	allowlistMissing = !fileExists(allowlistPath)
	writeFile file: "${target.workspace}/cml_error_allowlist.txt",
		text: allowlistMissing ? "" : readFile(allowlistPath)

	def execNr = env.EXECUTOR_NUMBER?.toInteger() ?: 0
	def sshPort = target.ssh_port ?: (2222 + execNr)
	def vncDisplay = target.vnc_display ?: (1 + execNr)
	def vmName = target.vm_name ?: "testvm-${execNr}"

	def runActualTest = {
		catchError(message: 'Integration test failed', stageResult: 'FAILURE') {
			sh label: "Perform integration test", script: """
				if ! [ -z "${target.hsm_serial}" ];then
					schsm_opts="--enable-hsm ${target.hsm_serial} ${target.hsm_vid} ${target.hsm_pid} ${target.hsm_pin}"

					echo "Testing image with \'\$schsm_opts\' and mode \'${target.test_mode}\'"
				else
					schsm_opts=""
					echo "Testing image with mode ${target.test_mode}"
				fi

				CML_DBG=n bash ${target.workspace}/VM-container-tests.sh --mode "${target.test_mode}" --dir "${target.workspace}" --image gyroidosimage.img --pki "${target.workspace}/test_certificates" --name "${vmName}" --ssh ${sshPort} --kill --vnc ${vncDisplay} --log-dir "${target.workspace}/out-${target.buildtype}/cml_logs" \$schsm_opts ${target.extra_opts ? target.extra_opts : ""}
			"""
		}
	}

	try {
		// HSM-based tests need locking
		// Negated to be defensive against bugs when adding new HSM types
		if (!(target.buildtype in ['asan', 'ccmode', 'dev', 'production'])){
			echo "Acquiring lock '${target.buildtype}' for integration test"
			lock(target.buildtype) {
				runActualTest()
			}
		} else {
			runActualTest()
		}

		catchError(message: 'ASAN output detected', stageResult: 'FAILURE') {
			sh label: "Check whether ASAN logs generated", script: """
				if ! [ -z "\$(find out-${target.buildtype}/cml_logs -name '*asan*')" ];then
					echo "Found ASAN logs"
					exit 1
				else
					echo "No ASAN logs generated"
					exit 0
				fi
			"""
		}

		catchError(buildResult: 'SUCCESS', stageResult: 'UNSTABLE') {
			sh label: "Check for CML ERROR/FATAL logs", script: """
				LOGDIR="out-${target.buildtype}/cml_logs"
				ALLOW="${target.workspace}/cml_error_allowlist.txt"

				# Every ERROR/FATAL line CML wrote (keep filename:line prefix for context)
				grep -rnP '<ERROR>|<FATAL>' "\$LOGDIR" 2>/dev/null > cml_errors.all || true
				# Effective allowlist: drop comment (#) and blank lines
				grep -vP '^[[:space:]]*(#|\$)' "\$ALLOW" 2>/dev/null > cml_errors.allow || true

				if [ -s cml_errors.allow ]; then
					grep -vP -f cml_errors.allow cml_errors.all > cml_errors.flagged || true
				else
					cp cml_errors.all cml_errors.flagged
				fi

				if [ -s cml_errors.flagged ]; then
					echo "CML wrote ERROR/FATAL log messages - marking stage UNSTABLE:"
					# Strip the "file:line:" prefix and leading timestamp, then group contiguous
					# entries (same file, consecutive lines) under one fault header stamped with
					# the first entry's timestamp.
					prev_file=""
					prev_line=""
					while IFS= read -r rawline; do
						file="\${rawline%%:*}"
						rest="\${rawline#*:}"
						line="\${rest%%:*}"
						content="\${rest#*:}"
						ts="\${content%% *}"
						stripped="\${content#* }"
						if [ "\$file" != "\$prev_file" ] || [ "\$line" != "\$((prev_line + 1))" ]; then
							echo "===>> [\$ts] CML FAULT: <<==="
						fi
						echo "\$stripped"
						prev_file="\$file"
						prev_line="\$line"
					done < cml_errors.flagged
					exit 1
				else
					echo "No un-allowlisted CML ERROR/FATAL messages found"
					exit 0
				fi
			"""
		}
	} finally {
		echo "Archiving CML logs"
		archiveArtifacts artifacts: 'out-**/cml_logs/**', fingerprint: true, allowEmptyArchive: true
		if (allowlistMissing) {
			echo "WARNING: CML error allowlist not found at ${allowlistPath} - " +
				"treated as empty, so no benign ERROR/FATAL messages were suppressed."
		}
	}
}

@Field def integrationTestMap = ["genericx86-64": this.&integrationTestX86];

def call(Map target) {
	// params
	// workspace: Jenkins workspace to operate on
	// gyroid_arch: GyroidOS architecture, used to determine manifest
	// gyroid_machine: GyroidOS machine type, used to determine manifest
	// buildtype: Type of image to build
	// selector: Build selector for CopyArtifact step
	// schsm_serial: serial of test schsm
	// schsm_pin: Pin of test schsm
	// extra_opts: Additional flags for VM-container-test.sh

	echo "Running on host: ${NODE_NAME}"

	echo "Entering stepIntegrationTest with parameters:\n\tworkspace: ${target.workspace}\n\tsource_tarball: ${target.source_tarball}\n\tmanifest_path: ${target.manifest_path}\n\tgyroid_machine: ${target.gyroid_machine}\n\tbuildtype: ${target.buildtype}\n\tselector: ${buildParameter('BUILDSELECTOR')}\n\ttest_mode: ${target.test_mode}\n\thsm_serial: ${target.hsm_serial}\n\thsm_pin: ${target.hsm_pin}\n\textra_opts: ${target.extra_opts}\n\tverbose: ${target.verbose}"

	script {
		def testFunc = integrationTestMap[target.gyroid_machine];
		if (testFunc != null) {
			testFunc(target);
		} else {
			echo "No integration test defined for machine ${target.gyroid_machine}. Skip."
			echo "${target.stage_name}"
			Utils.markStageSkippedForConditional(target.stage_name);
		}
	}
}
