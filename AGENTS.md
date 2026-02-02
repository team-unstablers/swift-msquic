<section id="project-info">

# swift-msquic

이 레포지토리는 MsQuic 라이브러리를 Swift에서 쉽게 쓸 수 있도록 prebuilt된 바이너리와 헬퍼 코드를 제공합니다.

</section>
<section id="design-principles">

# SwiftMsQuicHelper 설계 원칙

이 섹션은 `SwiftMsQuicHelper` 모듈의 API 및 Struct/Class 래퍼 설계 시 준수해야 할 원칙을 정의합니다.
**모든 에이전트는 이 원칙을 숙지하고, 코드 작성 시 반드시 따라야 합니다.**

> 📖 상세한 구현 계획은 `WRAPPER_PLAN.md`를 참조하세요.

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
- MsQuic 콜백은 **임의의 스레드**에서 호출될 수 있습니다.
- Swift Concurrency 사용 시 `@unchecked Sendable` 또는 `actor` 패턴을 고려합니다.

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
Sources/SwiftMsQuicHelper/
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
