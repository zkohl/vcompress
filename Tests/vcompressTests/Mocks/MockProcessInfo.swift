import Foundation
@testable import vcompress

/// Mock SystemInfoProvider with configurable CPU brand and Apple Silicon flag.
final class MockProcessInfo: SystemInfoProvider {

    let cpuBrand: String
    let isARM: Bool

    init(cpuBrand: String = "Apple M2 Pro", isARM: Bool = true) {
        self.cpuBrand = cpuBrand
        self.isARM = isARM
    }

    func cpuBrandString() -> String {
        cpuBrand
    }

    func isAppleSilicon() -> Bool {
        isARM
    }
}
