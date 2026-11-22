# Codex·Claude 스킬과 플러그인 관리

확인일: **2026-10-22**. 이 문서는 Folio의 현재 구현과 당시 확인한 공식 계약을 설명한다. 호스트 CLI의 옵션은 버전에 따라 달라지므로 Folio는 실행 전에 실제 하위 명령의 `--help`를 확인한다.

## 제공하는 기능

Mac의 Folio 설정에서 **스킬**과 **플러그인** 탭을 사용한다. 스킬 탭은 로컬 폴더 또는 Git 저장소에서 가져온 standalone 스킬을 설치·조회·업데이트·제거한다. 플러그인 탭은 설치된 Codex 또는 Claude Code CLI에 작업을 위임한다. iOS 앱에는 로컬 에이전트 관리 화면이 없다.

관리 코어는 Swift 6의 `FolioAgents` 모듈이다. `SkillStore`가 standalone 설치 변경을 소유하며, 플러그인 설정과 캐시는 호스트 CLI가 소유한다. Folio는 플러그인의 설정 파일을 직접 편집하지 않는다.

`SkillCatalog`는 선택한 홈과 설치 목록·영수증 해석을 담당하는 읽기 전용 값이다. `SkillStore`는 같은 catalog를 사용하되 작업 단계, 대상 경로·소유 영수증·현재 파일 해시의 재검사와 staging·rename·복구를 소유한다. 목록에서 관리 가능으로 표시된 항목도 변경 직전에 다시 검사한다.

플러그인 화면의 `AgentPluginsModel`은 캡처한 요청과 실행 Task를 하나의 `Job`으로 등록한다. 취소·화면 종료는 이 작업을 대상으로 하며, 같은 요청의 결과만 표시 상태에 반영한다. 설치 효과는 기존 호스트 CLI가 계속 소유한다.

## Standalone 스킬 경로

| 호스트 | 글로벌 신규 설치 | 프로젝트 신규 설치 | Folio의 기존 설치 처리 |
| --- | --- | --- | --- |
| Codex | `<선택한 홈>/.agents/skills/<name>` | `<선택한 프로젝트>/.agents/skills/<name>` | 글로벌 목록에 `~/.codex/skills` 호환 경로도 표시, 읽기 전용 |
| Claude Code | `<선택한 홈>/.claude/skills/<name>` | `<선택한 프로젝트>/.claude/skills/<name>` | Folio 소유 영수증이 없는 설치와 심볼릭 링크는 읽기 전용 |

