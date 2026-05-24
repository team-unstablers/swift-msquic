//
//  main.swift
//  SwiftMsQuicExample
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuic
import os

// MARK: - Error helpers

enum EchoExampleError: Error, CustomStringConvertible {
    case serverCertificateGenerationFailed(String)
    case datagramSendNotEnabled
    case datagramEchoTimeout
    case datagramEchoMismatch
    case streamEchoTimeout
    case streamEchoMismatch

    var description: String {
        switch self {
        case .serverCertificateGenerationFailed(let reason):
            return "Failed to generate self-signed certificate: \(reason)"
        case .datagramSendNotEnabled:
            return "Datagram send was not enabled within the deadline"
        case .datagramEchoTimeout:
            return "Datagram echo timed out"
        case .datagramEchoMismatch:
            return "Datagram echo payload did not match"
        case .streamEchoTimeout:
            return "Stream echo timed out"
        case .streamEchoMismatch:
            return "Stream echo payload did not match"
        }
    }
}

// MARK: - EchoServer

/// A minimal QUIC echo server built on top of `SwiftMsQuic`.
///
/// This example is intentionally small: it demonstrates how to host a
/// connection registry inside an actor and how to bridge MsQuic's
/// C-callback driven API (which fires on arbitrary worker threads) into
/// actor-isolated state via `Task { await self.register(...) }` hops.
actor EchoServer {
    private let registration: QuicRegistration
    private let configuration: QuicConfiguration
    private let listener: QuicListener
    private var activeConnections: [ObjectIdentifier: QuicConnection] = [:]
    private var isShuttingDown = false

    init() throws {
        self.registration = try QuicRegistration(
            config: .init(appName: "MsQuicEchoServer", executionProfile: .lowLatency)
        )

        var settings = QuicSettings()
        settings.peerBidiStreamCount = 100
        settings.idleTimeoutMs = 30_000
        settings.datagramReceiveEnabled = true

        self.configuration = try QuicConfiguration(
            registration: registration,
            alpnBuffers: ["echo"],
            settings: settings
        )

        try Self.ensureSelfSignedCertificate(certPath: "server.crt", keyPath: "server.key")
        try configuration.loadCredential(
            .init(
                type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
                flags: []
            )
        )

        self.listener = try QuicListener(registration: registration)
    }

    func start(port: UInt16) throws {
        // Capture Sendable copies so the `@Sendable` MsQuic callbacks don't
        // need to touch `self` synchronously. Actor hops happen via
        // `Task { await self.register(...) }` below.
        let config = self.configuration

        listener.onNewConnection { [weak self] _, info in
            print("[Server] New connection from \(info.remoteAddress)")

            let connection = try info.accept(configuration: config) { [weak self] _, _, stream, flags in
                // The stream handler runs non-isolated; forward to the
                // actor so the per-stream state lives inside EchoServer.
                // `[weak self]` is repeated on the inner closure so that
                // each closure captures `self` independently instead of
                // sharing a mutable capture with the outer `onNewConnection`
                // closure.
                await self?.handle(stream: stream, flags: flags)
            }

            // Wire connection-level events (lifecycle + datagrams) onto
            // actor-isolated methods. `onEvent` is synchronous so we
            // hop via Task for any work that needs actor isolation.
            connection.onEvent { [weak self] conn, event in
                switch event {
                case .datagramStateChanged(let sendEnabled, let maxSendLength):
                    print("[Server] Datagram state changed: enabled=\(sendEnabled), maxSendLength=\(maxSendLength)")

                case .datagramReceived(let buffer, _):
                    let data = buffer.data
                    let msg = String(data: data, encoding: .utf8) ?? "binary(\(data.count) bytes)"
                    print("[Server] Datagram received: \(msg)")
                    Task {
                        do {
                            try await conn.sendDatagram(data, flags: .dgramPriority)
                            print("[Server] Datagram echo sent")
                        } catch {
                            print("[Server] Datagram echo failed: \(error)")
                        }
                    }

                case .shutdownComplete:
                    print("[Server] Connection shutdown complete")
                    Task { [weak self] in
                        await self?.unregister(connection: conn)
                    }

                default:
                    break
                }
                return .success
            }

            // Register on the actor from the callback thread.
            Task { [weak self] in
                await self?.register(connection: connection)
            }

            return connection
        }

        try listener.start(alpnBuffers: ["echo"], localAddress: QuicAddress(port: port))
        print("[Server] Listening on \(port)")
    }

    func stop() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true

        print("[Server] Stopping listener...")
        await listener.stop()
        print("[Server] Listener stopped")

        let connections = Array(activeConnections.values)
        activeConnections.removeAll()
        if !connections.isEmpty {
            print("[Server] Shutting down \(connections.count) active connection(s)...")
        }
        for connection in connections {
            await connection.shutdown()
        }
    }

    // MARK: Actor-isolated helpers

    private func register(connection: QuicConnection) {
        guard !isShuttingDown else {
            // If the server is already winding down, proactively tear
            // the late-arriving connection down rather than hanging on
            // to it.
            Task { await connection.shutdown() }
            return
        }
        activeConnections[ObjectIdentifier(connection)] = connection
    }

    private func unregister(connection: QuicConnection) {
        activeConnections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private func handle(stream: QuicStream, flags: QuicStreamOpenFlags) async {
        let direction = flags.contains(.unidirectional) ? "unidirectional" : "bidirectional"
        print("[Server] Stream started (\(direction))")
        do {
            for try await data in stream.receive {
                let msg = String(data: data, encoding: .utf8) ?? "binary"
                print("[Server] Received: \(msg)")
                try await stream.send(data) // Echo
            }
            print("[Server] Stream closed by peer")
            await stream.shutdown(flags: .graceful)
        } catch {
            print("[Server] Stream error: \(error)")
        }
    }

    // MARK: Certificate bootstrap

    private static func ensureSelfSignedCertificate(certPath: String, keyPath: String) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: certPath) || !fm.fileExists(atPath: keyPath) else {
            return
        }

        print("[Server] Certificate not found. Generating self-signed cert...")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = [
            "req", "-x509", "-newkey", "rsa:2048",
            "-keyout", keyPath, "-out", certPath,
            "-days", "365", "-nodes", "-subj", "/CN=localhost",
        ]
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw EchoExampleError.serverCertificateGenerationFailed("\(error)")
        }

        guard process.terminationStatus == 0 else {
            throw EchoExampleError.serverCertificateGenerationFailed(
                "openssl exited with status \(process.terminationStatus)"
            )
        }
    }
}

