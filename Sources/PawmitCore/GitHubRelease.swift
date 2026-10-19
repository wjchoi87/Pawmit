import Foundation

/// 자동 업데이트를 GitHub Releases로: 설정의 업데이트 주소가 GitHub 저장소면
/// `releases/latest` API로 최신 태그·첨부 zip·릴리스 노트를 읽는다. 저장소가 public이어야 토큰 없이 읽힌다.
public enum GitHubRelease {
    /// 최신 Release 요약
    public struct Latest: Equatable, Sendable {
        /// 태그에서 앞의 v를 뗀 버전 (v0.2.1 → 0.2.1)
        public var version: String
        /// 설치용 zip 주소. 없으면 nil (소스 zip은 앱이 아니라서 안 쓴다)
        public var zipURL: String?
        public var notes: String?
    }

    /// 업데이트 주소가 GitHub 저장소 주소면 releases/latest API 주소로 바꿔 준다. 그 외엔 nil.
    /// 예) https://github.com/owner/repo, github.com/owner/repo, https://github.com/owner/repo/releases,
    ///     https://api.github.com/repos/owner/repo(/releases/latest)
    public static func latestAPI(for raw: String) -> URL? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = t.hasPrefix("github.com/") || t.hasPrefix("api.github.com/") ? "https://" + t : t
        guard let u = URL(string: full), u.scheme == "https", let host = u.host?.lowercased() else { return nil }
        let seg = u.path.split(separator: "/").map(String.init)
        let ownerRepo: (String, String)?
        if host == "api.github.com", seg.count >= 3, seg[0] == "repos" {
            ownerRepo = (seg[1], seg[2])
        } else if host == "github.com" || host == "www.github.com", seg.count >= 2 {
            ownerRepo = (seg[0], seg[1].hasSuffix(".git") ? String(seg[1].dropLast(4)) : seg[1])
        } else {
            ownerRepo = nil
        }
        guard let (owner, repo) = ownerRepo, isSafe(owner), isSafe(repo) else { return nil }
        return URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
    }

    /// releases/latest 응답 → 최신 Release. 태그가 없거나 JSON이 아니면 nil
    public static func parseLatest(_ data: Data) -> Latest? {
        guard let v = JSONValue.parse(data), let tag = v["tag_name"]?.string, !tag.isEmpty else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let assets: [(name: String, url: String)] = (v["assets"]?.array ?? []).compactMap { a in
            guard let name = a["name"]?.string, let url = a["browser_download_url"]?.string else { return nil }
            return (name, url)
        }
        // Pawmit 이름이 붙은 zip 우선, 없으면 첫 .zip. 디버그 심볼(dSYM) zip은 앱이 아니라서 뺀다
        let zips = assets.filter {
            let n = $0.name.lowercased()
            return n.hasSuffix(".zip") && !n.contains("dsym") && !n.contains("symbols")
        }
        let zip = zips.first { $0.name.lowercased().contains("pawmit") } ?? zips.first
        let body = v["body"]?.string
        return Latest(version: version, zipURL: zip?.url, notes: body?.isEmpty == true ? nil : body)
    }

    /// GitHub 사용자·저장소 이름에 쓰이는 글자만 (주소 조작 방지)
    static func isSafe(_ s: String) -> Bool {
        (1...100).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
            && s != "." && s != ".."
    }
}
