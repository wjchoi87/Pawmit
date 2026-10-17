import Foundation

/// 사용자가 정한 말(호칭 등) 뒤에 붙는 조사 고르기: 받침이 있으면 앞의 것, 없으면 뒤의 것.
/// 한글이 아닌 글자로 끝나면(영문 이름 등) 받침 없는 쪽을 쓴다.
public enum Korean {
    public static func hasBatchim(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: .whitespaces).unicodeScalars.last,
              (0xAC00...0xD7A3).contains(last.value) else { return false }
        return (last.value - 0xAC00) % 28 != 0
    }

    /// 예) particle("선배님", "이", "가") → "선배님이", particle("보스", "이라고", "라고") → "보스라고"
    public static func particle(_ word: String, _ withBatchim: String, _ without: String) -> String {
        word + (hasBatchim(word) ? withBatchim : without)
    }
}