Codex 공식 신규 경로는 `.agents/skills`이다. `.agent` 단수는 지원 경로로 취급하지 않는다. Codex의 실제 탐색에는 CWD부터 프로젝트 루트까지 각 `.agents/skills`, 사용자·관리자·번들 경로 등이 포함되지만, Folio의 목록은 **선택한 설치 대상의 직속 스킬 폴더와 글로벌 Codex 호환 경로**를 보여준다. 호스트의 모든 활성 스킬을 재현하는 목록은 아니다. [OpenAI 스킬 문서](https://learn.chatgpt.com/docs/build-skills)

Codex 소스는 `$CODEX_HOME/skills`를 이전 사용자 경로로 명시하고 계속 읽는다. Folio의 호환 목록은 기본 `~/.codex/skills`만 확인하며 별도 `CODEX_HOME` 탐색·이전·정리는 하지 않는다. 기존 위치의 스킬을 자동으로 옮기거나 덮어쓰지 않는다. [검토한 Codex 경로 해석 구현](https://github.com/openai/codex/blob/86e17e98c7f901277aeeb4649cf1b01462b082f2/codex-rs/ext/skills/src/host_roots.rs)

Claude는 개인 스킬을 `~/.claude/skills`, 프로젝트 스킬을 `.claude/skills`에서 읽는다. 같은 이름의 enterprise·personal·project 스킬은 enterprise → personal → project 순으로 우선한다. 플러그인 스킬에는 별도 네임스페이스가 붙는다. Codex는 같은 이름의 스킬을 병합하지 않으므로 경로가 다른 중복을 목록에서 구분해야 한다. Claude의 `synced`, `anthropic-skills` 이름은 계정 동기화 관련 예약 이름이어서 Folio 신규 설치에서 거부한다. `.claude/commands` 이전 형식이나 계정 동기화 디렉터리를 Folio가 변경하지 않는다. [Claude 스킬 문서](https://code.claude.com/docs/en/skills)

## 형식 검증과 소유권

스킬 폴더에는 UTF-8 `SKILL.md`가 필요하다. YAML frontmatter의 `name`은 폴더 이름과 같아야 하며 1–64자의 소문자·숫자·하이픈이다. 처음·끝 하이픈과 연속 하이픈은 허용하지 않는다. `description`은 비어 있지 않은 1–1,024자 문자열이다. YAML은 Yams로 읽으므로 인용 문자열·여러 줄 문자열을 지원한다. [Agent Skills 표준](https://agentskills.io/specification)

Folio의 설치 한도는 다음과 같다.

- `SKILL.md`: 256 KiB 이하.
- 설치 사본: 일반 파일 합계 32 MiB 이하, 파일·폴더 4,096개 이하.
- 원본 내부 심볼릭 링크·특수 파일과 외부 경로로 빠지는 Git 하위 경로: 거부.
- 대상의 `.agents`·`.claude`·`skills` 구성 요소가 심볼릭 링크인 경우: 쓰기 거부.

호스트가 심볼릭 링크 스킬을 지원하더라도 Folio가 임의의 링크 대상을 변경하지는 않는다. 기존 링크는 목록에서 확인할 수 있지만 Folio의 신규 설치 원본으로 사용할 수 없다. 대상 목록은 호스트의 동적 등록·계정 스킬·중첩 폴더 전체를 합산하지 않는다.

설치 시 `.folio-install.json`에 원본 정보, Git commit, 대상 경로와 내용·권한 SHA-256을 기록한다. 업데이트·제거는 해당 대상의 유효한 영수증과 현재 파일 해시가 일치할 때만 가능하다. 설치 후 사용자가 수정한 파일이나 다른 도구가 만든 설치는 보존한다. 영수증에는 다음 업데이트에 필요한 Git URL이 들어갈 수 있으므로 공개 저장소에 포함하기 전에 내용을 확인해야 한다. 토큰을 포함한 URL은 입력 단계에서 거부한다.

설치는 같은 대상 파일시스템의 staging 폴더에서 준비한 뒤 배타적 rename으로 반영한다. 업데이트는 원자적 swap으로 기존 설치를 교체한다. 취소가 반영 직전·직후에 도착할 수 있으므로 화면은 현재 목록을 다시 읽고 결과를 표시한다. 자동 백업 이력·여러 세대 rollback UI는 제공하지 않는다.

## Git와 프라이빗 원본

Git 원본은 HTTPS, SSH 또는 `git@host:owner/repo.git` 형식과 저장소 내부 상대 경로를 받는다. `ref` 기본값은 `HEAD`이며 branch·tag·commit을 실제 commit ID로 해석한 뒤 detached checkout한다. 영수증의 `revision`은 그 설치에서 사용한 commit이다. 다음 업데이트는 원래 저장소·ref를 다시 확인하므로 branch/tag가 이동했다면 새 commit을 가져올 수 있다.

프라이빗은 설치 범위와 별개다. 글로벌·프로젝트 어느 쪽이든 원본 저장소에 접근할 인증이 있어야 한다. Folio 자체 로그인·토큰 저장 UI는 없고 기존 Git credential helper와 SSH 인증을 사용한다. standalone Git 실행은 대화형 prompt와 저장소 hook을 차단하며 SSH에 BatchMode와 이미 확인된 host key를 요구한다. 처음 보는 host 또는 준비되지 않은 인증은 실패한다. 실제 프라이빗 서버에 대한 인증 성공은 이번 검증에서 확인하지 않았다.

32 MiB 한도는 **선택한 스킬 설치 사본**의 한도다. Git은 blob filter로 clone하지만 저장소 checkout에 필요한 네트워크 전송량·임시 저장소 크기 전체를 32 MiB로 제한하지는 않는다.

Claude 공식 프라이빗 marketplace도 기존 비대화형 Git 인증을 사용한다. SSH 키·known_hosts 또는 HTTPS credential helper 준비가 필요하며 marketplace manifest에 토큰을 넣는 계약은 없다. [프라이빗 marketplace 인증](https://code.claude.com/docs/en/plugins/host-marketplace)

## 플러그인·마켓플레이스

Standalone 스킬 폴더를 복사하는 작업과 플러그인 설치는 별개다. OpenAI portable 플러그인은 루트 `plugin.json`, `skills/`, `mcp.json`을 사용하고 `.codex-plugin/plugin.json`은 호환 형식이다. Claude 플러그인은 `.claude-plugin/plugin.json`과 루트의 컴포넌트 폴더를 사용한다. Folio가 두 형식의 내용을 임의 변환하지 않는다. [OpenAI 패키징 문서](https://developers.openai.com/plugins/build/plugins), [Claude 플러그인 개요](https://code.claude.com/docs/en/plugins)

| Folio 작업 | Codex 실제 명령 | Claude Code 실제 명령 |
| --- | --- | --- |
| 플러그인 목록 | `plugin list` | `plugin list` |
| 플러그인 설치 | `plugin add ID` | `plugin install ID` |
| 플러그인 제거 | `plugin remove ID` | `plugin uninstall ID` |
| 개별 업데이트 | 제공하지 않음 | `plugin update ID` |
| 활성화·비활성화 | 제공하지 않음 | `plugin enable ID`, `plugin disable ID` |
| 마켓플레이스 목록 | `plugin marketplace list` | `plugin marketplace list` |
| 추가 | `plugin marketplace add SOURCE` | `plugin marketplace add SOURCE` |
| 갱신 | `plugin marketplace upgrade NAME` | `plugin marketplace update NAME` |
| 제거 | `plugin marketplace remove NAME` | `plugin marketplace remove NAME` |

`ID`는 목록의 `name@marketplace`, `NAME`은 등록된 marketplace 이름이다. 입력은 shell 문자열로 이어 붙이지 않고 argument 배열로 전달한다. 옵션 형태의 ID·제어문자·자격 증명이 포함된 원본 주소는 거부한다.

Codex는 플러그인 작업에 `--scope`를 제공하지 않는다. Folio companion의 `user` 선택값은 이 경우 기본 실행을 나타낼 뿐 실제 `--scope user`를 전달하지 않는다. Claude의 변경 작업에는 명시적인 `user`·`project`·`local` 범위를 전달한다. 프로젝트 범위는 스킬 탭에서 선택한 프로젝트를 작업 폴더로 사용하며, 마켓플레이스 갱신·목록처럼 범위 옵션이 없는 명령에는 붙이지 않는다.

CLI를 찾는 위치는 사용자 `.local/bin`, `.npm-global/bin`, Homebrew·시스템 bin, 기존 PATH와 알려진 Codex 앱 번들이다. 자동으로 찾지 못하면 실행 파일을 직접 선택한다. 각 실행 전에 실제 subcommand help와 필요한 `--scope` 지원을 확인한다. 지원되는 경우 목록은 `--available --json`, 다른 명령은 `--json`을 사용한다. 이전 버전에서 `--json`·`--available`이 없으면 해당 선택 옵션을 빼고 텍스트 결과를 표시한다. 필수 범위를 조용히 생략하지 않는다.

검토한 설치 Codex는 `0.162.0-alpha.17.2`이다. 당시 help와 공식 Rust 구현은 `add/list/remove`, marketplace `add/list/upgrade/remove`를 제공한다. `upgrade`는 변경된 Git marketplace를 가져온 후 관련 설치 플러그인 캐시 갱신도 수행한다. 이 동작을 존재하지 않는 `codex plugin update` 명령으로 대체하지 않는다. [CLI 구현](https://github.com/openai/codex/blob/86e17e98c7f901277aeeb4649cf1b01462b082f2/codex-rs/cli/src/plugin_cmd.rs), [Marketplace 명령](https://github.com/openai/codex/blob/86e17e98c7f901277aeeb4649cf1b01462b082f2/codex-rs/cli/src/marketplace_cmd.rs), [갱신 후 캐시 처리](https://github.com/openai/codex/blob/86e17e98c7f901277aeeb4649cf1b01462b082f2/codex-rs/core-plugins/src/manager.rs)

Claude의 최신 문서에는 plugin list의 `--available --json`, plugin 변경 작업의 `--json`, marketplace 변경 작업의 `--json`이 있다. 이 환경에는 Claude CLI가 없어 실제 실행 검증은 하지 않았다. 호스트 버전별 차이를 help로 확인하는 이유다. [Claude CLI 명령 계약](https://code.claude.com/docs/en/plugins/cli-reference)

제거는 호스트 설정·설치 캐시를 변경한다. Claude는 마지막 marketplace 선언을 제거할 때 관련 플러그인과 저장된 설정·비밀값·데이터도 삭제할 수 있다. 화면은 제거 대상을 확인한 뒤 실행한다. 실행 중단 또는 실패는 이미 반영된 일부 변경을 되돌렸다는 의미가 아니며 목록 재조회가 필요하다.

CLI stdout/stderr는 합계 1 MiB까지 읽고 과도한 출력은 중단한다. 임시 출력 파일 크기를 주기적으로 검사하므로 디스크의 순간 사용량은 한도를 초과할 수 있다. 취소는 확인된 전용 프로세스 그룹을 종료한다. 하위 도구가 별도 세션·그룹을 만든 경우 그 생명주기까지 보장하지 않는다. 화면에 표시하기 전에 원본 URL·알려진 토큰 형태·자격 증명 필드를 가린다. 호스트가 출력할 수 있는 모든 임의 비밀값을 완벽히 식별하는 기능은 아니다.

## Swift companion과 macOS sandbox

서명된 Mac 앱은 App Sandbox를 사용한다. 글로벌 작업은 실제 사용자 홈, 프로젝트 작업은 대상 프로젝트, 로컬 설치·업데이트는 원본 폴더를 picker로 선택해 접근 권한을 부여해야 한다. 선택한 홈을 기준으로 글로벌 경로를 계산하므로 기본 sandbox container 홈을 실제 사용자 홈으로 오인하지 않는다. 현재 선택과 접근은 창·작업 수명에 묶이며 Folio가 모든 경로의 영구 접근을 자동 확보하지 않는다.

프로젝트 폴더 접근 권한이 있어도 외부 `git`·호스트 CLI·credential helper·SSH agent·네트워크 접근 권한이 함께 생기는 것은 아니다. sandbox에서 실행이 막히면 터미널용 Swift companion을 사용한다. 앱이 sandbox를 우회하거나 다른 앱의 권한을 복제하지 않는다.

```sh
swift run FolioAgentsCLI --help
swift run FolioAgentsCLI list --host codex --scope global
swift run FolioAgentsCLI install --host claude --scope project --project . --source ./skills/my-skill
swift run FolioAgentsCLI install --host codex --scope global --repo git@github.com:owner/private.git --path skills/my-skill
swift run FolioAgentsCLI update --host codex --scope global --name my-skill
swift run FolioAgentsCLI remove --host claude --scope project --project . --name my-skill
swift run FolioAgentsCLI plugin --host codex --action list
swift run FolioAgentsCLI plugin --host claude --action install --value plugin@marketplace --scope project --project .
```

CLI의 standalone `--scope`는 `global|project`, plugin `--scope`는 `user|project|local`이다. standalone에는 `--home PATH`, plugin에는 `--executable PATH`를 지정할 수 있다. 상대 로컬 경로는 현재 작업 폴더 기준이다. 성공 결과는 JSON이며 원본 Git URL을 출력하지 않는다. 오류는 stderr와 종료 코드 1, 잘못된 옵션은 종료 코드 2로 반환한다. CLI 제거 명령은 지정한 작업을 바로 실행하므로 대상을 먼저 `list`로 확인한다.

Folio의 본체·관리 코어·companion은 Swift다. 그래도 외부 플러그인에 포함된 Python/Node/MCP 실행 파일이 없어지는 것은 아니다. 공식 Codex와 Claude marketplace는 npm package source도 지원하며 이 경우 호스트는 npm client와 registry 인증 설정을 사용할 수 있다. Bun·Python을 Folio의 자체 설치 런타임으로 요구하지 않는 것과 모든 외부 패키지의 런타임을 제거하는 것은 다른 계약이다. [OpenAI npm source](https://developers.openai.com/plugins/build/plugins), [Claude package source](https://code.claude.com/docs/en/plugins/marketplace-reference)

## 설계 참고와 검증 경계

상태와 효과를 분리한 처리, 반영 전 완성된 사본을 만드는 설치 방식에는 다음 연구를 참고했다. 논문은 호스트 설치 경로·옵션·인증 계약의 근거가 아니다.

- David Harel, *Statecharts: A Visual Formalism for Complex Systems*, Science of Computer Programming 8, 1987: 복잡한 이벤트 상태를 계층·전이로 표현하는 설계 배경. [저자 출판 목록](https://www.weizmann.ac.il/math/harel/publications-0), [논문](https://www.weizmann.ac.il/math/harel/sites/math.harel/files/users/user50/Statecharts.pdf)
- Eelco Dolstra, Andres Löh, Nicolas Pierron, *NixOS: A Purely Functional Linux Distribution*: 불변 산출물과 원자적 전환으로 부분 업데이트를 줄이는 설계 배경. Folio가 Nix의 세대 관리 전체를 구현했다는 의미는 아니다. [저자 공개 원고](https://edolstra.github.io/pubs/nixos-jfp-submitted-v2.pdf)

실제 글로벌 스킬 설치·플러그인 설치·제거는 개발 검증 중 실행하지 않았다. 임시 홈·로컬 Git fixture와 명령 생성·입력 검증·취소·출력 제한을 검증 대상으로 삼는다. Private 원격 인증, 실제 Claude CLI, sandbox 서명본의 모든 외부 CLI 조합은 별도 현장 검증이 필요하다.
