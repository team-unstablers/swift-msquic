<section id="project-info">

# swift-msquic

이 레포지토리는 MsQuic 라이브러리를 Swift에서 쉽게 쓸 수 있도록 prebuilt된 바이너리와 헬퍼 코드를 제공합니다.

- 2026-02-06 기준: `QuicConnection.StreamHandler` 시그니처는 `(QuicConnection, QuicStream, QuicStreamOpenFlags) async -> Void`였습니다 (v1.x). v2.0.0에서 isolated 파라미터가 앞에 붙었으며, 아래 2026-04-11 항목과 §0.5를 참조하세요.
- 2026-03-23 기준: 로컬에서 연 `QuicStream`의 `connection` 프로퍼티는 `weak` back-reference입니다. 클라이언트 종료 시에는 활성 stream/task 참조를 먼저 정리해야 `QuicConnection`/`QuicRegistration` 해제가 지연되지 않습니다.
- 2026-04-10 기준: v2.0.0 Swift 6 migration을 준비하면서 모듈의 방향성이 **"thin C wrapper"**로 명확히 확정되었습니다. 상세 원칙은 아래 §0을, 구체적인 이행 계획은 `swift6-migration-plan.md`를 참조하세요.
- 2026-04-11 기준: **v2.0.0이 릴리스되었습니다.** Package가 Swift 6.0 tools-version + `swiftLanguageModes: [.v6]`로 전환되었고, `StreamHandler` 시그니처는 `(isolated (any Actor)?, QuicConnection, QuicStream, QuicStreamOpenFlags) async -> Void`가 되었습니다. 나머지 공개 표면 변경(예: `NewConnectionInfo.accept(...)`, raw `HQUIC`/`UnsafeMutableRawPointer?` 제거, `SwiftMsQuicAPI`가 namespace enum으로 전환, `QuicObject`가 `public class` non-`open`으로 강등 등)은 §0.5에 상세히 정리되어 있습니다.
- 2026-04-11 기준 (v2.0.0 직후): **Swift 모듈 이름이 `SwiftMsQuicHelper`에서 `SwiftMsQuic`으로 rename되었습니다.** 소비자는 `import SwiftMsQuicHelper`를 `import SwiftMsQuic`으로 바꿔야 합니다. Package.swift의 library product 이름(`SwiftMsQuic`/`SwiftMsQuicStatic`)은 그대로 유지됩니다 — 이제 product와 Swift module 이름이 일치합니다. 디렉토리도 `Sources/SwiftMsQuic/`로, DocC 번들도 `SwiftMsQuic.docc`로 함께 이동했습니다. 역사 문서(`swift6-migration-plan.md`)는 당시 기록이므로 과거 이름을 그대로 남겨 둡니다.

</section>
<section id="design-principles">

# SwiftMsQuic 설계 원칙

이 섹션은 `SwiftMsQuic` 모듈의 API 및 Struct/Class 래퍼 설계 시 준수해야 할 원칙을 정의합니다.
**모든 에이전트는 이 원칙을 숙지하고, 코드 작성 시 반드시 따라야 합니다.**

> 📖 상세한 구현 계획은 `WRAPPER_PLAN.md`를 참조하세요.

## 0. 모듈 스코프 (Module Scope)

**`SwiftMsQuic`은 MsQuic C 라이브러리의 *얇은 (thin)* Swift wrapper입니다. 고수준 네트워킹 추상화 라이브러리가 아닙니다.**

이 원칙은 2026-04-10 v2.0.0 Swift 6 migration 협의에서 확정되었으며, 아래 모든 세부 원칙(§1 ~ §5)은 이 상위 원칙에 종속됩니다. 새로운 API를 추가하거나 기존 API를 변경할 때, 에이전트는 "이 변경이 thin wrapper의 범위 안에 있는가?"를 먼저 물어야 합니다.

### 0.1 이 모듈이 지향하는 것 (What this module IS)

- **MsQuic의 의미론(semantics)을 투명하게 노출합니다.** Swift-idiomatic한 표면을 제공하되, MsQuic의 동작 모델을 우회하거나 재해석하지 않습니다.
- **MsQuic의 모든 주요 기능을 표현할 수 있어야 합니다.** Custom certificate validation, datagram context tracking, stream priority, connection resumption ticket 등 MsQuic 고급 기능을 "편의성"을 이유로 감추거나 제거하지 않습니다.
- **Swift-idiomatic한 표면**은 다음으로 한정됩니다:
  - `async/await` 기반 API (§1.2)
  - `CheckedContinuation` / `AsyncThrowingStream`으로 콜백 이벤트를 Swift Concurrency로 변환
  - Swift `enum`(associated value)으로 C의 union 기반 이벤트 구조체 변환 (§1.3)
  - `throws` 기반 에러 처리 (§1.4)
  - `OptionSet`으로 비트 플래그 래핑 (§4.2)
  - `@Sendable` 클로저 및 `Sendable` 값 타입 — raw C 타입은 public API에 노출하지 않음
