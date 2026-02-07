//
//  main.swift
//  SwiftMsQuicExample
//
//  Created by Gyuhwan Park on 2/3/26.
//

import Foundation
import SwiftMsQuicHelper
import os

@main
struct App {
    // Keep server-side connections alive until shutdown
    static let connectionLock = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: QuicConnection]())

    static func failAndExit(_ message: String, error: Error? = nil) -> Never {
        if let error {
            print("\(message): \(error)")
        } else {
            print(message)
        }
        exit(1)
    }

    static func assertOrExit(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            failAndExit("[ASSERT] \(message)")
        }
    }

    static func shutdownAllServerConnections() async {
        let connections = connectionLock.withLock { Array($0.values) }
        if !connections.isEmpty {
            print("[Server] Shutting down \(connections.count) active connection(s)...")
        }
        for connection in connections {
            await connection.shutdown()
        }
        connectionLock.withLock { $0.removeAll() }
    }
    
    static func main() async throws {
        print("Initializing MsQuic...")
        try SwiftMsQuicAPI.open().throwIfFailed()
        defer { 
            print("Closing MsQuic...")
            SwiftMsQuicAPI.close() 
        }
        
        let args = CommandLine.arguments
        if args.contains("--server") {
            do {
                try await runServer()
            } catch {
                failAndExit("[Main] Server failed", error: error)
            }
        } else if args.contains("--client") {
            do {
                try await runClient()
                print("[Main] Client test passed")
            } catch {
                failAndExit("[Main] Client failed", error: error)
            }
        } else {
            // Run both
            print("Running both server and client...")
            
            // Start server task
            let serverTask = Task {
                do {
                    try await runServer()
                } catch is CancellationError {
                    // Expected on shutdown in run-both mode.
                } catch {
                    failAndExit("[Main] Server task failed", error: error)
                }
            }
            
            // Give server a moment to start
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Run client
            do {
                try await runClient()
            } catch {
                failAndExit("[Main] Client failed", error: error)
            }

            // Client finished, stop server and exit.
            serverTask.cancel()
            _ = await serverTask.result
            print("Test finished.")
        }
    }
    
    static func runServer() async throws {
        print("[Server] Starting...")
        let reg = try QuicRegistration(config: .init(appName: "MsQuicEchoServer", executionProfile: .lowLatency))
        
        var settings = QuicSettings()
        settings.peerBidiStreamCount = 100
        settings.idleTimeoutMs = 30000 // 30 sec idle timeout
        settings.datagramReceiveEnabled = true
        
        let config = try QuicConfiguration(registration: reg, alpnBuffers: ["echo"], settings: settings)
        
        // Try to load cert
        let certPath = "server.crt"
        let keyPath = "server.key"
        let fm = FileManager.default
        
        if !fm.fileExists(atPath: certPath) || !fm.fileExists(atPath: keyPath) {
            print("[Server] Certificate not found. Generating self-signed cert...")
            
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
            process.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-keyout", keyPath, "-out", certPath, "-days", "365", "-nodes", "-subj", "/CN=localhost"]
            
            // Suppress output
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            
            do {
                try process.run()
                process.waitUntilExit()
                
                if process.terminationStatus != 0 {
                    print("[Server] Failed to generate cert. OpenSSL required.")
                    throw QuicError.internalError
                }
            } catch {
                print("[Server] Failed to run openssl: \(error)")
                throw error
            }
        }
        
        try config.loadCredential(.init(
            type: .certificateFile(certPath: certPath, keyPath: keyPath),
            flags: []
        ))
        
        let listener = try QuicListener(registration: reg)
        
        listener.onNewConnection { listener, info in
            print("[Server] New connection from \(info.remoteAddress)")
            
            let connection = try QuicConnection(handle: info.connection, configuration: config) { conn, stream, flags in
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
            
            // Retain connection to prevent premature deallocation
            connectionLock.withLock { $0[ObjectIdentifier(connection)] = connection }
            
            connection.onEvent { conn, event in
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
                    // Release asynchronously to avoid calling ConnectionClose inside the callback
                    Task {
                        connectionLock.withLock { $0.removeValue(forKey: ObjectIdentifier(conn)) }
                    }
                    
                default:
                    break
                }
                return .success
            }
            
            return connection
        }
        
        try listener.start(alpnBuffers: ["echo"], localAddress: QuicAddress(port: 4567))
        print("[Server] Listening on 4567")

        // Keep running until canceled (run-both mode) or process termination (server-only mode).
        do {
            while !Task.isCancelled {
                try await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch is CancellationError {
            // Expected when canceled.
        }

        print("[Server] Stopping listener...")
        await listener.stop()
        print("[Server] Listener stopped")
        await shutdownAllServerConnections()
    }
    
    static func runClient() async throws {
        print("[Client] Starting...")
        let reg = try QuicRegistration(config: .init(appName: "MsQuicEchoClient", executionProfile: .lowLatency))
        var settings = QuicSettings()
        settings.datagramReceiveEnabled = true
        let config = try QuicConfiguration(registration: reg, alpnBuffers: ["echo"], settings: settings)
        // No cert check for test
        try config.loadCredential(.init(type: .none, flags: [.client, .noCertificateValidation]))
        
        let connection = try QuicConnection(registration: reg)
        let datagramSendEnabledLock = OSAllocatedUnfairLock(initialState: false)
        let (datagramStream, datagramContinuation) = AsyncStream<Data>.makeStream()

        connection.onEvent { _, event in
            switch event {
            case .datagramStateChanged(let sendEnabled, let maxSendLength):
                print("[Client] Datagram state changed: enabled=\(sendEnabled), maxSendLength=\(maxSendLength)")
                datagramSendEnabledLock.withLock { $0 = sendEnabled }

            case .datagramReceived(let buffer, _):
                let data = buffer.data
                let msg = String(data: data, encoding: .utf8) ?? "binary(\(data.count) bytes)"
                print("[Client] Datagram received: \(msg)")
                datagramContinuation.yield(data)

            case .datagramSendStateChanged(let state, _):
                print("[Client] Datagram send state: \(state)")

            default:
                break
            }
            return .success
        }

        print("[Client] Connecting...")
        try await connection.start(configuration: config, serverName: "localhost", serverPort: 4567)
        print("[Client] Connected!")

        let datagramReadyDeadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
        while !datagramSendEnabledLock.withLock({ $0 }) && DispatchTime.now().uptimeNanoseconds < datagramReadyDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        assertOrExit(datagramSendEnabledLock.withLock({ $0 }), "Datagram send not enabled after connect")

        let datagramMessage = "Hello via DATAGRAM"
        let expectedDatagram = Data(datagramMessage.utf8)
        print("[Client] Sending datagram: \(datagramMessage)")
        try await connection.sendDatagram(expectedDatagram, flags: .dgramPriority)
        print("[Client] Datagram send completed")
        
        let echoedDatagram = await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                for await data in datagramStream {
                    return data
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        
        if let echoedDatagram {
            let msg = String(data: echoedDatagram, encoding: .utf8) ?? "binary(\(echoedDatagram.count) bytes)"
            print("[Client] Datagram echo received: \(msg)")
            assertOrExit(echoedDatagram == expectedDatagram, "Datagram echo mismatch")
        } else {
            failAndExit("[Client] Datagram echo timeout (2s)")
        }
        
        let stream = try connection.openStream(flags: .none)
        try await stream.start()
        print("[Client] Stream started")
        
        let message = "Hello MsQuic Swift!"
        let expectedStreamEcho = Data(message.utf8)
        print("[Client] Sending: \(message)")
        try await stream.send(Data(message.utf8), flags: .fin) // Send FIN to indicate end of write
        
        print("[Client] Waiting for echo...")
        let receivedStreamEcho = try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask {
                var received = Data()
                for try await data in stream.receive {
                    let msg = String(data: data, encoding: .utf8) ?? "?"
                    print("[Client] Echo received: \(msg)")
                    received.append(data)
                    if received.count >= expectedStreamEcho.count {
                        break
                    }
                }
                return received
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }

            let first = try await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let receivedStreamEcho else {
            failAndExit("[Client] Stream echo timeout (2s)")
        }
        assertOrExit(receivedStreamEcho == expectedStreamEcho, "Stream echo mismatch")
        print("[Client] Stream finished")
        
        datagramContinuation.finish()
        await connection.shutdown()
        print("[Client] Connection shutdown")
    }
}
