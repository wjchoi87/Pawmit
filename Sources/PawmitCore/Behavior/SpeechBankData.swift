import Foundation

/// 펫 혼잣말 데이터(여는 말 × 본문 × 맺음)의 언어별 상수.
/// .strings 테이블이 아닌 코드 상수로 두는 이유: 배열·조합형 데이터라 키 관리가 어렵고,
/// 번들이 없는 CLI·테스트에서도 동일하게 동작해야 한다.
/// `{user}`는 말할 때(`Brain.say`) 설정의 호칭으로 바뀐다.
public struct SpeechBankData: Sendable {
    public let openings: [String]
    public let endings: [String]
    public let bodies: [Mood: [String]]

    public static func current() -> SpeechBankData { L10n.isKorean ? .ko : .en }

    public static let ko = SpeechBankData(
        openings: ["", "", "", "음…", "앗!", "헤헤", "있잖아,", "{user}!", "흐음,", "오!", "후후"],
        endings: ["", "", "~", "!", "…", " ♪", "!!", "~!"],
        bodies: [
            .calm: ["오늘 날씨 좋다", "여기 자리 좋네", "산책 최고", "조용하고 좋아", "바람이 솔솔 부는 기분", "천천히 가자",
                    "커피 한 잔 어때", "오늘도 무사히", "창밖 구경 중", "구름 모양이 웃겨", "느긋하게 가자", "숨 한 번 크게 쉬어봐",
                    "평화롭다", "따뜻한 햇살 같아", "오늘 하루도 수고했어"],
            .cheerful: ["신난다", "기분 최고", "오늘 뭔가 잘 될 것 같아", "춤추고 싶어", "랄랄라", "에너지 충전 완료",
                        "히히 즐거워", "뭐든 할 수 있어", "같이 놀자", "웃으면 복이 와", "좋은 일 생길 거야", "파이팅",
                        "반짝반짝", "콧노래가 절로 나와", "오늘의 나 귀엽다"],
            .curious: ["저건 뭐지", "이 창 뒤엔 뭐가 있을까", "냄새가 나는데", "궁금하다", "뭐 하고 있어", "이 버튼은 뭘까",
                       "저기 구석에 뭐 있나", "탐험하러 가볼까", "새로운 거 발견", "커서가 어디 갔지", "이건 처음 보는데",
                       "킁킁, 수상해", "흥미로운걸", "조사해봐야겠어", "누가 여기 다녀갔지"],
            .proud: ["나 좀 멋지지", "완벽해", "역시 나야", "칭찬해 줘", "이 정도는 기본이지", "봤어? 봤어?",
                     "천재인가 봐", "오늘의 MVP", "박수 쳐줘", "멋짐 폭발", "내가 해냈어", "이거 내 작품이야"],
            .sleepy: ["졸려", "하암", "눈이 감겨", "5분만 잘게", "꾸벅꾸벅", "포근한 데 없나", "낮잠 시간인가", "이불 덮고 싶다",
                      "자장자장", "꿈나라 가고 싶어"],
            .hungry: ["배고파", "꼬르륵", "밥 줘", "주먹밥 먹고 싶다", "간식 어디 있지", "생선 냄새 나", "뭐 먹을 거 없나",
                      "배에서 소리 나", "냠냠 하고 싶어", "밥 먹으면 힘 날 것 같아"],
            .affectionate: ["{user} 최고", "옆에 있어서 좋아", "쓰다듬어 줘", "보고 싶었어", "같이 있자", "항상 응원해",
                            "오늘도 고마워", "사랑해", "꼭 안아주고 싶어", "{user} 편이야", "무리하지 마", "물 꼭 마셔"],
            .grumpy: ["흥", "심심해", "놀아주지도 않고", "삐졌어", "칫", "나 혼자 놀 거야", "관심 좀 줘", "부루퉁",
                      "아무도 안 놀아줘", "치사해"],
            .coding: ["커밋은 자주자주", "테스트 돌려봤어", "버그 잡으러 가자", "오늘 배포 안 하지", "로그 한번 확인해 봐",
                      "에이전트 열일 중", "리뷰는 꼼꼼하게", "타입 에러 조심", "스택트레이스는 맛있어", "린트 통과",
                      "코드가 예쁘다", "리팩터링은 내일 하자", "주석은 왜를 적는 거래", "PR 올렸어", "빌드 초록불"],
            .playful: ["잡아봐라", "숨바꼭질 할래", "공 어디 갔어", "술래는 너야", "점프 점프", "빙글빙글",
                       "까꿍", "같이 뛰자", "누가 더 빠른지 해보자", "장난칠까", "몰래 다가가야지", "놀이 시간"],
        ])