- **MsQuic 새 버전을 빠르게 따라갈 수 있어야 합니다.** 의미론 레이어가 얇을수록 MsQuic 업데이트(API 추가, 시그니처 변경, 바이너리 교체)의 반영 비용이 작아집니다.

### 0.2 이 모듈이 하지 않는 것 (What this module IS NOT)

- **`actor`를 `SwiftMsQuic` 내부에 도입하지 않습니다.** MsQuic 콜백은:
  1. **임의의 worker 스레드에서 동기적으로** 호출되고,
  2. 콜백 안에서 **즉시 `QuicStatus` 반환**을 요구하며 (특히 `ConnectionHandler`, `CertificateValidationHandler`, `EventHandler`),
  3. 반환값이 MsQuic 내부 상태 전이(accept/reject/pending 등)를 결정합니다.

  이 세 가지 제약은 Swift actor isolation 모델과 근본적으로 맞지 않습니다. actor로 전환하면 콜백 진입 시점에 hop이 필요하지만 hop은 async이므로 동기 반환값을 줄 수 없습니다. 따라서 핸들러 클래스(`QuicListener`, `QuicConnection`, `QuicStream`)는 **`OSAllocatedUnfairLock<InternalState>`으로 보호되는 `@unchecked Sendable` class**로 유지합니다. 자세한 스레드 안전성 규칙은 §3을 참조하십시오.

- **고수준 actor 기반 추상화(e.g. `QuicSession`, `QuicClient`, `QuicServer`)를 이 모듈에 추가하지 않습니다.** 그런 레이어가 필요한 사용자(e.g. `noctiluca`)는 이 모듈 위에 **직접** actor 래퍼를 작성합니다. 이유는 두 가지:
  1. 고수준 추상화의 요구 형태(상태 관리 전략, 연결 풀, 인증 흐름, 재시도 정책 등)는 사용처마다 다르며, 이 모듈에서 하나의 "정답"을 강제하면 다른 사용처에는 맞지 않습니다.
  2. 두 층 구조를 한 모듈에 섞으면 저수준 API 변경이 고수준 API에 연쇄적으로 영향을 미쳐 유지보수가 어려워집니다.

  대신 `Sources/SwiftMsQuicExample/`에서 **참고용** actor 기반 예제를 제공합니다 (v2.0.0 기준으로 `EchoServer`/`EchoClient` actor로 재작성되어 있습니다). 이 예제는 "사용자 쪽 actor 코드가 어떻게 이 모듈을 소비해야 하는지"를 보여주는 문서 역할만 하며, 모듈의 public API가 아닙니다.

- **동기 콜백을 async로 "편의상" 변환하지 않습니다.** `ConnectionHandler`, `CertificateValidationHandler`, `EventHandler`는 MsQuic의 반환값 요구 때문에 동기로 유지합니다. v2.0.0에서 `StreamHandler`만 예외적으로 async이며, 이는 MsQuic이 stream 시작 이벤트에는 동기 반환값을 요구하지 않기 때문입니다. `StreamHandler`에는 `isolated (any Actor)?` 파라미터가 추가되어 사용자가 호출 측 actor로 자연스럽게 hop할 수 있게 합니다.

- **MsQuic 기능을 "사용자가 쓰기 어렵다"는 이유로 노출에서 제외하지 않습니다.** 해당 기능을 쓰는 사용자가 보일러플레이트를 작성해야 하더라도, 이 모듈의 책임은 해당 기능을 **표현 가능하게** 만드는 것까지입니다. 편의 메서드를 추가하고 싶다면 사용자 측 레이어에서 확장으로 작성합니다.

### 0.3 구체 판단 예시 (Concrete Examples)

