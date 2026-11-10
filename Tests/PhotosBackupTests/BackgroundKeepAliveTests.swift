import AVFoundation
import XCTest
@testable import PhotosBackup

final class BackgroundKeepAliveTests: XCTestCase {
    func testRunsOnlyWhenEnabledWithWorkThatCanMove() {
        XCTAssertTrue(KeepAlivePolicy.shouldRun(enabled: true, queueCanMoveOnItsOwn: true, accountUsable: true))
        XCTAssertFalse(KeepAlivePolicy.shouldRun(enabled: false, queueCanMoveOnItsOwn: true, accountUsable: true))
        XCTAssertFalse(KeepAlivePolicy.shouldRun(enabled: true, queueCanMoveOnItsOwn: false, accountUsable: true))
        XCTAssertFalse(KeepAlivePolicy.shouldRun(enabled: true, queueCanMoveOnItsOwn: true, accountUsable: false))
    }

    /// iOS refuses to start audio or background location from the background.
    func testStartsOnlyFromTheForeground() {
        XCTAssertTrue(KeepAlivePolicy.canStart(isForeground: true))
        XCTAssertFalse(KeepAlivePolicy.canStart(isForeground: false))
    }

    /// Issue #37: the screen stays on only while a lock would stop the backup.
    func testTheScreenStaysAwakeOnlyWhenALockWouldStopTheBackup() {
        XCTAssertTrue(KeepAlivePolicy.keepsScreenAwake(isForeground: true, queueCanMoveOnItsOwn: true, keepAliveRunning: false))
        XCTAssertFalse(KeepAlivePolicy.keepsScreenAwake(isForeground: true, queueCanMoveOnItsOwn: true, keepAliveRunning: true))
        XCTAssertFalse(KeepAlivePolicy.keepsScreenAwake(isForeground: true, queueCanMoveOnItsOwn: false, keepAliveRunning: false))
        XCTAssertFalse(KeepAlivePolicy.keepsScreenAwake(isForeground: false, queueCanMoveOnItsOwn: true, keepAliveRunning: false))
    }

    /// The generated file has to be one AVAudioPlayer accepts, or the
    /// keep-alive fails to start on every device.
    func testTheSilentAudioIsAPlayableOneSecondWAV() throws {
        let data = BackgroundKeepAlive.silentWAV
        XCTAssertEqual(data.count, 44 + 16_000)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertTrue(data.dropFirst(44).allSatisfy { $0 == 0 })
        let player = try AVAudioPlayer(data: data)
        XCTAssertEqual(player.duration, 1, accuracy: 0.01)
        XCTAssertEqual(player.format.sampleRate, 8000)
    }

    @MainActor
    func testKeepAliveIsOnByDefaultAndRemembersItsSettings() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let preferences = BackupPreferences(defaults: defaults)
        XCTAssertTrue(preferences.keepAliveEnabled)
        XCTAssertEqual(preferences.keepAliveMode, .audio)
        preferences.keepAliveEnabled = false
        preferences.keepAliveMode = .location
        let reloaded = BackupPreferences(defaults: defaults)
        XCTAssertFalse(reloaded.keepAliveEnabled)
        XCTAssertEqual(reloaded.keepAliveMode, .location)
    }

    /// Audio mode on the simulator: the session and player start and stop.
    @MainActor
    func testAudioKeepAliveStartsAndStops() throws {
        let keepAlive = BackgroundKeepAlive()
        try keepAlive.start(.audio)
        XCTAssertEqual(keepAlive.mode, .audio)
        keepAlive.stop()
        XCTAssertFalse(keepAlive.isRunning)
    }
}
