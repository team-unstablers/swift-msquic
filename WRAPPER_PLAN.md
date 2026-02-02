# SwiftMsQuicAPI Wrapper Implementation Plan

`MsQuic`은 C 기반의 비동기 이벤트 드리븐 라이브러리이므로, Swift의 객체 지향 모델과 메모리 관리 모델(ARC)에 맞게 래핑하는 것이 핵심입니다.

## 설계 원칙

- **Class 기반 설계**: 모든 HQUIC 핸들 래퍼는 `class`로 구현하여 `CInteropHandle`을 채택하고, ARC를 활용한 자동 리소스 관리
- **Swift Concurrency**: `async/await` 패턴을 사용하여 콜백 기반 API를 현대적인 Swift 스타일로 제공
- **Swift enum**: C의 union 기반 이벤트 구조체를 Swift enum (associated value)으로 깔끔하게 매핑
- **throws 기반 에러 처리**: `QuicError` enum을 정의하고, 실패 시 throw

---

## Phase 1. 기반 인프라 (Foundation)

### 1.1 에러 처리 인프라

#### `QuicError.swift`
```swift
public enum QuicError: Error {
    case notInitialized
    case invalidParameter
    case invalidState
    case outOfMemory
    case connectionRefused
    case connectionTimeout
    case handshakeFailure
    case tlsError(alert: Int32)
    case protocolError
    case streamLimitReached
    case unknown(status: QuicStatus)

    init(status: QuicStatus) {
        // QuicStatus -> QuicError 매핑
    }
}
```

#### `QuicStatus` 확장
```swift
extension QuicStatus {
    func throwIfFailed() throws {
        if failed {
            throw QuicError(status: self)
        }
    }
}
```

### 1.2 Base Class 정의

#### `QuicObject.swift`
모든 MsQuic 래퍼 클래스의 공통 부모입니다.

```swift
public class QuicObject: CInteropHandle {
    /// 내부 HQUIC 핸들
    internal var handle: HQUIC?

    /// QUIC_API_TABLE 접근 편의 프로퍼티
    internal var api: QUIC_API_TABLE { SwiftMsQuicAPI.MsQuic }

    /// 핸들이 유효한지 확인
    public var isValid: Bool { handle != nil }

    deinit {
        // 서브클래스에서 오버라이드하여 적절한 Close 호출
    }
}
```

### 1.3 QUIC_BUFFER 래핑

#### `QuicBuffer.swift`
C의 `QUIC_BUFFER`와 Swift `Data` 간의 상호 변환을 처리합니다.

```swift
public struct QuicBuffer {
    public let data: Data

    public init(_ data: Data) { ... }
    public init(_ bytes: [UInt8]) { ... }
    public init(_ string: String, encoding: String.Encoding = .utf8) { ... }

    /// C API 호출 시 사용
    internal func withUnsafeQuicBuffer<T>(_ body: (UnsafePointer<QUIC_BUFFER>) throws -> T) rethrows -> T
}

/// 여러 버퍼를 한 번에 처리 (ALPN 등)
internal func withQuicBufferArray<T>(_ buffers: [QuicBuffer], _ body: (UnsafePointer<QUIC_BUFFER>, UInt32) throws -> T) rethrows -> T
```

---

## Phase 2. Configuration & Registration (설정 계층)

### 2.1 Registration

#### `QuicRegistration.swift`
앱 등록을 관리하는 클래스입니다.

```swift
public final class QuicRegistration: QuicObject {
    public init(config: QuicRegistrationConfig) throws {
        // MsQuic.RegistrationOpen 호출
    }

    /// 등록 종료 (graceful shutdown)
    public func shutdown(silent: Bool = false) {
        // MsQuic.RegistrationShutdown 호출
    }

    deinit {
        // MsQuic.RegistrationClose 호출
    }
}
```

### 2.2 Configuration

#### `QuicConfiguration.swift`
TLS 설정, ALPN, 타임아웃 등을 관리합니다.