| 제안 | thin wrapper에 맞는가? | 이유 |
|---|---|---|
| `QuicConnection.sendDatagram(_:)`에 자동 재시도 추가 | ❌ | MsQuic은 재시도를 하지 않음. 재시도 정책은 사용자 레이어 책임. |
| `NewConnectionInfo.accept(configuration:streamHandler:) -> QuicConnection` 추가 | ✅ | raw `HQUIC` 노출을 제거하기 위한 표면 정리. MsQuic 의미론(연결 수락 시점에 configuration 적용) 보존. |
| 모든 `QuicConnection`이 내부적으로 `NIOLockedValueBox`에 연결을 등록하고 `shutdown()` 호출 시 모두 정리 | ❌ | 전역 상태 관리. 사용자 레이어가 해야 할 일. |
| `QuicConnectionEvent.peerStreamStarted(stream: HQUIC, ...)` → `(stream: QuicStream, ...)` | ✅ | raw 포인터 대신 Swift 래퍼로 변환하는 것은 §1.3에 따른 자연스러운 변환. MsQuic 의미론은 동일. |
| `QuicClient` actor를 `SwiftMsQuic`에 추가 | ❌ | §0.2 위반. `SwiftMsQuicExample`에는 참고용으로 두어도 되지만 모듈 public API가 되어서는 안 됨. |
| `EventHandler` 대신 `events: AsyncStream<QuicConnectionEvent>` 기반 API로 전환 | ❌ | MsQuic은 `EventHandler`의 반환값(`QuicStatus`)으로 이벤트 처리 결과를 결정함. AsyncStream은 반환값을 표현할 수 없음. 보조적으로 병설하는 것도 의미론 혼란을 유발하므로 하지 않음. |
| `QuicStream.send(_:flags:)`의 fire-and-forget 오버로드 추가 | ✅ | MsQuic이 SEND_COMPLETE 이벤트를 통해 완료를 알려주므로, 사용자가 대기하지 않는 경우를 위한 편의 오버로드는 적절. 의미론 변경 없음. |

### 0.4 철학적 근거 (Philosophical Rationale)

- **swift-nio와 비교**: swift-nio는 "저수준 `Channel` + 고수준 `AsyncChannel`" 두 층 구조를 한 모듈에서 제공하지만, 그것은 swift-nio가 Swift 생태계의 **기반 네트워킹 라이브러리**이기 때문이며 자체 생태계(extras, HTTP, WebSocket 등 별도 레포)를 통해 고수준을 분리해두었습니다. `swift-msquic`은 규모가 훨씬 작고 MsQuic이라는 단일 백엔드에 종속되므로, "저수준만 담당하고 고수준은 사용자 측"이라는 **더 단순한** 선택을 합니다.
- **`@unchecked Sendable`에 대한 태도**: `@unchecked`는 "패배 선언"이 아니라 "여기에 수동 동기화가 있고, 그 규칙은 주석과 `OSAllocatedUnfairLock`으로 문서화되어 있다"는 **의도적 선언**입니다. Swift 6 strict concurrency 하에서도 C 라이브러리 래퍼는 이 패턴을 피할 수 없으며, 피하려 하면 MsQuic 의미론을 잃거나 코드가 복잡해집니다. §3 참조.

### 0.5 v2.0.0 릴리스 스냅샷 (2026-04-11)

§0 ~ §4의 원칙을 구현하기 위해 v2.0.0에서 아래 변경이 일괄 반영되었습니다. 이 subsection은 에이전트가 **현재 모듈의 공개 표면을 빠르게 파악**하기 위한 요약이며, 상세 변경 내역(사용자 마이그레이션 가이드 포함)은 `README.md`의 "Migrating from 1.x → 2.0" 섹션을, 이행 과정의 청크별 기록은 `swift6-migration-plan.md`를 참조하세요.

**Package / 언어 모드**
- `swift-tools-version: 6.0`, `swiftLanguageModes: [.v6]`. strict concurrency가 패키지 전역 기본 모드입니다. 배포 타겟은 그대로 (macOS 13 / iOS 16).

**StreamHandler와 isolation (§0.2, §1.2)**
- `QuicConnection.StreamHandler`가 `(isolated (any Actor)?, QuicConnection, QuicStream, QuicStreamOpenFlags) async -> Void`로 변경되었습니다. 첫 파라미터는 SE-0420 기반의 actor isolation 파라미터입니다.
- `onPeerStreamStarted(_:)`와 `init(handle:configuration:streamHandler:)`도 같은 typealias를 사용하므로 자동 반영됩니다.
- `EventHandler`, `CertificateValidationHandler`, `ConnectionHandler`는 **동기 `@Sendable` 그대로 유지**합니다. MsQuic의 동기 `QuicStatus` 반환 요구 때문입니다 (§0.2 참조).

