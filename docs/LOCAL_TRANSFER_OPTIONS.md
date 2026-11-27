# iPhone 파일 전달과 동기화 선택 — 2026-10-10

권고: **지속 동기화는 기존 iCloud Documents, Apple 기기끼리 파일 한 번 전달은 native ShareLink/AirDrop, 여러 플랫폼에 전달은 LocalSend, Folio 안의 근거리 전송에는 Acornry의 암호화 PSK 경로를 사용한다.** 위키·온톨로지 정본과 저장 권한은 KnowledgeKit에 유지한다. 전송 라이브러리가 위키 DB나 두 번째 동기화 엔진을 소유하지 않는다.

LocalSend·Acornry를 비교한 뒤 Folio는 Acornry의 암호화 전송과 수신, 가역 보관을 기존 ZIP·Markdown 가져오기에 연결했다. 적용한 구현과 사용 절차는 [근거리 전송](NEARBY_TRANSFER.md)에 기록한다.

| 방식 | 적합한 목적 | 실제 재사용 단위 | 현재 Folio 범위 |
|---|---|---|---|
| iCloud Documents | 같은 계정의 Mac/iPhone 자료함을 계속 함께 사용 | 기존 KnowledgeKit cloud access·CAS·metadata observation | 실제 양방향 원문 flow 관측 |
| AirDrop | 가까운 Apple 기기로 선택한 원문 전달 | system Share Sheet | 최종 iPhone ShareLink 경로 사용; 실제 상대 전송은 실행하지 않음 |
| LocalSend 외부 앱 | 다른 플랫폼/기기에 선택한 파일을 한 번 전달 | iOS system share/Files, 설치한 LocalSend 앱 | Folio Markdown/ZIP export·import 구현; LocalSend 실제 전송은 이번 작업에서 실행하지 않음 |
| LocalSend core 내장 | LocalSend wire와 직접 호환해야 할 때 | Rust core + 별도 Swift/C FFI·host layer | SwiftPM/SwiftUI transport SDK가 현재 checkout에 없으며 미연결 |
| Acornry | Apple 기기 간 Folio 내부 전송 | SwiftPM Acornry; Folio native 화면이 기존 typed API 소비 | TLS PSK·자동 키체인 준비/검색·문서에서 기기 선택·명시 수신·위키 import·자동 보관 구현; 실제 장치 실행 범위는 Current |

## 수신과 위키 저장은 다른 결과

Acornry는 단순 discovery transport가 아니다. AcornryNearby가 전송 수명, AcornryFileStore가 검증된 수신 bytes, manifest SHA·receipt·recovery를 소유한다. KnowledgeKit의 notes/ontology에 직접 수신하도록 연결하지 않는다. 호스트가 별도의 보호된 Received inbox를 만들고, 사용자가 수신 문서를 선택한 뒤 기존 위키 저장 계약으로 넣는다. 전송 동의가 자료함 변경 승인으로 승격되지 않는다.

송신은 Folio가 exportMarkdown 또는 exportSourceArchive로 만든 저장된 원문 복사본을 AcornryFileSource에 전달한다. 미저장 초안·SQLite·receipt·모델 상태를 전송하지 않는다. 수신 receipt는 파일 전달 결과이고 KnowledgeKit import/CAS receipt는 원문 반영 결과다. 응답 유실의 outcomeUnknown은 원래 ID+manifest digest로 reconcile하며 새 ID 재전송으로 숨기지 않는다.

Folio의 **자료 추가 → 파일 가져오기…**는 열린 자료함에 Markdown·PDF를 추가한다. 자료함 목록의 **자료함 가져오기…**는 _workspace.md가 하나 있는 Folio ZIP·원문 폴더를 이 기기의 자료함으로 복원한다. 먼저 자료함이 없으면 폴더·ZIP으로 열거나 새 자료함을 만든다. 다른 앱에서 ‘Folio로 열기’를 선택하면 파일명과 Markdown의 대상 자료함/ZIP의 새 로컬 자료함을 확인하고 명시적으로 추가한다. 원문 파일은 보존하며 ZIP을 Files에서 먼저 풀 필요가 없다.

ZIPFoundation 0.9.20을 사용하며 MIT 고지문을 패키지 resource로 포함한다. 모든 archive 경로에서 traversal·symlink·NFC/대소문자 중복·파일/부모 충돌을 거부하고, 8,192 entry·깊이32·archive/확장256MiB를 제한한다. notes/·attachments/·metadata만 최대2,048파일로 복사한다. note256KiB·metadata64KiB·첨부50MiB와 실제 확장 size/CRC를 확인한 뒤 기존 importLocal의 identity/no-overwrite 계약으로 넘긴다. SQLite·초안·receipt는 제외하며 같은 ID의 자료함을 자동 병합하지 않는다.

Markdown은 body·줄바꿈·기존 metadata bytes를 보존하고, 안정 ID가 없을 때만 추가한다. 기존 ID 충돌·유형/관계 오류는 strict prepareEdit에서 거부한다. 준비에는 effect가 없으며 기존 CAS execute/receipt로 새 notes/ 원문을 저장한다. 같은 파일명은 새 경로를 쓰고 기존 문서를 덮어쓰지 않는다. 이는 첨부 import와 별도 기능이다. [공통 source import](/Users/ax/repoGithub/NativeAgent/Knowledge/KnowledgeKit/Sources/KnowledgeKitApple/WikiSourceImport.swift).

## Acornry 채택 조건

Acornry README의 기본 approvalOnly는 Bonjour 스트림을 암호화하지 않는다. private ProjectVault 전송에는 사용할 수 없다. preSharedKey는 호스트가 안전하게 제공한 32바이트 이상의 키가 필요하고, 현 패키지는 그 키 배포·pairing registry를 제공하지 않는다. iOS26+ Wi-Fi Aware system pairing은 지원 SDK/기기/서비스 선언/entitlement에 따른 조건부 연결 보안이며, 앱 수신 동의나 Folio import 선택을 대신하지 않는다.

