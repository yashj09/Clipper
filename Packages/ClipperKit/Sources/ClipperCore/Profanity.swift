import Foundation

/// Common profanity, for muting or bleeping it in drafts. English only for now.
public enum Profanity {
    /// Lowercased, letters only.
    public static let english: Set<String> = [
        "fuck", "fucks", "fucked", "fucker", "fuckers", "fucking", "fuckin", "motherfucker", "motherfuckers", "motherfucking",
        "shit", "shits", "shitty", "shitting", "bullshit", "horseshit",
        "ass", "asses", "asshole", "assholes", "jackass", "dumbass",
        "bitch", "bitches", "bitching", "bitchy",
        "bastard", "bastards",
        "damn", "damned", "dammit", "goddamn", "goddamned", "goddammit",
        "crap", "crappy",
        "dick", "dicks", "dickhead",
        "piss", "pissed", "pissing",
        "cock", "cocks", "prick", "pricks", "wanker", "wankers", "bollocks", "bugger",
        "douche", "douchebag", "twat", "cunt", "cunts",
    ]

    /// Whether a transcribed word ("Fucking," or "shit!") is profane in the transcript's locale.
    public static func isProfane(_ word: String, locale: String) -> Bool {
        guard Locale.Language(identifier: locale).languageCode == .english else { return false }
        return english.contains(String(word.lowercased().filter(\.isLetter)))
    }

    /// The word with every letter after the first as an asterisk, punctuation kept: "Fucking," → "F******,".
    public static func masked(_ word: String) -> String {
        var seenLetter = false
        return String(word.map { c in
            guard c.isLetter else { return c }
            defer { seenLetter = true }
            return seenLetter ? "*" : c
        })
    }
}
