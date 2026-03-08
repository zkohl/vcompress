import XCTest
@testable import vcompress

final class ReporterTests: XCTestCase {

    // A fixed date: 2023-11-14T22:13:20Z (timeIntervalSince1970 = 1_700_000_000)
    private func makeClock() -> MockClock {
        MockClock(date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeConfig(
        quality: Quality = .standard,
        jobs: Int = 3,
        sourceDir: String = "/Volumes/Media/Raw",
        destDir: String = "/Volumes/Media/Compressed"
    ) -> Config {
        Config(
            sourceDir: URL(fileURLWithPath: sourceDir),
            destDir: URL(fileURLWithPath: destDir),
            jobs: jobs,
            quality: quality
        )
    }

    // MARK: - Plan Summary

    func test_planSummary_formatsAllCounts() {
        let entries = (0..<142).map { i in
            FileEntry(
                sourcePath: "/src/file\(i).mp4",
                relativePath: "file\(i).mp4",
                destPath: "/dst/file\(i).mp4",
                fileSize: 2_202_009_600,  // ~2.05 GB each, total ~312.5 GB for 142
                sourceContainer: "mp4"
            )
        }

        let result = ScanResult(
            pending: entries,
            skipCounts: [
                .alreadyHEVC: 38,
                .alreadyDone: 12,
                .tooSmall: 6,
                .noVideoTrack: 2,
                .notVideo: 21,
            ],
            warnings: [],
            totalScanned: 221
        )

        let clock = makeClock()
        let reporter = Reporter(clock: clock)
        let config = makeConfig()
        let plan = reporter.formatPlan(result, config: config)

        XCTAssert(plan.contains("Files to encode:   142"), "Plan should show pending count. Got:\n\(plan)")
        XCTAssert(plan.contains("Already HEVC:       38"), "Plan should show already HEVC count. Got:\n\(plan)")
        XCTAssert(plan.contains("Already done:       12"), "Plan should show already done count. Got:\n\(plan)")
        XCTAssert(plan.contains("Below min-size:      6"), "Plan should show below min-size count. Got:\n\(plan)")
        XCTAssert(plan.contains("No video track:      2"), "Plan should show no video track count. Got:\n\(plan)")
        XCTAssert(plan.contains("Not video:          21"), "Plan should show not video count. Got:\n\(plan)")
        XCTAssert(plan.contains("Total scanned:     221"), "Plan should show total scanned. Got:\n\(plan)")
    }

    func test_planSummary_showsEstimatedOutputRange() {
        // 500 GB input, lossy preset -> estimated 20%-35% = 100GB-175GB
        // In binary: 500_000_000_000 bytes
        let entries = [
            FileEntry(
                sourcePath: "/src/big.mp4",
                relativePath: "big.mp4",
                destPath: "/dst/big.mp4",
                fileSize: 500_000_000_000,  // 500 GB
                sourceContainer: "mp4"
            )
        ]

        let result = ScanResult(
            pending: entries,
            skipCounts: [:],
            warnings: [],
            totalScanned: 1
        )

        let clock = makeClock()
        let reporter = Reporter(clock: clock)
        let config = makeConfig()
        let plan = reporter.formatPlan(result, config: config)

        // Plan should show the estimated output range with actual values
        XCTAssert(plan.contains("Estimated output:"), "Plan should contain estimated output. Got:\n\(plan)")

        // Verify the range values are present (low = 20% of 500GB, high = 35% of 500GB)
        let est = Reporter.estimateOutput(inputSize: 500_000_000_000, quality: .standard)
        let lowStr = Reporter.formatSize(est.low)
        let highStr = Reporter.formatSize(est.high)
        XCTAssert(plan.contains(lowStr),
            "Plan should contain low estimate '\(lowStr)'. Got:\n\(plan)")
        XCTAssert(plan.contains(highStr),
            "Plan should contain high estimate '\(highStr)'. Got:\n\(plan)")
    }

    func test_planSummary_maxQuality_showsCorrectLabel() {
        let entries = [
            FileEntry(
                sourcePath: "/src/clip.mp4",
                relativePath: "clip.mp4",
                destPath: "/dst/clip.mp4",
                fileSize: 100_000_000,
                sourceContainer: "mp4"
            )
        ]

        let result = ScanResult(
            pending: entries,
            skipCounts: [:],
            warnings: [],
            totalScanned: 1
        )

        let clock = makeClock()
        let reporter = Reporter(clock: clock)
        let config = makeConfig(quality: .max)
        let plan = reporter.formatPlan(result, config: config)

        XCTAssert(plan.contains("max"),
            "Max quality plan should indicate max. Got:\n\(plan)")
        // Verify estimated range uses max percentages (15%-35%)
        let est = Reporter.estimateOutput(inputSize: 100_000_000, quality: .max)
        let lowStr = Reporter.formatSize(est.low)
        let highStr = Reporter.formatSize(est.high)
        XCTAssert(plan.contains(lowStr),
            "Max quality plan should contain low estimate '\(lowStr)'. Got:\n\(plan)")
        XCTAssert(plan.contains(highStr),
            "Max quality plan should contain high estimate '\(highStr)'. Got:\n\(plan)")
    }

    // MARK: - Progress Line

    func test_progressLine_formatsCorrectly() {
        let clock = makeClock()
        let reporter = Reporter(clock: clock)
        let line = reporter.formatProgress(
            index: 42,
            total: 142,
            path: "Trip/clip.mp4",
            inputSize: 500_000_000,
            outputSize: 125_000_000,
            elapsed: 38
        )

        // 500_000_000 bytes = 476.8 MB, 125_000_000 bytes = 119.2 MB
        // savings = (500M - 125M) / 500M * 100 = 75%
        XCTAssertEqual(
            line,
            "[ 42/142]  encoded  Trip/clip.mp4  476.8 MB \u{2192} 119.2 MB (75%)  38s"
        )
    }

    // MARK: - Completion Summary

    func test_completionSummary_computesSavingsPercentage() {
        let clock = makeClock()
        let reporter = Reporter(clock: clock)

        let inputSize: Int64 = 335_544_320_000  // ~312.5 GB
        let outputSize: Int64 = 88_146_239_488   // ~82.1 GB
        let saved = inputSize - outputSize
        let expectedPercent = Double(saved) / Double(inputSize) * 100

        let summary = reporter.formatSummary(
            encoded: 130,
            skipped: 89,
            failed: 2,
            inputSize: inputSize,
            outputSize: outputSize,
            wallTime: 8077,  // 2h 14m 37s
            stateFilePath: "/Volumes/Media/Compressed/.vcompress-state.json",
            logFilePath: "/Volumes/Media/Compressed/.vcompress-log-20250601T120000Z.txt"
        )

        XCTAssert(summary.contains("vcompress complete"), "Summary header missing")
        XCTAssert(summary.contains("Encoded:    130 files"), "Encoded count wrong. Got:\n\(summary)")
        XCTAssert(summary.contains("Skipped:     89 files"), "Skipped count wrong. Got:\n\(summary)")
        XCTAssert(summary.contains("Failed:       2 files"), "Failed count wrong. Got:\n\(summary)")
        XCTAssert(summary.contains("(\(String(format: "%.1f", expectedPercent))%)"), "Savings percentage wrong. Got:\n\(summary)")
        XCTAssert(summary.contains("2h 14m 37s"), "Wall time wrong. Got:\n\(summary)")
        XCTAssert(summary.contains(".vcompress-state.json"), "State path missing")
        XCTAssert(summary.contains(".vcompress-log-"), "Log path missing")
    }

    // MARK: - Log Line

    func test_logLine_usesISO8601WithColons() {
        // 1_700_000_000 = 2023-11-14T22:13:20Z
        let clock = makeClock()
        let reporter = Reporter(clock: clock)

        let line = reporter.formatLogLine(level: "INFO", message: "Starting encode")

        // Must contain colons in the timestamp (ISO 8601 standard)
        XCTAssert(line.contains("2023-11-14T22:13:20Z"), "Log line should use ISO 8601 with colons. Got: \(line)")
        XCTAssert(line.contains("[INFO]"), "Log line should contain level. Got: \(line)")
        XCTAssert(line.contains("Starting encode"), "Log line should contain message. Got: \(line)")
    }

    // MARK: - Log Filename

    func test_logFilename_usesCompactTimestampWithoutColons() {
        // 1_700_000_000 = 2023-11-14T22:13:20Z
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let filename = Reporter.logFilename(date: date)

        XCTAssertEqual(filename, ".vcompress-log-20231114T221320Z.txt")
        // Verify no colons in the filename
        XCTAssertFalse(filename.contains(":"), "Log filename must not contain colons")
    }

    // MARK: - Estimation

    func test_estimatedOutput_standard_rangeCorrect() {
        let est = Reporter.estimateOutput(inputSize: 312_500_000_000, quality: .standard)
        XCTAssertEqual(est.low, 15_625_000_000)    // 5%
        XCTAssertEqual(est.high, 46_875_000_000)   // 15%
    }

    func test_estimatedOutput_high_rangeCorrect() {
        let est = Reporter.estimateOutput(inputSize: 312_500_000_000, quality: .high)
        XCTAssertEqual(est.low, 15_625_000_000)    // 5%
        XCTAssertEqual(est.high, 62_500_000_000)   // 20%
    }

    func test_estimatedOutput_max_rangeCorrect() {
        let est = Reporter.estimateOutput(inputSize: 312_500_000_000, quality: .max)
        XCTAssertEqual(est.low, 46_875_000_000)    // 15%
        XCTAssertEqual(est.high, 109_375_000_000)  // 35%
    }

    func test_estimatedOutput_zeroInput_returnsZero() {
        let estStandard = Reporter.estimateOutput(inputSize: 0, quality: .standard)
        XCTAssertEqual(estStandard.low, 0)
        XCTAssertEqual(estStandard.high, 0)

        let estMax = Reporter.estimateOutput(inputSize: 0, quality: .max)
        XCTAssertEqual(estMax.low, 0)
        XCTAssertEqual(estMax.high, 0)
    }

    // MARK: - Format Size

    func test_formatSize_bytes() {
        XCTAssertEqual(Reporter.formatSize(0), "0 B")
        XCTAssertEqual(Reporter.formatSize(512), "512 B")
        XCTAssertEqual(Reporter.formatSize(1023), "1023 B")
    }

    func test_formatSize_KB() {
        // 1024 bytes = 1.0 KB
        XCTAssertEqual(Reporter.formatSize(1024), "1.0 KB")
        // 51200 bytes = 50.0 KB
        XCTAssertEqual(Reporter.formatSize(51200), "50.0 KB")
        // 1048575 bytes = 1024.0 KB - 1 byte ~ 1024.0 KB
        XCTAssertEqual(Reporter.formatSize(500_000), "488.3 KB")
    }

    func test_formatSize_MB() {
        // 1_048_576 = 1.0 MB
        XCTAssertEqual(Reporter.formatSize(1_048_576), "1.0 MB")
        // 500_000_000 bytes = 476.8 MB
        XCTAssertEqual(Reporter.formatSize(500_000_000), "476.8 MB")
        // 52_428_800 = 50.0 MB
        XCTAssertEqual(Reporter.formatSize(52_428_800), "50.0 MB")
    }

    func test_formatSize_GB() {
        // 1_073_741_824 = 1.0 GB
        XCTAssertEqual(Reporter.formatSize(1_073_741_824), "1.0 GB")
        // 5_368_709_120 = 5.0 GB
        XCTAssertEqual(Reporter.formatSize(5_368_709_120), "5.0 GB")
        // 312_500_000_000 bytes = 291.0 GB
        XCTAssertEqual(Reporter.formatSize(312_500_000_000), "291.0 GB")
    }

    // MARK: - Format Time

    func test_formatTime_seconds() {
        XCTAssertEqual(Reporter.formatTime(0), "0s")
        XCTAssertEqual(Reporter.formatTime(1), "1s")
        XCTAssertEqual(Reporter.formatTime(38), "38s")
        XCTAssertEqual(Reporter.formatTime(59), "59s")
    }

    func test_formatTime_minutes() {
        XCTAssertEqual(Reporter.formatTime(60), "1m 0s")
        XCTAssertEqual(Reporter.formatTime(90), "1m 30s")
        XCTAssertEqual(Reporter.formatTime(3599), "59m 59s")
    }

    func test_formatTime_hours() {
        XCTAssertEqual(Reporter.formatTime(3600), "1h 0m 0s")
        XCTAssertEqual(Reporter.formatTime(8077), "2h 14m 37s")
        XCTAssertEqual(Reporter.formatTime(86400), "24h 0m 0s")
    }
}