// MARK: - EchoClient

/// A one-shot QUIC echo client that exercises the same datagram and
/// stream surface the server supports.
///
/// Unlike `EchoServer`, the client has no long-lived registry — the
/// actor here mostly exists to own the inbound datagram stream and to
/// keep the `connection.onEvent` callback's shared state (whether
/// datagram send is enabled, the pending datagram stream) neatly
/// isolated.
actor EchoClient {
    private let registration: QuicRegistration
    private let configuration: QuicConfiguration
    private var datagramSendEnabled = false
    private var pendingDatagramContinuation: CheckedContinuation<Data, Error>?
    private var pendingDatagramDeadlineTask: Task<Void, Never>?

    init() throws {
        self.registration = try QuicRegistration(
            config: .init(appName: "MsQuicEchoClient", executionProfile: .lowLatency)
        )

        var settings = QuicSettings()
        settings.datagramReceiveEnabled = true

        self.configuration = try QuicConfiguration(
            registration: registration,
            alpnBuffers: ["echo"],
            settings: settings
        )
        try configuration.loadCredential(
            .init(type: .none, flags: [.client, .noCertificateValidation])
        )
    }

    func run(serverName: String, serverPort: UInt16) async throws {
        let connection = try QuicConnection(registration: registration)

        connection.onEvent { [weak self] _, event in
            guard let self else { return .success }
            switch event {
            case .datagramStateChanged(let sendEnabled, let maxSendLength):
                print("[Client] Datagram state changed: enabled=\(sendEnabled), maxSendLength=\(maxSendLength)")
                Task { await self.setDatagramSendEnabled(sendEnabled) }

            case .datagramReceived(let buffer, _):
                let data = buffer.data
                let msg = String(data: data, encoding: .utf8) ?? "binary(\(data.count) bytes)"
                print("[Client] Datagram received: \(msg)")
                Task { await self.deliverDatagram(data) }

            case .datagramSendStateChanged(let state):
                print("[Client] Datagram send state: \(state)")

            default:
                break
            }
            return .success
        }

        print("[Client] Connecting...")
        try await connection.start(
            configuration: configuration,
            serverName: serverName,
            serverPort: serverPort
        )
        print("[Client] Connected!")

        try await waitForDatagramSendReady(timeoutNanos: 2_000_000_000)

        // Datagram echo round-trip
        let datagramMessage = "Hello via DATAGRAM"
        let expectedDatagram = Data(datagramMessage.utf8)
        print("[Client] Sending datagram: \(datagramMessage)")
        try await connection.sendDatagram(expectedDatagram, flags: .dgramPriority)
        print("[Client] Datagram send completed")

        let echoedDatagram = try await receiveDatagram(timeoutNanos: 2_000_000_000)
        let echoedMsg = String(data: echoedDatagram, encoding: .utf8) ?? "binary(\(echoedDatagram.count) bytes)"
        print("[Client] Datagram echo received: \(echoedMsg)")
        if echoedDatagram != expectedDatagram {
            throw EchoExampleError.datagramEchoMismatch
        }

        // Stream echo round-trip
        let stream = try connection.openStream(flags: .none)
        try await stream.start()
        print("[Client] Stream started")

        let streamMessage = "Hello MsQuic Swift!"
        let expectedStreamEcho = Data(streamMessage.utf8)
        print("[Client] Sending: \(streamMessage)")
        try await stream.send(expectedStreamEcho, flags: .fin)

        print("[Client] Waiting for echo...")
        let receivedStreamEcho = try await Self.collectStreamEcho(
            from: stream,
            expectedByteCount: expectedStreamEcho.count,
            timeoutNanos: 2_000_000_000
        )
        if receivedStreamEcho != expectedStreamEcho {
            throw EchoExampleError.streamEchoMismatch
        }
        print("[Client] Stream finished")

        await stream.shutdown(flags: .graceful)
        print("[Client] Stream shutdown complete")

        await connection.shutdown()
        print("[Client] Connection shutdown")
    }

    // MARK: Actor-isolated helpers

    private func setDatagramSendEnabled(_ enabled: Bool) {
        datagramSendEnabled = enabled
    }

    private func deliverDatagram(_ data: Data) {
        guard let continuation = pendingDatagramContinuation else { return }
        pendingDatagramContinuation = nil
        pendingDatagramDeadlineTask?.cancel()
        pendingDatagramDeadlineTask = nil
        continuation.resume(returning: data)
    }

    private func failPendingDatagram(_ error: Error) {
        guard let continuation = pendingDatagramContinuation else { return }
        pendingDatagramContinuation = nil
        pendingDatagramDeadlineTask = nil
        continuation.resume(throwing: error)
    }

    private func waitForDatagramSendReady(timeoutNanos: UInt64) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNanos
        while !datagramSendEnabled && DispatchTime.now().uptimeNanoseconds < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !datagramSendEnabled {
            throw EchoExampleError.datagramSendNotEnabled
        }
    }

    private func receiveDatagram(timeoutNanos: UInt64) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            pendingDatagramContinuation = continuation
            pendingDatagramDeadlineTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanos)
                guard !Task.isCancelled else { return }
                await self?.failPendingDatagram(EchoExampleError.datagramEchoTimeout)
            }
        }
    }

    private static func collectStreamEcho(
        from stream: QuicStream,
        expectedByteCount: Int,
        timeoutNanos: UInt64
    ) async throws -> Data {
        try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var received = Data()
                for try await data in stream.receive {
                    let msg = String(data: data, encoding: .utf8) ?? "?"
                    print("[Client] Echo received: \(msg)")
                    received.append(data)
                    if received.count >= expectedByteCount {
                        break
                    }
                }
                return received
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanos)
                return nil
            }

            guard let first = try await group.next(), let received = first else {
                group.cancelAll()
                throw EchoExampleError.streamEchoTimeout
            }
            group.cancelAll()
            return received
        }
    }
}

