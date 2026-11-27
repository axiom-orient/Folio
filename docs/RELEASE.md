# Folio v0.1.0 소스 릴리스

Folio는 Mac·iPhone·iPad용 자료함이다. PDF·Markdown을 추가하고, 한글·영문 근거를 찾아 원문 페이지와 구획을 연다. 확인한 근거는 별도 노트로 저장하고, 저장한 인용을 다시 열 수 있다. [PDF 지원 범위](PDF_EVIDENCE.md)

## 구조와 정리

| 경계 | 구현과 최종 점검 |
| --- | --- |
| 자료 추가와 원문 | `FolioFileIntake`가 현재 자료함의 요청을 `WikiWorkspace`에 전달한다. 파일명에 콜론이 있어도 첨부 링크를 해석할 수 있으며, URL 스킴과 자료함 밖 경로는 계속 검증한다. 첨부 노트와 근거 노트는 같은 링크 생성을 사용한다. |
| 검색과 인용 | `WikiKnowledgeQuery`가 다시 만들 수 있는 색인을 관리한다. `WikiWorkspace`는 결과 게시·원문 열기·저장 직전에 현재 원본 버전과 출처를 대조한다. 본문이 있는 PDF는 실제 이미지 영역만 OCR한다. |
| 쓰기와 복구 | 명시 저장, 관계 승인, 원문 버전 검사, 완료 영수증과 초안 복구는 기존 소유자가 처리한다. 여러 번의 원문 검사는 각 파일에 적용된다. |
| 배포 구성 | 두 런타임 검사 타깃은 같은 테스트 소스와 fixture를 읽는다. 중복 아이콘 출력을 제거했다. 검색 모델이 재현에 사용하는 원본 토크나이저 JSON은 개발 도구에 보관하고 앱에는 압축된 토크나이저를 포함한다. |

## 배포 산출물

[GitHub Releases](https://github.com/axiom-orient/Folio/releases/tag/v0.1.0)에서 **Folio-0.1.0-source.tar.gz**와 체크섬을 받는다. 릴리스에 첨부한 아카이브에는 두 모델과 압축 토크나이저가 들어 있다. Git으로 받는 경우 `v0.1.0` 태그를 선택한 뒤 `git lfs pull`을 실행한다. [Git LFS와 GitHub 생성 소스 아카이브](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/managing-git-lfs-objects-in-archives-of-your-repository)

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./script/build_and_run.sh --build-only
./script/build_ios.sh --local-simulator
```

Xcode 27 이상이 필요하다. 위 Mac 명령은 로컬 자료함 개발 앱을 만든다. iCloud·App Group·Spotlight가 포함된 Mac과 iOS 애플리케이션은 `Folio.xcodeproj`에서 각 Apple 개발팀의 서명과 권한으로 빌드한다. 공개 Mac 설치 파일에는 배포용 서명과 Apple 공증이 필요하다. [Mac 개발 구성](../MacApp/README.md) · [Apple 공증 요구 사항](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

릴리스 아카이브는 태그가 가리키는 공개 소스를 기준으로 만들며 모델 파일의 해시를 대조한다. 라이선스와 제3자 고지는 [LICENSE](../LICENSE)와 [Vendor 고지](../Vendor/README.md)를 따른다.

콜론 PDF의 가져오기 재시도와 인용, 이름이 바뀐 폴더의 링크와 복원, 혼합 PDF와 원문 검증, 관계 승인 영수증과 초안 복구를 포함한 핵심 회귀 34개를 확인했다. 소스에 포함된 토크나이저를 다시 생성해 기존 산출물과 바이트 단위로 대조했다.