**이벤트 표면에서 raw C 타입 제거 (§1.3)**
- `NewConnectionInfo.connection: HQUIC` 제거 → `info.accept(configuration:streamHandler:) throws -> QuicConnection` 메서드로 대체. raw handle은 `internal`로 숨겨졌고 콜백 안에서만 소비됩니다.
- `QuicConnectionEvent.peerStreamStarted(stream: HQUIC, ...)` → `(stream: QuicStream, ...)`. converter가 콜백 시점에 Swift 래퍼를 즉시 생성합니다.
- `QuicConnectionEvent.datagramSendStateChanged`와 `QuicStreamEvent.sendComplete`에서 `context: UnsafeMutableRawPointer?` 필드가 제거되었습니다. 해당 dispatch는 `handleEvent` 상단에서 raw event의 `ClientContext`를 직접 읽어 continuation/SendContext를 해제하는 방식으로 바뀌었으므로, public enum에는 노출되지 않습니다.

**글로벌 API / 가시성 (§0.1, §4)**
- `SwiftMsQuicAPI`가 `public enum` (case 없는 namespace)으로 전환되었고 `shared` 인스턴스가 제거되었습니다. `SwiftMsQuicAPI.MsQuic` (raw API table)은 `internal`로 강등되어 모듈 내부에서만 사용됩니다. 전역 상태(raw API 포인터)는 `OSAllocatedUnfairLock<ApiState>`로 보호됩니다.
- `QuicExecutionProfile.asLibEnum`: `public extension` → `internal extension`.
- `QuicObject`: `open class` → `public class` (non-`open`). 외부 모듈에서의 상속은 차단되지만 타입 참조는 가능합니다. (최초 플랜 초안의 `internal class`는 Swift 컴파일러가 public 서브클래스의 internal 부모를 허용하지 않아 채택되지 않았습니다.)
- `QuicObject.handle`은 `internal nonisolated(unsafe) var`입니다. 쓰기는 `init`에 국한되고, 읽기는 Swift task와 MsQuic C 콜백 스레드 모두에서 발생하지만 `HQUIC`가 불변 opaque 포인터라는 가정 하에 안전합니다.
- `QuicObject` 자체는 `@unchecked Sendable`입니다. subclass들이 `@Sendable` 클로저(예: `OSAllocatedUnfairLock.withLock` 바디)에서 `self`를 캡처할 수 있도록 하기 위함이며, thread-safety는 §3 규칙에 따라 subclass별 lock으로 제공됩니다.
- `QuicAddress.raw` / `init(_ raw:)`는 예외적으로 `public` 유지 (noctiluca 호환).

**Sendable 적합성**
- 모든 configuration/helper 값 타입(`QuicSettings`, `QuicRegistrationConfig`, `QuicCredentialConfig`, `QuicCredentialType`, `QuicExecutionProfile`, `QuicBuffer`)에 `Sendable`이 명시적으로 선언되었습니다.
- 모든 핸들 클래스(`QuicRegistration`, `QuicConfiguration`, `QuicListener`, `QuicConnection`, `QuicStream`)는 `@unchecked Sendable`이며, `OSAllocatedUnfairLock<InternalState>`로 가변 상태를 보호합니다.

**`withLockUnchecked` 사용 지점**
- 비-Sendable 값을 lock 경계 밖으로 꺼내야 하는 세 지점에서 `withLock` 대신 `withLockUnchecked`를 사용합니다:
  1. `SwiftMsQuicAPI.MsQuic` getter — `UnsafeRawPointer?` 반환.
  2. `QuicObject.retainSelfForCallback()` / `releaseSelfFromCallback()` — `Unmanaged<AnyObject>` 및 `self` 캡처.
  3. `QuicConnection` datagram send dispatch — `DatagramSendContext?` 반환.
- 세 경우 모두 직렬화는 여전히 OSAllocatedUnfairLock이 보장하며, non-Sendable 값은 lock 반환 직후 로컬에서만 사용됩니다.

**Pre-existing 버그 수정**
- `QuicStream.InternalState`의 `receiveStream` 저장 위치, `QuicStream.deinit`/`QuicListener.deinit`의 continuation drain 누락, `QuicListener.start(...)`의 nil-coalescing 모호성, `QuicCertificate.swift`의 non-Darwin 가지 누락이 함께 수정되었습니다. 상세는 `swift6-migration-plan.md` Chunk 1 섹션을 참조하세요.

**Example (`SwiftMsQuicExample`)**
- `EchoServer`/`EchoClient` actor로 전면 재작성되었습니다. `@main struct App`은 얇은 진입점이며, 새 connection 등록 / 스트림 처리 / 데이터그램 수신은 actor-isolated 메서드로 분리되어 있습니다. 이 예제는 "사용자 측 actor 레이어가 `SwiftMsQuic`을 어떻게 소비해야 하는지"에 대한 참고 구현이며, public API가 아닙니다.

## 1. 핵심 설계 원칙 (Core Design Principles)

