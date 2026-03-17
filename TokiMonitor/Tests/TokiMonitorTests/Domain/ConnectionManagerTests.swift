import Testing
@testable import TokiMonitor

@Suite("ConnectionState")
struct ConnectionStateTests {

    @Test("Initial state is disconnected")
    func initialState() {
        let state = ConnectionState.disconnected
        #expect(!state.isConnected)
    }

    @Test("Connected state reports isConnected")
    func connectedState() {
        let state = ConnectionState.connected
        #expect(state.isConnected)
    }

    @Test("Reconnecting state is not connected")
    func reconnectingState() {
        let state = ConnectionState.reconnecting(attempt: 1, maxAttempts: 3)
        #expect(!state.isConnected)
    }

    @Test("ConnectionState equality")
    func equality() {
        #expect(ConnectionState.connected == ConnectionState.connected)
        #expect(ConnectionState.disconnected == ConnectionState.disconnected)
        #expect(
            ConnectionState.reconnecting(attempt: 2, maxAttempts: 3)
            == ConnectionState.reconnecting(attempt: 2, maxAttempts: 3)
        )
        #expect(
            ConnectionState.reconnecting(attempt: 1, maxAttempts: 3)
            != ConnectionState.reconnecting(attempt: 2, maxAttempts: 3)
        )
    }
}