```swift
public final class QuicConfiguration: QuicObject {
    public let registration: QuicRegistration

    public init(
        registration: QuicRegistration,
        alpnBuffers: [String],
        settings: QuicSettings? = nil
    ) throws {
        // MsQuic.ConfigurationOpen 호출
    }

    /// TLS 인증서 로드 (서버용)
    public func loadCredential(_ credential: QuicCredentialConfig) throws {
        // MsQuic.ConfigurationLoadCredential 호출
    }

    deinit {
        // MsQuic.ConfigurationClose 호출
    }
}
```

#### `QuicSettings.swift`
QUIC 설정 값들을 Swift 스타일로 래핑합니다.

```swift
public struct QuicSettings {
    public var maxBytesPerKey: UInt64?
    public var handshakeIdleTimeoutMs: UInt64?
    public var idleTimeoutMs: UInt64?
    public var maxAckDelayMs: UInt32?
    public var disconnectTimeoutMs: UInt32?
    public var keepAliveIntervalMs: UInt32?
    public var peerBidiStreamCount: UInt16?
    public var peerUnidiStreamCount: UInt16?
    // ... 기타 설정

    public init() { }

    /// C 구조체로 변환
    internal func withUnsafeSettings<T>(_ body: (UnsafePointer<QUIC_SETTINGS>) throws -> T) rethrows -> T
}
```

#### `QuicCredentialConfig.swift`
TLS 인증서 설정을 관리합니다.

```swift
public enum QuicCredentialType {
    /// 인증서 파일 경로 (PEM 등)
    case certificateFile(certPath: String, keyPath: String)

    /// PKCS#12 파일
    case certificatePkcs12(path: String, password: String?)

    /// 클라이언트 - 인증서 검증 안 함 (개발용)
    case none
}

public struct QuicCredentialConfig {
    public let type: QuicCredentialType
    public let flags: QuicCredentialFlags

    public init(type: QuicCredentialType, flags: QuicCredentialFlags = []) { ... }

    /// C 구조체로 변환
    internal func withUnsafeCredentialConfig<T>(_ body: (UnsafePointer<QUIC_CREDENTIAL_CONFIG>) throws -> T) rethrows -> T
}

public struct QuicCredentialFlags: OptionSet {
    public static let none = QuicCredentialFlags([])
    public static let client = QuicCredentialFlags(rawValue: QUIC_CREDENTIAL_FLAG_CLIENT)
    public static let noServerCertificateValidation = QuicCredentialFlags(rawValue: QUIC_CREDENTIAL_FLAG_NO_CERTIFICATE_VALIDATION)
    // ... 기타 플래그
}
```

---

## Phase 3. Callback 인프라 & Event 정의

### 3.1 Event Enum 정의

#### `QuicListenerEvent.swift`
```swift
public enum QuicListenerEvent {
    case newConnection(info: NewConnectionInfo)
    case stopComplete

    public struct NewConnectionInfo {
        public let connection: HQUIC  // 아직 래핑되지 않은 raw 핸들
        public let serverName: String?
        public let negotiatedAlpn: String?
    }
}
```

#### `QuicConnectionEvent.swift`
```swift
public enum QuicConnectionEvent {
    case connected(negotiatedAlpn: String?, resumption: Bool)
    case shutdownInitiatedByTransport(status: QuicStatus, errorCode: UInt64)
    case shutdownInitiatedByPeer(errorCode: UInt64)
    case shutdownComplete(handshakeCompleted: Bool, peerAcknowledged: Bool)
    case localAddressChanged(address: QuicAddress)
    case peerAddressChanged(address: QuicAddress)
    case peerStreamStarted(stream: HQUIC, flags: QuicStreamOpenFlags)
    case streamsAvailable(bidirectional: UInt16, unidirectional: UInt16)
    case datagramReceived(data: Data)
    case datagramStateChanged(sendEnabled: Bool, maxLength: UInt16?)
    case datagramSendStateChanged(state: QuicDatagramSendState, context: UnsafeMutableRawPointer?)
    case resumed(data: Data?)
    case resumptionTicketReceived(ticket: Data)
    case peerCertificateReceived(certificate: QuicCertificate?, chain: QuicCertificateChain?)
}
```