    public static let en = SpeechBankData(
        openings: ["", "", "", "Hmm…", "Oh!", "Hehe", "Hey,", "{user}!", "Hm,", "Ooh!", "Hoho"],
        endings: ["", "", "~", "!", "…", " ♪", "!!", "~!"],
        bodies: [
            .calm: ["Nice weather today", "This spot is nice", "Walks are the best", "So calm and quiet",
                    "Feels like a gentle breeze", "Let's take it slow", "How about a coffee", "Another safe day",
                    "Just watching the window", "That cloud looks funny", "No need to hurry", "Take a deep breath",
                    "So peaceful", "Feels like warm sunshine", "Good work today"],
            .cheerful: ["So excited", "Feeling great", "Something good will happen today", "I wanna dance", "La la la",
                        "Energy fully charged", "Hehe this is fun", "I can do anything", "Let's play together",
                        "Smile and luck follows", "Good things are coming", "You got this", "Sparkle sparkle",
                        "Can't stop humming", "I'm extra cute today"],
            .curious: ["What's that", "What's behind this window", "I smell something", "So curious", "Whatcha doing",
                       "What does this button do", "What's in that corner", "Time to explore", "Found something new",
                       "Where did the cursor go", "Never seen this before", "Sniff sniff, suspicious", "Interesting",
                       "Better investigate", "Someone's been here"],
            .proud: ["Pretty cool, right", "Perfect", "That's so me", "Praise me", "That was easy", "Did you see? Did you?",
                     "Maybe I'm a genius", "Today's MVP", "Applause please", "Coolness overload", "I did it",
                     "This one's my masterpiece"],
            .sleepy: ["So sleepy", "Yaaawn", "Eyes closing", "Just five minutes", "Nodding off", "Need a cozy spot",
                      "Nap time already", "Wanna be under a blanket", "Sleepy bye", "Off to dreamland"],
            .hungry: ["I'm hungry", "Grrumble", "Food please", "Craving a rice ball", "Where are the snacks",
                      "I smell fish", "Anything to eat", "My tummy's talking", "Nom nom", "Food would fix this"],
            .affectionate: ["{user} is the best", "Glad you're here", "Pet me", "Missed you", "Stay with me",
                            "Always rooting for you", "Thanks for today", "Love you", "Wanna hug you tight",
                            "I'm on {user}'s side", "Don't overdo it", "Drink some water"],
            .grumpy: ["Hmph", "Bored", "Nobody plays with me", "I'm sulking", "Tch", "Fine, I'll play alone",
                      "Pay attention to me", "Pouty", "No one ever plays", "Not fair"],
            .coding: ["Commit early, commit often", "Did you run the tests", "Let's go squash bugs", "No deploys today, right",
                      "Check the logs", "Agents are grinding", "Review carefully", "Watch out for type errors",
                      "Stack traces are tasty", "Lint passed", "This code is pretty", "Refactor tomorrow",
                      "Comments should say why", "PR is up", "Build is green"],
            .playful: ["Catch me", "Wanna play hide and seek", "Where's the ball", "You're it", "Jump jump", "Spin spin",
                       "Peekaboo", "Let's run together", "Race you", "Feeling mischievous", "Gonna sneak up", "Playtime"],
        ])
}
