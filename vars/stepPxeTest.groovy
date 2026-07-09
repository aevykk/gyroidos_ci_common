import org.jenkinsci.plugins.pipeline.modeldefinition.Utils

def call(Map target) {
	// params
	// workspace: Jenkins workspace to operate on
	// gyroid_machine: GyroidOS machine type (only genericx86-64 supported)
	// buildtype: buildtype whose image to flash on hardware (e.g. pxe)
	// artifact_buildtype: optional override for the artifact source buildtype
	// selector: Build selector for CopyArtifact step
	// stage_name: name of the enclosing stage (for skip marking)

	echo "Running PXE hardware test on host: ${NODE_NAME}"

	// Only genericx86-64 is supported for now.
	if (target.gyroid_machine != 'genericx86-64') {
		echo "No PXE hardware test defined for machine ${target.gyroid_machine}. Skip."
		Utils.markStageSkippedForConditional(target.stage_name)
		return
	}

	def srcBuild = target.artifact_buildtype ?: target.buildtype

	// Fetch the built image (for the bootstrap flash) and the test PKI (for the suite).
	step ([$class: 'CopyArtifact',
		projectName: env.JOB_NAME,
		selector: target.selector,
		filter: "out-${srcBuild}/**/gyroidosimage.tar.zst",
		flatten: true]);

	dir("${target.workspace}/test_certificates") {
		step ([$class: 'CopyArtifact',
			projectName: env.JOB_NAME,
			selector: target.selector,
			filter: "out-${srcBuild}/test_certificates/**",
			flatten: true]);
	}

	// Ship the orchestration/flash/reset/test-wrapper scripts and the (QEMU) test harness.
	def resources = ['pxe_bootstrap_test.sh', 'pxe_flash.sh', 'pxe_reset.sh', 'pxe_run_tests.sh',
	                 'VM-container-tests.sh', 'VM-management.sh', 'VM-container-commands.sh',
	                 'settings.sh', 'testdata.sh']
	for (r in resources) {
		writeFile file: "${target.workspace}/${r}", text: libraryResource(r)
	}

	// Host-specific settings (PXE_DIR, HTTP_ADDR, HTTP_PORT, TARGET_IP, PDU_* power
	// control) come from the pxe node's environment. CI supplies the image tarball, the
	// flash script and the reset command (bootstrap), and the test PKI/log dir (test).
	// One lock spans BOTH stages so no other run grabs the hardware mid-cycle; the two
	// stages appear as separate bubbles so a bootstrap failure is distinct from a test
	// failure. Both are non-blocking (stage FAILED, build stays green).
	def bootstrapOk = false
	lock("pxe-test") {
		stage("PXE Bootstrap") {
			catchError(message: 'PXE bootstrap failed', buildResult: 'SUCCESS', stageResult: 'FAILURE') {
				withEnv(["IMAGE_SRC=${target.workspace}/gyroidosimage.tar.zst",
						 "FLASH_SRC=${target.workspace}/pxe_flash.sh",
						 "RESET_CMD=bash ${target.workspace}/pxe_reset.sh"]) {
					sh label: "Flash + boot node via PXE",
						script: "bash ${target.workspace}/pxe_bootstrap_test.sh"
				}
				bootstrapOk = true
			}
		}

		stage("PXE Test") {
			if (!bootstrapOk) {
				echo "Bootstrap failed; skipping hardware integration test."
				Utils.markStageSkippedForConditional("PXE Test")
			} else {
				catchError(message: 'PXE hardware test failed', buildResult: 'SUCCESS', stageResult: 'FAILURE') {
					withEnv(["TEST_PKI=test_certificates",
							 "TEST_LOG_DIR=${target.workspace}/out-${target.buildtype}/cml_logs"]) {
						sh label: "Run integration suite on node",
							script: "bash ${target.workspace}/pxe_run_tests.sh"
					}
				}
			}
		}
	}

	echo "Archiving CML logs"
	archiveArtifacts artifacts: "out-${target.buildtype}/cml_logs/**", fingerprint: true, allowEmptyArchive: true
}
