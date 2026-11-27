import XCTest
@testable import PhotosBackup

final class PowerPolicyTests: XCTestCase {

    func testOnlyWhileChargingBlocksUnpluggedAndAllowsCharging() {
        let unplugged = PowerStatus(isCharging: false, batteryPercent: 85)
        let charging = PowerStatus(isCharging: true, batteryPercent: 15)

        let blocked = PowerPolicy.decision(onlyWhileCharging: true, minimumBatteryPercent: 0, status: unplugged)
        XCTAssertFalse(blocked.allowsUploads)
        XCTAssertEqual(blocked.pauseReason, "Waiting for charger")

        XCTAssertEqual(
            PowerPolicy.decision(onlyWhileCharging: true, minimumBatteryPercent: 0, status: charging),
            .allowed
        )
    }

    func testMinimumBatteryBlocksUnpluggedBelowThresholdOnly() {
        let lowUnplugged = PowerStatus(isCharging: false, batteryPercent: 25)
        let okUnplugged = PowerStatus(isCharging: false, batteryPercent: 30)
        let lowCharging = PowerStatus(isCharging: true, batteryPercent: 10)
        let unknownLevel = PowerStatus(isCharging: false, batteryPercent: nil)

        let blocked = PowerPolicy.decision(onlyWhileCharging: false, minimumBatteryPercent: 30, status: lowUnplugged)
        XCTAssertFalse(blocked.allowsUploads)
        XCTAssertEqual(blocked.pauseReason, "Waiting for battery to reach 30%")

        XCTAssertEqual(PowerPolicy.decision(onlyWhileCharging: false, minimumBatteryPercent: 30, status: okUnplugged), .allowed)
        XCTAssertEqual(PowerPolicy.decision(onlyWhileCharging: false, minimumBatteryPercent: 30, status: lowCharging), .allowed)
        XCTAssertEqual(PowerPolicy.decision(onlyWhileCharging: false, minimumBatteryPercent: 30, status: unknownLevel), .allowed)
        XCTAssertEqual(PowerPolicy.decision(onlyWhileCharging: false, minimumBatteryPercent: 0, status: lowUnplugged), .allowed)
    }

    @MainActor
    func testPreferencesPersistPowerAndLocationWakeSettings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = BackupPreferences(defaults: defaults)
        XCTAssertFalse(preferences.onlyWhileCharging)
        XCTAssertEqual(preferences.minimumBatteryPercent, 0)
        XCTAssertFalse(preferences.significantLocationWake)

        preferences.onlyWhileCharging = true
        preferences.minimumBatteryPercent = 50
        preferences.significantLocationWake = true

        let reloaded = BackupPreferences(defaults: defaults)
        XCTAssertTrue(reloaded.onlyWhileCharging)
        XCTAssertEqual(reloaded.minimumBatteryPercent, 50)
        XCTAssertTrue(reloaded.significantLocationWake)
    }
}
