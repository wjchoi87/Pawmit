# Third-party notices

Pawmit은 아래 오픈소스의 코드·데이터·설계를 참고하거나 Swift로 옮겨 다시 작성했습니다.
각 소스 파일 상단 주석에 어디서 무엇을 가져왔는지 적어 두었습니다.
**펫 그림·에셋은 어떤 저장소에서도 가져오지 않았습니다.** 기본 펫은 모두 코드로 새로 그린 것입니다.

## 코드를 옮겨 쓴 것 (MIT)

| 프로젝트 | 저작권 | Pawmit에서 쓴 곳 |
|---|---|---|
| [boxed-dev/bezel](https://github.com/boxed-dev/bezel) | Copyright (c) 2026 Bezel contributors | 결정 JSON(PermissionRequest·AskUserQuestion·ExitPlanMode), 설정 merge·uninstall, 터미널 점프(iTerm·Terminal·tmux·kitty), tty 추출, AppleScript 이스케이프 — `AgentAdapters.swift`, `HookInstaller.swift`, `TerminalJumper.swift`, `PawmitCLI/main.swift` |
| [Louis-CFM/coucou](https://github.com/Louis-CFM/coucou) | Copyright (c) 2026 Louis Raillé | 멀티 에이전트 이벤트·필드 정규화, 에이전트별 설치 형식, 소켓 uid 검사, 설정 strict read·백업, OpenCode 플러그인 구조 — `AgentAdapters.swift`, `HookInstaller.swift`, `UnixSocket.swift` |
| [matias-mn/hookling](https://github.com/matias-mn/hookling) | Copyright (c) 2026 hookling contributors | Codex 펫 스프라이트시트 규격과 행별 프레임 시간, 투명 펫 창 설정, SplitMix64 시드 난수 아이디어 — `SpritePack.swift`, `PetActor.swift`, `Seeded.swift` |
| [OpenPetsHQ/openpets](https://github.com/OpenPetsHQ/openpets) | Copyright (c) 2026 OpenPets | hook 이벤트 → 펫 반응 매핑, 욕구 모델, Codex v2 시트·pet.json 검증 규칙, 투명 영역 클릭 통과 방식 — `PetState.swift`, `SpritePack.swift`, `Director.swift` |
| [bssm-oss/desktop-pet](https://github.com/bssm-oss/desktop-pet) | Copyright (c) 2025 bssm-oss | GIF·APNG 프레임 디코딩과 delay 처리 — `SpritePack.swift` |
| [tonybaloney/vscode-pets](https://github.com/tonybaloney/vscode-pets) | Copyright (c) 2022 Anthony Shaw | 상태 지속 시간·속도 계수, 공 던지기 물리 (코드만, 미디어 제외) — `Brain.swift`, `Props.swift` |
| [orta/esheep-macos](https://github.com/orta/esheep-macos) | Copyright (c) 2025 Orta Therox | 가중치 룰렛 행동 선택 — `Seeded.swift` |
| [almathkurali/octo-pet](https://github.com/almathkurali/octo-pet) | Copyright (c) 2026 Ali Almathkur | 클릭·드래그 구분 패턴 — `PetActor.swift` |
| [ethanmcrae/agent-pet](https://github.com/ethanmcrae/agent-pet) | Copyright (c) 2026 Xander Hunt | 집 들어가기·나오기 연출(가라앉기·솟아오르기) 아이디어 — `Brain.swift` |
| [Tri9ster/hooknotice](https://github.com/Tri9ster/hooknotice) | Copyright (c) 2026 Tri9ster | 차단형 PermissionRequest 응답 흐름 참고 |
| [anthropics/claude-desktop-buddy](https://github.com/anthropics/claude-desktop-buddy) | Copyright 2026 Anthropic, PBC | 승인·상태 프로토콜 설계 참고 |
| [caigee-cmd/claude-petty](https://github.com/caigee-cmd/claude-petty) | Copyright (c) 2026 Claude Glance Contributors | 메뉴바 패널 설정 참고 |
| [SeakMengs/WindowPet](https://github.com/SeakMengs/WindowPet) | Copyright (c) 2023 Seakmeng | 펫 오버레이 구조 참고 |
| [adryd325/oneko.js](https://github.com/adryd325/oneko.js) | Copyright © 2022 adryd | 커서 쫓기 동작 참고 |

MIT License 전문:

```
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## 데이터·설계를 참고한 것 (Apache License 2.0 · Unlicense)

| 프로젝트 | 라이선스 | 참고한 것 |
|---|---|---|
| [openai/codex](https://github.com/openai/codex) | Apache-2.0 | Codex 펫 시트 규격·행별 프레임 시간 데이터 (hookling 정리본 경유) |
| [farouqaldori/vibe-notch](https://github.com/farouqaldori/vibe-notch) | Apache-2.0 | non-activating 패널 설정, 터미널 앱 목록 (코드 복사 없음, 설계 참고) |
| [mdonoughe/neko-mac](https://github.com/mdonoughe/neko-mac) | Unlicense (public domain) | 커서 추적·idle→잠 전이 |

Apache-2.0 원문: https://www.apache.org/licenses/LICENSE-2.0

## 동작만 참고하고 코드는 쓰지 않은 것

| 프로젝트 | 라이선스 | 비고 |
|---|---|---|
| [pixelomer/Shijima-Qt](https://github.com/pixelomer/Shijima-Qt) | GPL-3.0 | Shimeji 행동 개념만 |
| [rullerzhou-afk/clawd-on-desk](https://github.com/rullerzhou-afk/clawd-on-desk) | AGPL-3.0 | 에이전트 이벤트 → 상태 매핑 사실 정보만 |
| Kumario1/agentNotch, justinpaulson/claude-pet | 라이선스 없음 | 아이디어만 (터미널 응답 시 소켓 EOF로 정리 등) |

## 캐릭터

기본 펫 6종은 "작고 둥근 치비" 화풍을 따른 **오리지널 디자인**입니다. 특정 작품의 캐릭터 이름·모양을 복제하지 않았습니다.