// MARK: - Entry point

@main
struct App {
    static func main() async throws {
        print("Initializing MsQuic...")
        try SwiftMsQuicAPI.open().throwIfFailed()
        defer {
            print("Closing MsQuic...")
            SwiftMsQuicAPI.close()
        }

        let args = CommandLine.arguments
        if args.contains("--server") {
            try await runServerOnly()
        } else if args.contains("--client") {
            try await runClientOnly()
        } else {
            print("Running both server and client...")
            try await runServerAndClient()
            print("Test finished.")
        }
    }

    private static func runServerOnly() async throws {
        print("[Server] Starting...")
        let server = try EchoServer()
        try await server.start(port: 4567)

        // Serve until the process receives a signal. In this minimal
        // example we simply sleep forever; production code should
        // install a signal handler and call `server.stop()`.
        while true {
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private static func runClientOnly() async throws {
        print("[Client] Starting...")
        let client = try EchoClient()
        try await client.run(serverName: "localhost", serverPort: 4567)
        print("[Main] Client test passed")
    }

    private static func runServerAndClient() async throws {
        print("[Server] Starting...")
        let server = try EchoServer()
        try await server.start(port: 4567)

        // Let the server settle before connecting.
        try await Task.sleep(nanoseconds: 1_000_000_000)

        do {
            print("[Client] Starting...")
            let client = try EchoClient()
            try await client.run(serverName: "localhost", serverPort: 4567)
        } catch {
            await server.stop()
            throw error
        }

        await server.stop()
    }
}
