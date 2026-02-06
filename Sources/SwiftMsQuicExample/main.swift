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
    
    static func main() async throws {
        print("Initializing MsQuic...")
        try SwiftMsQuicAPI.open().throwIfFailed()
        defer { 
            print("Closing MsQuic...")
            SwiftMsQuicAPI.close() 
        }
        
        let args = CommandLine.arguments
        if args.contains("--server") {
            try await runServer()
        } else if args.contains("--client") {
            try await runClient()
        } else {
            // Run both
            print("Running both server and client...")
            
            // Start server task
            let _ = Task {
                do {
                    try await runServer()
                } catch {
                    print("Server failed: \(error)")
                    exit(1)
                }
            }
            
            // Give server a moment to start
            try await Task.sleep(nanoseconds: 1_000_000_000)
            
            // Run client
            try await runClient()
            
            // Client finished, kill server (in a real app, signal it)
            // But server task is sleeping forever.
            // We can just exit.
            print("Test finished.")
        }
    }
    
    static func runServer() async throws {
        print("[Server] Starting...")
        let reg = try QuicRegistration(config: .init(appName: "MsQuicEchoServer", executionProfile: .lowLatency))
        
        var settings = QuicSettings()
        settings.peerBidiStreamCount = 100
        settings.idleTimeoutMs = 30000 // 30 sec idle timeout
        
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
                if case .shutdownComplete = event {
                    print("[Server] Connection shutdown complete")
                    // Release asynchronously to avoid calling ConnectionClose inside the callback
                    Task {
                        connectionLock.withLock { $0.removeValue(forKey: ObjectIdentifier(conn)) }
                    }
                }
                return .success
            }
            
            return connection
        }
        
        try listener.start(alpnBuffers: ["echo"], localAddress: QuicAddress(port: 4567))
        print("[Server] Listening on 4567")
        
        // Keep running forever
        try await Task.sleep(nanoseconds: 100_000_000_000_000) 
    }
    
    static func runClient() async throws {
        print("[Client] Starting...")
        let reg = try QuicRegistration(config: .init(appName: "MsQuicEchoClient", executionProfile: .lowLatency))
        let config = try QuicConfiguration(registration: reg, alpnBuffers: ["echo"])
        // No cert check for test
        try config.loadCredential(.init(type: .none, flags: [.client, .noCertificateValidation]))
        
        let connection = try QuicConnection(registration: reg)
        print("[Client] Connecting...")
        try await connection.start(configuration: config, serverName: "localhost", serverPort: 4567)
        print("[Client] Connected!")
        
        let stream = try connection.openStream(flags: .none)
        try await stream.start()
        print("[Client] Stream started")
        
        let message = "Hello MsQuic Swift!"
        print("[Client] Sending: \(message)")
        try await stream.send(Data(message.utf8), flags: .fin) // Send FIN to indicate end of write
        
        print("[Client] Waiting for echo...")
        for try await data in stream.receive {
            let msg = String(data: data, encoding: .utf8) ?? "?"
            print("[Client] Echo received: \(msg)")
        }
        print("[Client] Stream finished")
        
        await connection.shutdown()
        print("[Client] Connection shutdown")
    }
}