초기 비교에서 public savedTransfers()만 있고 purge/forget이 없는 gap을 발견했다. 후속 구현에서 Acornry 자체 FileStore/Nearby에 완료 batch의 archive/restore를 추가했다. hidden archive의 실제 bytes도 원격 receipt·같은 ID lookup의 근거로 유지한다. Folio는 이 API로 active inbox64건/1GiB를 회전하며 bytes를 직접 삭제하지 않는다. 보관은 디스크 공간 회수가 아니다. 전송은 foreground 사용으로 한정하고 Folio의 protected-data/background admission과 Acornry stop/drain을 연결했다. background 완료를 보장하지 않는다. [실제 호스트 사용·보안 계약](NEARBY_TRANSFER.md).

Acornry는 iOS17+/macOS14+ Swift6 패키지이며 외부 SwiftPM dependency가 없다. MIT와 THIRD_PARTY_NOTICES를 보존한다. VERSION3.0.0은 검토 후보이며 README의 Apple SDK build·실제 무선 전송·SwiftUI runtime는 NOT_RUN이다. 이 로컬 비교를 그 gate의 PASS로 쓰지 않는다.

근거: [Acornry API](/Users/ax/repoMobileModule/Acornry/Sources/Acornry/AcornryNearby.swift), [보안 설정](/Users/ax/repoMobileModule/Acornry/Sources/Acornry/AcornryConfiguration.swift), [파일 저장](/Users/ax/repoMobileModule/Acornry/Sources/Acornry/AcornryFileStore.swift), [Apple 통합](/Users/ax/repoMobileModule/Acornry/docs/APPLE_INTEGRATION.md), [Folio sharing](../Sources/FolioUI/WikiSharing.swift), [원문 export/CAS 코어](/Users/ax/repoGithub/NativeAgent/Knowledge/KnowledgeKit/Sources/KnowledgeKitApple/WikiSourceExport.swift).

## 선택을 바꾸는 조건

Windows/Android/Linux 상대와 Folio 내부에서 직접 호환해야 하면 LocalSend protocol adapter의 가치가 커진다. Apple 기기만 대상으로 앱 안에서 수신/재개/영수증을 보여줘야 하면 Acornry가 더 작은 통합 단위다. 같은 개인의 Mac/iPhone 최신 원문을 계속 공유하려는 현재 요구에는 이미 작동한 iCloud 자료함이 정본 경로다. 새 network engine을 동기화로 오인해 채택하지 않는다.

## LocalSend의 실제 재사용 경계

로컬 app manifest는 1.18.2+64이고 Git metadata는 없다. 공식 release의 같은 버전 표시는 동일 source commit의 증거가 아니다. 현재 protocol 정본은 v2.2이며 prepare-upload의 파일 메타데이터→수신자의 subset 승인→session/file token upload 흐름을 제공한다. TLS 여부는 protocol의 선택과 앱의 실제 policy를 구분한다. 현재 로컬 Rust 구현은 일반 peer 경로에서 certificate fingerprint와 mutual TLS를 사용하고, browser web-send는 다른 경로다. [공식 release](https://github.com/localsend/localsend/releases), [protocol](https://github.com/localsend/protocol), [변경 기록](https://github.com/localsend/protocol/blob/main/CHANGELOG.md).

현재 구조는 Flutter UI → isolates/Flutter Rust Bridge → Rust localsend core다. 순수 Dart 전송 패키지도 SwiftPM product도 아니다. iOS podspec의 staticlib은 Flutter/cargokit 경로에 묶여 있어 Folio에 import하는 Swift SDK로 사용할 수 없다. native 내부 호환이 필수인 경우에만 C ABI/Swift host 또는 protocol adapter를 별도 범위로 구현한다.

iOS ShareExtension은 generic file/text를 받고 받은 Documents를 Files에 공개한다. 사용자가 설치한 LocalSend는 Folio의 native 공유창에서 선택하는 외부 전송 목적지로 활용할 수 있다. 이때 Folio 자체에 새 discovery·HTTP server·Rust runtime을 넣을 필요가 없다. 자동 multicast discovery를 새 앱에 넣는 경우 Local Network usage와 multicast entitlement가 필요하다. background에서 receiver socket이 유지된다고 보장하지 않는다. [Local Network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy), [multicast entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.multicast).

로컬 소스 근거: [Rust server](/Users/ax/repository/localsend/packages/core/src/http/server/v2.rs), [FRB server bridge](/Users/ax/repository/localsend/packages/localsend_isolates/rust/src/api/server.rs), [ShareExtension](/Users/ax/repository/localsend/app/ios/ShareExtension/Info.plist), [Files 설정](/Users/ax/repository/localsend/app/ios/Runner/Info.plist), [iOS podspec](/Users/ax/repository/localsend/packages/localsend_isolates/rust_builder/ios/rust_lib_localsend_app.podspec). 앱/core checkout의 LICENSE는 Apache-2.0이며 별도 protocol 문서 라이선스로 자동 확장하지 않는다.

Apple의 AirDrop도 가까운 기기에 문서를 보내는 system share 경로다. 현재 Mac/iPhone 전용 사용에는 기존 native 공유창을 우선 사용하고, Folio 내부 receiver·durable receipt가 별도로 필요한 경우에 Acornry 통합 비용을 감수하는 것이 사용자 단계와 코드 책임을 줄인다. [Apple AirDrop](https://support.apple.com/en-ie/guide/iphone/iphcd8b9f0af/ios).
