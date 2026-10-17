# 펫 만들기·고치기·주고받기

Pawmit 펫은 모두 **pet.json 하나**로 정의됩니다. 기본 펫 7종도 같은 형식이라(`Sources/PawmitCore/Pets/PetCatalog.swift`의 `builtinJSON`),
사람이든 에이전트든 JSON만 고치면 새 펫을 만들 수 있습니다.

| 하고 싶은 것 | 방법 |
|---|---|
| 완전히 새로운 생김새의 펫 | **펫 메이커** (`"kind": "rig"`) — 직접 그리기 / 부위별 그림 파일 / 말로 설명 → AI 초안 |
| 기본 펫의 색·부위만 바꾼 변형 | `"base": "mongle"` + 바꿀 필드 |
| 그림 파일·Codex 스프라이트로 된 펫 | 그림 펫 (kind 없음) |
| 성격·말투·색 | **스타일** — 모든 펫에 공통 (`style`, 설정 → 펫 → 스타일) |

## 펫 메이커 (kind "rig")

메뉴바 집 → 커스텀 펫 만들기 → **펫 메이커**, 또는 설정 → 펫 → 펫 메이커.

1. 몸 구조를 고릅니다: **두 발**(치비형) · **네 발**(옆모습) · **다리 없음**(통통 튀기) · **날개**(파닥이며 떠다니기)
2. 부위(머리·몸·팔·다리·귀·꼬리·날개·장식)를 고르고 그립니다
   - 펜: 손으로 그으면 손떨림을 줄인 매끈한 닫힌 모양이 됩니다. **무늬**를 켜면 외곽선 없이 부위 안쪽에만 칠해집니다(배·점·귀 안쪽)
   - 동그라미, 옮기기(부위 끌기 / 주황 점 = 관절 끌기), 얼굴 위치, 지우개, 되돌리기(⌘Z)
   - 그림 넣기: 부위마다 PNG·GIF를 넣거나 캔버스에 끌어다 놓기
   - **말로 설명해서 초안 받기**: 로그인된 claude(안 되면 codex)가 고른 몸 구조에 맞춰 그려 줍니다
3. 오른쪽 미리보기에서 걷기·먹기·잠 등 모든 동작을 바로 확인하고 저장합니다

눈·입은 코드로 그려서 기본 펫처럼 표정(깜빡임·웃음·놀람·울음 …)이 자동으로 바뀝니다. 행동 수천 가지와 모니터 건너기도 그대로 붙습니다.

### 형식

좌표는 SVG와 같습니다: **100×100 캔버스, y는 아래로, 바닥선 y=96, 가운데 x=50**. 두 발·다리 없음·날개는 정면, 네 발은 오른쪽을 봅니다.
부위 모양은 SVG path(`d`)라서 `pawmit pet svg <펫>`으로 뽑아 아무 SVG 뷰어에서 볼 수 있습니다.

```json
{
  "kind": "rig", "name": "새싹감자", "interjection": "싹!", "skeleton": "biped",
  "outline": "#5A3B1C", "lineWidth": 3,
  "parts": {
    "body": { "shapes": [ { "d": "M35 80 A15 13.5 0 1 1 65 80 A15 13.5 0 1 1 35 80 Z", "fill": "#C9915A" },
                          { "d": "M44 78 A6 5 0 1 1 56 78 A6 5 0 1 1 44 78 Z", "fill": "#E8C08A", "line": false } ] },
    "head": { "shapes": [ { "d": "M28 52 A22 18 0 1 1 72 52 A22 18 0 1 1 28 52 Z", "fill": "#C9915A" } ] },
    "acc1": { "parent": "head", "shapes": [ { "d": "M48 35 C44 26 52 24 51 33 Z", "fill": "#7CC36B" } ] },
    "armL": { "image": "arm-left.png", "imageRect": [28, 68, 12, 18] }
  },
  "face": { "anchor": [50, 54], "parent": "head", "eyes": "dot", "eyeGap": 14, "mouth": "smile", "blush": "#F7A5B8" }
}
```