#### `QuicStreamEvent.swift`
```swift
public enum QuicStreamEvent {
    case startComplete(status: QuicStatus, id: UInt64, peerAccepted: Bool)
    case receive(data: Data, flags: QuicReceiveFlags)
    case sendComplete(canceled: Bool, context: UnsafeMutableRawPointer?)
    case peerSendShutdown
    case peerSendAborted(errorCode: UInt64)
    case peerReceiveAborted(errorCode: UInt64)
    case sendShutdownComplete(graceful: Bool)
    case shutdownComplete(connectionShutdown: Bool, connectionShutdownByApp: Bool, connectionErrorCode: UInt64)
    case idealSendBufferSize(byteCount: UInt64)
    case peerAccepted
    case cancelOnLoss(errorCode: UInt64)
}
```

### 3.2 Callback Thunk 함수

#### `QuicCallbackThunks.swift`
C 콜백 함수 포인터로 사용할 static 함수들입니다.

```swift
/// Listener 콜백 thunk
internal func quicListenerCallback(
    _ listener: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_LISTENER_EVENT>?
) -> QUIC_STATUS {
    guard let context = context, let event = event else {
        return QUIC_STATUS_INVALID_PARAMETER
    }
    let listener = QuicListener.fromCInteropHandle(context)
    return listener.handleEvent(event.pointee).rawValue
}

/// Connection 콜백 thunk
internal func quicConnectionCallback(
    _ connection: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_CONNECTION_EVENT>?
) -> QUIC_STATUS {
    guard let context = context, let event = event else {
        return QUIC_STATUS_INVALID_PARAMETER
    }
    let connection = QuicConnection.fromCInteropHandle(context)
    return connection.handleEvent(event.pointee).rawValue
}

/// Stream 콜백 thunk
internal func quicStreamCallback(
    _ stream: HQUIC?,
    _ context: UnsafeMutableRawPointer?,
    _ event: UnsafeMutablePointer<QUIC_STREAM_EVENT>?
) -> QUIC_STATUS {
    guard let context = context, let event = event else {
        return QUIC_STATUS_INVALID_PARAMETER
    }
    let stream = QuicStream.fromCInteropHandle(context)
    return stream.handleEvent(event.pointee).rawValue
}
```

### 3.3 Event → Swift Enum 변환

#### `QuicEventConverter.swift`
C 이벤트 구조체를 Swift enum으로 변환하는 유틸리티입니다.

```swift
internal enum QuicEventConverter {
    static func convert(_ event: QUIC_LISTENER_EVENT) -> QuicListenerEvent { ... }
    static func convert(_ event: QUIC_CONNECTION_EVENT) -> QuicConnectionEvent { ... }
    static func convert(_ event: QUIC_STREAM_EVENT) -> QuicStreamEvent { ... }
}
```

---

## Phase 4. Listener (서버 역할)

### 4.1 QuicListener

#### `QuicListener.swift`
```swift
public final class QuicListener: QuicObject {
    public let registration: QuicRegistration

    /// 새 연결 수신 시 호출되는 핸들러
    public typealias ConnectionHandler = (QuicListener, QuicListenerEvent.NewConnectionInfo) async throws -> QuicConnection?

    private var connectionHandler: ConnectionHandler?
    private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    public init(registration: QuicRegistration) throws {
        // MsQuic.ListenerOpen 호출
        // context로 self.asCInteropHandle 전달
        // callback으로 quicListenerCallback 전달
    }

    /// 리스닝 시작
    public func start(
        alpnBuffers: [String],
        localAddress: QuicAddress? = nil
    ) async throws {
        // MsQuic.ListenerStart 호출
    }

    /// 리스닝 중지
    public func stop() async {
        // MsQuic.ListenerStop 호출
        // STOP_COMPLETE 이벤트를 기다림
    }

    /// 새 연결 핸들러 설정
    public func onNewConnection(_ handler: @escaping ConnectionHandler) {
        self.connectionHandler = handler
    }

    /// 콜백에서 호출됨
    internal func handleEvent(_ event: QUIC_LISTENER_EVENT) -> QuicStatus {
        let swiftEvent = QuicEventConverter.convert(event)

        switch swiftEvent {
        case .newConnection(let info):
            // connectionHandler 호출하여 연결 수락 여부 결정
            // 수락 시 QuicConnection 인스턴스 생성 및 반환
        case .stopComplete:
            // continuation resume
        }
    }

    deinit {
        // MsQuic.ListenerClose 호출
    }
}
```