### 1.1 Class 기반 설계
- 모든 `HQUIC` 핸들 래퍼는 **`class`**로 구현합니다 (struct 아님).
- `CInteropHandle` 프로토콜을 채택하여 C 콜백의 context로 `self`를 전달할 수 있게 합니다.
- **ARC를 활용한 자동 리소스 관리**: `deinit`에서 해당 MsQuic Close API를 호출합니다.

```swift
// ✅ Good
public final class QuicConnection: QuicObject, CInteropHandle {
    deinit {
        api.ConnectionClose(handle)
    }
}

// ❌ Bad - struct는 CInteropHandle로 사용 불가
public struct QuicConnection { ... }
```

### 1.2 Swift Concurrency (async/await)
- 콜백 기반 MsQuic API를 **`async/await`** 패턴으로 래핑합니다.
- `CheckedContinuation`을 사용하여 콜백 이벤트를 Swift Concurrency로 변환합니다.
- 데이터 수신은 `AsyncThrowingStream`을 활용합니다.

```swift
// ✅ Good
public func start(configuration: QuicConfiguration, serverName: String, serverPort: UInt16) async throws

// ❌ Bad - completion handler 스타일
public func start(configuration: QuicConfiguration, serverName: String, serverPort: UInt16, completion: @escaping (Result<Void, Error>) -> Void)
```

### 1.3 Swift Enum으로 이벤트 매핑
- C의 union 기반 이벤트 구조체(`QUIC_*_EVENT`)를 **Swift enum (associated value)**으로 변환합니다.
- Raw C 구조체를 직접 노출하지 않습니다.

```swift
// ✅ Good
public enum QuicConnectionEvent {
    case connected(negotiatedAlpn: String?, resumption: Bool)
    case shutdownInitiatedByPeer(errorCode: UInt64)
    // ...
}

// ❌ Bad - C 구조체 직접 노출
public typealias QuicConnectionEvent = QUIC_CONNECTION_EVENT
```

### 1.4 throws 기반 에러 처리
- 실패 가능한 API는 `QuicError`를 throw합니다.
- `QuicStatus`에 `throwIfFailed()` 메서드를 제공합니다.

```swift
// ✅ Good
public func start() async throws

// ❌ Bad - Result 반환
public func start() async -> Result<Void, QuicError>

// ❌ Bad - QuicStatus 직접 반환
public func start() async -> QuicStatus
```

## 2. 메모리 관리 원칙 (Memory Management)

### 2.1 CInteropHandle 사용 시 주의
- `Unmanaged.passUnretained`를 사용하므로, **콜백이 호출되는 동안 객체가 해제되지 않도록** 주의합니다.
- 필요 시 외부에서 strong reference를 유지하거나, 내부적으로 self-retain 패턴을 사용합니다.

### 2.2 버퍼 수명 관리
- `RECEIVE` 이벤트의 버퍼: `StreamReceiveComplete` 호출 전까지만 유효
- `SEND` 버퍼: `SEND_COMPLETE` 이벤트 전까지 유지 필요
- Swift `Data`로 복사하여 안전하게 관리하거나, 명시적인 수명 관리 로직 구현

```swift
// ✅ Good - 데이터 복사
case .receive:
    let data = Data(bytes: event.RECEIVE.Buffers, count: Int(event.RECEIVE.TotalBufferLength))
    // data는 안전하게 사용 가능
```

### 2.3 객체 해제 순서
객체는 반드시 다음 순서로 해제되어야 합니다:
```
Stream → Connection → Listener → Configuration → Registration → MsQuicClose()
```

## 3. 스레드 안전성 (Thread Safety)

### 3.1 콜백 스레드
- MsQuic 콜백은 **임의의 worker 스레드**에서 **동기적으로** 호출됩니다. 콜백은 즉시 `QuicStatus`를 반환해야 하므로 Swift Concurrency suspension을 사용할 수 없습니다.
- 이 모듈은 **`actor` 대신 `OSAllocatedUnfairLock`-protected `@unchecked Sendable` class** 패턴을 일관되게 사용합니다 (상세 근거는 §0.2 참조).
- 모든 가변 상태는 `OSAllocatedUnfairLock<InternalState>` 내부에 두고, `internalState.withLock { ... }`으로만 접근합니다.
- `CheckedContinuation.resume()` 호출은 반드시 **lock 외부**에서 수행합니다. lock 내부에서 resume하면 continuation이 깨어나는 다른 task가 같은 lock을 잡으려 할 때 deadlock 또는 priority inversion이 발생할 수 있습니다.