| 필드 | 값 |
|---|---|
| `skeleton` | `biped` `quadruped` `blob` `winged` |
| `parts.<부위>` | 부위 id는 뼈대마다 다름 (아래 표) + 장식 `acc1`…`acc6`(`parent`로 붙을 뼈) |
| `shapes[]` | `d`(SVG path: M L H V C S Q T A Z), `fill`(#RRGGBB), `line: false`면 외곽선 없는 무늬 |
| `image` · `imageRect` | 같은 폴더의 그림 파일과 캔버스 위 [x, y, w, h] |
| `pivot` | 관절 [x, y] (생략하면 뼈대 기본값). 이 점을 중심으로 회전한다 |
| `z` | 그리는 순서 (생략하면 뼈대 기본값) |
| `face.eyes` | `dot` `round` `sparkle` `sleepy` `none` |
| `face.mouth` | `smile` `cat` `tiny` `none` |
| `face.eyeGap` `eyeSize` `eyeColor` `blush` | 눈 사이(캔버스 단위)·크기 배율·눈 색·볼터치 색 |

| 뼈대 | 부위 (기본 관절) |
|---|---|
| biped | body(50,84) head(50,66) armL(37,73) armR(63,73) legL(44,86) legR(56,86) earL(38,42) earR(62,42) tail(38,84) |
| quadruped | body(47,80) head(62,70) legFN(57,82) legFF(61,82) legBN(35,82) legBF(39,82) earL(62,50) earR(72,50) tail(29,72) |
| blob | body(50,96) head(50,70, 선택) armL(30,82) armR(70,82) earL earR tail |
| winged | biped 부위 + wingL(42,72) wingR(58,72) |

그리는 규칙: 부위는 **쉬는 자세**(팔은 옆으로 늘어뜨리고, 다리는 곧게 바닥까지)로 그리고, 관절 근처에서 부모 부위와 조금 겹치게 그립니다.

```bash
pawmit pet new "새싹감자" --skeleton biped
```

```bash
pawmit pet svg 새싹감자 -o potato.svg
```

## 스타일 (모든 펫)

```json
"style": {
  "personality": { "energy": 0.9, "laziness": 0.1 },
  "speech": { "prefix": "싹!", "suffix": "감", "emoji": "lots", "chattiness": 0.8, "polite": false, "tone": "느긋한 시골 할머니 말투" },
  "colors": { "body": "#FFE4EC" }
}
```

| 필드 | 설명 |
|---|---|
| `personality` | 성격 8가지 0…1: energy curiosity sociability artistry mischief appetite laziness tidiness. 빠진 항목은 seed 성격. 행동 분포가 이걸 따른다 |
| `speech.prefix` / `suffix` | 말 앞 말버릇 / 말끝 (혼잣말·대화 모두) |
| `speech.emoji` | `none` `some` `lots` |
| `speech.chattiness` | 혼잣말 빈도 0(조용)…1(수다) |
| `speech.polite` · `tone` | 대화 AI의 존댓말 여부·말투 설명 |
| `colors` | 기본 치비: body accent belly innerEar outline blush / 고양이: body stripe belly earInner outline eye nose cheek / 메이커 펫: `"원래색": "새색"` |

메이커 펫은 pet.json의 `style`로 같이 저장돼 내보낼 때 따라갑니다. 설정 → 펫 → 스타일에서 바꾼 값(config.json `petStyles`)이 그 위에 덮입니다.

## 빠른 시작 (기본 펫 변형)

```bash
pawmit pet new "Mint Bunny" --base tokki
```

`~/.pawmit/pets/mint-bunny/pet.json`이 만들어집니다. 바꾸고 싶은 필드만 덮어쓰세요.

```json
{ "kind": "chibi", "base": "tokki", "name": "Mint Bunny", "body": "#D8F5E4", "belly": "#F2FFF6", "interjection": "민트!" }
```

```bash
pawmit pet validate mint-bunny
```

```bash
pawmit pet preview mint-bunny
```

`preview`는 실행 중인 앱이 10가지 포즈를 그린 PNG 경로를 출력합니다. 설치하지 않은 폴더도 경로로 미리볼 수 있습니다.

```bash
pawmit pet use mint-bunny
```

## 종류

| kind | 설명 |
|---|---|
| `rig` | 메이커 펫. 부위 그림을 뼈대에 붙여 움직임 (위 설명) |
| `chibi` | 두 발로 걷는 치비. 부위(귀·꼬리·무늬)와 색을 조합 |
| `cat` | 네 발로 걷는 고양이. 털색 |
| (없음) | 그림 펫. 같은 폴더에 상태별 그림(`idle.gif`, `walk.png` …) 또는 Codex 스프라이트시트 |

## 공통 필드

| 필드 | 설명 |
|---|---|
| `name` | 이름 |
| `interjection` | 말버릇 (말풍선 앞에 붙음) |
| `base` | 기본 펫 id(`mongle` `banban` `tokki` `nalda` `bamtol` `haedal` `cat`). 그 정의 위에 이 파일의 필드를 덮어씀 |
| `scale` | 화면 크기 보정 0.5…1.5 (기본 치비 1, 고양이 0.86) |
| `description` | 설명 (표시용) |

## chibi

| 필드 | 값 |
|---|---|
| `ears` | `round` `cat` `bunny` `squirrel` `tiny` `none` |
| `tail` | `none` `cat` `puff` `fluffy` `otter` |
| `pattern` | `none` `hachiware` `chestnut` `muzzle` |
| `body` `accent` `innerEar` `belly` `outline` `blush` | `#RRGGBB`. `accent`는 무늬·꼬리 색, `belly`가 없으면 배 색 없음 |
| `blushAlpha` | 볼터치 진하기 0…1 (기본 0.85) |
| `headRX` `headRY` | 머리 가로·세로 반지름 (14…21, 11…17) |

## cat

| 필드 | 값 |
|---|---|
| `coat` | `cheese` `gray` `black` `white` `tuxedo` (바탕 털색) |
| `body` `stripe` `belly` `outline` `earInner` `nose` `eye` `pupil` `cheek` | `#RRGGBB`로 덮어쓰기. `"stripe": null`이면 줄무늬 없음 |

## 그림 펫

폴더에 상태 이름으로 그림을 넣습니다(GIF·APNG·PNG·WebP). `idle` 하나만 있어도 걷기·기쁨 같은 모션이 자동으로 붙습니다.
상태: idle, sit, walk, run, sleep, eat, dig, draw, play, pounce, alert, happy, sad, groom, think, drag, fall, wave.
`pet.json`에는 `name`, `facing`(`"left"`면 그림이 왼쪽을 봄)만 있으면 됩니다.
Codex 펫(`pet.json` + `spritesheet.webp`, 192×208 셀 8×9/8×11)도 그대로 넣으면 됩니다.

## 주고받기 (.pawmitpet)

```bash
pawmit pet export mint-bunny -o mint-bunny.pawmitpet
```

```bash
pawmit pet import mint-bunny.pawmitpet
```

앱에서는 설정 → 펫 → **지금 펫만… / 가져오기…**, 또는 Finder에서 `.pawmitpet` 파일을 더블클릭합니다. 가져오기 전에 이름·종류·그림 목록을 보여주고 확인을 받으며, 기존 펫을 덮어쓰지 않고 새 폴더에 풉니다.

파일은 JSON 하나입니다. 코드로 그리는 펫은 그대로 읽고 고칠 수 있습니다.

```json
{ "pawmitPet": 1, "name": "Mint Bunny",
  "pet": { "kind": "chibi", "base": "tokki", "body": "#D8F5E4" },
  "files": { "idle.gif": "<base64>" } }
```

가져올 때 막는 것: 그림(png·gif·webp·apng·jpg·heic) 외 파일, `../`·숨김 파일 이름, 읽을 수 없는 그림, 총 25MB·파일 64개 초과, 모르는 부위·잘못된 색.

### 전체 백업

**모두 내보내기…**(`pawmit pet export --all`)는 같은 확장자에 펫 여러 마리와 펫 설정을 담습니다. 가져오기는 파일 안의 `pawmitPets` 키로 백업인지 알아봅니다.

```json
{ "pawmitPets": 1,
  "pets": { "mint-bunny": { "pawmitPet": 1, "name": "Mint Bunny", "pet": { … } } },
  "settings": { "pet": "folder:mint-bunny", "friends": ["banban"], "catCoat": "cheese",
                "behaviorSeed": "1234", "petStyles": { "mongle": { "colors": { "body": "#FFFFFF" } } } } }
```

펫마다 위와 같은 검사를 거치고, 하나라도 걸리면 아무것도 쓰지 않습니다. 같은 폴더에 똑같은 펫이 있으면 건너뛰고, 다른 펫이 있으면 번호를 붙인 새 폴더에 풀며 설정의 펫 id도 그 폴더로 바꿉니다. 백업 전체는 400MB·200마리까지입니다.

## 새 부위 추가 (코드)

부위 하나가 파일 하나의 컴포넌트입니다.

| 위치 | 내용 |
|---|---|
| `Sources/Pawmit/Pet/Chibi/Ears.swift` | 귀 (`ChibiEarPart`) |
| `Sources/Pawmit/Pet/Chibi/Tails.swift` | 꼬리 (`ChibiTailPart`) |
| `Sources/Pawmit/Pet/Chibi/Patterns.swift` | 무늬·머리 모양 (`ChibiPatternPart`) |
| `Sources/Pawmit/Pet/Chibi/ChibiParts.swift` | 레지스트리 + 부위가 받는 정보(`ChibiPartContext`) |
| `Sources/Pawmit/Pet/Kit/InkKit.swift` | 치비·고양이 공통 그리기: 손그림 덩어리, 팔다리, 콩 발, 외곽선, 주름선, 그림자 |
| `Sources/PawmitCore/Pets/PetCatalog.swift` | 기본 펫 정의, 부위 id 목록, 검사 |
| `Sources/PawmitCore/Pets/RigSpec.swift` · `RigTemplates.swift` · `SVGPath.swift` | 메이커 펫 형식·뼈대 프리셋·기본 모양·SVG path |
| `Sources/Pawmit/Pet/Rig/` | 메이커 펫 포즈 엔진(RigPoser)·렌더러·얼굴 |
| `Sources/Pawmit/UI/Maker/` | 메이커 창·캔버스·AI 초안 |

1. 프로토콜을 따르는 struct를 만든다 (좌표: 발 중심 0,0, y 위쪽, 오른쪽을 보는 기준)
2. `ChibiParts`의 목록과 `PetCatalog.chibiEars`(·Tails·Patterns)에 같은 id를 추가한다
3. `pawmit debug sheet`(기본 펫 전부) 또는 `pawmit pet preview <펫>`으로 모든 포즈를 확인한다
4. 몸 프레임 캐시 영역을 벗어나지 않는지 `pawmit debug framecache bounds`로 확인한다 (`overflow`가 비어야 함)
