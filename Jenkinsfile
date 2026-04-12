// ============================================================================
//  Jenkinsfile  —  horse-provider-crosssocket CI pipeline
//
//  Agent requirements  (label: 'windows && delphi')
//  ─────────────────────────────────────────────────
//  Software:
//    • Delphi 10.4 Sydney or later
//      Set DELPHI_ROOT as a system environment variable on the agent, e.g.:
//        DELPHI_ROOT=C:\Program Files (x86)\Embarcadero\Studio\22.0
//    • Boss package manager:  https://github.com/HashLoad/boss/releases
//      boss.exe must be in the system PATH.
//    • PowerShell (built-in on Windows Server 2016+)
//
//  Repository must contain:
//    • samples/tests/HorseCSTestServer.dproj
//    • samples/tests/HorseCSTestClient.dproj
//
//  Pipeline stages
//  ───────────────
//  1. Checkout         — clean checkout; clears stale modules/
//  2. Check environment— scripts\check-env.bat; fails fast on missing tools
//  3. Install deps     — boss install → modules\horse + modules\Delphi-Cross-Socket
//  4. Build            — msbuild both test .dproj files (Win64 Release)
//  5. Integration test — server (background) + client (exit code = failures)
//  6. Archive          — fingerprinted executables
// ============================================================================

pipeline {
    agent {
        label 'windows && delphi'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
        disableConcurrentBuilds()
        // Colour the console output (requires AnsiColor plugin)
        ansiColor('xterm')
    }

    parameters {
        choice(
            name:        'PLATFORM',
            choices:     ['Win64', 'Win32'],
            description: 'Target platform (Win64 recommended; Win32 for 32-bit testing)'
        )
        choice(
            name:        'CONFIG',
            choices:     ['Release', 'Debug'],
            description: 'Build configuration'
        )
        booleanParam(
            name:         'CLEAN_BUILD',
            defaultValue: false,
            description:  'Pass "clean" to build.bat — removes previous output before compiling'
        )
    }

    environment {
        PLATFORM    = "${params.PLATFORM    ?: 'Win64'}"
        CONFIG      = "${params.CONFIG      ?: 'Release'}"
        CLEAN_FLAG  = "${params.CLEAN_BUILD ? 'clean' : ''}"

        // Artifact paths — must match DCC_ExeOutput in the .dproj files
        SERVER_EXE  = "samples\\tests\\${PLATFORM}\\${CONFIG}\\HorseCSTestServer.exe"
        CLIENT_EXE  = "samples\\tests\\${PLATFORM}\\${CONFIG}\\HorseCSTestClient.exe"
    }

    stages {

        // ── Stage 1: Checkout ─────────────────────────────────────────────────
        stage('Checkout') {
            steps {
                // Clean workspace removes stale modules/ from previous boss install
                // so boss always resolves the latest declared dependency versions.
                cleanWs()
                checkout scm
                echo "Checked out ${env.GIT_BRANCH} @ ${env.GIT_COMMIT?.take(8)}"
            }
        }

        // ── Stage 2: Environment check ────────────────────────────────────────
        //
        // Runs before any compilation.  Verifies:
        //   rsvars.bat reachable, BDS set, dcc64/dcc32 present,
        //   CodeGear.Delphi.Targets exists, boss in PATH,
        //   .dproj files committed, port 9100 free.
        //
        // Fails the build immediately with a clear message rather than letting
        // MSBuild emit cryptic "target not found" or "unit not found" errors.
        stage('Check environment') {
            steps {
                bat "scripts\\check-env.bat ${CONFIG} ${PLATFORM}"
            }
        }

        // ── Stage 3: Build ────────────────────────────────────────────────────
        //
        // build.bat:
        //   1. Loads rsvars.bat
        //   2. boss install  (modules/ populated from boss.json)
        //   3. Optional clean
        //   4. msbuild HorseCSTestServer.dproj  (HORSE_CROSSSOCKET in .dproj)
        //   5. msbuild HorseCSTestClient.dproj
        stage('Build') {
            steps {
                bat "scripts\\build.bat ${CONFIG} ${PLATFORM} ${CLEAN_FLAG}"
            }
            post {
                failure {
                    echo '''Build failed. Common causes:
  - modules\\ missing or incomplete: check boss install output
  - Unit not found: verify DCC_UnitSearchPath in the .dproj
  - Compiler error: look for [dcc64 Error] lines above
  - rsvars.bat not called: check DELPHI_ROOT on the agent'''
                }
            }
        }

        // ── Stage 4: Integration tests ────────────────────────────────────────
        //
        // run-tests.bat:
        //   1. Starts HorseCSTestServer.exe in background on port 9100
        //   2. Polls GET /ping until ready (PowerShell, up to 10 s)
        //   3. Runs HorseCSTestClient.exe  — 14 tests
        //   4. Stops server unconditionally
        //   5. Exits with client's exit code (0 = pass, N = N failures)
        stage('Integration tests') {
            steps {
                bat "scripts\\run-tests.bat ${PLATFORM} ${CONFIG}"
            }
            post {
                failure {
                    echo 'One or more integration tests failed — review client output above for which test and what response was received.'
                }
                always {
                    // Safety net: kill server even if stage is aborted mid-run
                    bat 'taskkill /F /IM HorseCSTestServer.exe /T >nul 2>&1 & exit 0'
                }
            }
        }

        // ── Stage 5: Archive ──────────────────────────────────────────────────
        stage('Archive') {
            steps {
                archiveArtifacts(
                    artifacts:         "${SERVER_EXE}, ${CLIENT_EXE}",
                    fingerprint:       true,
                    allowEmptyArchive: false
                )
            }
        }
    }

    post {
        always {
            // Final safety net regardless of which stage failed or was aborted
            bat 'taskkill /F /IM HorseCSTestServer.exe /T >nul 2>&1 & exit 0'
        }
        success {
            echo "SUCCESS — ${CONFIG} ${PLATFORM}  |  branch: ${env.GIT_BRANCH}  |  commit: ${env.GIT_COMMIT?.take(8)}"
        }
        failure {
            echo "FAILURE — ${CONFIG} ${PLATFORM}  |  branch: ${env.GIT_BRANCH}  |  commit: ${env.GIT_COMMIT?.take(8)}"
        }
    }
}
