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

				CML_DBG=n bash ${target.workspace}/VM-container-tests.sh --mode "${target.test_mode}" --dir "${target.workspace}" --image gyroidosimage.img --pki "${target.workspace}/test_certificates" --name "${vmName}" --ssh ${sshPort} --kill --vnc ${vncDisplay} --log-dir "${target.workspace}/out-${srcBuild}/cml_logs" \$schsm_opts ${target.extra_opts ? target.extra_opts : ""}
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
				if ! [ -z "\$(find out-${srcBuild}/cml_logs -name '*asan*')" ];then
					echo "Found ASAN logs"
					exit 1
				else
					echo "No ASAN logs generated"
					exit 0
				fi
			"""
		}
	} finally {
		echo "Archiving CML logs"
		archiveArtifacts artifacts: 'out-**/cml_logs/**', fingerprint: true, allowEmptyArchive: true
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