```swift
// ✅ Good - lock 내부에서 continuation을 꺼내 nil로 설정, lock 밖에서 resume
let continuation = internalState.withLock { state -> CheckedContinuation<Void, Error>? in
    let c = state.startContinuation
    state.startContinuation = nil
    return c
}
continuation?.resume()

// ❌ Bad - lock 내부에서 resume
internalState.withLock { state in
    state.startContinuation?.resume()  // deadlock 위험
    state.startContinuation = nil
}
```

- 모든 `@unchecked Sendable` 선언에는 **어떤 lock이 어떤 상태를 보호하는지** 명시하는 주석을 달아야 합니다. `@unchecked`는 단순히 컴파일러를 우회하는 도구가 아니라, 수동 동기화의 **의도적 문서화**입니다.

```swift
// ✅ Good
/// `internalState` lock protects all mutable fields below; `handle` is
/// `nonisolated(unsafe)` because it is write-once in init.
public final class QuicConnection: QuicObject, @unchecked Sendable {
    private struct InternalState: @unchecked Sendable {
        // CheckedContinuation / AsyncThrowingStream.Continuation 보관
        // 모든 접근은 internalState.withLock { ... } 경유
        var connectContinuation: CheckedContinuation<Void, Error>?
        // ...
    }
    private let internalState = OSAllocatedUnfairLock(initialState: InternalState())
}
```

### 3.2 Continuation 관리
- 여러 스레드에서 접근 가능한 continuation 딕셔너리는 **lock으로 보호**합니다.

```swift
// ✅ Good
private let lock = NSLock()
private var continuations: [UUID: CheckedContinuation<Void, Error>] = [:]

func storeContinuation(_ continuation: CheckedContinuation<Void, Error>, id: UUID) {
    lock.withLock {
        continuations[id] = continuation
    }
}
```

## 4. API 설계 컨벤션 (API Design Conventions)

### 4.1 네이밍
| 패턴 | Swift 네이밍 |
|------|-------------|
| `QUIC_*_OPEN` | `init(...)` 생성자 |
| `QUIC_*_CLOSE` | `deinit` 또는 `close()` |
| `QUIC_*_START` | `start(...) async throws` |
| `QUIC_*_SHUTDOWN` | `shutdown(...) async` |
| `QUIC_*_SEND` | `send(...) async throws` |

### 4.2 플래그 타입
- C의 비트 플래그는 **`OptionSet`**으로 래핑합니다.

```swift
public struct QuicStreamOpenFlags: OptionSet, Sendable {
    public let rawValue: UInt32

    public static let none = QuicStreamOpenFlags([])
    public static let unidirectional = QuicStreamOpenFlags(rawValue: QUIC_STREAM_OPEN_FLAG_UNIDIRECTIONAL)
}
```

### 4.3 설정 구조체
- C 설정 구조체는 Swift `struct`로 래핑하고, `withUnsafe*` 패턴으로 C API에 전달합니다.

```swift
public struct QuicSettings {
    public var idleTimeoutMs: UInt64?

    internal func withUnsafeSettings<T>(_ body: (UnsafePointer<QUIC_SETTINGS>) throws -> T) rethrows -> T
}
```

## 5. 파일 구조 (File Structure)

```
Sources/SwiftMsQuic/
├── Core/
│   ├── QuicObject.swift          # Base class
│   ├── QuicError.swift           # 에러 enum
│   ├── QuicBuffer.swift          # Data ↔ QUIC_BUFFER
│   └── CInteropHandle.swift      # (기존)
├── Configuration/
│   ├── QuicRegistration.swift
│   ├── QuicConfiguration.swift
│   ├── QuicSettings.swift
│   └── QuicCredentialConfig.swift
├── Events/
│   ├── QuicListenerEvent.swift
│   ├── QuicConnectionEvent.swift
│   ├── QuicStreamEvent.swift
│   └── QuicEventConverter.swift
├── Handlers/
│   ├── QuicListener.swift
│   ├── QuicConnection.swift
│   └── QuicStream.swift
├── Utilities/
│   ├── QuicAddress.swift
│   ├── QuicCallbackThunks.swift
│   └── Quic*Flags.swift
└── SwiftMsQuicAPI.swift          # (기존) Entry point
```

</section>
<section id="agent-rules">

# AGENT RULES

<conditional-rule applies-to="Google Gemini" excludes="OpenAI Codex, Anthropic Claude Code">

# [GEMINI ONLY] 적극적 문맥 수집 전략 (Aggressive Context Gathering)

당신(Gemini)은 **100만 토큰 이상의 거대한 컨텍스트 윈도우**를 가지고 있습니다.
토큰을 아끼기 위해 불확실한 추측을 하는 것보다, **차라리 너무 많이 읽는 것이 훨씬 낫습니다.**

