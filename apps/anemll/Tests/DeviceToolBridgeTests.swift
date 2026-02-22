import CoreLocation
import OpenClawGatewayCore
import OpenClawKit
import Testing
@testable import OpenClaw

// MARK: - Mock Services

private final class MockReminders: RemindersServicing, @unchecked Sendable {
    var listCallCount = 0
    var addCallCount = 0

    func list(
        params _: OpenClawRemindersListParams
    ) async throws -> OpenClawRemindersListPayload {
        self.listCallCount += 1
        return OpenClawRemindersListPayload(reminders: [])
    }

    func add(
        params _: OpenClawRemindersAddParams
    ) async throws -> OpenClawRemindersAddPayload {
        self.addCallCount += 1
        return OpenClawRemindersAddPayload(
            reminder: OpenClawReminderPayload(
                identifier: "mock-1",
                title: "Test",
                dueISO: nil,
                completed: false,
                listName: nil))
    }
}

private final class MockCalendar: CalendarServicing,
    @unchecked Sendable
{
    func events(
        params _: OpenClawCalendarEventsParams
    ) async throws -> OpenClawCalendarEventsPayload {
        OpenClawCalendarEventsPayload(events: [])
    }

    func add(
        params _: OpenClawCalendarAddParams
    ) async throws -> OpenClawCalendarAddPayload {
        OpenClawCalendarAddPayload(
            event: OpenClawCalendarEventPayload(
                identifier: "cal-1",
                title: "Test",
                startISO: "2026-01-01T00:00:00Z",
                endISO: "2026-01-01T01:00:00Z",
                location: nil,
                notes: nil,
                isAllDay: false))
    }
}

private final class MockContacts: ContactsServicing,
    @unchecked Sendable
{
    func search(
        params _: OpenClawContactsSearchParams
    ) async throws -> OpenClawContactsSearchPayload {
        OpenClawContactsSearchPayload(contacts: [])
    }

    func add(
        params _: OpenClawContactsAddParams
    ) async throws -> OpenClawContactsAddPayload {
        OpenClawContactsAddPayload(
            contact: OpenClawContactPayload(
                identifier: "c-1",
                givenName: "Test",
                familyName: "User",
                phoneNumbers: nil,
                emailAddresses: nil))
    }
}

@MainActor
private final class MockLocation: LocationServicing,
    @unchecked Sendable
{
    func authorizationStatus() -> CLAuthorizationStatus {
        .authorizedWhenInUse
    }

    func accuracyAuthorization() -> CLAccuracyAuthorization {
        .fullAccuracy
    }

    func ensureAuthorization(
        mode _: OpenClawLocationMode
    ) async -> CLAuthorizationStatus {
        .authorizedWhenInUse
    }

    func currentLocation(
        params _: OpenClawLocationGetParams,
        desiredAccuracy _: OpenClawLocationAccuracy,
        maxAgeMs _: Int?,
        timeoutMs _: Int?
    ) async throws -> CLLocation {
        CLLocation(latitude: 37.7749, longitude: -122.4194)
    }

    func startLocationUpdates(
        desiredAccuracy _: OpenClawLocationAccuracy,
        significantChangesOnly _: Bool
    ) -> AsyncStream<CLLocation> {
        AsyncStream { $0.finish() }
    }

    func stopLocationUpdates() {}

    func startMonitoringSignificantLocationChanges(
        onUpdate _: @escaping @Sendable (CLLocation) -> Void
    ) {}

    func stopMonitoringSignificantLocationChanges() {}
}

private final class MockPhotos: PhotosServicing,
    @unchecked Sendable
{
    func latest(
        params _: OpenClawPhotosLatestParams
    ) async throws -> OpenClawPhotosLatestPayload {
        OpenClawPhotosLatestPayload(photos: [])
    }
}

