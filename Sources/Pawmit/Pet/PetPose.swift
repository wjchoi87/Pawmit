import CoreGraphics
import Foundation
import PawmitCore

/// 펫이 지금 하고 있는 동작. 기본 펫 렌더러와 커스텀 스프라이트 팩이 모두 이 값을 보고 그린다.
enum PetAnim: String, CaseIterable, Codable {
    case idle, sit, walk, run, sleep, eat, dig, draw, play, pounce, alert, happy, sad, groom, think, drag, fall, wave
}

enum Facing: Int {
    case left = -1, right = 1
    var sign: CGFloat { CGFloat(rawValue) }
}

/// 렌더링 한 프레임에 필요한 펫 상태 스냅샷.
struct PetPose {
    var anim: PetAnim = .idle
    var facing: Facing = .right
    /// 현재 anim이 시작된 뒤 지난 시간(초)
    var animTime: TimeInterval = 0
    /// 전역 시간(초). 꼬리 흔들기·숨쉬기처럼 anim과 무관하게 이어지는 움직임용
    var clock: TimeInterval = 0
    /// 걷기 주기 위상 (이동 거리에 비례)
    var walkPhase: CGFloat = 0
    /// 지면에서 뜬 높이 (점프)
    var hop: CGFloat = 0
    /// 1 = 보통, <1 웅크림, >1 늘어남
    var stretch: CGFloat = 1
    /// 눈이 바라보는 방향 (-1...1)
    var look: CGVector = .zero
    /// 눈 깜빡임 진행도 0(뜸)...1(감음)
    var blink: CGFloat = 0
    /// 입에 문 크레용 색 (낙서 중)
    var crayon: CGColor? = nil
    /// 물걸레 들고 있음 (청소 중)
    var mop = false
    /// 들어가기/나오기 연출용 크기·투명도
    var scale: CGFloat = 1
    var opacity: CGFloat = 1
    /// 행동 조합기가 얹는 절차적 모션 (팔·기울기·표정)
    var motion: MotionSpec? = nil
    var motionTime: TimeInterval = 0
    /// 시스템 상태 반영: 더위(CPU) 0...1, 통통(디스크) 0...1
    var heat: CGFloat = 0
    var chubby: CGFloat = 0
}
