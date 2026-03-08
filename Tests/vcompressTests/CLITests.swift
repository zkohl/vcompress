import XCTest
@testable import vcompress

final class CLITests: XCTestCase {

    // MARK: - parseMinSize Tests

    func test_minSize_parsesMB() throws {
        let result = try parseMinSize("50MB")
        XCTAssertEqual(result, 52_428_800)
    }

    func test_minSize_parsesGB_caseInsensitive() throws {
        let result = try parseMinSize("2gb")
        XCTAssertEqual(result, 2_147_483_648)
    }

    func test_minSize_parsesKB() throws {
        let result = try parseMinSize("500KB")
        XCTAssertEqual(result, 512_000)
    }

    func test_minSize_rejectsInvalid() {
        // Plain number without unit
        XCTAssertThrowsError(try parseMinSize("50"))
        // Unsupported unit
        XCTAssertThrowsError(try parseMinSize("50TB"))
        // Non-numeric
        XCTAssertThrowsError(try parseMinSize("abc"))
    }

    // MARK: - pathsOverlap Tests

    func test_overlap_sourceIsParentOfDest_rejects() {
        let source = URL(fileURLWithPath: "/Volumes/Media/Raw")
        let dest = URL(fileURLWithPath: "/Volumes/Media/Raw/Output")
        XCTAssertTrue(pathsOverlap(source, dest))
    }

    func test_overlap_destIsParentOfSource_rejects() {
        let source = URL(fileURLWithPath: "/Volumes/Media/Raw/Subfolder")
        let dest = URL(fileURLWithPath: "/Volumes/Media/Raw")
        XCTAssertTrue(pathsOverlap(source, dest))
    }

    func test_overlap_symlinkResolvedBeforeCheck() throws {
        // Create a real symlink so resolvingSymlinksInPath() works.
        let fm = FileManager.default
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vcompress-symtest-\(UUID().uuidString)")
        let realDir = base.appendingPathComponent("real")
        let outputDir = realDir.appendingPathComponent("output")
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        // Create a symlink: base/link -> base/real
        let linkURL = base.appendingPathComponent("link")
        try fm.createSymbolicLink(at: linkURL, withDestinationURL: realDir)

        // source = base/link (symlink), dest = base/real/output
        // After resolving, link -> real, so source = base/real, dest = base/real/output
        // dest is a child of source -> overlap
        XCTAssertTrue(pathsOverlap(linkURL, outputDir),
            "Symlink-resolved paths that overlap must be detected")
    }

    func test_overlap_unrelatedPaths_passes() {
        let source = URL(fileURLWithPath: "/Volumes/Media/Raw")
        let dest = URL(fileURLWithPath: "/Volumes/Media/Compressed")
        XCTAssertFalse(pathsOverlap(source, dest))
    }

    func test_overlap_identicalPaths_rejects() {
        let source = URL(fileURLWithPath: "/Volumes/Media/Raw")
        let dest = URL(fileURLWithPath: "/Volumes/Media/Raw")
        XCTAssertTrue(pathsOverlap(source, dest))
    }

    // MARK: - Jobs Validation Tests

    func test_jobs_0_rejects() {
        XCTAssertThrowsError(try validateJobCount(0))
    }

    func test_jobs_65_rejects() {
        XCTAssertThrowsError(try validateJobCount(65))
    }

    func test_jobs_1through64_passes() {
        for j in 1...64 {
            XCTAssertNoThrow(try validateJobCount(j), "jobs=\(j) should be valid")
        }
    }

    // MARK: - Auto-Jobs Detection Tests

    func test_autoJobs_m2Pro_returns3() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M2 Pro", isARM: true)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 3)
    }

    func test_autoJobs_unknownAppleSilicon_returns2() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M99", isARM: true)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 2)
    }

    func test_autoJobs_intel_returns1() {
        let sysInfo = MockProcessInfo(cpuBrand: "Intel(R) Core(TM) i9", isARM: false)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 1)
    }

    func test_autoJobs_m1Max_returns4() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M1 Max", isARM: true)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 4)
    }

    func test_autoJobs_m3Ultra_returns4() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M3 Ultra", isARM: true)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 4)
    }

    func test_autoJobs_m4Base_returns2() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M4", isARM: true)
        XCTAssertEqual(resolveJobCount(nil, sysInfo: sysInfo), 2)
    }

    func test_autoJobs_explicitOverridesAuto() {
        let sysInfo = MockProcessInfo(cpuBrand: "Apple M2 Pro", isARM: true)
        // Auto would be 3, but explicit 5 should be returned as-is
        XCTAssertEqual(resolveJobCount(5, sysInfo: sysInfo), 5)
    }
}