private final class MockCamera: CameraServicing,
    @unchecked Sendable
{
    func listDevices() async -> [CameraController.CameraDeviceInfo] {
        []
    }

    func snap(
        params _: OpenClawCameraSnapParams
    ) async throws -> (
        format: String, base64: String,
        width: Int, height: Int
    ) {
        ("jpeg", "dGVzdA==", 320, 240)
    }

    func clip(
        params _: OpenClawCameraClipParams
    ) async throws -> (
        format: String, base64: String,
        durationMs: Int, hasAudio: Bool
    ) {
        ("mp4", "dGVzdA==", 1000, false)
    }
}

private final class MockMotion: MotionServicing,
    @unchecked Sendable
{
    func activities(
        params _: OpenClawMotionActivityParams
    ) async throws -> OpenClawMotionActivityPayload {
        OpenClawMotionActivityPayload(activities: [])
    }

    func pedometer(
        params _: OpenClawPedometerParams
    ) async throws -> OpenClawPedometerPayload {
        OpenClawPedometerPayload(
            startISO: "2026-01-01T00:00:00Z",
            endISO: "2026-01-01T01:00:00Z",
            numberOfSteps: 0,
            distance: nil,
            floorsAscended: nil,
            floorsDescended: nil)
    }
}

// MARK: - Error-throwing mock

private final class ErrorReminders: RemindersServicing,
    @unchecked Sendable
{
    func list(
        params _: OpenClawRemindersListParams
    ) async throws -> OpenClawRemindersListPayload {
        throw NSError(
            domain: "test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "REMINDERS_PERMISSION_REQUIRED",
            ])
    }

    func add(
        params _: OpenClawRemindersAddParams
    ) async throws -> OpenClawRemindersAddPayload {
        throw NSError(
            domain: "test",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "REMINDERS_PERMISSION_REQUIRED",
            ])
    }
}

// MARK: - Tests

@Suite struct DeviceToolBridgeTests {
    @MainActor
    private func makeBridge(
        reminders: any RemindersServicing = MockReminders(),
        calendar: any CalendarServicing = MockCalendar(),
        contacts: any ContactsServicing = MockContacts(),
        location: any LocationServicing = MockLocation(),
        photos: any PhotosServicing = MockPhotos(),
        camera: any CameraServicing = MockCamera(),
        motion: any MotionServicing = MockMotion()
    ) -> DeviceToolBridgeImpl {
        DeviceToolBridgeImpl(
            reminders: reminders,
            calendar: calendar,
            contacts: contacts,
            location: location,
            photos: photos,
            camera: camera,
            motion: motion)
    }

    @Test func supportedCommandsReturnsAll() async {
        let bridge = await makeBridge()
        let commands = bridge.supportedCommands()
        #expect(commands.count == 11)
        #expect(commands.contains("reminders.list"))
        #expect(commands.contains("calendar.events"))
        #expect(commands.contains("contacts.search"))
        #expect(commands.contains("location.get"))
        #expect(commands.contains("photos.latest"))
        #expect(commands.contains("camera.snap"))
        #expect(commands.contains("motion.activity"))
        #expect(commands.contains("motion.pedometer"))
    }

    @Test func executeRoutesRemindersListCorrectly() async {
        let mockReminders = MockReminders()
        let bridge = await makeBridge(
            reminders: mockReminders)
        let result = await bridge.execute(
            command: "reminders.list",
            params: nil)
        #expect(result.error == nil)
        #expect(
            result.payload.objectValue?["ok"]?.boolValue
                == true)
        #expect(mockReminders.listCallCount == 1)
    }

    @Test func executeReturnsErrorForUnknownCommand() async {
        let bridge = await makeBridge()
        let result = await bridge.execute(
            command: "unknown.command",
            params: nil)
        #expect(result.error != nil)
        #expect(
            result.error?.contains("unsupported") == true)
    }

    @Test func executeHandlesServiceError() async {
        let bridge = await makeBridge(
            reminders: ErrorReminders())
        let result = await bridge.execute(
            command: "reminders.list",
            params: nil)
        #expect(result.error != nil)
        #expect(
            result.error?.contains(
                "REMINDERS_PERMISSION_REQUIRED") == true)
    }
}