### 4.2 QuicAddress

#### `QuicAddress.swift`
```swift
public struct QuicAddress {
    public let family: AddressFamily
    public let ip: String
    public let port: UInt16

    public enum AddressFamily {
        case ipv4
        case ipv6
        case unspecified
    }

    public init(ip: String, port: UInt16) { ... }
    public init(port: UInt16) { ... }  // any address

    /// C 구조체로 변환
    internal func withUnsafeAddress<T>(_ body: (UnsafePointer<QUIC_ADDR>) throws -> T) rethrows -> T
}
```

---

## Phase 5. Connection (연결 관리)

### 5.1 QuicConnection

#### `QuicConnection.swift`
```swift
public final class QuicConnection: QuicObject {
    public enum State {
        case idle
        case connecting
        case connected
        case shuttingDown
        case closed
    }

    public private(set) var state: State = .idle

    /// 클라이언트용 생성자
    public init(registration: QuicRegistration) throws {
        // MsQuic.ConnectionOpen 호출
    }

    /// 서버에서 Listener가 받은 연결을 래핑
    internal init(handle: HQUIC, configuration: QuicConfiguration) {
        // 이미 존재하는 핸들을 래핑
        // MsQuic.ConnectionSetConfiguration 호출
    }

    /// 서버에 연결 (클라이언트)
    public func start(
        configuration: QuicConfiguration,
        serverName: String,
        serverPort: UInt16
    ) async throws {
        // MsQuic.ConnectionStart 호출
        // CONNECTED 이벤트를 기다림
    }

    /// 연결 종료
    public func shutdown(errorCode: UInt64 = 0) async {
        // MsQuic.ConnectionShutdown 호출
        // SHUTDOWN_COMPLETE 이벤트를 기다림
    }

    /// 스트림 생성
    public func openStream(flags: QuicStreamOpenFlags = .none) async throws -> QuicStream {
        // QuicStream 생성 및 반환
    }

    /// 피어가 시작한 스트림 수신 핸들러
    public typealias StreamHandler = (QuicConnection, QuicStream) async -> Void
    public func onPeerStreamStarted(_ handler: @escaping StreamHandler) { ... }

    /// 이벤트 핸들러 (고급 사용자용)
    public typealias EventHandler = (QuicConnection, QuicConnectionEvent) -> QuicStatus
    public func onEvent(_ handler: @escaping EventHandler) { ... }

    /// 콜백에서 호출됨
    internal func handleEvent(_ event: QUIC_CONNECTION_EVENT) -> QuicStatus { ... }

    deinit {
        // MsQuic.ConnectionClose 호출
    }
}
```

### 5.2 스트림 열기 플래그

#### `QuicStreamOpenFlags.swift`
```swift
public struct QuicStreamOpenFlags: OptionSet {
    public let rawValue: UInt32

    public static let none = QuicStreamOpenFlags([])
    public static let unidirectional = QuicStreamOpenFlags(rawValue: QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL)
    public static let zeroCopy = QuicStreamOpenFlags(rawValue: QUIC_STREAM_OPEN_FLAG_0_RTT)
    // ... 기타 플래그
}
```

---

## Phase 6. Stream (데이터 송수신)

### 6.1 QuicStream

