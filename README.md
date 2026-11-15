# AirDrop iCloud Mover

`~/Downloads`를 iCloud Drive의 Downloads 폴더로 연결(심볼릭 링크)해 두면, macOS AirDrop이 그 폴더에 저장하지 못하고 `/private/tmp`에 파일을 남깁니다. 이 도구는 그 파일을 iCloud Downloads 폴더로 **옮깁니다**. `~/Downloads` 연결과 Finder ⌥⌘L은 그대로 둡니다.

## 원인
`~/Downloads`가 링크인 상태에서 AirDrop으로 파일을 받으면 시스템 로그(sharingd)에 다음이 남습니다.

- `Whitelisted downloads folder url`: AirDrop이 저장할 수 있게 허용된 곳은 `~/Downloads`
- `Failed to accees downloads directory, falling back`: 링크가 가리키는 iCloud 경로에 접근하지 못해 대체 위치에 저장

`~/Downloads`가 링크인 한 매번 이렇게 됩니다(macOS 26에서 확인). 확인한 범위에서 AirDrop 저장 위치를 바꾸는 공식 설정은 없습니다.

## 동작 방식
- **언제 실행되나:** `/private/tmp`에 변화가 생기면 macOS(launchd)가 실행합니다. 감지를 놓칠 때를 대비해 5분마다 한 번 더 확인합니다. 받을 파일이 없으면 바로 끝납니다.
- **무엇을 옮기나:** `/private/tmp` 바로 아래에 있고, 내 계정 소유이며, AirDrop 표식(quarantine 기록의 `sharingd`)이 있는 파일만 옮깁니다. 다른 앱의 임시 파일, 폴더, 링크는 건드리지 않습니다.
- **언제 옮기나:** 3초 동안 변하지 않고 파일에 쓰고 있는 프로그램이 없을 때 옮깁니다. Finder 미리보기(스페이스바)처럼 읽기만 하는 프로그램은 막지 않습니다. 계속 바뀌거나 쓰는 중이면 최대 3분 기다리고, 그래도 안 되면 다음 실행에서 다시 봅니다.
- **어떻게 옮기나:** 기본 구성의 Mac에서는 `/private/tmp`와 iCloud Drive가 같은 디스크 볼륨이라 복사가 아니라 위치만 바꿉니다. 즉시 끝나고 디스크를 더 쓰지 않으며, 파일 내용과 속성도 그대로 남습니다. 볼륨이 다르면 macOS의 `mv`가 복사한 뒤 원본을 지웁니다.
- **같은 이름이 있으면:** 덮어쓰지 않고 `사진 (2).HEIC`처럼 번호를 붙입니다.

## 사용법
이 저장소의 **Code → Download ZIP**으로 받아 압축을 풀고 터미널을 엽니다. `cd `(뒤에 공백 한 칸)를 입력하고, 풀린 폴더를 터미널 창으로 끌어다 놓은 뒤 Return을 누릅니다.

**1. 확인만 하기** (아무것도 바꾸지 않음)
```bash
/bin/bash mover.sh check
```
`~/Downloads 연결 대상`이 iCloud Downloads 폴더인지 봅니다.

**2. 설치** (지금 `/private/tmp`에 있는 AirDrop 파일도 바로 옮겨집니다)
```bash
/bin/bash mover.sh install
```
`y`를 입력하면 설치됩니다. sudo, 추가 프로그램, 보안 설정 변경은 필요 없습니다.

**3. 동작 확인**
작은 사진 하나를 AirDrop으로 보내고 30초쯤 뒤에 확인합니다.
```bash
/bin/bash mover.sh status
```
`MOVED 파일이름 -> 파일이름`이 보이면 정상입니다. Finder ⌥⌘L에서도 확인하세요.

**4. 지금 바로 한 번 옮기기** (설치하지 않고 쓰거나, 자동 실행이 막혔을 때)
```bash
/bin/bash mover.sh run
```

**5. 제거**
```bash
/bin/bash mover.sh uninstall
```
자동 실행만 제거합니다. 이미 옮긴 파일과 로그는 남습니다.

설치하면 스크립트가 `~/Library/Application Support/AirDrop iCloud Mover/`에 복사되므로, 압축을 푼 폴더는 지워도 됩니다. 그 뒤에 `status`나 `uninstall`을 쓰려면 아래처럼 실행합니다.
```bash
/bin/bash "$HOME/Library/Application Support/AirDrop iCloud Mover/mover.sh" status
```

## 문제가 생기면
- **`status`에 `privacy permission`이 보일 때:** 백그라운드에서 도는 `/bin/bash`가 iCloud Drive에 접근하지 못한 것으로 보입니다. 터미널에서 `run`이 되는지 먼저 확인하세요. 터미널에서는 되는데 자동 실행만 막히면, 시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에 `/bin/bash`를 추가해야 할 가능성이 큽니다. 다만 그러면 bash로 실행되는 모든 스크립트가 같은 권한을 갖게 됩니다. 원하지 않으면 자동 실행을 제거하고 필요할 때 `run`만 쓰세요.
- **기록 위치:** `~/Library/Logs/AirDrop iCloud Mover.log`. Console 앱에서도 볼 수 있고, 1MB를 넘으면 `.1` 파일로 넘깁니다.

## 한계
- **3초 대기는 완료 보장이 아닙니다.** 로그상 AirDrop은 수신과 압축 해제를 끝낸 뒤 파일을 내놓고, 파일에 쓰는 프로그램이 있으면 기다리므로 대개 완성본입니다. 큰 동영상은 처음 한 번 원본 크기와 재생을 직접 확인하세요.
- **`sharingd` 표식은 출처를 추정하는 단서일 뿐입니다.** AirDrop이 아닌 다른 공유 수신 파일도 같은 표식이면 함께 옮겨질 수 있습니다.
- **iCloud 업로드 완료는 이 도구가 확인하지 않습니다.** Finder의 동기화 표시로 확인하세요.

## 설계 결정
- **복사 대신 이동:** `/private/tmp`는 macOS가 비우는 곳이라 원본을 남겨도 백업이 되지 않습니다. 같은 볼륨이라 이동은 즉시 끝나고 속성도 바뀌지 않으므로, 복사본을 원본과 대조하는 단계가 필요 없습니다.
- **주기 실행 대신 폴더 변화 감지 + 5분 안전망:** `/private/tmp`에 변화가 있을 때만 실행되고, 받을 파일이 없으면 바로 끝납니다. 감지를 놓칠 수 있다는 점은 launchd 설명서에 명시돼 있어서 5분 안전망을 둡니다.
- **선택하지 않은 안:** `~/Downloads`를 원래 폴더로 되돌리기(⌥⌘L이 로컬 폴더를 열고, 브라우저가 받는 중인 파일까지 처리해야 함), Finder 폴더 액션(시스템 숨김 폴더에서 불안정), Swift 감시 앱(컴파일과 서명 필요), fswatch(추가 설치 필요).

## 파일
- `mover.sh`: 실행 스크립트 하나 (약 200줄)
- `tests/test_mover.sh`: 실제 macOS 도구로 임시 폴더에서 검증. 실제 `/private/tmp`, Downloads, iCloud는 건드리지 않습니다.
- `tests/LAST_RUN.txt`: 마지막 테스트 결과
- `LICENSE`: MIT 라이선스
