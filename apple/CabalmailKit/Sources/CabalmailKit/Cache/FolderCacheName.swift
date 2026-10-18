import Foundation

/// A folder path as one filesystem-safe path component, injectively.
///
/// The offline caches each name a folder's files after the folder. Both used
/// to build that name by replacing `/` and `.` with `_`, which is not
/// injective: `a/b` and `a_b` collapse to the same string, so the nested
/// folder never got a file of its own — it wrote into the flat sibling's, and
/// every visit replaced the other's snapshot wholesale, leaving neither
/// folder with a usable offline copy of itself (#1871, measured on stage with
/// `zzc/qq` and `zzc_qq`).
///
/// So the readable part is a lossy slug and the identity is a digest of the
/// exact path beside it. The digest also answers the case-insensitive
/// filesystem, where two folders differing only in case would otherwise share
/// a name although IMAP considers them distinct.
enum FolderCacheName {
    /// The suffix separator between the slug and the digest. A dot, so a
    /// name reads as `Archive_2024.1f0c3a9b74d2e5a6`.
    private static let separator: Character = "."
    /// Hex digits in the digest: 64 bits, written out.
    private static let digestLength = 16
    /// Scalars of the folder path kept in the slug. Long enough to stay
    /// recognisable in a container dump, short enough to leave room under
    /// the 255-byte name limit for the digest and any extension.
    private static let slugLimit = 64

    /// The path component for a folder, stable across launches and unique
    /// per distinct folder path.
    static func component(for folder: String) -> String {
        "\(slug(folder))\(separator)\(digest(folder))"
    }

    /// Whether a cache entry's base name was written by this scheme — the
    /// name with whatever extension the caller appends already stripped.
    ///
    /// Used to sweep the pre-#1871 names, which cannot be renamed into the
    /// new scheme: the old name is ambiguous by construction, so which folder
    /// its contents belong to is exactly what is not knowable. A cache is
    /// rebuildable, so the sweep drops them and the next online visit
    /// refills.
    static func isCurrent(base name: String) -> Bool {
        guard let digest = name.split(separator: separator).last, name.contains(separator) else {
            return false
        }
        return digest.count == digestLength && digest.allSatisfy(hexDigits.contains)
    }

    private static let hexDigits = Set("0123456789abcdef")

    /// Readable, lossy: ASCII letters, digits and `-` survive; everything
    /// else becomes `_`.
    private static func slug(_ folder: String) -> String {
        let mapped = folder.unicodeScalars.map { scalar -> Character in
            let character = Character(scalar)
            let kept = character.isASCII && (character.isLetter || character.isNumber || character == "-")
            return kept ? character : "_"
        }
        return String(mapped.prefix(slugLimit))
    }

    /// FNV-1a over the path's UTF-8, as 16 lowercase hex digits.
    ///
    /// Not `Hasher`: that one is seeded per process, so the same folder would
    /// take a different file on every launch. Not a cryptographic digest
    /// either — nothing here is adversarial, the job is only to tell two
    /// folder paths apart.
    private static func digest(_ folder: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in Array(folder.utf8) {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: digestLength - hex.count) + hex
    }
}