#### `QuicStream.swift`
```swift
public final class QuicStream: QuicObject {
    public enum State {
        case idle
        case starting
        case started
        case shuttingDown
        case closed
    }

    public private(set) var state: State = .idle
    public private(set) var streamId: UInt64?

    /// Connection에서 생성
    internal init(connection: QuicConnection, flags: QuicStreamOpenFlags) throws {
        // MsQuic.StreamOpen 호출
    }

    /// 피어가 시작한 스트림 래핑
    internal init(handle: HQUIC) {
        // 이미 존재하는 핸들을 래핑
    }

    /// 스트림 시작
    public func start(flags: QuicStreamStartFlags = .none) async throws {
        // MsQuic.StreamStart 호출
        // START_COMPLETE 이벤트를 기다림
    }

    /// 데이터 전송
    public func send(_ data: Data, flags: QuicSendFlags = .none) async throws {
        // MsQuic.StreamSend 호출
        // SEND_COMPLETE 이벤트를 기다림
    }

    /// 데이터 수신 (AsyncSequence)
    public var receive: AsyncThrowingStream<Data, Error> {
        // RECEIVE 이벤트를 AsyncStream으로 변환
    }

    /// 전송 종료 (half-close)
    public func shutdownSend(errorCode: UInt64 = 0) async {
        // MsQuic.StreamShutdown(QUIC_STREAM_SHUTDOWN_FLAG_GRACEFUL)
    }

    /// 수신 종료
    public func shutdownReceive(errorCode: UInt64 = 0) async {
        // MsQuic.StreamShutdown(QUIC_STREAM_SHUTDOWN_FLAG_ABORT_RECEIVE)
    }

    /// 스트림 완전 종료
    public func shutdown(errorCode: UInt64 = 0) async {
        // MsQuic.StreamShutdown(QUIC_STREAM_SHUTDOWN_FLAG_ABORT)
        // SHUTDOWN_COMPLETE 이벤트를 기다림
    }

    /// 수신 완료 알림 (flow control)
    public func receiveComplete(length: UInt64) {
        // MsQuic.StreamReceiveComplete 호출
    }

    /// 콜백에서 호출됨
    internal func handleEvent(_ event: QUIC_STREAM_EVENT) -> QuicStatus { ... }

    deinit {
        // MsQuic.StreamClose 호출
    }
}
```

### 6.2 전송/수신 플래그

#### `QuicStreamFlags.swift`
```swift
public struct QuicStreamStartFlags: OptionSet {
    public let rawValue: UInt32

    public static let none = QuicStreamStartFlags([])
    public static let immediate = QuicStreamStartFlags(rawValue: QUIC_STREAM_START_FLAG_IMMEDIATE)
    public static let failBlocked = QuicStreamStartFlags(rawValue: QUIC_STREAM_START_FLAG_FAIL_BLOCKED)
    // ... 기타 플래그
}

public struct QuicSendFlags: OptionSet {
    public let rawValue: UInt32

    public static let none = QuicSendFlags([])
    public static let fin = QuicSendFlags(rawValue: QUIC_SEND_FLAG_FIN)
    public static let allowLoss = QuicSendFlags(rawValue: QUIC_SEND_FLAG_ALLOW_0_RTT)
    // ... 기타 플래그
}

public struct QuicReceiveFlags: OptionSet {
    public let rawValue: UInt32

    public static let none = QuicReceiveFlags([])
    public static let fin = QuicReceiveFlags(rawValue: QUIC_RECEIVE_FLAG_FIN)
    public static let zeroCopy = QuicReceiveFlags(rawValue: QUIC_RECEIVE_FLAG_0_RTT)
}
```

---

## Phase 7. 통합 및 사용 예제

### 7.1 클라이언트 예제
```swift
// 초기화
try SwiftMsQuicAPI.open().throwIfFailed()
defer { SwiftMsQuicAPI.close() }

// 등록 및 설정
let registration = try QuicRegistration(config: .init(appName: "MyClient", executionProfile: .lowLatency))
let configuration = try QuicConfiguration(registration: registration, alpnBuffers: ["h3"])
try configuration.loadCredential(.init(type: .none, flags: [.client, .noServerCertificateValidation]))

// 연결
let connection = try QuicConnection(registration: registration)
try await connection.start(configuration: configuration, serverName: "localhost", serverPort: 4433)

// 스트림 열기
let stream = try await connection.openStream()
try await stream.start()

// 데이터 전송
try await stream.send(Data("Hello, QUIC!".utf8), flags: .fin)

// 데이터 수신
for try await data in stream.receive {
    print("Received: \(String(data: data, encoding: .utf8) ?? "")")
}

// 종료
await connection.shutdown()
```

