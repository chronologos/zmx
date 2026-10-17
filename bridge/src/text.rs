//! Turning bytes a program chose into text that is safe to hand on.

/// Standard-alphabet base64, padding optional. Strict otherwise: anything unexpected is `None`.
pub fn base64(s: &str) -> Option<Vec<u8>> {
    let body = s.trim_end_matches('=').as_bytes();
    if s.len() - body.len() > 2 || body.len() % 4 == 1 {
        return None;
    }
    let mut out = Vec::with_capacity(body.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &b in body {
        let v = match b {
            b'A'..=b'Z' => b - b'A',
            b'a'..=b'z' => b - b'a' + 26,
            b'0'..=b'9' => b - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    // Leftover bits must be zero, so each text has exactly one encoding.
    (acc == 0).then_some(out)
}

/// Characters that draw nothing themselves but change how their neighbours are drawn or read:
/// controls, direction overrides, joiners, line separators. A status line has no use for them,
/// and they are how one pane's text gets to impersonate another's.
fn invisible(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{061C}' | '\u{200B}'..='\u{200F}' | '\u{2028}'..='\u{202E}'
            | '\u{2060}'..='\u{2069}' | '\u{FEFF}' | '\u{FFF9}'..='\u{FFFB}'
            | '\u{E0000}'..='\u{E007F}')
}

/// Drop invisible characters and cut to `max` characters. Empty becomes `None`.
pub fn clean(s: &str, max: usize) -> Option<String> {
    let out: String = s.chars().filter(|&c| !invisible(c)).take(max).collect();
    let out = out.trim();
    (!out.is_empty()).then(|| out.to_owned())
}

/// base64 → UTF-8 → `clean`.
pub fn decode(s: &str, max: usize) -> Option<String> {
    clean(std::str::from_utf8(&base64(s)?).ok()?, max)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_accepts_padded_and_bare() {
        assert_eq!(base64("aGk=").unwrap(), b"hi");
        assert_eq!(base64("aGk").unwrap(), b"hi");
        assert_eq!(base64("UGxhbg==").unwrap(), b"Plan");
        assert_eq!(base64("").unwrap(), b"");
        assert_eq!(base64("4pyz").unwrap(), "✳".as_bytes());
    }

    #[test]
    fn base64_rejects_everything_else() {
        for bad in ["-", "a", "aGk-", "aG k", "aGk===", "aGl=", "a=Gk", "aGk_"] {
            assert_eq!(base64(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn clean_strips_what_cannot_be_seen() {
        assert_eq!(clean("a\u{202E}b\u{1b}[31mc\u{200B}\n", 99).unwrap(), "ab[31mc");
        assert_eq!(clean("  héllo  ", 99).unwrap(), "héllo");
        assert_eq!(clean("héllo", 2).unwrap(), "hé");
        assert_eq!(clean("\u{2066}\u{2069}", 99), None);
    }

    #[test]
    fn decode_needs_utf8() {
        assert_eq!(decode("aGk=", 9).unwrap(), "hi");
        assert_eq!(decode("/w==", 9), None);
    }
}