## 1. 무관용 읽기 원칙 (Zero Assumption & Deep Dive)
- **추측 금지:** 파일명이나 임포트 구문만 보고 내부 구현을 단정 짓지 마십시오. "이거겠지?" 싶은 순간, **무조건 `read_file`로 열어서 내용을 확인하십시오.**
- **연관 파일 통째로 읽기 ("3-Hop Rule"):** 특정 기능을 분석하거나 수정할 때, 타겟 파일 하나만 달랑 읽고 멈추지 마십시오.
  1. **Target:** 분석할 대상 파일
  2. **Dependencies:** 그 파일이 상속받거나 사용하는 부모 클래스, 프로토콜, Extension 파일들
  3. **Usages:** 그 파일이 어디서, 어떻게 호출되는지 (검색 결과)
  - 위 파일들을 찔끔찔끔 읽지 말고, `read_file`을 병렬로 호출하여 **한꺼번에, 공격적으로** 읽어들이십시오.
- **Swift/iOS 특화:** Swift 코드는 Extension으로 흩어져 있는 경우가 많습니다. `MyClass.swift`를 읽을 때 `MyClass+*.swift`가 존재한다면 반드시 같이 찾아서 읽으십시오.

## 2. 불확실성 해소 (Ask, Don't Guess)
- `search_file_content` 결과가 없거나 모호한 경우, 적당히 가설을 세워 진행하려 하지 마십시오.
- **즉시 멈추고 질문하십시오:** "X 로직을 찾으려 했으나 검색되지 않습니다. 혹시 별도의 서브모듈이나 다른 경로에 있나요?"라고 사용자에게 물어보십시오.
- 모르는 것은 문제가 아니지만, **파일을 안 읽어서 모르는데 아는 척하는 것은 엄격히 금지**됩니다.

</conditional-rule>

## 1. Interaction & Language
- 작업을 진행할 때 확실하지 않거나 궁금한 점이 있으면, 되도록 **추측하지 말고 사용자에게 질문**해서 명확히 하는 것을 우선해 주세요.
- 사용자가 한국어 화자인 만큼, 모든 대화와 Plan 작성은 **반드시 한국어**로 진행해 주세요.
- 프로젝트에 대한 중요한 정보나 커다란 변경 사항이 있을 때는, `AGENTS.md`를 수정하여 프로젝트에 대한 최신 정보를 반영해 주세요.
- **권한이 부족하여 작업을 수행할 수 없는 경우, 반드시 사용자에게 elevation 요청을 해야 합니다.** (If a command fails due to insufficient permissions, you must elevate the command to the user for approval.)

## 2. Workflow Protocol (중요)
당신(에이전트)가 OpenAI Codex인 경우, 당신은 기본적으로 자율적(Autonomous)으로 행동하지만, 아래의 **[Explicit Plan Mode]** 조건에 해당할 경우 행동 방식을 변경해야 합니다.

### [Explicit Plan Mode] 트리거 조건
1. 사용자가 명시적으로 **'Plan 모드'**, **'계획 모드'**, 또는 **'설계 먼저'**라고 요청한 경우.
2. 작업이 **3개 이상의 파일**에 구조적 변경을 일으키거나, **Core Logic(Protobuf, Network, AVFoundation)**을 건드리는 위험한 변경일 경우.

### [Explicit Plan Mode] 행동 수칙
위 조건이 발동되면 **즉시 코드 구현을 멈추고** 다음 절차를 따르세요:
1. **Stop:** 코드를 작성하거나 수정하지 마십시오. (파일 읽기는 가능)
2. **Plan:** **한국어**로 상세 구현 계획, 영향 범위, 예상 리스크를 작성하십시오.
3. **Ask:** 사용자에게 계획을 제시하고 **"이대로 진행할까요?"**라고 승인을 요청하십시오.
4. **Action:** 사용자의 명시적 승인(예: "ㅇㅇ", "진행해")이 떨어진 후에만 코드를 수정하십시오.

*(위 조건에 해당하지 않는 단순 수정이나 버그 픽스는 기존대로 승인 없이 즉시 처리하고 결과를 보고하십시오.)*

<conditional-rule applies-to="all agent, but excluding claude code (because claude code has own interview/decision ui)">

## 2-1. 'INTERVIEW LOOP'

아래 트리거 조건이 발동되면 **즉시 코드 구현을 멈추고**, 아래의 **[Phase 1 -> Phase 2 -> Phase 3]** 순서를 엄격히 준수하세요.

### TRIGGER CONDITIONS