### 7.2 서버 예제
```swift
// 초기화
try SwiftMsQuicAPI.open().throwIfFailed()
defer { SwiftMsQuicAPI.close() }

// 등록 및 설정
let registration = try QuicRegistration(config: .init(appName: "MyServer", executionProfile: .lowLatency))
let configuration = try QuicConfiguration(registration: registration, alpnBuffers: ["h3"])
try configuration.loadCredential(.init(
    type: .certificateFile(certPath: "server.crt", keyPath: "server.key"),
    flags: []
))

// 리스너 시작
let listener = try QuicListener(registration: registration)
listener.onNewConnection { listener, info in
    let connection = try QuicConnection(handle: info.connection, configuration: configuration)

    connection.onPeerStreamStarted { connection, stream in
        for try await data in stream.receive {
            // Echo back
            try await stream.send(data, flags: .fin)
        }
    }

    return connection
}

try await listener.start(alpnBuffers: ["h3"], localAddress: QuicAddress(port: 4433))

// 서버 실행 유지...
```

---

## 구현 순서 (권장)

### Step 1: 기반 인프라
1. `QuicError.swift` - 에러 enum 정의
2. `QuicStatus` 확장 - `throwIfFailed()` 추가
3. `QuicBuffer.swift` - Data ↔ QUIC_BUFFER 변환
4. `QuicObject.swift` - Base class 정의

### Step 2: 설정 계층
5. `QuicSettings.swift` - 설정 구조체
6. `QuicCredentialConfig.swift` - TLS 설정
7. `QuicRegistration.swift` - 앱 등록 (기존 코드 리팩토링)
8. `QuicConfiguration.swift` - 설정 관리

### Step 3: 이벤트 & 콜백
9. `QuicListenerEvent.swift` - Listener 이벤트 enum
10. `QuicConnectionEvent.swift` - Connection 이벤트 enum
11. `QuicStreamEvent.swift` - Stream 이벤트 enum
12. `QuicEventConverter.swift` - C → Swift 변환
13. `QuicCallbackThunks.swift` - 콜백 thunk 함수

### Step 4: 주요 클래스
14. `QuicAddress.swift` - 주소 래퍼
15. `QuicListener.swift` - 서버 리스너
16. `QuicConnection.swift` - 연결 관리
17. `QuicStream.swift` - 스트림 관리

### Step 5: 플래그 & 유틸리티
18. `QuicStreamOpenFlags.swift`
19. `QuicStreamFlags.swift` (Start, Send, Receive 플래그)

### Step 6: 테스트 & 문서
20. 단위 테스트 작성
21. 통합 테스트 (echo 서버/클라이언트)
22. API 문서화

---

## 주의사항

### 메모리 관리
- `CInteropHandle`의 `Unmanaged.passUnretained`를 사용하므로, 콜백이 호출되는 동안 객체가 해제되지 않도록 주의
- `QuicStream`의 `RECEIVE` 이벤트에서 받은 버퍼는 `StreamReceiveComplete` 호출 전까지만 유효
- `SEND_COMPLETE` 전까지 전송 버퍼를 유지해야 함

### 스레드 안전성
- MsQuic 콜백은 임의의 스레드에서 호출될 수 있음
- Swift Concurrency 사용 시 `@unchecked Sendable` 또는 actor 고려
- Continuation 관리 시 lock 필요

### 수명 관리
- 객체 해제 순서: Stream → Connection → Listener → Configuration → Registration → MsQuicClose
- `deinit`에서 비동기 작업이 필요한 경우 별도의 `close()` 메서드 제공 고려