1. **Multiple Valid Approaches (복수의 유효한 접근법):**
   목표를 달성하는 방법이 두 가지 이상이며, 각 방법이 서로 다른 장단점(Trade-offs)이나 비용을 가질 때.
2. **Ambiguity & Assumptions (모호성 및 가정):**
   사용자의 요청이 명확하지 않아 임의의 가정이 필요하거나, 요청이 여러 가지 의미로 해석될 수 있을 때.
3. **Architectural Impact (아키텍처 영향):**
   단순 구현을 넘어, 프로젝트의 구조, 컨벤션, 또는 외부 인터페이스에 지속적인 영향을 미치는 결정을 내려야 할 때.

### Phase 1. Ambiguity Check & Interview (Loop)
계획을 세우기 전, 요구사항을 분석하여 불명확한 점(Ambiguity)이나 기술적 선택지(Trade-offs)를 모두 제거해야 합니다.

1. **Loop Condition (반복 조건):** 명확하지 않은 사항이 남아있다면 아래 2~4번 과정을 반복합니다.
2. **Action (질문):** 결정이 필요한 사항을 **Markdown 리스트** 형태로 정리하여 사용자에게 질문합니다.
   - 과도한 UI 장식(ASCII Art 등)은 배제하고, 내용 전달에 집중합니다.
   - 각 옵션의 **기술적 장단점**과 에이전트의 **권장 사항(Recommended)**을 명시합니다.
   
   > **[질문 포맷 예시]**
   > ## 🧐 확인이 필요한 사항
   > 1. **라이브러리 선택**
   >    - (A) `google.protobuf` (권장): 표준, 의존성 낮음
   >    - (B) `betterproto`: 코드는 간결하나 외부 의존성 있음
   > 
   > (추가 질문이 있는 경우) 2. (추가 질문)
   > ... 
   > 
   > 👉 선택해 주세요.

3. **Wait & Analyze (대기 및 분석):** 사용자의 답변을 기다린 후, 그 답변을 분석합니다.
4. **Resolve or Re-ask (해결 또는 재질문):**
   - 사용자의 답변이 불충분하거나, 답변으로 인해 **새로운 기술적 모호함**이 발생했다면 **다시 질문(Loop)**합니다.
   - 사용자가 역으로 질문(Reverse Question)을 한 경우:
     - 사용자가 질문을 받았을 때 바로 선택하지 않고, "A랑 B의 성능 차이가 구체적으로 어느 정도야?"라던가 "이걸 선택하면 나중에 바꾸기 힘들어?" 같은 추가 정보를 요구하는 경우가 있습니다.
     - 해당 질문에 대해 성실히 답변한 후, "그래서 어떤 옵션으로 진행할까요?"와 같이 다시 본래의 인터뷰 문맥(선택 요구)으로 부드럽게 복귀하십시오.
   - 사용자가 **"스킵(Skip)"** 또는 **"알아서 해"**라고 명시하면, **에이전트의 권장 사항(Recommended)을 채택**하고 루프를 즉시 종료합니다.

### Phase 2. Plan (계획 수립)
모든 불확실성이 해소(Resolved)된 후, 상세 구현 계획을 **한국어**로 작성하십시오.
1. 변경할 파일 목록과 핵심 로직을 설명합니다.
2. 작성된 계획을 사용자에게 제시하고 **"이대로 진행할까요?"**라고 승인을 요청합니다.
 - 사용자가 수정을 요청하면 계획을 수정하여 다시 승인을 받습니다.

### Phase 3. Action (이행)
사용자의 명시적 승인(예: "ㅇㅇ", "진행해")이 확인된 후에만 코드를 수정하십시오.

</conditional-rule>

## COMMIT CONVENTIONS

- 만약 git commit을 작성할 때는 기존 커밋 컨벤션을 따르는 것을 우선하고, 당신 자신을 Co-author로 추가하지 말아주세요.
- 커밋 컨벤션은 다음과 같습니다.

```
[scope]: [subject]
```

- [scope]: 변경 사항의 범위를 나타내는 짧은 단어 (예: core, ui, docs 등)
- [subject]: 변경 사항을 간결하게 설명하는 문장 (명령문 형태)

### EXAMPLES
  - `transport/quic: QUIC 연결 재시도 로직 추가`
  - `msgdef/v1/channels: 채널 메시지 정의 업데이트`
  - `docs(README): README 파일에 설치 가이드 추가`
  - `test(transport/quic): QUIC 전송 테스트 케이스 작성`

# EXTERNAL DOCUMENTATIONS

- `sosumi` MCP가 구성되어 있는 경우, 이 MCP를 통해 Apple Developer Documentation을 읽을 수 있습니다. 이를 적극적으로 활용하십시오.
</section>
